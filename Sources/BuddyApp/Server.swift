import Foundation
import Darwin
import BuddyCore

/// One client socket: a hook process or an editor extension.
@MainActor
final class Connection {
    enum Role { case unknown, hook, ext }
    let fd: Int32
    /// The first message decides the role; a hook connection carries one hook message only.
    var role: Role = .unknown
    let peerPid: pid_t?
    /// Taken at accept: names the connecting process even if it exits and its pid is reused.
    let peerToken: audit_token_t?
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()
    private var chunk = [UInt8](repeating: 0, count: 65536)
    var isClosed = false
    var onLine: ((Data, Connection) -> Void)?
    var onClose: ((Connection) -> Void)?

    init(fd: Int32) {
        self.fd = fd
        self.peerPid = PeerCheck.peerPid(fd)
        self.peerToken = PeerCheck.peerToken(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        UnixSocket.setSendTimeout(fd, seconds: 1)
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        let fd = fd
        src.setCancelHandler { Darwin.close(fd) }  // the source may still read until cancel completes
        source = src
        src.resume()
    }

    private func readAvailable() {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else { close(); return }
        do {
            for line in try buffer.append(Data(chunk[0..<n])) {
                onLine?(line, self)
                if isClosed { return }
            }
        } catch {
            log.error("Dropping connection: \(String(describing: error), privacy: .public)")
            close()
        }
    }

    /// False if the peer is gone; the connection is then closed.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !isClosed else { return false }
        do { try UnixSocket.writeAll(fd, data); return true } catch {
            log.error("Socket write failed: \(String(describing: error), privacy: .public)")
            close()
            return false
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let source { source.cancel() } else { Darwin.close(fd) }
        source = nil
        onClose?(self)
    }
}

/// Identity, so `PendingReplies` can key held hooks by connection.
extension Connection: Hashable {
    nonisolated static func == (a: Connection, b: Connection) -> Bool { a === b }
    nonisolated func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

@MainActor
final class SocketServer {
    static let maxConnections = 64
    let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var paused = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    var onMessage: ((WireMessage, Connection) -> Void)?
    var onClose: ((Connection) -> Void)?

    init(path: String) { self.path = path }

    func start() throws {
        listenFD = try UnixSocket.listen(path)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptOne() } }
        acceptSource = src
        src.resume()
        log.info("Listening on socket")
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else {
            let e = errno
            log.error("accept failed: \(e)")
            if e == EMFILE || e == ENFILE { pauseAccepting() }
            return
        }
        guard connections.count < Self.maxConnections, PeerCheck.peerUid(fd) == getuid() else {
            log.error("Connection refused (limit or other user)")
            Darwin.close(fd)
            return
        }
        let conn = Connection(fd: fd)
        conn.onLine = { [weak self] line, c in
            do { self?.onMessage?(try WireMessage.decode(line), c) } catch {
                log.error("Bad line, dropping connection")
                c.close()
            }
        }
        conn.onClose = { [weak self] c in
            self?.connections[ObjectIdentifier(c)] = nil
            self?.onClose?(c)
        }
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
        // A client that never says who it is gets 5 s.
        Task { @MainActor [weak conn] in
            try? await Task.sleep(for: .seconds(5))
            if let conn, conn.role == .unknown { conn.close() }
        }
    }

    /// Closes the listener and every open connection, and removes the socket file.
    func stop() {
        // libdispatch traps when a suspended source is released.
        if paused { acceptSource?.resume(); paused = false }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        connections.values.forEach { $0.close() }
        unlink(path)
    }

    /// Out of file descriptors: stop accepting for a second instead of spinning.
    private func pauseAccepting() {
        guard !paused, let src = acceptSource else { return }
        src.suspend()
        paused = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.paused else { return }
            self.paused = false
            self.acceptSource?.resume()
        }
    }
}

import Foundation
import Darwin

public struct SocketError: Error, CustomStringConvertible {
    public let call: String
    public let code: Int32
    public var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
}

public enum UnixSocket {
    /// `BUDDY_SOCKET` overrides the path only when `allowOverride` (debug builds: tests, extension development).
    public static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment, allowOverride: Bool) -> String {
        if allowOverride, let p = env["BUDDY_SOCKET"], !p.isEmpty { return p }
        let home = env["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/Buddy/buddy.sock"
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError(call: "path", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var addr = try address(path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else { let e = errno; close(fd); throw SocketError(call: "connect", code: e) }
        return fd
    }

    /// Creates the folder if needed. It must be a real directory owned by this user; mode becomes 0700.
    public static func prepareDirectory(_ dir: String) throws {
        if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw SocketError(call: "mkdir", code: errno) }
        var st = stat()
        guard lstat(dir, &st) == 0 else { throw SocketError(call: "lstat", code: errno) }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { throw SocketError(call: "socket dir owner/type", code: EPERM) }
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SocketError(call: "open dir", code: errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw SocketError(call: "fchmod", code: errno) }
    }

    /// One instance only: holds an exclusive flock on `<dir>/buddy.lock` while the returned fd is open.
    public static func acquireLock(_ dir: String) throws -> Int32 {
        let fd = open(dir + "/buddy.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SocketError(call: "open lock", code: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { let e = errno; close(fd); throw SocketError(call: "flock", code: e) }
        return fd
    }

    /// Binds a listening socket with mode 0600. Call `prepareDirectory` and `acquireLock` first.
    public static func listen(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        // No umask change: it is process-wide. The 0700 folder already blocks other users before the chmod.
        let rc = try withAddress(path) { bind(fd, $0, $1) }
        guard rc == 0 else { let e = errno; close(fd); throw SocketError(call: "bind", code: e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; close(fd); throw SocketError(call: "listen", code: e) }
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError(call: "write", code: errno)
                }
                off += n
            }
        }
    }

    /// Blocks until one full line arrives. Returns nil on EOF before a newline.
    public static func readLine(_ fd: Int32) throws -> Data? {
        var buf = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw SocketError(call: "read", code: errno) }
            if n == 0 { return nil }
            if let line = try buf.append(Data(chunk[0..<n])).first { return line }
        }
    }

    public static func setSendTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads and discards until the peer closes or the receive timeout fires.
    public static func drainUntilClose(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { continue }
            if n < 0 && errno == EINTR { continue }
            return
        }
    }
}

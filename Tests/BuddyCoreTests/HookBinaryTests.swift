import Foundation
import Darwin
import Testing
@testable import BuddyCore

/// Integration tests: spawn the built buddy-hook binary.
@Suite(.serialized) struct HookBinaryTests {
    static var binary: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/buddy-hook")
    }

    static func tempSocketPath() -> String {
        // sockaddr_un paths are short; use /tmp, not the long scratch temp dir.
        "/tmp/buddy-t-\(UUID().uuidString.prefix(8)).sock"
    }

    func run(stdin: String, socket: String) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = Self.binary
        p.environment = ["BUDDY_SOCKET": socket, "CLAUDE_PID": "\(getpid())", "HOME": "/nonexistent"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        return (p, output)
    }

    /// accept() with a 3 s limit, so a broken hook fails the test instead of hanging it.
    func acceptWithin3s(_ server: Int32) throws -> Int32 {
        var pfd = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 3000) == 1 else { throw SocketError(call: "poll", code: ETIMEDOUT) }
        return accept(server, nil, nil)
    }

    @Test func failOpenWithoutApp() throws {
        let start = Date()
        let (p, out) = try run(stdin: #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
                               socket: Self.tempSocketPath())
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func garbageInputSendsNothing() throws {
        let path = Self.tempSocketPath()
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        let (p, out) = try run(stdin: "not json", socket: path)
        let conn = try acceptWithin3s(server)
        defer { close(conn) }
        #expect(try UnixSocket.readLine(conn) == nil)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    func roundTrip(output: JSONValue) throws -> (Int32, Data, HookMessage?) {
        let path = Self.tempSocketPath()
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        let (p, out) = try run(stdin: #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, socket: path)
        let conn = try acceptWithin3s(server)
        defer { close(conn) }
        var got: HookMessage?
        if let line = try UnixSocket.readLine(conn), case .hook(let m) = try WireMessage.decode(line) {
            got = m
            try UnixSocket.writeAll(conn, WireMessage.encode(ReplyMessage(id: m.id, output: output)))
        }
        p.waitUntilExit()
        return (p.terminationStatus, out.fileHandleForReading.readDataToEndOfFile(), got)
    }

    @Test func blockingReplyPrinted() throws {
        let (status, out, msg) = try roundTrip(output: HookOutput.allow())
        #expect(status == 0)
        #expect(msg?.wantsReply == true)
        #expect(msg?.env.claudePid == getpid())
        #expect(try JSONDecoder().decode(JSONValue.self, from: out) == HookOutput.allow())
    }

    @Test func deferReplyPrintsNothing() throws {
        let (status, out, _) = try roundTrip(output: .null)
        #expect(status == 0)
        #expect(out.isEmpty)
    }

    @Test func nonBlockingHookWaitsForAppToClose() throws { // S1
        let path = Self.tempSocketPath()
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        let (p, _) = try run(stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#, socket: path)
        let conn = try acceptWithin3s(server)
        let line = try UnixSocket.readLine(conn)
        #expect(line != nil)
        usleep(300_000)
        #expect(p.isRunning)  // still alive, so the app can check its path
        close(conn)
        let start = Date()
        p.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(p.terminationStatus == 0)
    }
}

import Foundation
import Darwin
import Testing
@testable import BuddyCore

private final class BundleMarker {}

private let builtHook: URL? = {
    let url = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("buddy-hook")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

/// Integration tests: spawn the built buddy-hook binary, found next to the test bundle.
@Suite(.serialized, .enabled(if: builtHook != nil, "buddy-hook is not built next to the test bundle"))
struct HookBinaryTests {
    static var binary: URL { builtHook ?? URL(fileURLWithPath: "/nonexistent/buddy-hook") }

    static func tempSocketPath() -> String {
        // sockaddr_un paths are short; use /tmp, not the long scratch temp dir.
        "/tmp/buddy-t-\(UUID().uuidString.prefix(8)).sock"
    }

    func run(stdin: String, socket: String, env: [String: String] = [:]) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = Self.binary
        p.environment = ["BUDDY_SOCKET": socket, "CLAUDE_PID": "\(getpid())", "HOME": "/nonexistent"].merging(env) { $1 }
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
        // Generous: a busy test machine is slow to start a process, but the hook never waits here.
        #expect(Date().timeIntervalSince(start) < 3)
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

    /// `answer` builds the line the fake app sends back for the hook message.
    func roundTrip(output: JSONValue) throws -> (Int32, Data, HookMessage?) {
        try roundTrip { try WireMessage.encode(ReplyMessage(id: $0.id, output: output)) }
    }

    func roundTrip(answer: (HookMessage) throws -> Data) throws -> (Int32, Data, HookMessage?) {
        let path = Self.tempSocketPath()
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        let (p, out) = try run(stdin: #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, socket: path)
        let conn = try acceptWithin3s(server)
        defer { close(conn) }
        var got: HookMessage?
        if let line = try UnixSocket.readLine(conn), case .hook(let m) = try WireMessage.decode(line) {
            got = m
            try UnixSocket.writeAll(conn, answer(m))
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

    @Test func wrongReplyIdPrintsNothing() throws {
        let (status, out, msg) = try roundTrip { _ in try WireMessage.encode(ReplyMessage(id: "someone-else", output: HookOutput.allow())) }
        #expect(msg != nil)
        #expect(status == 0)
        #expect(out.isEmpty)
    }

    @Test func nonReplyKindPrintsNothing() throws {
        let (status, out, _) = try roundTrip { _ in try WireMessage.encode(AckMessage(reqId: "x", ok: true, error: nil)) }
        #expect(status == 0)
        #expect(out.isEmpty)
    }

    @Test func nonBlockingHookWaitsForAppToClose() throws {
        let path = Self.tempSocketPath()
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        // A 10 s cap (DEBUG builds only): an exit within 3 s can only come from the close.
        let (p, _) = try run(stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#, socket: path, env: ["BUDDY_HOOK_WAIT_MS": "10000"])
        let conn = try acceptWithin3s(server)
        let line = try UnixSocket.readLine(conn)
        #expect(line != nil)
        #expect(p.isRunning)  // still alive, so the app can check its path
        close(conn)
        let start = Date()
        p.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(p.terminationStatus == 0)
    }
}

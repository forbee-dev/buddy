import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct RequestAndPromptTests {
    @Test func replacedRequestCannotBeAnsweredWithOldId() { // H1
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "old", extra: ["tool_name": "Bash"]))
        let c = s.apply(hook("PermissionRequest", id: "new", extra: ["tool_name": "Bash"]))
        #expect(c.staleRequests == ["old"])
        let oldOK = s.resolve(sid: "s1", requestId: "old")
        #expect(!oldOK)
        #expect(s.sessions["s1"]?.pending?.id == "new")
    }

    @Test func promptGuardRefusals() { // H2
        let fg = ProcInfo.Status(pgid: 10, tpgid: 10, stopped: false)
        #expect(PromptGuard.refusal(state: .done, status: fg) == nil)
        #expect(PromptGuard.refusal(state: .idle, status: fg) == nil)
        #expect(PromptGuard.refusal(state: .working, status: fg) != nil)
        #expect(PromptGuard.refusal(state: .needsPermission, status: fg) != nil)
        #expect(PromptGuard.refusal(state: .done, status: nil) != nil)
        #expect(PromptGuard.refusal(state: .done, status: .init(pgid: 10, tpgid: 11, stopped: false)) != nil)
        #expect(PromptGuard.refusal(state: .done, status: .init(pgid: 10, tpgid: 10, stopped: true)) != nil)
        let me = ProcInfo.status(of: getpid())
        #expect(me != nil && me?.stopped == false)
        #expect(ProcInfo.status(of: 999_999) == nil)
    }

    @Test func promptSanitized() { // L5
        #expect(PromptGuard.sanitize("a\nb\r\nc\td\u{1B}[31m\u{7F}e\u{0}\rf\u{9B}g") == "a\nb\nc\td[31me\nfg")
        let big = PromptGuard.sanitize(String(repeating: "é", count: 40_000))
        #expect(big.utf8.count <= PromptGuard.maxBytes && big.utf8.count > PromptGuard.maxBytes - 2)
    }
}

@Suite struct DisplayTests {
    @Test func revealsHiddenCharacters() { // M3
        #expect(DisplayText.reveal("rm\u{202E}fdp.exe") == "rm\\u{202E}fdp.exe")
        #expect(DisplayText.reveal("a\u{200B}b\u{FEFF}") == "a\\u{200B}b\\u{FEFF}")
        #expect(DisplayText.reveal("line1\n\tline2") == "line1\n\tline2")
    }

    @Test func detailShowsAllKeysCommandFirst() { // M3
        let input = json(#"{"command":"ls","description":"List","dangerouslyDisableSandbox":true,"timeout":5}"#)
        let d = PermissionDisplay.detail(input)
        #expect(d.hasPrefix("command:\nls"))
        #expect(d.contains("dangerouslyDisableSandbox:\ntrue"))
        #expect(d.contains("timeout:\n5"))
        #expect(!d.contains("List"))
        #expect(PermissionDisplay.sandboxDisabled(input))
        #expect(PermissionDisplay.detail(json(#"{"command":"ls"}"#)) == "ls")
        #expect(PermissionDisplay.stats("a\nb\nc") == (3, 5))
    }

    @Test func frameIndexNeverNegativeOrPastEnd() {
        #expect(AnimClock.frameIndex(elapsed: -0.5, fps: 8, count: 4, loop: true).index == 0)
        #expect(AnimClock.frameIndex(elapsed: .nan, fps: 8, count: 4, loop: false).index == 0)
        #expect(AnimClock.frameIndex(elapsed: 0.6, fps: 8, count: 4, loop: true).index == 0)
        #expect(AnimClock.frameIndex(elapsed: 0.3, fps: 8, count: 4, loop: true).index == 2)
        let once = AnimClock.frameIndex(elapsed: 10, fps: 8, count: 4, loop: false)
        #expect(once.index == 3 && once.finished)
        #expect(!AnimClock.frameIndex(elapsed: 0.3, fps: 8, count: 4, loop: false).finished)
        #expect(AnimClock.frameIndex(elapsed: 1, fps: 8, count: 0, loop: true).index == 0)
        #expect(AnimClock.frameIndex(elapsed: 1e300, fps: 8, count: 3, loop: true).index < 3)
    }

    @Test func payloadSlimmed() throws { // L6
        let big = String(repeating: "x", count: 20_000)
        let post = try HookPayload.decode(Data(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"ls"},"tool_response":{"stdout":"secret"},"prompt":"hi"}"#.utf8))
        #expect(post["tool_use_id"]?.string == "t1")
        #expect(post["tool_response"] == nil && post["prompt"] == nil)
        #expect(post["tool_input"] == json(#"{"command":"ls"}"#))
        #expect(post["tool_name"]?.string == "Bash")
        let stop = try HookPayload.decode(JSONEncoder().encode(JSONValue.object(["hook_event_name": "Stop", "last_assistant_message": .string(big)])))
        #expect((stop["last_assistant_message"]?.string?.count ?? 0) <= 16_001)
        let perm = json(#"{"hook_event_name":"PermissionRequest","tool_input":{"command":"ls","x":"y"},"permission_suggestions":[]}"#)
        #expect(try HookPayload.decode(JSONEncoder().encode(perm))["tool_input"] == perm["tool_input"])
    }
}

@Suite struct RoutingTests {
    @Test func inboxSocketMustMatchClaudePid() { // M2
        #expect(InboxClient.validatedSocket("/tmp/cc-socks/42.sock", claudePid: 42) == "/private/tmp/cc-socks/42.sock")
        #expect(InboxClient.validatedSocket("/private/tmp/cc-socks/42.sock", claudePid: 42) != nil)
        #expect(InboxClient.validatedSocket("/tmp/cc-socks/43.sock", claudePid: 42) == nil)
        #expect(InboxClient.validatedSocket("/tmp/evil/42.sock", claudePid: 42) == nil)
        #expect(InboxClient.validatedSocket("/tmp/cc-socks/42.sock", claudePid: nil) == nil)
    }

    @Test func routingFieldsOnlyFromSessionStart() { // M2
        var s = SessionStore()
        var start = hook("SessionStart", pid: 42)
        start.env.messagingSocket = "/tmp/cc-socks/42.sock"
        start.env.messagingToken = "t"
        _ = s.apply(start)
        #expect(s.sessions["s1"]?.env.messagingSocket == "/private/tmp/cc-socks/42.sock")
        var hijack = hook("Stop", pid: 66)
        hijack.env.messagingSocket = "/tmp/cc-socks/66.sock"
        let c = s.apply(hijack)
        #expect(c.sessionId == nil)
        #expect(s.sessions["s1"]?.env.claudePid == 42 && s.sessions["s1"]?.state == .starting)
        var later = hook("Stop", pid: 42)
        later.env.tty = "ttys999"
        _ = s.apply(later)
        #expect(s.sessions["s1"]?.env.tty == "ttys001")
        var bad = hook("SessionStart", session: "s2", pid: 50)
        bad.env.messagingSocket = "/tmp/other.sock"
        bad.env.messagingToken = "t"
        _ = s.apply(bad)
        #expect(s.sessions["s2"]?.env.messagingSocket == nil && s.sessions["s2"]?.env.messagingToken == nil)
    }

    @Test func socketFileChecks() throws { // M2
        let dir = PeerCheck.resolved(NSTemporaryDirectory()) + "/bsf-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sock = dir + "/a.sock"
        let fd = try UnixSocket.listen(sock)
        defer { close(fd) }
        try InboxClient.checkSocketFile(sock)
        symlink(sock, dir + "/link.sock")
        #expect(throws: SocketError.self) { try InboxClient.checkSocketFile(dir + "/link.sock") }
        FileManager.default.createFile(atPath: dir + "/plain", contents: Data())
        #expect(throws: SocketError.self) { try InboxClient.checkSocketFile(dir + "/plain") }
    }

    @Test func hiddenSessionsNeverHeld() { // M5
        var s = SessionStore()
        var m = hook("PermissionRequest", id: "r", extra: ["tool_name": "Bash"])
        m.env.attended = "0"
        _ = s.apply(m)
        #expect(s.sessions["s1"]?.pending == nil)
    }

    @Test func permissionDeniedClearsCard() {
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r", extra: ["tool_name": "Bash"]))
        let c = s.apply(hook("PermissionDenied", extra: ["tool_name": "Bash"]))
        #expect(c.staleRequests == ["r"] && s.sessions["s1"]?.pending == nil)
    }

    @Test func sessionLimitAndNoPidTTL() { // L1
        var s = SessionStore()
        for i in 0..<(SessionStore.maxSessions + 5) { _ = s.apply(hook("SessionStart", session: "s\(i)", pid: Int32(1000 + i))) }
        #expect(s.sessions.count == SessionStore.maxSessions)
        var t = SessionStore()
        let then = Date(timeIntervalSince1970: 0)
        _ = t.apply(hook("SessionStart", session: "nopid", pid: nil), now: then)
        #expect(t.reap(isAlive: { _ in true }, now: then.addingTimeInterval(60)).ended.isEmpty)
        #expect(t.reap(isAlive: { _ in true }, now: then.addingTimeInterval(SessionStore.noPidTTL + 1)).ended == ["nopid"])
    }
}

@Suite(.serialized) struct PeerAndDirTests {
    @Test func peerCheckSeesOwnProcess() throws { // M1
        let path = "/tmp/buddy-pc-\(UUID().uuidString.prefix(6)).sock"
        let server = try UnixSocket.listen(path)
        defer { close(server); unlink(path) }
        let client = try UnixSocket.connect(path)
        defer { close(client) }
        let conn = accept(server, nil, nil)
        defer { close(conn) }
        #expect(PeerCheck.peerPid(client) == getpid())
        #expect(PeerCheck.peerUid(client) == getuid())
        let me = try #require(PeerCheck.path(of: getpid()))
        let peer = PeerCheck.peerPid(client).flatMap(PeerCheck.path(of:))
        let name = (me as NSString).lastPathComponent
        #expect(HookTrust.serverAllowed(peerUid: PeerCheck.peerUid(client), ownUid: getuid(), peerPath: peer, selfPath: me, names: [name]))
        #expect(!HookTrust.serverAllowed(peerUid: PeerCheck.peerUid(client), ownUid: getuid(), peerPath: peer, selfPath: me, names: ["ls"]))
    }

    @Test func hookPeerPolicy() { // M2
        let hookPath = "/bin/ls"
        let real = PeerCheck.resolved(hookPath)
        #expect(PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [7, 8], claudePid: 7))
        #expect(PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [9, 7], claudePid: 7))
        #expect(!PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [9, 8, 7], claudePid: 7))
        #expect(!PeerCheck.hookPeerAllowed(peerPath: "/usr/bin/node", expectedHookPath: hookPath, ancestors: [7], claudePid: 7))
        #expect(!PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [7], claudePid: nil))
    }

    @Test func socketDirAndSingleInstanceLock() throws { // L2
        let base = "/tmp/buddy-dir-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: base); try? FileManager.default.removeItem(atPath: base + "-link") }
        try UnixSocket.prepareDirectory(base)
        var st = stat()
        lstat(base, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        symlink(base, base + "-link")
        #expect(throws: SocketError.self) { try UnixSocket.prepareDirectory(base + "-link") }
        let a = try UnixSocket.acquireLock(base)
        #expect(throws: SocketError.self) { _ = try UnixSocket.acquireLock(base) }
        close(a)
        let b = try UnixSocket.acquireLock(base)
        close(b)
    }

    @Test func socketOverrideOnlyWhenAllowed() { // M1
        let env = ["BUDDY_SOCKET": "/tmp/x.sock", "HOME": "/Users/u"]
        #expect(UnixSocket.defaultPath(env: env, allowOverride: true) == "/tmp/x.sock")
        #expect(UnixSocket.defaultPath(env: env, allowOverride: false) == "/Users/u/Library/Application Support/Buddy/buddy.sock")
    }
}

@Suite struct PayloadLimitTests {
    /// The tool name is model-chosen text: clipped at 200 characters like the hook does.
    @Test func toolNameIsClipped() throws {
        let long = String(repeating: "x", count: 5000)
        let p = try HookPayload.decode(Data(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"\#(long)"}"#.utf8))
        #expect(p["tool_name"]?.string == String(repeating: "x", count: 200) + "…")
        #expect(HookPayload.limits["tool_name"] == 200)
    }
}

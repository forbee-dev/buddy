import CoreGraphics
import Foundation
import Testing
@testable import BuddyCore

@Suite struct RemoteAuthTests {
    let token = String(repeating: "ab", count: 32)
    let ssh = ["/usr/bin/ssh"]
    let remote = RemoteInfo(host: "devbox", user: "tiago")

    func check(uid: uid_t? = getuid(), path: String? = "/usr/bin/ssh", sent: String?, expected: String?, remote: RemoteInfo?? = nil,
               equals: (String, String) -> Bool = RemoteAuth.constantTimeEquals) -> RemoteAuth.Verdict {
        RemoteAuth.check(peerUid: uid, peerPath: path, allowedClients: ssh, sent: sent, expected: expected,
                         remote: remote ?? self.remote, equals: equals)
    }

    @Test func accepts() { #expect(check(sent: token, expected: token) == .ok) }

    @Test func rejectsWrongOrMissingToken() {
        #expect(check(sent: String(repeating: "cd", count: 32), expected: token) == .badToken)
        #expect(check(sent: String(token.dropLast()), expected: token) == .badToken)
        #expect(check(sent: nil, expected: token) == .noToken)
        #expect(check(sent: "", expected: token) == .noToken)
        #expect(check(sent: token, expected: nil) == .notConfigured)
    }

    @Test func rejectsNonSSHPeerAndOtherUser() {
        #expect(check(path: "/bin/zsh", sent: token, expected: token) == .notSSH)
        #expect(check(path: "/opt/homebrew/bin/ssh", sent: token, expected: token) == .notSSH)
        #expect(check(path: nil, sent: token, expected: token) == .notSSH)
        #expect(check(uid: getuid() + 1, sent: token, expected: token) == .otherUser)
        #expect(check(uid: nil, sent: token, expected: token) == .otherUser)
        #expect(check(sent: token, expected: token, remote: .some(nil)) == .noRemote)
    }

    @Test func usesTheConstantTimeCompare() {
        var calls = 0
        _ = check(sent: token, expected: token) { a, b in calls += 1; return RemoteAuth.constantTimeEquals(a, b) }
        #expect(calls == 1)
        #expect(check(sent: token, expected: token) { _, _ in false } == .badToken)
    }

    @Test func constantTimeEquals() {
        #expect(RemoteAuth.constantTimeEquals(token, token))
        #expect(!RemoteAuth.constantTimeEquals("abc", "abd"))
        #expect(!RemoteAuth.constantTimeEquals("ab", "abc"))
        #expect(!RemoteAuth.constantTimeEquals("abcd", "abc"))
        #expect(!RemoteAuth.constantTimeEquals("", "a"))
    }

    @Test func newTokenIs256BitHex() {
        let a = RemoteAuth.newToken(), b = RemoteAuth.newToken()
        #expect(RemoteAuth.isValidToken(a) && a != b)
        #expect(!RemoteAuth.isValidToken(token.uppercased()))
        #expect(!RemoteAuth.isValidToken(token + "0"))
    }

    @Test func mainSocketRejectsRemoteFields() {
        let local = hook("Stop")
        var withRemote = local
        withRemote.remote = remote
        var withToken = local
        withToken.token = token
        #expect(RemoteAuth.mainSocketAccepts(local))
        #expect(!RemoteAuth.mainSocketAccepts(withRemote))
        #expect(!RemoteAuth.mainSocketAccepts(withToken))
    }

    @Test func wireCarriesRemoteFields() throws {
        let line = #"{"kind":"hook","id":"1","wantsReply":false,"payload":{},"env":{"claudePid":7,"ssh":true},"remote":{"host":"devbox","user":"t"},"token":"x"}"#
        guard case .hook(let h) = try WireMessage.decode(Data(line.utf8)) else { Issue.record("not a hook"); return }
        #expect(h.remote == RemoteInfo(host: "devbox", user: "t") && h.token == "x" && h.env.claudePid == 7)
        #expect(!String(decoding: try WireMessage.encode(hook("Stop")), as: UTF8.self).contains("remote"))
    }

    @Test func localizeDropsSecretsAndRemotePaths() throws {
        let raw = HookMessage(id: "r1", wantsReply: false,
                              payload: json(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/home/t/api","prompt":"secret","transcript_path":"/Users/me/.claude/x.jsonl"}"#),
                              env: HookEnv(claudePid: 4242, shellPid: 1, tty: "ttys001", messagingSocket: "/tmp/cc-socks/4242.sock",
                                           messagingToken: "t", attended: "1", entrypoint: "claude-desktop"),
                              remote: RemoteInfo(host: "dev\u{202E}box\n", user: String(repeating: "u", count: 100)), token: token)
        let (m, origin) = try RemoteAuth.localize(raw, sshPid: 900)
        #expect(m.token == nil)
        #expect(m.env == HookEnv(attended: "1"))
        #expect(m.payload["prompt"] == nil && m.payload["transcript_path"] == nil && m.payload["cwd"]?.string == "/home/t/api")
        #expect(origin == RemoteOrigin(host: #"dev\u{202E}box"#, user: String(repeating: "u", count: 64) + "…", sshPid: 900, claudePid: 4242))
    }

    @Test func displaySanitizing() {
        #expect(RemoteInfo.display("a\tb\nc") == "a b c")
        #expect(RemoteInfo.display("x\u{200B}y") == #"x\u{200B}y"#)
        #expect(RemoteInfo.display("   ") == "?")
        #expect(RemoteInfo.display(String(repeating: "h", count: 300)).count == 65)
    }
}

@Suite struct RemoteSessionTests {
    let origin = RemoteOrigin(host: "devbox", user: "t", sshPid: 900, claudePid: 4242)

    func remoteHook(_ event: String, session: String = "r1", extra: [String: JSONValue] = [:]) -> HookMessage {
        var p: [String: JSONValue] = ["session_id": .string(session), "hook_event_name": .string(event), "cwd": "/home/t/api"]
        p.merge(extra) { $1 }
        return HookMessage(id: UUID().uuidString, wantsReply: event == "PermissionRequest", payload: .object(p), env: HookEnv(attended: "1"))
    }

    @Test func remoteSessionLooks() throws {
        var store = SessionStore()
        _ = store.apply(remoteHook("SessionStart"), origin: origin, isAlive: { _ in true })
        let s = try #require(store.sessions["r1"])
        #expect(s.projectName == "devbox:api")
        #expect(s.lookKey == "devbox:/home/t/api")
        #expect(s.mascotKey == "ssh-900-4242")
        #expect(s.env.claudePid == nil && s.transcriptPath == nil)
    }

    @Test func localAndRemoteNeverMix() {
        var store = SessionStore()
        _ = store.apply(remoteHook("SessionStart"), origin: origin, isAlive: { _ in true })
        #expect(store.apply(hook("Stop", session: "r1"), isAlive: { _ in true }).sessionId == nil)
        var other = origin
        other.sshPid = 901
        #expect(store.apply(remoteHook("Stop"), origin: other, isAlive: { _ in true }).sessionId == nil)
        #expect(store.sessions["r1"]?.state == .starting)
        _ = store.apply(hook("SessionStart", session: "l1"), isAlive: { _ in true })
        #expect(store.apply(remoteHook("Stop", session: "l1"), origin: origin, isAlive: { _ in true }).sessionId == nil)
        #expect(store.sessions["l1"]?.remote == nil)
    }

    @Test func remoteSessionsAreCapped() {
        var store = SessionStore()
        for i in 0..<(SessionStore.maxRemoteSessions + 2) {
            var o = origin
            o.claudePid = Int32(5000 + i)
            _ = store.apply(remoteHook("SessionStart", session: "r\(i)"), origin: o, isAlive: { _ in true })
        }
        #expect(store.sessions.count == SessionStore.maxRemoteSessions)
        _ = store.apply(hook("SessionStart", session: "local"), isAlive: { _ in true })
        #expect(store.sessions["local"] != nil)
    }

    @Test func reapFollowsTheSSHClient() {
        var store = SessionStore()
        _ = store.apply(remoteHook("SessionStart"), origin: origin, isAlive: { _ in true })
        #expect(store.reap(isAlive: { $0 == 900 }).ended.isEmpty)
        #expect(store.reap(isAlive: { $0 == 4242 }).ended == ["r1"])
    }

    @Test func clearRekeysOnTheSameConnection() {
        var store = SessionStore()
        _ = store.apply(remoteHook("SessionStart"), origin: origin, isAlive: { _ in true })
        _ = store.apply(remoteHook("SessionEnd", extra: ["reason": "clear"]), origin: origin, isAlive: { _ in true })
        _ = store.apply(remoteHook("SessionStart", session: "r2"), origin: origin, isAlive: { _ in true })
        #expect(store.sessions.keys.sorted() == ["r2"])
        #expect(store.sessions["r2"]?.mascotKey == "ssh-900-4242")
    }

    @Test func nextPromptRefusedForRemote() {
        #expect(PromptGuard.refusal(state: .done, status: nil, remote: true) == PromptGuard.remoteRefusal)
        #expect(PromptGuard.refusal(state: .done, status: .init(pgid: 1, tpgid: 1, stopped: false), remote: true) == PromptGuard.remoteRefusal)
        #expect(PromptGuard.refusal(state: .done, status: .init(pgid: 1, tpgid: 1, stopped: false)) == nil)
    }

    /// Fake tree: Code (200) → Code Helper (300) → zsh (400, an extension terminal) → bash (450) → ssh (500).
    @Test func jumpTargetFromSSHAncestry() {
        let chain: [Int32] = [500, 450, 400, 300, 200]
        let editor = RemoteJump.env(ancestors: chain, tty: "ttys009", bundleId: "com.microsoft.VSCode", extShells: [400, 999])
        #expect(editor?.claudePid == 500 && editor?.shellPid == 400 && editor?.tty == "ttys009")
        #expect(editor.map { TerminalApp.detect($0) } == .vscode)
        let iterm = RemoteJump.env(ancestors: chain, tty: "ttys003", bundleId: "com.googlecode.iterm2", extShells: [])
        #expect(iterm?.shellPid == 450)
        #expect(iterm.map { TerminalApp.detect($0) } == .iterm)
        #expect(RemoteJump.env(ancestors: [], tty: nil, bundleId: nil, extShells: []) == nil)
    }
}

@Suite struct RemoteInstallTests {
    let token = String(repeating: "0f", count: 32)

    @Test(arguments: ["devbox", "user@devbox", "dev-box.example.com", "u_1@10.0.0.2"])
    func validHosts(_ h: String) { #expect(RemoteInstall.validHost(h)) }

    @Test(arguments: ["", "-oProxyCommand=x", "a@-b", "dev box", "a;b", "a$(b)", "`a`", "a@b@c", "@b", "a@", "a'b", "a\"b", "a|b", "ä", "a/b"])
    func invalidHosts(_ h: String) { #expect(!RemoteInstall.validHost(h)) }

    @Test func command() {
        let env = "/Users/me/Library/Application Support/Buddy/remote-install.env"
        let c = RemoteInstall.command(host: "devbox", envFile: env, script: "/Applications/Buddy.app/Contents/Resources/remote/install.sh")
        #expect(c == "cat '/Users/me/Library/Application Support/Buddy/remote-install.env' '/Applications/Buddy.app/Contents/Resources/remote/install.sh' | ssh devbox 'bash -s'")
        #expect(RemoteInstall.command(host: "x;y", envFile: env, script: "/a") == nil)
        #expect(RemoteInstall.command(host: "-oProxyCommand=x", envFile: env, script: "/a") == nil)
        #expect(RemoteInstall.command(host: "x", envFile: "/it's.env", script: "/b'c")
                == #"cat '/it'\''s.env' '/b'\''c' | ssh x 'bash -s'"#)
    }

    @Test func envFileIsPrivateNewAndHoldsOnlyTheToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-env-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try RemoteInstall.writeEnvFile(token: token, dir: dir)
        #expect(path == dir + "/remote-install.env")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "BUDDY_TOKEN=\(token)\n")
        var st = stat()
        #expect(lstat(path, &st) == 0 && st.st_mode & 0o777 == 0o600 && st.st_uid == getuid())
        #expect(lstat(dir, &st) == 0 && st.st_mode & 0o777 == 0o700)
        // A second write replaces the file; a symlink planted at the path is replaced, never followed.
        let target = dir + "/target"
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        unlink(path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        _ = try RemoteInstall.writeEnvFile(token: token, dir: dir)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
        #expect(lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG)
        #expect(throws: (any Error).self) { try RemoteInstall.writeEnvFile(token: "nope", dir: dir) }
    }

    @Test func sshConfigQuotesTheLocalPath() {
        #expect(RemoteInstall.sshConfig(host: "me@devbox", remoteHome: "/home/me", localSocket: "/Users/me/Library/Application Support/Buddy/remote.sock")
                == "Host devbox\n  RemoteForward /home/me/.buddy/buddy.sock \"/Users/me/Library/Application Support/Buddy/remote.sock\"")
    }
}

/// buddy-hook-remote must slim payloads like `HookPayload` (docs/protocol.md).
@Suite struct RemoteHookParityTests {
    static let hookPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/remote/buddy-hook-remote").path

    static let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    func pythonSlim(_ payload: String) throws -> JSONValue {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let code = """
        import importlib.machinery, importlib.util, json, sys
        loader = importlib.machinery.SourceFileLoader("hook", sys.argv[1])
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hook", loader))
        loader.exec_module(m)
        print(json.dumps(m.slim(json.loads(sys.stdin.read()))))
        """
        p.arguments = ["-I", "-B", "-c", code, Self.hookPath]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test(.enabled(if: hasPython, "/usr/bin/python3 is not installed"), arguments: [
        #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"\#(String(repeating: "x", count: 300))","content":"no","run_in_background":true},"tool_response":{"backgroundTaskId":"b1","stdout":"no"},"extra":1}"#,
        #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/a","content":"whole"},"permission_suggestions":[{"type":"addRules"}]}"#,
        #"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"\#(String(repeating: "m", count: 16_100))","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"no"},5]}"#,
        #"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>bd-1_x</task-id><status>completed</status>"}"#,
        #"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"just a prompt"}"#,
        #"{"session_id":"s","hook_event_name":"SubagentStart","agent_id":"\#(String(repeating: "a", count: 150))","agent_type":"Explore","cwd":5}"#,
    ])
    func sameAsSwift(_ payload: String) throws {
        #expect(try pythonSlim(payload) == (try HookPayload.decode(Data(payload.utf8))))
    }
}

@Suite struct TagLayoutTests {
    @Test func widthsAndDistance() {
        #expect(TagLayout.tagWidth(text: 40.2, max: 120) == 53)
        #expect(TagLayout.tagWidth(text: 300, max: 120) == 120)
        #expect(TagLayout.footprint(sprite: 64, tag: 90) == 90)
        #expect(TagLayout.footprint(sprite: 64, tag: 30) == 64)
        #expect(TagLayout.minDistance(90, 70) == 86)
    }

    func tag(_ id: String, x: CGFloat, w: CGFloat, y: CGFloat = 0, p: Int = 1) -> TagLayout.Tag {
        TagLayout.Tag(id: id, rect: CGRect(x: x - w / 2, y: y, width: w, height: 20), priority: p)
    }

    @Test func clearTagsStay() {
        #expect(TagLayout.resolve([tag("a", x: 100, w: 80), tag("b", x: 200, w: 80)]).isEmpty)
        // Same x, other row (a pinned buddy higher up).
        #expect(TagLayout.resolve([tag("a", x: 100, w: 80), tag("b", x: 100, w: 80, y: 50)]).isEmpty)
    }

    @Test func lowerPriorityIsCut() {
        // "web-app" at 260 and "docs-site" at 330, both 90 wide: 70 apart, room for docs-site is 2 * (70 - 45 - 6) = 38 → stacked.
        #expect(TagLayout.resolve([tag("web", x: 260, w: 90, p: 2), tag("docs", x: 330, w: 90, p: 1)]) == ["docs": .stack])
        // 100 apart: room 2 * (100 - 45 - 6) = 98 ≥ 90 → fits. 80 apart: room 58 → cut to 58.
        #expect(TagLayout.resolve([tag("web", x: 260, w: 90, p: 2), tag("docs", x: 360, w: 90, p: 1)]).isEmpty)
        #expect(TagLayout.resolve([tag("web", x: 260, w: 90, p: 1), tag("docs", x: 340, w: 90, p: 2)]) == ["web": .truncate(58)])
    }

    @Test func tieGoesToLowerId() {
        #expect(TagLayout.resolve([tag("b", x: 100, w: 80), tag("a", x: 110, w: 80)]) == ["b": .stack])
    }
}

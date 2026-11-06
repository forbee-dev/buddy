import Foundation
import Darwin
import Testing
@testable import BuddyCore

/// `host`: the plugin's process, the pid itself by default. `tty: nil` is the service without a TUI.
private func openCodeHook(_ event: String, session: String, pid: Int32?, host: Int32? = nil, tty: String? = "ttys001",
                          extra: [String: JSONValue] = [:]) -> HookMessage {
    var m = hook(event, session: session, pid: pid, extra: extra)
    m.env.agent = HookEnv.openCode
    m.env.hostPid = host ?? pid
    m.env.tty = tty
    return m
}

@Suite struct OpenCodeStoreTests {
    @Test func sessionsOfOneProcessStaySeparate() {
        var s = SessionStore()
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 500))
        _ = s.apply(openCodeHook("SessionStart", session: "ses_b", pid: 500))
        #expect(s.sessions.count == 2)
        #expect(s.sessions["ses_a"]?.mascotKey == "ses_a")
        #expect(s.sessions["ses_a"]?.agentName == "OpenCode")
        // A Claude session on the same pid never takes an OpenCode one over.
        _ = s.apply(hook("SessionStart", session: "claude", pid: 500))
        #expect(s.sessions.count == 3)
        #expect(s.sessions["claude"]?.agentName == "Claude")
    }

    @Test func theServiceMovesToTheTUIFoundLater() {
        var s = SessionStore()
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 500, tty: nil), isAlive: { _ in true })
        _ = s.apply(openCodeHook("UserPromptSubmit", session: "ses_a", pid: 77, host: 500), isAlive: { _ in true })
        #expect(s.sessions["ses_a"]?.state == .working)
        #expect(s.sessions["ses_a"]?.env.claudePid == 77)
        #expect(s.sessions["ses_a"]?.env.tty == "ttys001")
        // An event without a TUI search comes from the host: accepted, the routing stays.
        _ = s.apply(openCodeHook("Stop", session: "ses_a", pid: 500, tty: nil), isAlive: { _ in true })
        #expect(s.sessions["ses_a"]?.state == .done)
        #expect(s.sessions["ses_a"]?.env.claudePid == 77)
        // Another live pid of another host is refused.
        _ = s.apply(openCodeHook("UserPromptSubmit", session: "ses_a", pid: 88, host: 600), isAlive: { _ in true })
        #expect(s.sessions["ses_a"]?.state == .done)
        #expect(s.sessions["ses_a"]?.env.claudePid == 77)
        // Claude Code keeps its rule: another live pid is refused.
        _ = s.apply(hook("SessionStart", session: "c", pid: 500), isAlive: { _ in true })
        _ = s.apply(hook("UserPromptSubmit", session: "c", pid: 77), isAlive: { _ in true })
        #expect(s.sessions["c"]?.state == .starting)
    }

    @Test func agentsNeverTakeOverEachOther() {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", session: "c", pid: 500), isAlive: { _ in false })
        let card = hook("PermissionRequest", session: "c", pid: 500, extra: ["tool_name": "Bash"])
        _ = s.apply(card, isAlive: { _ in false })
        // The old pid is dead, and still an OpenCode message cannot take the Claude session, its routing, or its card.
        for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"] {
            _ = s.apply(openCodeHook(event, session: "c", pid: 77, extra: ["tool_name": "Bash"]), isAlive: { _ in false })
        }
        #expect(s.sessions["c"]?.env.agent == nil)
        #expect(s.sessions["c"]?.env.claudePid == 500)
        #expect(s.sessions["c"]?.pending?.id == card.id)
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 77), isAlive: { _ in false })
        _ = s.apply(hook("UserPromptSubmit", session: "ses_a", pid: 77), isAlive: { _ in false })
        #expect(s.sessions["ses_a"]?.state == .starting)
        #expect(s.sessions["ses_a"]?.env.agent == HookEnv.openCode)
    }

    @Test func resumeInANewTUIRevivesTheSession() {
        var s = SessionStore()
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 77, host: 500), isAlive: { _ in true })
        _ = s.reap(isAlive: { $0 != 77 })
        #expect(s.sessions["ses_a"]?.state == .ended)
        // A late event that is not a new turn or a card does not bring the buddy back.
        _ = s.apply(openCodeHook("PostToolUse", session: "ses_a", pid: 500, tty: nil), isAlive: { $0 != 77 })
        #expect(s.sessions["ses_a"]?.state == .ended)
        _ = s.apply(openCodeHook("UserPromptSubmit", session: "ses_a", pid: 88, host: 500), isAlive: { $0 != 77 })
        #expect(s.sessions["ses_a"]?.state == .working)
        #expect(s.sessions["ses_a"]?.env.claudePid == 88)
    }

    @Test func aSilentSessionOfTheServiceEnds() {
        var s = SessionStore()
        let t0 = Date()
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 500, tty: nil), now: t0)
        _ = s.apply(openCodeHook("SessionStart", session: "ses_t", pid: 77, host: 500), now: t0)
        _ = s.apply(openCodeHook("SessionStart", session: "ses_p", pid: 500, tty: nil), now: t0)
        _ = s.apply(openCodeHook("PermissionRequest", session: "ses_p", pid: 500, tty: nil, extra: ["tool_name": "edit"]), now: t0)
        #expect(s.reap(isAlive: { _ in true }, now: t0 + 600).ended.isEmpty)
        // Only the silent session on the service ends: a TUI pid is reaped by its death, a card waits for the user.
        #expect(s.reap(isAlive: { _ in true }, now: t0 + SessionStore.openCodeNoTTYTTL + 1).ended == ["ses_a"])
        // Its next turn revives it.
        _ = s.apply(openCodeHook("UserPromptSubmit", session: "ses_a", pid: 500, tty: nil), now: t0 + 4000, isAlive: { _ in true })
        #expect(s.sessions["ses_a"]?.state == .working)
    }

    @Test func subagentSessionAndQuestionCard() {
        var s = SessionStore()
        _ = s.apply(openCodeHook("SessionStart", session: "ses_a", pid: 500))
        _ = s.apply(openCodeHook("SubagentStart", session: "ses_a", pid: 500, extra: ["agent_id": "ses_k", "agent_type": "explore"]))
        #expect(s.sessions["ses_a"]?.subagents["ses_k"] != nil)
        let input = json(#"{"questions":[{"question":"Which?","header":"Q","options":[{"label":"A"}],"multiSelect":false}]}"#)
        _ = s.apply(openCodeHook("PermissionRequest", session: "ses_a", pid: 500,
                                 extra: ["tool_name": "AskUserQuestion", "tool_use_id": "frm_1", "tool_input": input]))
        #expect(s.sessions["ses_a"]?.state == .asking)
        #expect(s.sessions["ses_a"]?.pending?.kind == .question)
    }
}

@Suite struct OpenCodeEnvTests {
    @Test func agentMarkerRoundTrips() throws {
        let env = HookEnv(claudePid: 1, agent: HookEnv.openCode)
        let back = try JSONDecoder().decode(HookEnv.self, from: JSONEncoder().encode(env))
        #expect(back.agent == "opencode")
        let old = try JSONDecoder().decode(HookEnv.self, from: Data(#"{"claudePid":1}"#.utf8))
        #expect(old.agent == nil)
    }

    @Test func procArgsParsing() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { buf += $0 }
        buf += Array("/bin/opencode".utf8) + [0, 0, 0]
        buf += Array("opencode".utf8) + [0] + Array("--x".utf8) + [0]
        buf += Array("TERM_PROGRAM=iTerm.app".utf8) + [0] + Array("A=b=c".utf8) + [0] + Array("NOEQ".utf8) + [0, 0]
        buf += Array("executable_path=/bin/opencode".utf8) + [0]
        #expect(ProcInfo.parseEnvironment(buf, keys: ["TERM_PROGRAM", "A", "NOEQ"]) == ["TERM_PROGRAM": "iTerm.app", "A": "b=c"])
        #expect(ProcInfo.parseEnvironment(buf, keys: ["A"]) == ["A": "b=c"])
        #expect(ProcInfo.parseEnvironment([1, 0], keys: ["A"]) == nil)
    }

    @Test func ownProcessLookups() {
        #expect(ProcInfo.allPids().contains(getpid()))
        #expect(ProcInfo.cwd(of: getpid()) == PeerCheck.resolved(FileManager.default.currentDirectoryPath))
        #expect(ProcInfo.environment(of: getpid(), keys: ["PATH"]) != nil)
    }

    @Test func findAndCheckATUI() {
        let own = getpid()
        // A host with a tty is the TUI itself; without one, nothing runs this binary from a terminal in a missing folder.
        #expect(OpenCodeTUI.find(host: own, cwd: "/nonexistent-buddy") == (ProcInfo.tty(of: own) == nil ? nil : own))
        #expect(OpenCodeTUI.find(host: Int32.max, cwd: "/") == nil)
        #expect(!OpenCodeTUI.isTUI(own, of: own, cwd: FileManager.default.currentDirectoryPath))
        #expect(!OpenCodeTUI.isTUI(own, of: own, cwd: nil))
    }

    @Test func pickTheOneTUIInTheFolder() {
        typealias C = OpenCodeTUI.Candidate
        let tui = C(pid: 10, ppid: 5, tty: "ttys001", cwd: "/p")
        #expect(OpenCodeTUI.pick([tui, C(pid: 11, ppid: 1, tty: nil, cwd: "/p"), C(pid: 12, ppid: 6, tty: "ttys002", cwd: "/q")], cwd: "/p") == 10)
        // Its own helper with the same binary does not count.
        #expect(OpenCodeTUI.pick([tui, C(pid: 13, ppid: 10, tty: "ttys001", cwd: "/p")], cwd: "/p") == 10)
        // Two TUIs in one folder: Buddy cannot tell which one.
        #expect(OpenCodeTUI.pick([tui, C(pid: 14, ppid: 7, tty: "ttys003", cwd: "/p")], cwd: "/p") == nil)
        #expect(OpenCodeTUI.pick([], cwd: "/p") == nil)
    }
}

@Suite struct OpenCodeInstallerTests {
    let hookPath = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"
    let template = OpenCodeInstaller.marker + "\nconst HOOK = \"__BUDDY_HOOK_PATH__\";\n"

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-oc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func pluginFolder() {
        #expect(OpenCodeInstaller.pluginURL(env: [:], home: "/h").path == "/h/.config/opencode/plugins/buddy.js")
        #expect(OpenCodeInstaller.pluginURL(env: ["XDG_CONFIG_HOME": "/x"], home: "/h").path == "/x/opencode/plugins/buddy.js")
        #expect(OpenCodeInstaller.pluginURL(env: ["XDG_CONFIG_HOME": "/x", "OPENCODE_CONFIG_DIR": "/oc"], home: "/h").path == "/oc/plugins/buddy.js")
        #expect(OpenCodeInstaller.pluginURL(env: ["OPENCODE_CONFIG_DIR": ""], home: "/h").path == "/h/.config/opencode/plugins/buddy.js")
    }

    @Test func hookPathIsAStringLiteral() {
        let out = OpenCodeInstaller.render(template: template, hookPath: "/A \"b\"\\c/buddy-hook")
        #expect(out?.contains(#"const HOOK = "/A \"b\"\\c/buddy-hook";"#) == true)
        #expect(OpenCodeInstaller.render(template: "const HOOK = \"__BUDDY_HOOK_PATH__\";", hookPath: hookPath) == nil)
    }

    @Test func bundledTemplateRenders() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("opencode-plugin/buddy.js"), encoding: .utf8)
        let out = try #require(OpenCodeInstaller.render(template: text, hookPath: hookPath))
        #expect(out.contains("const HOOK = \"\(hookPath)\";"))
    }

    @Test func installStatusAndRemove() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plugins/buddy.js")
        let other = dir.appendingPathComponent("plugins/other.js")
        #expect(OpenCodeInstaller.status(url: url, template: template, hookPath: hookPath) == .missing)
        #expect(try OpenCodeInstaller.install(url: url, template: template, hookPath: hookPath) == .written(backup: nil))
        try Data("export default {}".utf8).write(to: other)
        #expect(OpenCodeInstaller.status(url: url, template: template, hookPath: hookPath) == .current)
        #expect(try OpenCodeInstaller.install(url: url, template: template, hookPath: hookPath) == .unchanged)
        let moved = "/Moved/Buddy.app/Contents/MacOS/buddy-hook"
        #expect(OpenCodeInstaller.status(url: url, template: template, hookPath: moved) == .outdated)
        #expect(try OpenCodeInstaller.install(url: url, template: template, hookPath: moved) == .written(backup: nil))
        #expect(OpenCodeInstaller.status(url: url, template: template, hookPath: moved) == .current)
        #expect(try OpenCodeInstaller.remove(url: url) == .written(backup: nil))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try OpenCodeInstaller.remove(url: url) == .unchanged)
        #expect(throws: OpenCodeInstallError.badTemplate) { try OpenCodeInstaller.install(url: url, template: nil, hookPath: hookPath) }
    }

    @Test func neverTouchesAFileThatIsNotBuddys() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("buddy.js")
        let theirs = Data("// someone else's buddy\n".utf8)
        try theirs.write(to: url)
        #expect(OpenCodeInstaller.status(url: url, template: template, hookPath: hookPath) == .foreign)
        #expect(throws: OpenCodeInstallError.notOurs(url.path)) { try OpenCodeInstaller.install(url: url, template: template, hookPath: hookPath) }
        #expect(try OpenCodeInstaller.remove(url: url) == .unchanged)
        #expect(FileManager.default.contents(atPath: url.path) == theirs)
    }
}

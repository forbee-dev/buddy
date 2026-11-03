import Foundation
import Testing
@testable import BuddyCore

@Suite struct MultiLinePromptTests {
    @Test func newlinesKeptAndControlsDropped() {
        #expect(PromptGuard.sanitize("one\ntwo\r\nthree\rfour") == "one\ntwo\nthree\nfour")
        // No ESC (C0) or CSI (C1) survives, so the text cannot end a bracketed paste.
        #expect(PromptGuard.sanitize("x\u{1B}[201~y\u{9B}201~z") == "x[201~y201~z")
        #expect(PromptGuard.sanitize("\t\n") == "\t\n")
    }

    @Test func inboxKeepsNewlinesInJSON() throws {
        let data = try InboxClient.lines(token: nil, text: PromptGuard.sanitize("a\nb"))
        let msg = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(msg["message"]?["content"]?.string == "a\nb")
    }
}

@Suite struct NotificationActionTests {
    @Test func actionsMapToAnswers() {
        #expect(NotificationActions.decide(.deny, requestId: "r1", pendingId: "r1", enabled: true) == .answer(HookOutput.deny("")))
        #expect(NotificationActions.decide(.review, requestId: "r1", pendingId: "r1", enabled: true) == .open)
        #expect(NotificationActions.decide(.answer, requestId: "r1", pendingId: "r1", enabled: true) == .open)
        #expect(NotificationActions.decide(.open, requestId: "r1", pendingId: "r1", enabled: true) == .open)
    }

    /// Review H1: Allow needs the card. The old `allow` id from an older notification only opens it.
    @Test func noNotificationPathAllows() {
        #expect(NotificationAction(rawValue: "allow") == nil)
        let actions: [NotificationAction] = [.open, .deny, .review, .answer, .reply]
        for a in actions {
            for (req, pending) in [("r1", "r1"), ("old", "r1"), ("r1", nil)] as [(String, String?)] {
                for enabled in [true, false] {
                    let out = NotificationActions.decide(a, requestId: req, pendingId: pending, enabled: enabled, text: "go")
                    if case .answer(let o) = out { #expect(o == HookOutput.deny(""), "\(a)") }
                }
            }
        }
    }

    @Test func staleOrMissingRequestIdRefused() {
        #expect(NotificationActions.decide(.deny, requestId: "old", pendingId: "new", enabled: true) == .alreadyAnswered)
        #expect(NotificationActions.decide(.deny, requestId: "old", pendingId: nil, enabled: true) == .alreadyAnswered)
        #expect(NotificationActions.decide(.deny, requestId: nil, pendingId: "r1", enabled: true) == .alreadyAnswered)
    }

    @Test func actionsNeedTheSetting() {
        #expect(NotificationActions.decide(.deny, requestId: "r1", pendingId: "r1", enabled: false) == .open)
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: false, text: "go") == .open)
    }

    @Test func textReplyGoesThroughPromptGuard() {
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: true,
                                           text: "run tests\r\nthen \u{1B}[2Jcommit") == .sendPrompt("run tests\nthen [2Jcommit"))
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: true, text: " \n\u{7}") == .open)
    }

    @Test func subagentLabelIsMarkedRevealedAndClipped() {
        let note = NotificationActions.subagentNote("Fix\u{202E}gnp.exe\nnow " + String(repeating: "x", count: 60))
        #expect(note.hasPrefix("Claude says: Fix\\u{202E}gnp.exe now "))
        #expect(!note.contains("\u{202E}") && !note.contains("\n"))
        #expect(note.count == "Claude says: ".count + 40 && note.hasSuffix("…"))
    }
}

@Suite struct PaletteOrderTests {
    private func store() -> SessionStore {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 0)
        func at(_ sec: Double) -> Date { t0.addingTimeInterval(sec) }
        _ = s.apply(hook("Stop", session: "done1", pid: 1), now: at(1))
        _ = s.apply(hook("UserPromptSubmit", session: "work", pid: 2), now: at(2))
        _ = s.apply(hook("PermissionRequest", session: "perm", id: "p", pid: 3, extra: ["tool_name": "Bash",
            "tool_input": json(#"{"command":"swift test\nopen x","description":"Run"}"#)]), now: at(5))
        _ = s.apply(hook("PermissionRequest", session: "ask", id: "q", pid: 4, extra: ["tool_name": "AskUserQuestion",
            "tool_input": json(#"{"questions":[{"question":"Pick a library?\nmore","options":[]}]}"#)]), now: at(3))
        _ = s.apply(hook("SessionStart", session: "idle", pid: 5), now: at(9))
        _ = s.apply(hook("Notification", session: "idle", pid: 5, extra: ["notification_type": "idle_prompt"]), now: at(9))
        _ = s.apply(hook("SessionEnd", session: "gone", pid: 6, extra: ["reason": "other"]), now: at(9))
        return s
    }

    @Test func waitingFirstThenDoneWorkingIdle() {
        let rows = PaletteOrder.sorted(Array(store().sessions.values))
        #expect(rows.map(\.id) == ["ask", "perm", "done1", "work", "idle"])  // the longest wait first; ended left out
    }

    @Test func filterByProjectOrState() {
        var s = store()
        _ = s.apply(hook("Stop", session: "web", pid: 7, extra: ["cwd": "/Users/me/web-app"]))
        let rows = PaletteOrder.sorted(Array(s.sessions.values))
        #expect(PaletteOrder.filter(rows, query: "WEB").map(\.id) == ["web"])
        #expect(PaletteOrder.filter(rows, query: "needs permission").map(\.id) == ["perm"])
        #expect(PaletteOrder.filter(rows, query: "done web").map(\.id) == ["web"])
        #expect(PaletteOrder.filter(rows, query: "  ").count == rows.count)
    }

    @Test func nextWaitingWrapsAndSkipsSelf() {
        let rows = PaletteOrder.sorted(Array(store().sessions.values))
        #expect(PaletteOrder.nextWaiting(after: "ask", in: rows)?.id == "perm")
        #expect(PaletteOrder.nextWaiting(after: "perm", in: rows)?.id == "ask")
        #expect(PaletteOrder.nextWaiting(after: "work", in: rows)?.id == "ask")
        #expect(PaletteOrder.nextWaiting(after: nil, in: rows)?.id == "ask")
        let one = rows.filter { $0.id != "ask" }
        #expect(PaletteOrder.nextWaiting(after: "perm", in: one) == nil)
    }

    @Test func summaryShowsFirstLine() {
        let s = store().sessions
        #expect(PaletteOrder.summary(s["perm"]!) == "Bash: swift test")
        #expect(PaletteOrder.summary(s["ask"]!) == "Pick a library?")
        #expect(PaletteOrder.summary(s["done1"]!) == nil)
    }
}

@Suite struct DiagnosticsTests {
    @Test func ringBufferKeepsNewest50() {
        var r = RingBuffer<Int>(capacity: 50)
        for i in 0..<120 { r.append(i) }
        #expect(r.items.count == 50)
        #expect(r.items.first == 70 && r.items.last == 119)
    }

    @Test func reportRedactsHomeAndSessionIds() {
        let sid = "3f2a9c1e-1111-4222-8333-944455556666"
        let rows = [DiagRow(.warn, "Hooks", "Missing events: SubagentStart", fix: "Install hooks."),
                    DiagRow(.ok, "Socket", "Listening on /Users/alice/Library/Application Support/Buddy/buddy.sock", fix: "never shown"),
                    DiagRow(.bad, "Note", "transcript /Users/alice/.claude/projects/x/\(sid).jsonl; other user /Users/alicex/y")]
        let ev = DiagEvent(time: Date(timeIntervalSince1970: 0), sessionId: sid, project: "web-app", event: "PermissionRequest",
                           tool: "Bash", result: DiagEvent.result(for: HookOutput.allow()))
        let text = DiagnosticsReport.format(rows: rows, events: [ev], generated: Date(timeIntervalSince1970: 0), home: "/Users/alice",
                                            timeZone: TimeZone(identifier: "UTC")!)
        #expect(!text.contains("/Users/alice/"))
        #expect(text.contains("~/Library/Application Support/Buddy/buddy.sock"))
        #expect(text.contains("/Users/alicex/y"))  // another home is not cut
        #expect(!text.contains(sid) && text.contains("3f2a9c1e…"))
        #expect(text.contains("[WARN] Hooks: Missing events: SubagentStart\n       Fix: Install hooks."))
        #expect(!text.contains("never shown"))
        #expect(text.contains("  00:00:00  3f2a9c1e  project-1  PermissionRequest  Bash  replied allow"))
        #expect(!text.contains("web-app"))
    }

    @Test func reportAliasesProjectsAndHosts() {
        let t = Date(timeIntervalSince1970: 0)
        let events = [DiagEvent(time: t, sessionId: "a", project: "web-app", event: "Stop", tool: nil, result: "received"),
                      DiagEvent(time: t, sessionId: "b", project: "api", host: "devbox", event: "Stop", tool: nil, result: "received"),
                      DiagEvent(time: t, sessionId: "c", project: "web-app", event: "Stop", tool: nil, result: "received"),
                      DiagEvent(time: t, sessionId: "d", project: "api", host: "prod-db", event: "Stop", tool: nil, result: "received"),
                      DiagEvent(time: t, sessionId: "-", project: "-", event: "remote", tool: nil, result: "rejected: token mismatch")]
        let text = DiagnosticsReport.format(rows: [], events: events, generated: t, home: "/Users/alice", timeZone: TimeZone(identifier: "UTC")!)
        for line in ["  a  project-1  Stop", "  b  ssh-1:project-2  Stop", "  c  project-1  Stop", "  d  ssh-2:project-2  Stop", "  -  -  remote"] {
            #expect(text.contains(line), "\(line)")
        }
        for secret in ["web-app", "api", "devbox", "prod-db"] { #expect(!text.contains(secret), "\(secret)") }
    }

    @Test func homeRedactionIgnoresCase() {
        #expect(DiagnosticsReport.redact("/users/ALICE/x and /Users/alice", home: "/Users/alice") == "~/x and ~")
        #expect(DiagnosticsReport.redact("/Users/alicex", home: "/Users/alice") == "/Users/alicex")
    }

    @Test func eventTextIsRevealedAndClipped() {
        let e = DiagEvent(time: Date(), sessionId: "s", project: "p", event: "Stop", tool: "Bash\u{202E}" + String(repeating: "x", count: 80), result: "r")
        #expect(e.tool?.contains("\\u{202E}") == true && e.tool?.count == 64)
    }

    @Test func replyResults() {
        #expect(DiagEvent.result(for: HookOutput.deny("x")) == "replied deny")
        #expect(DiagEvent.result(for: HookOutput.allowAlways(json(#"{"type":"addRules"}"#))) == "replied always allow")
        #expect(DiagEvent.result(for: HookOutput.answer(toolInput: json("{}"), answers: ["q": "a"])) == "replied answers")
        #expect(DiagEvent.result(for: .null) == "deferred")
    }

    @Test func hooksDisabledDetection() {
        let on = Data(#"{"disableAllHooks": true, "allowManagedHooksOnly": true}"#.utf8)
        let off = Data(#"{"disableAllHooks": false}"#.utf8)
        let bad = Data("{not json".utf8)
        let r = HookBlockers.check([.init(name: "user", data: on, managed: false),
                                    .init(name: "local", data: bad, managed: false),
                                    .init(name: "missing", data: nil, managed: false),
                                    .init(name: "managed", data: Data(#"{"allowManagedHooksOnly": true}"#.utf8), managed: true)])
        // allowManagedHooksOnly counts only in managed settings.
        #expect(r.blockers == ["disableAllHooks in user", "allowManagedHooksOnly in managed"])
        #expect(r.unreadable == ["local"])
        let clean = HookBlockers.check([.init(name: "user", data: off, managed: false), .init(name: "m", data: Data("[]".utf8), managed: true)])
        #expect(clean.blockers.isEmpty && clean.unreadable == ["m"])
    }

    @Test func missingEventsListed() throws {
        let path = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"
        let full = try #require(try HookInstaller.install(settings: nil, hookPath: path))
        #expect(HookInstaller.missingEvents(settings: full, hookPath: path).isEmpty)
        #expect(HookInstaller.missingEvents(settings: nil, hookPath: path).count == HookInstaller.specs.count)
        var dict = try obj(full)
        var hooks = try #require(dict["hooks"] as? [String: Any])
        hooks["SubagentStop"] = nil
        dict["hooks"] = hooks
        let partial = try JSONSerialization.data(withJSONObject: dict)
        #expect(HookInstaller.missingEvents(settings: partial, hookPath: path) == ["SubagentStop"])
        #expect(HookInstaller.missingEvents(settings: Data("{bad".utf8), hookPath: path).count == HookInstaller.specs.count)
    }

    @Test func claudeVersionFromPath() {
        #expect(ClaudeVersion.fromExecutable("/Users/me/.local/share/claude/versions/2.1.317") == "2.1.317")
        #expect(ClaudeVersion.fromExecutable("/opt/homebrew/bin/node") == nil)
        #expect(ClaudeVersion.fromExecutable("/x/versions/latest") == nil)
        #expect(ClaudeVersion.fromExecutable(nil) == nil)
    }
}

@Suite struct UninstallPlanTests {
    @Test func stepsInOrderAndNeverDeleteTheApp() {
        let steps = UninstallPlan.steps(editors: [("VS Code", "/usr/local/bin/code"), ("Cursor", "/usr/local/bin/cursor")],
                                        home: "/Users/me", appPath: "/Applications/Buddy.app")
        #expect(steps == [.removeHooks,
                          .uninstallExtension(editor: "VS Code", cli: "/usr/local/bin/code"),
                          .uninstallExtension(editor: "Cursor", cli: "/usr/local/bin/cursor"),
                          .unregisterLoginItem,
                          .removeRemoteToken,
                          .removeSupportFolder(path: "/Users/me/Library/Application Support/Buddy"),
                          .quitAndReveal(appPath: "/Applications/Buddy.app")])
        // The only step that deletes anything on disk is the support folder; the app is only revealed.
        #expect(!steps.contains { step in
            if case .removeSupportFolder(let p) = step { return p.contains(".app") }
            return false
        })
    }

    @Test func noEditorStillListsTheStep() {
        let steps = UninstallPlan.steps(editors: [], home: "/h", appPath: "/a/Buddy.app")
        #expect(steps.count == 6)
        #expect(steps[1] == .uninstallExtension(editor: "VS Code / Cursor", cli: nil))
    }

    @Test func extensionListParsing() {
        #expect(UninstallPlan.listsExtension("ms-python.python\nTiagoSantos-Local.Buddy-Companion\n"))
        #expect(!UninstallPlan.listsExtension("tiagosantos-local.buddy-companion-old\nother.ext"))
        #expect(!UninstallPlan.listsExtension(""))
    }
}

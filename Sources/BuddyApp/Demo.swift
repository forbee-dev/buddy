#if DEBUG
import AppKit
import BuddyCore

/// `--demo-cards`: fake sessions and requests for a visual check of every card. DEBUG builds only.
/// `--demo-activity`: one session with subagents and background shells (minis, Activity tab, subagent card).
/// `--demo-palette` (or `=card`, with the first card open), `--demo-diagnostics`, `--demo-uninstall`: the card sessions
/// plus that window. `--demo-appearance=light|dark` forces the appearance.
/// `--demo-wave2`: impatience level 2, a high-five pair (repeats), a tip, tokens and cost on the Activity tab.
/// `--demo-away`: the "while you were away" digest. `--demo-mix`: Character → Mix with Crate, and a skin outfit.
/// `--demo-ssh` (or `=diagnostics`): one SSH session (`devbox:api`), two local buddies dragged close (tag overlap fix),
/// and Settings → SSH (or Diagnostics). `--demo-idle`: no sessions, only the sleeping buddy (idle CPU check).
@MainActor
enum Demo {
    static let activity = CommandLine.arguments.contains("--demo-activity")
    static func arg(_ name: String) -> String? { CommandLine.arguments.first { $0 == name || $0.hasPrefix(name + "=") } }
    static let on = activity || ["--demo-cards", "--demo-palette", "--demo-diagnostics", "--demo-uninstall", "--demo-wave2", "--demo-away",
                                 "--demo-mix", "--demo-ssh", "--demo-idle"].contains { arg($0) != nil }
    /// Card state per demo request id, so the screenshots show more than the first step.
    static let presets: [String: (inout QuestionFlow) -> Void] = [
        "review-PermissionRequest": { f in
            f.pick(0); f.go(to: 1); f.pick(0); f.pick(1); f.go(to: 3)
        },
        "mobile-PermissionRequest": { f in
            f.go(to: 1); f.pick(0); f.pick(3); f.others[1] = "watchOS"; f.moveCursor(0)
        },
    ]

    static func start(model: AppModel) {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-appearance=") }) {
            NSApp.appearance = NSAppearance(named: arg.hasSuffix("dark") ? .darkAqua : .aqua)
        }
        model.walking = false  // a moving card stays disarmed; the debug build has its own defaults domain
        if arg("--demo-idle") != nil { model.sleepMascot = true; return }
        if activity { startActivity(model: model); return }
        if arg("--demo-wave2") != nil { startWave2(model: model); return }
        if arg("--demo-away") != nil { startAway(model: model); return }
        if arg("--demo-mix") != nil { startMix(model: model); return }
        if arg("--demo-ssh") != nil { startSSH(model: model); return }
        let transcript = writeTranscript()
        let env = HookEnv(termProgram: "iTerm.app", attended: "1")
        func send(_ sid: String, _ event: String, _ extra: [String: JSONValue]) {
            var p: [String: JSONValue] = ["session_id": .string(sid), "hook_event_name": .string(event),
                                          "cwd": .string("/Users/demo/\(sid)")]
            if let transcript { p["transcript_path"] = .string(transcript) }
            p.merge(extra) { $1 }
            model.applyDemo(HookMessage(id: "\(sid)-\(event)", wantsReply: event == "PermissionRequest", payload: .object(p), env: env))
        }
        func ask(_ sid: String, _ questions: String) {
            send(sid, "PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": json(#"{"questions":\#(questions)}"#)])
        }
        let three = #"""
        [{"question":"Which state library should the settings screen use?","header":"State","multiSelect":false,"options":[
          {"label":"Observation","description":"The @Observable macro. Least code, iOS 17+.","preview":"@Observable\nfinal class Settings {\n    var theme = Theme.system\n    var fontSize = 14\n}"},
          {"label":"Combine","description":"ObservableObject with @Published. Works on older systems.","preview":"final class Settings: ObservableObject {\n    @Published var theme = Theme.system\n    @Published var fontSize = 14\n}"},
          {"label":"Plain structs","description":"Pass values down and callbacks up."}]},
         {"question":"Which platforms do you want to ship first?","header":"Platforms","multiSelect":true,"options":[
          {"label":"macOS","description":"The desktop app."},{"label":"iOS","description":"iPhone and iPad."},{"label":"Web"}]},
         {"question":"Should I add tests for the new screen?","header":"Tests","multiSelect":false,"options":[
          {"label":"Yes, unit tests","description":"Swift Testing, no UI tests."},{"label":"No tests for now"}]}]
        """#
        for sid in ["web-app", "review", "mobile"] { ask(sid, three) }
        ask("api", #"[{"question":"The migration drops the legacy column. Run it now?","header":"Migrate","multiSelect":false,"options":[{"label":"Run it","description":"Applies to the dev database only."},{"label":"Wait","description":"I review the SQL first."}]}]"#)
        send("infra", "PermissionRequest", ["tool_name": "Bash", "tool_input": json(#"""
        {"command":"rm -rf build/ && swift build -c release 2>&1 | tail -20\nopen build/Buddy.app","description":"Clean the build folder and build a release","dangerouslyDisableSandbox":true}
        """#), "permission_suggestions": json(#"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"swift build:*"}],"behavior":"allow","destination":"localSettings"}]"#)])
        send("docs", "PermissionRequest", ["tool_name": "Read", "tool_input": json(#"{"file_path":"/Users/demo/docs/README.md"}"#)])
        send("notes", "Stop", ["last_assistant_message": .string("""
        Done. I **renamed** the `Settings` type and fixed *two* failing tests.

        - `SettingsTests.swift`: the theme default is now `.system`.
        - `AppModel.swift`: removed the unused `legacyTheme` flag.

        See [the docs](https://example.com) for the new names. The build is green and nothing else changed. \
        I did not touch the release scripts or the signing setup. Next step: run the app once and check the settings window.
        """)])
        if let p = arg("--demo-palette") {
            PaletteController.shared.show(model: model)
            if p.hasSuffix("=card") { PaletteController.shared.demoOpenFirst(model: model) }
            return
        }
        if arg("--demo-diagnostics") != nil {
            model.extClients = [("vscode", "0.1.3"), ("vscode", "0.1.3"), ("cursor", "0.1.2")]
            model.claudeVersions = ["2.1.309", "2.1.317"]
            model.record("infra", "PermissionRequest", "Bash", "replied deny")
            model.record("docs", "PermissionRequest", "Read", "replied allow")
            model.record("api", "PermissionRequest", "AskUserQuestion", "deferred to terminal")
            model.record("notes", "NextPrompt", nil, "sent via editor")
            SettingsWindow.show(model: model, tab: .diagnostics)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                FileHandle.standardOutput.write(Data(Diagnostics.shared.report(model).utf8))
            }
            return
        }
        if arg("--demo-uninstall") != nil { UninstallWindow.show(model: model); return }
        // Never focus: a key bubble would take keystrokes meant for the app in front.
        for c in model.director?.controllers.values ?? [:].values { c.showBubble(focus: false) }
    }

    /// Subagents: running, needs permission, done (it ends after 3 s so its mini is still there at 5 s).
    /// Shells: one running, one finished. At 7 s the bubble switches to Activity with the first row marked.
    private static func startActivity(model: AppModel) {
        let env = HookEnv(termProgram: "iTerm.app", attended: "1")
        var n = 0
        func send(_ event: String, agent: String? = nil, _ extra: [String: JSONValue] = [:]) {
            var p: [String: JSONValue] = ["session_id": "demo", "hook_event_name": .string(event), "cwd": "/Users/demo/shop-api"]
            if let agent { p["agent_id"] = .string(agent); p["agent_type"] = agent == "a3" ? "Explore" : "general-purpose" }
            p.merge(extra) { $1 }
            n += 1
            model.applyDemo(HookMessage(id: "demo-\(n)", wantsReply: event == "PermissionRequest", payload: .object(p), env: env))
        }
        func spawn(_ id: String, _ input: String) {
            send("PreToolUse", ["tool_name": "Agent", "tool_use_id": .string("tu-\(id)"), "tool_input": json(input)])
            send("SubagentStart", agent: id)
        }
        func shell(_ id: String, _ input: String) {
            send("PostToolUse", ["tool_name": "Bash", "tool_input": json(input), "tool_response": .object(["backgroundTaskId": .string(id)])])
        }
        send("UserPromptSubmit")
        spawn("a1", #"{"description":"Review the payments module","subagent_type":"general-purpose"}"#)
        spawn("a2", #"{"description":"Write migration tests","subagent_type":"general-purpose","run_in_background":true}"#)
        spawn("a3", #"{"description":"Find unused assets","subagent_type":"Explore"}"#)
        shell("b1", #"{"command":"npm run dev","description":"Start the dev server","run_in_background":true}"#)
        shell("b2", #"{"command":"npm run build -- --watch=false","run_in_background":true}"#)
        send("Stop", ["last_assistant_message": "Three helpers are on it.",
                      "background_tasks": json(#"[{"id":"a1","type":"subagent","status":"running"},{"id":"a2","type":"subagent","status":"running"},{"id":"a3","type":"subagent","status":"running"},{"id":"b1","type":"shell","status":"running"}]"#)])
        send("PermissionRequest", agent: "a2", ["tool_name": "Bash", "tool_input": json(#"{"command":"swift test --filter MigrationTests","description":"Run the migration tests"}"#)])
        for c in model.director?.controllers.values ?? [:].values { c.showBubble(focus: false) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            send("SubagentStop", agent: "a3", ["last_assistant_message": .string("Found 4 unused images in `Assets/legacy`. Nothing else references them.")])
            try? await Task.sleep(for: .seconds(4))
            model.director?.openActivity(sessionId: "demo", highlight: "a1", focus: false)
        }
    }

    /// Sends one demo hook event; `ago` moves its time into the past.
    private static func event(_ model: AppModel, _ sid: String, _ name: String, ago: TimeInterval = 0, _ extra: [String: JSONValue] = [:]) {
        var p: [String: JSONValue] = ["session_id": .string(sid), "hook_event_name": .string(name), "cwd": .string("/Users/demo/\(sid)")]
        p.merge(extra) { $1 }
        counter += 1
        model.applyDemo(HookMessage(id: "\(sid)-\(name)-\(counter)", wantsReply: name == "PermissionRequest", payload: .object(p),
                                    env: HookEnv(termProgram: "iTerm.app", attended: "1")), now: Date().addingTimeInterval(-ago))
    }
    private static var counter = 0

    /// A transcript with assistant usage lines (repeated ids, as Claude Code writes them) and one subagent file.
    private static func usageTranscript(_ name: String, scale: Int) -> JSONValue {
        let dir = FileManager.default.currentDirectoryPath + "/.build/demo/usage"
        let path = "\(dir)/\(name).jsonl"
        func line(_ id: String, _ model: String, _ n: Int) -> String {
            #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(n / 50),"output_tokens":\#(n / 6),"cache_creation_input_tokens":\#(n / 3),"cache_read_input_tokens":\#(n)}}}"#
        }
        let main = (1...6).flatMap { i in [line("m\(i)", "claude-opus-5-5", 3000 * scale), line("m\(i)", "claude-opus-5-5", 3000 * scale)] }
        do {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(name)/subagents", withIntermediateDirectories: true)
            try (main.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try (line("s1", "claude-haiku-5-5", 9000) + "\n").write(toFile: "\(dir)/\(name)/subagents/agent-a1.jsonl", atomically: true, encoding: .utf8)
        } catch { return .null }
        return .string(path)
    }

    private static func startWave2(model: AppModel) {
        model.escalateMinutes = 3
        model.funExtras = true
        model.showUsage = true
        event(model, "api-gateway", "PermissionRequest", ago: 7 * 60, ["tool_name": "Bash", "tool_input": json(#"{"command":"make deploy-staging","description":"Deploy to staging"}"#)])
        event(model, "web-app", "UserPromptSubmit", ["transcript_path": usageTranscript("web-app", scale: 2)])
        event(model, "docs-site", "UserPromptSubmit")
        event(model, "shop-api", "UserPromptSubmit")
        event(model, "shop-api", "PostToolUse", ["tool_name": "Bash", "tool_input": json(#"{"command":"npm test"}"#)])
        event(model, "data-jobs", "UserPromptSubmit", ["transcript_path": usageTranscript("data-jobs", scale: 5)])
        event(model, "data-jobs", "PreToolUse", ["tool_name": "Agent", "tool_use_id": "tu-1", "tool_input": json(#"{"description":"Profile the nightly import"}"#)])
        event(model, "data-jobs", "SubagentStart", ["agent_id": "a1", "agent_type": "general-purpose"])
        event(model, "data-jobs", "PostToolUse", ["agent_id": "a1", "tool_name": "Bash", "tool_input": json(#"{"command":"python import.py","description":"Run the import","run_in_background":true}"#),
                                                   "tool_response": json(#"{"backgroundTaskId":"b1"}"#)])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            model.director?.showTip(Tips.match(tool: "Bash", input: json(#"{"command":"npm test"}"#)) ?? "", sessionId: "shop-api")
            event(model, "web-app", "Stop", ["last_assistant_message": "Done."])
            event(model, "docs-site", "Stop", ["last_assistant_message": "Done."])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                model.director?.openActivity(sessionId: "data-jobs", highlight: "a1", focus: false)
            }
            // Repeat the high-five so a screenshot can catch it.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                let pair = ["web-app", "docs-site"].compactMap { sid in model.director?.controllers.values.first { $0.spec.sessionId == sid } }
                guard pair.count == 2 else { continue }
                let (l, r) = pair[0].centerX <= pair[1].centerX ? (pair[0], pair[1]) : (pair[1], pair[0])
                l.highFive(mirrored: false, spark: true)
                r.highFive(mirrored: true, spark: false)
            }
        }
    }

    private static func startAway(model: AppModel) {
        model.showUsage = true
        event(model, "api-gateway", "Stop", ago: 12 * 60, ["last_assistant_message": "Done."])
        event(model, "docs-site", "PermissionRequest", ago: 4 * 60, ["tool_name": "Write", "tool_input": json(#"{"file_path":"/Users/demo/docs-site/index.md"}"#)])
        for (i, a) in ["f1", "f2"].enumerated() {
            event(model, "web-app", "PreToolUse", ago: 25 * 60, ["tool_name": "Agent", "tool_use_id": .string("t\(i)")])
            event(model, "web-app", "SubagentStart", ago: 25 * 60, ["agent_id": .string(a)])
            event(model, "web-app", "PostToolUseFailure", ago: 9 * 60, ["tool_name": "Agent", "tool_use_id": .string("t\(i)")])
        }
        event(model, "web-app", "PostToolUse", ago: 25 * 60, ["tool_name": "Bash", "tool_input": json(#"{"command":"npm run dev","run_in_background":true}"#),
                                                              "tool_response": json(#"{"backgroundTaskId":"b1"}"#)])
        event(model, "web-app", "UserPromptSubmit", ago: 6 * 60, ["task_id": "b1", "task_status": "completed"])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            model.showDigest(since: Date().addingTimeInterval(-20 * 60))
        }
    }

    private static func startMix(model: AppModel) {
        Task { @MainActor in
            // Skins load off the main thread; Crate must be in the sheet before the buddies get their looks.
            await SkinStore.shared.loading?.value
            SkinStore.shared.demoEnable("crate")
            model.character = AppModel.mix
            for sid in ["api-gateway", "web-app", "docs-site", "shop-api"] { event(model, sid, "UserPromptSubmit") }
            event(model, "web-app", "Stop")
            try? await Task.sleep(for: .seconds(0.5))
            // A skin outfit on a Crate buddy, if one drew Crate.
            if let s = model.sessions.first(where: { model.look(for: $0)?.base == "crate/crate" }) { model.setLook(s, outfit: .some("crate/cartridge")) }
        }
    }

    private static func startSSH(model: AppModel) {
        model.arrangement = .free
        model.showUsage = true
        model.demoSSH()
        // The demo's own pid stands in for the ssh client; the claude pid is a remote one.
        let origin = RemoteOrigin(host: "devbox", user: "tiago", sshPid: getpid(), claudePid: 4242)
        for (i, name) in ["UserPromptSubmit", "Stop"].enumerated() {
            var p: [String: JSONValue] = ["session_id": "remote-1", "hook_event_name": .string(name), "cwd": "/home/tiago/api"]
            if name == "Stop" { p["last_assistant_message"] = "Migrations ran on the dev database. 3 tables changed, all tests pass." }
            model.applyDemo(HookMessage(id: "remote-\(i)", wantsReply: false, payload: .object(p), env: HookEnv(attended: "1")), origin: origin)
        }
        event(model, "web-app", "UserPromptSubmit")
        event(model, "docs-site", "Stop", ["last_assistant_message": "Done."])
        SSHForm.shared.host = "devbox"
        SettingsWindow.show(model: model, tab: arg("--demo-ssh") == "--demo-ssh=diagnostics" ? .diagnostics : .ssh)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // As if dragged: web-app and docs-site stand closer than their tags are wide.
            let f = model.director?.floor ?? .zero
            for (sid, dx) in [("web-app", 260.0), ("docs-site", 324.0)] {
                guard let c = model.director?.controllers.values.first(where: { $0.spec.sessionId == sid }) else { continue }
                c.setX(f.minX + dx - c.panelSize.width / 2)
            }
            model.director?.controllers.values.first { $0.spec.sessionId == "remote-1" }?.showBubble(focus: false)
            model.director?.wake()
        }
    }

    /// A small transcript under the repo's .build folder (inside home, so the path check passes).
    private static func writeTranscript() -> String? {
        let dir = FileManager.default.currentDirectoryPath + "/.build/demo"
        let path = dir + "/transcript.jsonl"
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Add a settings screen"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I read the project. The app has no settings yet, and the model layer uses plain classes. Before I write the screen I need a few choices from you."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{}}]}}"#,
        ]
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch { return nil }
    }

    private static func json(_ s: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .null }
}
#endif

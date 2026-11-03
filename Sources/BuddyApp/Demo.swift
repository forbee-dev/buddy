#if DEBUG
import AppKit
import BuddyCore

/// `--demo-cards`: fake sessions and requests for a visual check of every card. DEBUG builds only.
/// `--demo-activity`: one session with subagents and background shells (minis, Activity tab, subagent card).
/// `--demo-appearance=light|dark` forces the appearance.
@MainActor
enum Demo {
    static let activity = CommandLine.arguments.contains("--demo-activity")
    static let on = activity || CommandLine.arguments.contains("--demo-cards")
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
        if activity { startActivity(model: model); return }
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

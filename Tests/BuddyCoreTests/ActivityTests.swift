import Foundation
import Testing
@testable import BuddyCore

private func agentCall(_ event: String, _ useId: String, _ extra: [String: JSONValue] = [:]) -> HookMessage {
    var e: [String: JSONValue] = ["tool_name": "Agent", "tool_use_id": .string(useId)]
    e.merge(extra) { $1 }
    return hook(event, extra: e)
}

private func inAgent(_ event: String, _ agent: String, _ extra: [String: JSONValue] = [:], id: String = UUID().uuidString) -> HookMessage {
    var e: [String: JSONValue] = ["agent_id": .string(agent), "agent_type": "general-purpose", "cwd": "/tmp/other"]
    e.merge(extra) { $1 }
    return hook(event, id: id, extra: e)
}

private func bgShell(_ tid: String, _ input: String) -> HookMessage {
    hook("PostToolUse", extra: ["tool_name": "Bash", "tool_input": json(input),
                                "tool_response": .object(["backgroundTaskId": .string(tid)])])
}

private func stop(_ tasks: String) -> HookMessage { hook("Stop", extra: ["background_tasks": json(tasks)]) }

@Suite struct ActivityTests {
    @Test func foregroundSubagentLifecycle() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(agentCall("PreToolUse", "tu1", ["tool_input": json(#"{"description":"Find bugs","subagent_type":"general-purpose"}"#)]))
        _ = s.apply(inAgent("SubagentStart", "a1"))
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .running)
        #expect(s.sessions["s1"]?.subagents["a1"]?.label == "Find bugs")
        #expect(s.sessions["s1"]?.subagents["a1"]?.background == false)
        _ = s.apply(inAgent("PostToolUse", "a1", ["tool_name": "Bash"]))
        _ = s.apply(inAgent("SubagentStop", "a1", ["last_assistant_message": .string("Found 2\u{1B}[31m bugs" + String(repeating: "x", count: 400))]))
        let a = s.sessions["s1"]?.subagents["a1"]
        #expect(a?.state == .done && a?.endedAt != nil)
        #expect(a?.lastMessage?.hasPrefix("Found 2\\u{001B}[31m bugs") == true)
        #expect((a?.lastMessage?.count ?? 0) <= 300)
        _ = s.apply(agentCall("PostToolUse", "tu1", ["tool_response": json(#"{"agentId":"a1"}"#)]))
        #expect(s.sessions["s1"]?.state == .working)
        #expect(s.sessions["s1"]?.cwd == "/tmp/proj")
        #expect(s.sessions["s1"]?.activeSubagents == 0)
    }

    @Test func backgroundSubagentOutlivesParentStop() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(agentCall("PreToolUse", "tu2", ["tool_input": json(#"{"description":"Run sleep","run_in_background":true}"#)]))
        _ = s.apply(inAgent("SubagentStart", "a2"))
        _ = s.apply(agentCall("PostToolUse", "tu2", ["tool_response": json(#"{"agentId":"a2"}"#)]))
        _ = s.apply(stop(#"[{"id":"a2","type":"subagent","status":"running"}]"#))
        #expect(s.sessions["s1"]?.state == .done)
        #expect(s.sessions["s1"]?.subagents["a2"]?.state == .running)
        #expect(s.sessions["s1"]?.subagents["a2"]?.background == true)
        _ = s.apply(inAgent("PostToolUse", "a2", ["tool_name": "Bash"]))
        #expect(s.sessions["s1"]?.state == .done)
        _ = s.apply(inAgent("SubagentStop", "a2"))
        #expect(s.sessions["s1"]?.subagents["a2"]?.state == .done)
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "a2"]))
        #expect(s.sessions["s1"]?.state == .working)
        _ = s.apply(stop("[]"))
        #expect(s.sessions["s1"]?.state == .done)
        #expect(s.sessions["s1"]?.subagents["a2"]?.state == .done)
    }

    @Test func fifoMappingFixedByAgentId() {
        var s = SessionStore()
        _ = s.apply(agentCall("PreToolUse", "tu1", ["tool_input": json(#"{"description":"alpha"}"#)]))
        _ = s.apply(agentCall("PreToolUse", "tu2", ["tool_input": json(#"{"description":"beta","run_in_background":true}"#)]))
        _ = s.apply(inAgent("SubagentStart", "x"))
        _ = s.apply(inAgent("SubagentStart", "y"))
        #expect(s.sessions["s1"]?.subagents["x"]?.label == "alpha")
        #expect(s.sessions["s1"]?.subagents["y"]?.label == "beta")
        _ = s.apply(agentCall("PostToolUse", "tu2", ["tool_response": json(#"{"agentId":"x"}"#)]))
        #expect(s.sessions["s1"]?.subagents["x"]?.label == "beta")
        #expect(s.sessions["s1"]?.subagents["x"]?.background == true)
        #expect(s.sessions["s1"]?.subagents["y"]?.label == "alpha")
        // A call still in the queue: swap with it, and the next start gets the displaced one.
        _ = s.apply(agentCall("PreToolUse", "tu3", ["tool_input": json(#"{"description":"gamma"}"#)]))
        _ = s.apply(agentCall("PreToolUse", "tu4", ["tool_input": json(#"{"subagent_type":"Explore"}"#)]))
        _ = s.apply(inAgent("SubagentStart", "z", ["agent_type": "Explore"]))
        _ = s.apply(agentCall("PostToolUse", "tu4", ["tool_response": json(#"{"agentId":"z"}"#)]))
        #expect(s.sessions["s1"]?.subagents["z"]?.label == "Explore")
        _ = s.apply(inAgent("SubagentStart", "w"))
        #expect(s.sessions["s1"]?.subagents["w"]?.label == "gamma")
    }

    @Test func failedViaPostToolUseFailure() {
        var s = SessionStore()
        _ = s.apply(agentCall("PreToolUse", "tu5"))
        _ = s.apply(inAgent("SubagentStart", "f"))
        _ = s.apply(agentCall("PostToolUseFailure", "tu5", ["error": "boom"]))
        #expect(s.sessions["s1"]?.subagents["f"]?.state == .failed)
        _ = s.apply(inAgent("SubagentStop", "f"))
        #expect(s.sessions["s1"]?.subagents["f"]?.state == .failed)
        #expect(s.sessions["s1"]?.subagents["f"]?.label == "general-purpose")
    }

    @Test func subagentEventsDoNotTouchMainState() { // regression: they used to drive the main buddy
        var s = SessionStore()
        _ = s.apply(hook("Stop", extra: ["last_assistant_message": "main"]))
        for e in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "Stop"] {
            _ = s.apply(inAgent(e, "a1", ["tool_name": "Bash", "notification_type": "permission_prompt", "last_assistant_message": "sub"]))
        }
        #expect(s.sessions["s1"]?.state == .done)
        #expect(s.sessions["s1"]?.lastMessage == "main")
        #expect(s.sessions["s1"]?.cwd == "/tmp/proj")
        #expect(s.sessions["s1"]?.subagents.isEmpty == true)
    }

    @Test func subagentPermissionAttributedAndScoped() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(agentCall("PreToolUse", "tu1", ["tool_input": json(#"{"description":"Touch files"}"#)]))
        _ = s.apply(inAgent("SubagentStart", "a1"))
        _ = s.apply(inAgent("PermissionRequest", "a1", ["tool_name": "Bash", "tool_input": json(#"{"command":"touch x"}"#)], id: "r1"))
        let sess = s.sessions["s1"]
        #expect(sess?.pending?.agentId == "a1")
        #expect(sess?.subagentLabel("a1") == "Touch files")
        #expect(sess?.state == .needsPermission && sess?.mainState == .working)
        #expect(sess?.subagents["a1"]?.state == .needsPermission)
        // Same tool name, other agents: the card stays.
        let mainPost = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash"]))
        let otherPost = s.apply(inAgent("PostToolUse", "a9", ["tool_name": "Bash"]))
        #expect(mainPost.staleRequests.isEmpty && otherPost.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.pending?.id == "r1")
        let ownPost = s.apply(inAgent("PostToolUse", "a1", ["tool_name": "Bash"]))
        #expect(ownPost.staleRequests == ["r1"])
        #expect(s.sessions["s1"]?.state == .working)
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .running)
        // Main Stop keeps a subagent card; answering it leaves the main state alone.
        _ = s.apply(inAgent("PermissionRequest", "a1", ["tool_name": "Bash"], id: "r2"))
        let mainStop = s.apply(hook("Stop"))
        #expect(mainStop.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.state == .needsPermission)
        let resolved = s.resolve(requestId: "r2")
        #expect(resolved)
        #expect(s.sessions["s1"]?.state == .done)
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .running)
        // A main request is not cleared by a subagent's tool of the same name.
        _ = s.apply(hook("PermissionRequest", id: "r3", extra: ["tool_name": "Bash"]))
        let subPost = s.apply(inAgent("PostToolUse", "a1", ["tool_name": "Bash"]))
        #expect(subPost.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.pending?.id == "r3")
    }

    @Test func shellsStartFinishAndStop() {
        var s = SessionStore()
        _ = s.apply(bgShell("sh1", #"{"description":"Sleep 6 seconds","command":"sleep 6","run_in_background":true}"#))
        _ = s.apply(bgShell("sh2", #"{"command":"sleep 40; echo never","run_in_background":true}"#))
        _ = s.apply(bgShell("sh3", #"{"command":"tail -f log","run_in_background":true}"#))
        _ = s.apply(bgShell("fg", #"{"command":"ls"}"#))
        #expect(s.sessions["s1"]?.shells["sh1"]?.label == "Sleep 6 seconds")
        #expect(s.sessions["s1"]?.shells["sh2"]?.label == "sleep 40; echo never")
        #expect(s.sessions["s1"]?.shells["fg"] == nil)
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "TaskStop", "tool_input": json(#"{"task_id":"sh2"}"#)]))
        #expect(s.sessions["s1"]?.shells["sh2"]?.state == .stopped)
        _ = s.apply(stop(#"[{"id":"sh1","type":"shell","status":"running"},{"id":"sh3","type":"shell","status":"running"}]"#))
        #expect(s.sessions["s1"]?.shells["sh1"]?.state == .running)
        _ = s.apply(hook("Stop"))  // no list: proves nothing
        #expect(s.sessions["s1"]?.runningShells == 2)
        _ = s.apply(stop(#"[{"id":"sh3","type":"shell","status":"running"}]"#))
        #expect(s.sessions["s1"]?.shells["sh1"]?.state == .finished)
        #expect(s.sessions["s1"]?.shells["sh2"]?.state == .stopped)
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "sh3"]))
        #expect(s.sessions["s1"]?.shells["sh3"]?.state == .finished)
    }

    @Test func sessionEndEndsEverything() {
        var s = SessionStore()
        _ = s.apply(bgShell("sh1", #"{"command":"sleep 9","run_in_background":true}"#))
        _ = s.apply(inAgent("SubagentStart", "a1"))
        _ = s.apply(hook("SessionEnd", extra: ["reason": "prompt_input_exit"]))
        #expect(s.sessions["s1"]?.runningShells == 0 && s.sessions["s1"]?.activeSubagents == 0)
    }

    @Test func capsAndExpiry() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<25 {
            _ = s.apply(inAgent("SubagentStart", "a\(i)"), now: t0.addingTimeInterval(Double(i)))
            if i < 22 { _ = s.apply(inAgent("SubagentStop", "a\(i)"), now: t0.addingTimeInterval(Double(i))) }
        }
        for i in 0..<12 { _ = s.apply(bgShell("sh\(i)", #"{"command":"x","run_in_background":true}"#), now: t0) }
        let sess = s.sessions["s1"]
        #expect(sess?.subagents.count == Activity.maxSubagents)
        #expect(sess?.subagents["a0"] == nil && sess?.subagents["a24"] != nil && sess?.subagents["a5"] != nil)
        #expect(sess?.shells.count == Activity.maxShells)
        _ = s.reap(isAlive: { _ in true }, now: t0.addingTimeInterval(Activity.keepEnded + 30))
        #expect(s.sessions["s1"]?.subagents.count == 3)
        #expect(s.sessions["s1"]?.shells.count == Activity.maxShells)
    }

    @Test func payloadKeepsOnlyActivityFields() throws {
        let pre = try HookPayload.decode(Data(#"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Agent","agent_id":"a1","agent_type":"Explore",
         "tool_input":{"description":"d","prompt":"SECRET","subagent_type":"Explore","run_in_background":true,"model":"x","command":"\#(String(repeating: "c", count: 300))"}}
        """#.utf8))
        #expect(pre["agent_id"]?.string == "a1" && pre["agent_type"]?.string == "Explore")
        #expect(pre["tool_input"]?["prompt"] == nil && pre["tool_input"]?["model"] == nil)
        #expect(pre["tool_input"]?["run_in_background"]?.bool == true)
        #expect(pre["tool_input"]?["description"]?.string == "d")
        #expect((pre["tool_input"]?["command"]?.string?.count ?? 0) <= 201)
        let post = try HookPayload.decode(Data(#"""
        {"hook_event_name":"PostToolUse","tool_response":{"agentId":"a1","content":"SECRET","backgroundTaskId":"b1","stdout":"SECRET"}}
        """#.utf8))
        #expect(post["tool_response"] == json(#"{"agentId":"a1","backgroundTaskId":"b1"}"#))
        let stop = try HookPayload.decode(Data(#"""
        {"hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","command":"SECRET","description":"SECRET"}]}
        """#.utf8))
        #expect(stop["background_tasks"] == json(#"[{"id":"b1","type":"shell","status":"running"}]"#))
        let note = try HookPayload.decode(Data(#"""
        {"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>by5x4bhvl</task-id><summary>SECRET</summary></task-notification>"}
        """#.utf8))
        #expect(note["task_id"]?.string == "by5x4bhvl" && note["prompt"] == nil)
        let typed = try HookPayload.decode(Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"see <task-id>x</task-id>"}"#.utf8))
        #expect(typed["task_id"] == nil)
        #expect(HookPayload.taskNotificationId("<task-notification><task-id>a b</task-id>") == nil)
    }

    @Test func installerAddsNewEventsIdempotently() throws {
        let path = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"
        var old = try obj(HookInstaller.install(settings: nil, hookPath: path))
        var hooks = try #require(old["hooks"] as? [String: Any])
        hooks["SubagentStart"] = nil
        hooks["SubagentStop"] = nil
        old["hooks"] = hooks
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(HookInstaller.status(settings: oldData, hookPath: path) == .outdated)
        #expect(HookInstaller.status(settings: Data(#"{"hooks":{}}"#.utf8), hookPath: path) == .missing)
        let new = try #require(try HookInstaller.install(settings: oldData, hookPath: path))
        let added = try #require(try obj(new)["hooks"] as? [String: Any])
        for e in ["SubagentStart", "SubagentStop"] {
            let h = try #require((added[e] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
            #expect(h.count == 1 && h.first?["timeout"] as? Int == 5)
        }
        #expect(HookInstaller.status(settings: new, hookPath: path) == .current)
        #expect(try HookInstaller.install(settings: new, hookPath: path) == nil)
    }

    @Test func miniScale() {
        #expect(BuddySize.medium.miniPointsPerPixel(backingScale: 2) == 1)
        #expect(BuddySize.tiny.miniPointsPerPixel(backingScale: 2) == 0.5)
        #expect(BuddySize.tiny.miniPointsPerPixel(backingScale: 1) == 1)
        #expect(BuddySize.medium.miniPointsPerPixel(backingScale: 1) == 1)
        #expect(BuddySize.small.miniPointsPerPixel(backingScale: 2) == 1)
        #expect(BuddySize.huge.miniPointsPerPixel(backingScale: 2) == 2)
    }
}

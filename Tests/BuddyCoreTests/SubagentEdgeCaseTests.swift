import Foundation
import Testing
@testable import BuddyCore

private func inAgent(_ event: String, _ agent: String, _ extra: [String: JSONValue] = [:], id: String = UUID().uuidString) -> HookMessage {
    var e: [String: JSONValue] = ["agent_id": .string(agent), "agent_type": "general-purpose"]
    e.merge(extra) { $1 }
    return hook(event, id: id, extra: e)
}
private func shellIn(_ agent: String?, _ tid: String) -> HookMessage {
    var e: [String: JSONValue] = ["tool_name": "Bash", "tool_input": json(#"{"command":"sleep 15","run_in_background":true}"#),
                                  "tool_response": .object(["backgroundTaskId": .string(tid)])]
    if let agent { e["agent_id"] = .string(agent) }
    return hook("PostToolUse", extra: e)
}
private func tasks(_ ids: [(String, String)]) -> JSONValue {
    .array(ids.map { .object(["id": .string($0.0), "type": .string($0.1), "status": "running"]) })
}

@Suite struct EdgeCaseTests {
    /// E1 timeline: a subagent starts a shell, stops, the parent Stop lists only the shell, the subagent resumes and stops.
    @Test func shellInsideSubagentKeepsItOpen() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(inAgent("SubagentStart", "ade5"))
        _ = s.apply(hook("Stop", extra: ["background_tasks": tasks([("ade5", "subagent")])]))
        _ = s.apply(shellIn("ade5", "bd0p"))
        #expect(s.sessions["s1"]?.shells["bd0p"]?.owner == "ade5")
        // Regression (early finish): the owner's SubagentStop and the parent Stop without the subagent ended it too soon.
        _ = s.apply(inAgent("SubagentStop", "ade5", ["background_tasks": tasks([("ade5", "subagent"), ("bd0p", "shell")])]))
        #expect(s.sessions["s1"]?.subagents["ade5"]?.state == .running)
        #expect(s.sessions["s1"]?.shells["bd0p"]?.state == .running)
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "ade5", "task_status": "completed"]))
        #expect(s.sessions["s1"]?.subagents["ade5"]?.state == .running)
        _ = s.apply(hook("Stop", extra: ["background_tasks": tasks([("bd0p", "shell")])]))
        #expect(s.sessions["s1"]?.subagents["ade5"]?.state == .running)
        #expect(s.sessions["s1"]?.shells["bd0p"]?.state == .running)
        // The same id starts again: no duplicate, running again.
        _ = s.apply(inAgent("SubagentStart", "ade5"))
        #expect(s.sessions["s1"]?.subagents.count == 1)
        // A SubagentStop list is the newest truth for shells too.
        _ = s.apply(inAgent("SubagentStop", "ade5", ["background_tasks": tasks([("ade5", "subagent")])]))
        #expect(s.sessions["s1"]?.shells["bd0p"]?.state == .finished)
        #expect(s.sessions["s1"]?.subagents["ade5"]?.state == .done)
        _ = s.apply(hook("Stop", extra: ["background_tasks": tasks([])]))
        #expect(s.sessions["s1"]?.subagents["ade5"]?.state == .done)
    }

    @Test func resumeReopensAFinishedSubagent() {
        var s = SessionStore()
        _ = s.apply(inAgent("SubagentStart", "a1"))
        _ = s.apply(inAgent("SubagentStop", "a1"))
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .done)
        _ = s.apply(inAgent("SubagentStart", "a1"))
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .running && s.sessions["s1"]?.subagents["a1"]?.endedAt == nil)
    }

    @Test func unknownSubagentStopIsIgnored() {
        var s = SessionStore()
        _ = s.apply(shellIn(nil, "sh1"))
        _ = s.apply(inAgent("SubagentStop", "internal", ["background_tasks": tasks([])]))
        #expect(s.sessions["s1"]?.shells["sh1"]?.state == .running)
        #expect(s.sessions["s1"]?.subagents.isEmpty == true)
    }

    /// E2: TaskStop of a subagent sends no SubagentStop.
    @Test func killedSubagentIsStopped() {
        var s = SessionStore()
        _ = s.apply(inAgent("SubagentStart", "a29"))
        _ = s.apply(shellIn(nil, "a29x"))
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "TaskStop", "tool_input": json(#"{"task_id":"a29"}"#),
                                                "tool_response": json(#"{"task_id":"a29","task_type":"local_agent"}"#)]))
        #expect(s.sessions["s1"]?.subagents["a29"]?.state == .stopped)
        #expect(s.sessions["s1"]?.subagents["a29"]?.endedAt != nil)
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "a29", "task_status": "killed"]))
        #expect(s.sessions["s1"]?.subagents["a29"]?.state == .stopped)
        // A local_agent stop never stops a shell, and a local_bash stop never a subagent.
        _ = s.apply(inAgent("SubagentStart", "b1"))
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "TaskStop", "tool_input": json(#"{"task_id":"b1"}"#),
                                                "tool_response": json(#"{"task_type":"local_bash"}"#)]))
        #expect(s.sessions["s1"]?.subagents["b1"]?.state == .running)
        #expect(s.sessions["s1"]?.shells["a29x"]?.state == .running)
    }

    @Test func taskNotificationStatusConfirms() {
        var s = SessionStore()
        _ = s.apply(inAgent("SubagentStart", "k1"))
        _ = s.apply(inAgent("SubagentStart", "c1"))
        _ = s.apply(shellIn(nil, "sh1"))
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "k1", "task_status": "killed"]))
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "c1", "task_status": "completed"]))
        _ = s.apply(hook("UserPromptSubmit", extra: ["task_id": "sh1", "task_status": "killed"]))
        #expect(s.sessions["s1"]?.subagents["k1"]?.state == .stopped)
        #expect(s.sessions["s1"]?.subagents["c1"]?.state == .done)
        #expect(s.sessions["s1"]?.shells["sh1"]?.state == .stopped)
    }

    /// E3: Notification has no agent_id; it never changes subagents.
    @Test func notificationNeverTouchesSubagents() {
        var s = SessionStore()
        _ = s.apply(inAgent("SubagentStart", "a1"))
        _ = s.apply(inAgent("PermissionRequest", "a1", ["tool_name": "Bash"], id: "r1"))
        _ = s.apply(hook("Notification", extra: ["notification_type": "permission_prompt"]))
        _ = s.apply(inAgent("Notification", "a1", ["notification_type": "idle_prompt"]))
        #expect(s.sessions["s1"]?.subagents["a1"]?.state == .needsPermission)
        #expect(s.sessions["s1"]?.pending?.id == "r1")
        _ = s.apply(inAgent("SubagentStart", "a2"))
        _ = s.apply(hook("Notification", extra: ["notification_type": "agent_needs_input"]))
        #expect(s.sessions["s1"]?.subagents["a2"]?.state == .running)
    }

    @Test func hookKeepsStatusTypeAndPathOnly() throws {
        let note = try HookPayload.decode(Data(#"""
        {"hook_event_name":"UserPromptSubmit","prompt":"<task-notification><task-id>a29</task-id><status>killed</status><summary>SECRET</summary></task-notification>"}
        """#.utf8))
        #expect(note["task_id"]?.string == "a29" && note["task_status"]?.string == "killed")
        let odd = try HookPayload.decode(Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"<task-notification><task-id>a</task-id><status>rm -rf /</status>"}"#.utf8))
        #expect(odd["task_status"] == nil)
        let plain = try HookPayload.decode(Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"say <status>killed</status>"}"#.utf8))
        #expect(plain["task_status"] == nil && plain["task_id"] == nil)
        let stop = try HookPayload.decode(Data(#"""
        {"hook_event_name":"PostToolUse","tool_name":"TaskStop","tool_input":{"task_id":"a29"},"tool_response":{"message":"SECRET","task_id":"a29","task_type":"local_agent","command":"SECRET"}}
        """#.utf8))
        #expect(stop["tool_response"] == json(#"{"task_type":"local_agent"}"#))
        let edit = try HookPayload.decode(Data(#"{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/p/db/migrations/1.sql","old_string":"SECRET"}}"#.utf8))
        #expect(edit["tool_input"] == json(#"{"file_path":"/p/db/migrations/1.sql"}"#))
    }
}

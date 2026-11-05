import Foundation
import Darwin
import Testing
@testable import BuddyCore

private func fileHook(_ event: String, id: String = UUID().uuidString, path: String, useId: String? = nil) -> HookMessage {
    var e: [String: JSONValue] = ["tool_name": "Read", "tool_input": .object(["file_path": .string(path)])]
    if let useId { e["tool_use_id"] = .string(useId) }
    return hook(event, id: id, extra: e)
}

@Suite struct StoreRegressionTests {
    @Test func compactKeepsTheState() { // 1
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(hook("SessionStart", extra: ["source": "compact"]))
        #expect(s.sessions["s1"]?.state == .working)
        _ = s.apply(hook("SessionStart", extra: ["source": "resume"]))
        #expect(s.sessions["s1"]?.state == .starting)
    }

    @Test func otherCallOfTheSameToolKeepsTheCard() { // 2
        var s = SessionStore()
        _ = s.apply(fileHook("PermissionRequest", id: "r1", path: "/a"))
        let other = s.apply(fileHook("PostToolUse", path: "/b", useId: "x"))
        #expect(other.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.pending?.id == "r1" && s.sessions["s1"]?.state == .needsPermission)
        let same = s.apply(fileHook("PostToolUse", path: "/a", useId: "y"))
        #expect(same.staleRequests == ["r1"])
        // The pending side holds the whole input; the PostToolUse side is trimmed.
        let long = String(repeating: "p", count: 300)
        _ = s.apply(fileHook("PermissionRequest", id: "r2", path: long))
        let trimmed = s.apply(fileHook("PostToolUse", path: HookPayload.trim(long, HookPayload.inputLimit)))
        #expect(trimmed.staleRequests == ["r2"])
    }

    @Test func resumeOntoAnEndedIdLeavesOneSession() { // 3
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", session: "B", pid: 7))
        _ = s.apply(hook("SessionEnd", session: "B", pid: 7, extra: ["reason": "logout"]))
        _ = s.apply(hook("SessionStart", session: "A", pid: 7))
        _ = s.apply(hook("SessionEnd", session: "A", pid: 7, extra: ["reason": "resume"]))
        #expect(s.sessions["A"]?.state == .idle)
        _ = s.apply(hook("SessionStart", session: "B", pid: 7, extra: ["source": "resume"]))
        #expect(s.sessions.count == 1)
        #expect(s.sessions["B"]?.state == .starting)
        #expect(!s.sessions.values.contains { $0.state == .idle })
    }

    @Test func lateNotificationAfterTheTerminalAnswered() { // 4
        var s = SessionStore()
        let t0 = Date()
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash"]), now: t0)
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash"]), now: t0)
        #expect(s.sessions["s1"]?.state == .working)
        _ = s.apply(hook("Notification", extra: ["notification_type": "permission_prompt"]), now: t0.addingTimeInterval(2))
        #expect(s.sessions["s1"]?.state == .working)
        _ = s.apply(hook("Notification", extra: ["notification_type": "permission_prompt"]), now: t0.addingTimeInterval(15))
        #expect(s.sessions["s1"]?.state == .needsPermission)
    }

    @Test func agentCallWaitsForALateSubagentStart() { // 5
        var s = SessionStore()
        _ = s.apply(hook("PreToolUse", extra: ["tool_name": "Agent", "tool_use_id": "tu1",
                                               "tool_input": json(#"{"description":"Scan","run_in_background":true}"#)]))
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "Agent", "tool_use_id": "tu1", "tool_response": json(#"{"agentId":"bg"}"#)]))
        _ = s.apply(hook("PreToolUse", extra: ["tool_name": "Agent", "tool_use_id": "tu2", "tool_input": json(#"{"description":"Other"}"#)]))
        _ = s.apply(hook("SubagentStart", extra: ["agent_id": "fg", "agent_type": "Explore"]))
        #expect(s.sessions["s1"]?.subagents["fg"]?.label == "Other")
        _ = s.apply(hook("SubagentStart", extra: ["agent_id": "bg", "agent_type": "general-purpose"]))
        #expect(s.sessions["s1"]?.subagents["bg"]?.label == "Scan")
        #expect(s.sessions["s1"]?.subagents["bg"]?.background == true)
        #expect(s.sessions["s1"]?.agentCalls.isEmpty == true)
    }

    @Test func stopFailureEndsInError() throws { // 6
        let raw = #"{"session_id":"s1","hook_event_name":"StopFailure","stop_hook_active":false,"error_type":"rate_limit","error":"Rate limited","last_assistant_message":"Half done"}"#
        let p = try HookPayload.decode(Data(raw.utf8))
        #expect(p["error"]?.string == "Rate limited" && p["last_assistant_message"]?.string == "Half done")
        #expect(p["stop_hook_active"] == nil && p["error_type"] == nil)
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash"]))
        let c = s.apply(HookMessage(id: "m", wantsReply: false, payload: p, env: HookEnv(claudePid: 100, attended: "1")))
        #expect(c.staleRequests == ["r1"])
        let sess = s.sessions["s1"]
        #expect(sess?.state == .error && sess?.pending == nil)
        #expect(sess?.lastError == "Rate limited" && sess?.lastMessage == "Half done" && sess?.note == "API error")
        // error_details is the human text; error is the code.
        _ = s.apply(hook("StopFailure", extra: ["error": "rate_limit", "error_details": "429 Too Many Requests"]))
        #expect(s.sessions["s1"]?.lastError == "429 Too Many Requests")
        _ = s.apply(hook("StopFailure", extra: ["error": "rate_limit"]))
        #expect(s.sessions["s1"]?.lastError == "rate_limit")
    }

    @Test func sessionTitleIsTheDisplayName() throws {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart"))
        #expect(s.sessions["s1"]?.displayName == "proj")
        let raw = #"{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/tmp/proj","session_title":"api work"}"#
        let p = try HookPayload.decode(Data(raw.utf8))
        _ = s.apply(HookMessage(id: "m", wantsReply: false, payload: p, env: HookEnv(claudePid: 100, attended: "1")))
        #expect(s.sessions["s1"]?.displayName == "api work" && s.sessions["s1"]?.projectName == "proj")
        _ = s.apply(hook("UserPromptSubmit", extra: ["session_title": "renamed"]))
        #expect(s.sessions["s1"]?.displayName == "renamed")
    }

    @Test func installerHasStopFailure() throws { // 6
        let path = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"
        let out = try #require(try HookInstaller.install(settings: nil, hookPath: path))
        let hooks = try #require(try obj(out)["hooks"] as? [String: Any])
        let h = try #require((hooks["StopFailure"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(h.first?["timeout"] as? Int == 5)
        #expect(try HookInstaller.install(settings: out, hookPath: path) == nil)
    }

    @Test func perUserInboxFolder() { // 7
        let uid = getuid()
        #expect(InboxClient.validatedSocket("/tmp/cc-socks-\(uid)/42.sock", claudePid: 42) == "/private/tmp/cc-socks-\(uid)/42.sock")
        #expect(InboxClient.validatedSocket("/tmp/cc-socks/42.sock", claudePid: 42) == "/private/tmp/cc-socks/42.sock")
        #expect(InboxClient.validatedSocket("/tmp/cc-socks-\(uid + 1)/42.sock", claudePid: 42) == nil)
        #expect(InboxClient.validatedSocket("/tmp/cc-socks-\(uid)/43.sock", claudePid: 42) == nil)
    }

    @Test func uninstallDeletesOnlySettingsBackups() { // 8
        let steps = UninstallPlan.steps(editors: [], home: "/h", appPath: "/a/Buddy.app")
        #expect(steps[1] == .removeSettingsBackups(dir: "/h/.claude"))
        #expect(UninstallPlan.isSettingsBackup("settings.json.buddy-backup-20261105-120000-000"))
        #expect(!UninstallPlan.isSettingsBackup("settings.json"))
        #expect(!UninstallPlan.isSettingsBackup("settings.local.json.buddy-backup-1"))
        #expect(!UninstallPlan.isSettingsBackup(".settings.buddy-tmp"))
    }
}

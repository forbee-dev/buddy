import Foundation
import Testing
@testable import BuddyCore

@Suite struct SessionStoreTests {
    @Test func basicLifecycle() {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", extra: ["source": "startup"]))
        #expect(s.sessions["s1"]?.state == .starting)
        #expect(s.sessions["s1"]?.projectName == "proj")
        _ = s.apply(hook("UserPromptSubmit"))
        #expect(s.sessions["s1"]?.state == .working)
        _ = s.apply(hook("Stop", extra: ["last_assistant_message": "All done"]))
        #expect(s.sessions["s1"]?.state == .done)
        #expect(s.sessions["s1"]?.lastMessage == "All done")
        _ = s.apply(hook("SessionEnd", extra: ["reason": "prompt_input_exit"]))
        #expect(s.sessions["s1"]?.state == .ended)
    }

    @Test func permissionAnsweredInTerminal() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)]))
        #expect(s.sessions["s1"]?.state == .needsPermission)
        #expect(s.sessions["s1"]?.pending?.id == "r1")
        let c = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash"]))
        #expect(c.staleRequests == ["r1"])
        #expect(s.sessions["s1"]?.pending == nil)
        #expect(s.sessions["s1"]?.state == .working)
        #expect(s.sessions["s1"]?.note == "Answered in terminal")
        let resolved = s.resolve(sid: "s1", requestId: "r1")
        #expect(resolved == false)
    }

    @Test func questionViaPermissionRequestAndBuddyAnswer() {
        var s = SessionStore()
        _ = s.apply(hook("PreToolUse", extra: ["tool_name": "AskUserQuestion"]))
        #expect(s.sessions["s1"]?.state == .asking)
        _ = s.apply(hook("PermissionRequest", id: "q1", extra: ["tool_name": "AskUserQuestion"]))
        #expect(s.sessions["s1"]?.pending?.kind == .question)
        let resolved = s.resolve(sid: "s1", requestId: "q1")
        #expect(resolved)
        #expect(s.sessions["s1"]?.state == .working)
        let after = s.apply(hook("PostToolUse", extra: ["tool_name": "AskUserQuestion"]))
        #expect(after.staleRequests.isEmpty)
    }

    @Test func connectionCloseClearsCard() {
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash"]))
        let closed = s.requestClosed(sid: "s1", requestId: "r1")
        #expect(closed)
        #expect(s.sessions["s1"]?.pending == nil)
        #expect(s.sessions["s1"]?.state == .working)
    }

    @Test func toolFailureShowsErrorAndClearsCard() {
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash"]))
        let c = s.apply(hook("PostToolUseFailure", extra: ["tool_name": "Bash", "error": "Exit code 1"]))
        #expect(c.staleRequests == ["r1"])
        #expect(s.sessions["s1"]?.state == .error)
        _ = s.apply(hook("UserPromptSubmit"))
        #expect(s.sessions["s1"]?.state == .working)
    }

    @Test func reaperEndsDeadSessions() {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", session: "a", pid: 1))
        _ = s.apply(hook("SessionStart", session: "b", pid: 2))
        let ended = s.reap { $0 == 1 }.ended
        #expect(ended == ["b"])
        #expect(s.sessions["b"]?.state == .ended)
        #expect(s.sessions["a"]?.state == .starting)
    }

    @Test func clearRekeysSameProcess() {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", session: "old", pid: 7))
        let key = s.sessions["old"]?.mascotKey
        _ = s.apply(hook("SessionEnd", session: "old", pid: 7, extra: ["reason": "clear"]))
        #expect(s.sessions["old"]?.state == .idle)
        _ = s.apply(hook("SessionStart", session: "new", pid: 7, extra: ["source": "clear"]))
        #expect(s.sessions["old"] == nil)
        #expect(s.sessions["new"]?.mascotKey == key)
    }

    @Test func unattendedHidden() {
        var s = SessionStore()
        var m = hook("SessionStart")
        m.env.attended = "0"
        _ = s.apply(m)
        #expect(s.sessions["s1"]?.hidden == true)
    }
}

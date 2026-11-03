import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct StoreReleaseTests {
    @Test func rekeyReleasesPending() { // C1
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", session: "old", id: "r", pid: 7, extra: ["tool_name": "Bash"]))
        let c = s.apply(hook("SessionStart", session: "new", pid: 7, extra: ["source": "clear"]))
        #expect(c.staleRequests == ["r"])
        #expect(s.sessions["new"]?.pending == nil)
    }

    @Test func reapReleasesPending() { // C1
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r", pid: 7, extra: ["tool_name": "Bash"]))
        let r = s.reap { _ in false }
        #expect(r.ended == ["s1"] && r.stale == ["r"])
    }

    @Test func parallelBashMatchesToolUseId() { // C3
        var s = SessionStore()
        _ = s.apply(toolHook("PermissionRequest", id: "A", useId: "use-a"))
        let replaced = s.apply(toolHook("PermissionRequest", id: "B", useId: "use-b"))
        #expect(replaced.staleRequests == ["A"])
        let otherTool = s.apply(toolHook("PostToolUse", useId: "use-a"))
        #expect(otherTool.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.pending?.id == "B")
        let denied = s.apply(toolHook("PermissionDenied", useId: "use-a"))
        #expect(denied.staleRequests.isEmpty && s.sessions["s1"]?.pending?.id == "B")
        let own = s.apply(toolHook("PostToolUseFailure", useId: "use-b"))
        #expect(own.staleRequests == ["B"])
        // No tool_use_id on either side: fall back to the tool name.
        _ = s.apply(hook("PermissionRequest", id: "C", extra: ["tool_name": "Bash"]))
        let byName = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash"]))
        #expect(byName.staleRequests == ["C"])
    }

    @Test func endedSessionIgnoresAllButSessionStart() { // C4
        var s = SessionStore()
        _ = s.apply(hook("SessionEnd", extra: ["reason": "logout"]))
        #expect(s.sessions["s1"]?.state == .ended)
        _ = s.apply(hook("Stop"))
        #expect(s.sessions["s1"]?.state == .ended)
        _ = s.apply(hook("SessionStart"))
        #expect(s.sessions["s1"]?.state == .starting)
        let revived = s.removeIfEnded("s1")
        #expect(!revived)
        _ = s.apply(hook("SessionEnd", extra: ["reason": "logout"]))
        let removed = s.removeIfEnded("s1")
        #expect(removed && s.sessions["s1"] == nil)
    }

    @Test func sessionStartFromOtherPidOnlyIfOldIsDead() { // Low: env takeover
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", pid: 10))
        _ = s.apply(hook("SessionStart", pid: 11), isAlive: { _ in true })
        #expect(s.sessions["s1"]?.env.claudePid == 10)
        _ = s.apply(hook("SessionStart", pid: 11), isAlive: { $0 != 10 })
        #expect(s.sessions["s1"]?.env.claudePid == 11)
    }
}

/// Request id → connection binding, as `AppModel` uses it. Tokens stand in for connections.
@Suite struct PendingRepliesTests {
    func permission(_ id: String, session: String = "s1") -> HookMessage {
        hook("PermissionRequest", session: session, id: id, extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)])
    }

    @Test func staleRequestIdSendsNothing() {
        var store = SessionStore()
        var replies = PendingReplies<Int>()
        _ = store.apply(permission("old"))
        replies.hold("old", sid: "s1", token: 1)
        let c = store.apply(permission("new"))
        replies.hold("new", sid: "s1", token: 2)
        #expect(c.staleRequests == ["old"])
        // The card that showed "old" answers late: nothing is sent, and "new" stays open and held.
        let late = replies.answer(sid: "s1", requestId: "old", store: &store)
        #expect(late == .stale)
        #expect(store.sessions["s1"]?.pending?.id == "new")
        #expect(replies.contains("new"))
        // Another session's id never answers this one.
        let otherSession = replies.answer(sid: "s2", requestId: "new", store: &store)
        #expect(otherSession == .stale)
        let current = replies.answer(sid: "s1", requestId: "new", store: &store)
        #expect(current == .send(2))
        #expect(!replies.contains("new"))
        let twice = replies.answer(sid: "s1", requestId: "new", store: &store)
        #expect(twice == .stale)
    }

    @Test func currentCardWithAGoneHookIsNotDelivered() {
        var store = SessionStore()
        var replies = PendingReplies<Int>()
        _ = store.apply(permission("r1"))
        let r = replies.answer(sid: "s1", requestId: "r1", store: &store)
        #expect(r == .notDelivered)
        #expect(store.sessions["s1"]?.pending == nil)
    }

    @Test func heldOnlyWhenTheSessionShowsThisRequest() {
        var store = SessionStore()
        let msg = permission("r1")
        _ = store.apply(msg)
        #expect(PendingReplies<Int>.shouldHold(msg, in: store))
        // A message that did not become the pending request (an older id, or no reply wanted) is not held.
        #expect(!PendingReplies<Int>.shouldHold(permission("r0"), in: store))
        #expect(!PendingReplies<Int>.shouldHold(hook("Stop", id: "r1"), in: store))
        // A hidden session never holds a hook.
        var hidden = SessionStore()
        var quiet = permission("h1", session: "q")
        quiet.env.attended = "0"
        _ = hidden.apply(quiet)
        #expect(hidden.sessions["q"]?.pending == nil)
        #expect(!PendingReplies<Int>.shouldHold(quiet, in: hidden))
    }

    @Test func closeClearsOnlyThatConnection() {
        var replies = PendingReplies<Int>()
        replies.hold("a", sid: "s1", token: 1)
        replies.hold("b", sid: "s2", token: 1)
        replies.hold("c", sid: "s3", token: 2)
        let closed = replies.closed(1)
        #expect(closed.map(\.id) == ["a", "b"] && closed.map(\.sid) == ["s1", "s2"])
        #expect(!replies.contains("a") && !replies.contains("b") && replies.contains("c"))
        let again = replies.closed(1)
        #expect(again.isEmpty)
    }

    /// Both sockets check `contains` before the store sees the message, and `hold` keeps the first connection.
    @Test func duplicateIdIsRejected() {
        var replies = PendingReplies<Int>()
        let first = replies.hold("dup", sid: "s1", token: 1)
        #expect(first && replies.contains("dup"))
        let second = replies.hold("dup", sid: "s2", token: 2)
        #expect(!second)
        let taken = [replies.take("dup"), replies.take("dup")]
        #expect(taken == [1, nil])
    }

    @Test func staleIdsFromStoreChangeGetNull() {
        var store = SessionStore()
        var replies = PendingReplies<Int>()
        _ = store.apply(toolHook("PermissionRequest", id: "r1", useId: "t1"))
        replies.hold("r1", sid: "s1", token: 7)
        replies.hold("other", sid: "s9", token: 8)
        let c = store.apply(toolHook("PostToolUse", useId: "t1"))
        #expect(c.staleRequests == ["r1"])
        let stale = replies.takeStale(c.staleRequests + ["unknown"])
        #expect(stale.map(\.id) == ["r1"] && stale.map(\.token) == [7])
        #expect(!replies.contains("r1") && replies.contains("other"))
    }
}

@Suite struct SessionScopedRequestTests {
    /// The same request id in two sessions: answering or closing one never touches the other.
    @Test func sameIdInTwoSessions() {
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", session: "a", id: "same", pid: 100, extra: ["tool_name": "Bash"]))
        _ = s.apply(hook("PermissionRequest", session: "b", id: "same", pid: 200, extra: ["tool_name": "Bash"]))
        let resolved = s.resolve(sid: "b", requestId: "same")
        #expect(resolved)
        #expect(s.sessions["a"]?.pending?.id == "same")
        #expect(s.sessions["b"]?.pending == nil)
        let closed = s.requestClosed(sid: "a", requestId: "same")
        #expect(closed)
        #expect(s.sessions["a"]?.note == "Answered in terminal")
        let again = s.requestClosed(sid: "b", requestId: "same")
        #expect(!again)
    }

    @Test func sshOffEndsOnlyRemoteSessions() {
        var s = SessionStore()
        let origin = RemoteOrigin(host: "devbox", user: "t", sshPid: 900, claudePid: 42)
        let remote = HookMessage(id: "rr", wantsReply: true,
                                 payload: .object(["session_id": "r1", "hook_event_name": "PermissionRequest", "tool_name": "Bash"]),
                                 env: HookEnv(attended: "1"))
        _ = s.apply(remote, origin: origin, isAlive: { _ in true })
        _ = s.apply(hook("UserPromptSubmit", session: "local"))
        let r = s.endRemoteSessions()
        #expect(r.ended == ["r1"] && r.stale == ["rr"])
        #expect(s.sessions["r1"]?.state == .ended)
        #expect(s.sessions["local"]?.state == .working)
    }

    @Test func reapReportsNoChangeWhenNothingChanged() {
        var s = SessionStore()
        _ = s.apply(hook("UserPromptSubmit"))
        let alive = s.reap(isAlive: { _ in true })
        #expect(!alive.changed)
        let gone = s.reap(isAlive: { _ in false })
        #expect(gone.changed && gone.ended == ["s1"])
    }
}

@Suite struct AnswerRoutingTests {
    @Test func answerFromOtherSessionIsNotDelivered() {
        var store = SessionStore()
        var replies = PendingReplies<Int>()
        _ = store.apply(hook("PermissionRequest", session: "A", id: "a1", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)]))
        _ = store.apply(hook("PermissionRequest", session: "B", id: "x", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)]))
        replies.hold("x", sid: "B", token: 2)
        #expect(replies.answer(sid: "A", requestId: "x", store: &store) == .stale)
        // Same id shown on A too: the hold still belongs to B.
        _ = store.apply(hook("PermissionRequest", session: "A", id: "x", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)]))
        #expect(replies.answer(sid: "A", requestId: "x", store: &store) == .notDelivered)
        #expect(replies.contains("x"))
    }

    @Test func staleJumpTicketIsRejected() {
        let old = JumpTicket(generation: 1)
        #expect(old.isCurrent(jumpGenerationNow: 1))
        #expect(!old.isCurrent(jumpGenerationNow: 2))
    }
}

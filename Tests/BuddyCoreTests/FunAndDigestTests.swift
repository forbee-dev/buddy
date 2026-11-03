import Foundation
import Testing
@testable import BuddyCore

private func inAgent(_ event: String, _ agent: String, _ extra: [String: JSONValue] = [:], id: String = UUID().uuidString) -> HookMessage {
    var e: [String: JSONValue] = ["agent_id": .string(agent), "agent_type": "general-purpose"]
    e.merge(extra) { $1 }
    return hook(event, id: id, extra: e)
}

@Suite struct ImpatienceAndDigestTests {
    @Test func levels() {
        #expect(Impatience.level(waited: 179, after: 180) == 0)
        #expect(Impatience.level(waited: 180, after: 180) == 1)
        #expect(Impatience.level(waited: 359, after: 180) == 1)
        #expect(Impatience.level(waited: 360, after: 180) == 2)
        #expect(Impatience.level(waited: 9999, after: nil) == 0)
        #expect(Impatience.level(waited: 9999, after: 0) == 0)
        #expect(Impatience.label(waited: 365) == "waiting 6m")
    }

    @Test func waitingSinceFollowsTheCard() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 5_000)
        _ = s.apply(hook("PermissionRequest", id: "r1", extra: ["tool_name": "Bash"]), now: t0)
        _ = s.apply(inAgent("SubagentStart", "a1"), now: t0.addingTimeInterval(60))
        #expect(s.sessions["s1"]?.waitingSince == t0)
        _ = s.resolve(sid: "s1", requestId: "r1")
        #expect(s.sessions["s1"]?.waitingSince == nil)
    }

    @Test func digestOrderAndPlurals() {
        var s = SessionStore()
        let away = Date(timeIntervalSince1970: 10_000), now = away.addingTimeInterval(20 * 60)
        _ = s.apply(hook("Stop", session: "old"), now: away.addingTimeInterval(-60))
        _ = s.apply(hook("Stop", session: "api", extra: ["cwd": "/x/api-gateway"]), now: now.addingTimeInterval(-12 * 60))
        _ = s.apply(hook("PermissionRequest", session: "docs", id: "r1", extra: ["cwd": "/x/docs-site", "tool_name": "Bash"]),
                    now: now.addingTimeInterval(-4 * 60))
        for (i, a) in ["f1", "f2"].enumerated() {
            _ = s.apply(hook("PreToolUse", session: "web", extra: ["tool_name": "Agent", "tool_use_id": .string("t\(i)")]), now: away)
            _ = s.apply(hook("SubagentStart", session: "web", extra: ["agent_id": .string(a)]), now: away)
            _ = s.apply(hook("PostToolUseFailure", session: "web", extra: ["tool_name": "Agent", "tool_use_id": .string("t\(i)")]),
                        now: now.addingTimeInterval(-60))
        }
        _ = s.apply(hook("PostToolUse", session: "web", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"x","run_in_background":true}"#),
                                                               "tool_response": json(#"{"backgroundTaskId":"b1"}"#)]), now: away)
        _ = s.apply(hook("UserPromptSubmit", session: "web", extra: ["task_id": "b1"]), now: now.addingTimeInterval(-30))
        let lines = AwayDigest.build(Array(s.sessions.values), since: away, now: now)
        #expect(lines.map(\.text) == ["api-gateway finished 12 min ago", "docs-site waiting 4 min", "2 subagents failed", "1 shell finished"])
        #expect(lines.map(\.sessionId) == ["api", "docs", "web", "web"])
        #expect(AwayDigest.focus(lines) == "docs")
        #expect(AwayDigest.build(Array(s.sessions.values), since: now, now: now.addingTimeInterval(60)).isEmpty)
        #expect(AwayDigest.focus([]) == nil)
    }
}

@Suite struct FunTests {
    private func tip(_ tool: String, _ input: String) -> String? { Tips.match(tool: tool, input: json(input)) }

    @Test func tipPatterns() {
        #expect(tip("Bash", #"{"command":"cd app && npm test -- --watch=false"}"#) == "It looks like you're running tests. Want me to cheer?")
        #expect(tip("Edit", #"{"file_path":"/p/db/migrations/0042_users.rb"}"#)?.contains("migration") == true)
        #expect(tip("Write", #"{"file_path":"/p/schema.SQL"}"#)?.contains("migration") == true)
        #expect(tip("Bash", #"{"command":"git push origin main"}"#)?.contains("shipping") == true)
        #expect(tip("Grep", "{}")?.contains("searching") == true)
        #expect(tip("Bash", #"{"command":"ls -la"}"#) == nil)
        #expect(tip("Read", #"{"file_path":"/p/a.sql"}"#) == nil)
        #expect(Tips.match(tool: nil, input: nil) == nil)
        // A tip never quotes the command.
        for r in Tips.rules { #expect(!r.text.contains("npm") && !r.text.contains("git ")) }
        #expect(Tips.rules.count >= 15)
    }

    @Test func storeKeepsTheNewestTipOnly() {
        var s = SessionStore()
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"swift test"}"#)]))
        #expect(s.sessions["s1"]?.tip?.contains("tests") == true)
        _ = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash", "tool_input": json(#"{"command":"ls"}"#)]))
        #expect(s.sessions["s1"]?.tip == nil)
    }

    @Test func tipRateLimit() {
        var l = TipLimiter()
        let t = Date(timeIntervalSince1970: 0)
        do { let ok = l.allow("a", now: t); #expect(ok) }
        do { let ok = l.allow("a", now: t.addingTimeInterval(3599)); #expect(!ok) }
        do { let ok = l.allow("b", now: t.addingTimeInterval(10)); #expect(ok) }
        do { let ok = l.allow("a", now: t.addingTimeInterval(3600)); #expect(ok) }
        l.forget("a")
        l.forget("b")
        #expect(l.count == 0)
        do { let ok = l.allow("a", now: t.addingTimeInterval(3601)); #expect(ok) }
    }

    @Test func highFivePartner() {
        let t = Date(timeIntervalSince1970: 0)
        let a = HighFive.Finish(key: "a", at: t, x: 100, slot: nil)
        let far = HighFive.Finish(key: "far", at: t, x: 900, slot: nil)
        let late = HighFive.Finish(key: "late", at: t.addingTimeInterval(-4), x: 150, slot: nil)
        let near = HighFive.Finish(key: "near", at: t.addingTimeInterval(-2), x: 300, slot: nil)
        #expect(HighFive.partner(for: a, among: [a, far, late, near])?.key == "near")
        #expect(HighFive.partner(for: a, among: [far, late]) == nil)
        let g1 = HighFive.Finish(key: "g1", at: t, x: 0, slot: 2), g2 = HighFive.Finish(key: "g2", at: t, x: 900, slot: 3)
        #expect(HighFive.partner(for: g1, among: [g2])?.key == "g2")
    }
}

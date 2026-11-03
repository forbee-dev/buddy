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

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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

@Suite struct SkinTests {
    private static let loaded = Result { try SpriteSheet.load(Data(contentsOf: repo.appendingPathComponent("design/sprites.json"))) }
    static var base: SpriteSheet { get throws { try loaded.get() } }
    static let blank = Array(repeating: String(repeating: ".", count: 32), count: 32)
    static var crateJSON: [String: Any] {
        let data = (try? Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json"))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A small outfit-and-palette skin, changed by `patch`.
    private func skin(_ patch: (inout [String: Any]) -> Void) throws -> Skin {
        var rows = Self.blank
        rows[9] = String(repeating: ".", count: 14) + "KAAK" + String(repeating: ".", count: 14)
        var obj: [String: Any] = ["name": "example", "author": "Buddy", "palettes": ["mint-neon": try Self.base.palettes["claude"] ?? [:]],
                                  "outfits": ["antenna": ["label": "Antenna", "rows": rows]]]
        patch(&obj)
        return try SkinLoader.validate(JSONSerialization.data(withJSONObject: obj), base: Self.base)
    }

    private func rejects(_ e: SkinError, _ patch: (inout [String: Any]) -> Void, line: Int = #line) {
        do {
            _ = try skin(patch)
            Issue.record("accepted, expected \(e) (line \(line))")
        } catch {
            #expect(error as? SkinError == e, "line \(line)")
        }
    }

    /// Crate with one state changed.
    private func crate(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { o in
            o = Self.crateJSON
            var bases = o["bases"] as? [String: Any] ?? [:]
            var c = bases["crate"] as? [String: Any] ?? [:]
            change(&c)
            bases["crate"] = c
            o["bases"] = bases
        }
    }

    @Test func outfitSkinMergesUnderItsName() throws {
        let s = try skin { _ in }
        let merged = try Self.base.merged([s])
        #expect(merged.outfits["example/antenna"]?.label == "Antenna (example)")
        #expect(merged.paletteNames.contains("example/mint-neon"))
        #expect(merged.outfits(fitting: "clawd").contains("example/antenna"))
        // Same names as built-ins stay apart.
        let clash = try skin { o in o["outfits"] = ["cap": (o["outfits"] as? [String: Any])?["antenna"] as Any]; o["palettes"] = nil }
        let both = try Self.base.merged([clash])
        #expect(both.outfits["cap"]?.label == (try Self.base).outfits["cap"]?.label)
        #expect(both.outfits["example/cap"] != nil)
        let f = try #require(merged.anim(base: "clawd", chain: ["idle"])?.frames.first)
        let r = SpriteRenderer.render(sheet: merged, frame: f, look: Look(base: "clawd", palette: "example/mint-neon", outfit: "example/antenna"), mirrored: false)
        #expect(r.missing.isEmpty)
    }

    @Test func charOrColorKeyOfAnotherSkinIsRefused() throws {
        let crate = try SkinLoader.validate(Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json")), base: Self.base)
        let plain = try skin { _ in }
        #expect(SkinLoader.conflict(plain, with: [crate]) == nil)
        let sameChar = try skin { o in o["legend"] = ["Q": "glow"]; o["colors"] = ["glow": "#00FF00"] }
        #expect(SkinLoader.conflict(sameChar, with: [crate]) == .charTaken("Q", "crate"))
        let sameKey = try skin { o in o["legend"] = ["X": "screen"]; o["colors"] = ["screen": "#00FF00"] }
        #expect(SkinLoader.conflict(sameKey, with: [plain, crate]) == .colorTaken("screen", "crate"))
        #expect(SkinLoader.conflict(sameKey, with: []) == nil)
        // A built-in palette key cannot become a fixed color.
        rejects(.builtInColor("body")) { o in o["colors"] = ["body": "#00FF00"] }
    }

    @Test func outfitLabelsAreRevealedAndClipped() throws {
        let s = try skin { o in
            var outfits = o["outfits"] as? [String: Any] ?? [:]
            var a = outfits["antenna"] as? [String: Any] ?? [:]
            a["label"] = "Ant\u{202E}enna " + String(repeating: "x", count: 60)
            outfits["antenna"] = a
            o["outfits"] = outfits
        }
        let label = try #require(s.outfits["antenna"]?.label)
        #expect(label.hasPrefix("Ant\\u{202E}enna") && label.count == 40 && !label.contains("\u{202E}"))
    }

    @Test func crateCharacter() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json"))
        let crate = try SkinLoader.validate(data, base: Self.base)
        let merged = try Self.base.merged([crate])
        #expect(merged.baseNames == ["clawd", "crate/crate"])
        let fits = merged.outfits(fitting: "crate/crate")
        #expect(fits.contains("cap") && fits.contains("crown") && !fits.contains("glasses") && !fits.contains("scarf"))
        #expect(merged.outfits(fitting: "clawd").contains("glasses"))
        for st in SkinLoader.states {
            let f = try #require(merged.anim(base: "crate/crate", chain: [st])?.frames.first)
            let r = SpriteRenderer.render(sheet: merged, frame: f, look: Look(base: "crate/crate", palette: "teal", outfit: "cap"), mirrored: false)
            #expect(r.missing.isEmpty, "\(st)")
        }
        // Without the skin, a crate look still renders (the first base), never crashes.
        #expect(try Self.base.anim(base: "crate/crate", chain: ["idle"]) != nil)
    }

    @Test func rejections() throws {
        #expect(throws: SkinError.tooBig(SkinLoader.maxBytes + 1)) { try SkinLoader.validate(Data(count: SkinLoader.maxBytes + 1), base: Self.base) }
        #expect(throws: SkinError.notJSON) { try SkinLoader.validate(Data("{".utf8), base: Self.base) }
        rejects(.badName) { $0["name"] = "a/b" }
        rejects(.badName) { $0["name"] = nil }
        rejects(.empty) { $0["outfits"] = nil; $0["palettes"] = nil }
        let outfit = ["rows": Self.blank]
        rejects(.tooManyOutfits(65)) { o in o["outfits"] = Dictionary(uniqueKeysWithValues: (0..<65).map { ("o\($0)", outfit) }) }
        let palette = try Self.base.palettes["claude"] ?? [:]
        rejects(.tooManyPalettes(33)) { o in o["palettes"] = Dictionary(uniqueKeysWithValues: (0..<33).map { ("p\($0)", palette) }) }
        rejects(.badKey("bad/key")) { o in o["outfits"] = ["bad/key": outfit] }
        rejects(.badGrid("short")) { o in o["outfits"] = ["short": ["rows": ["...."]]] }
        rejects(.badGrid("wide")) { o in o["outfits"] = ["wide": ["rows": Array(repeating: String(repeating: ".", count: 33), count: 32)]] }
        var odd = Self.blank
        odd[5] = "Q" + String(repeating: ".", count: 31)
        rejects(.unknownChar("odd", "Q")) { o in o["outfits"] = ["odd": ["rows": odd]] }
        rejects(.legendClash("K")) { o in o["legend"] = ["K": "body"] }
        var badHex = palette
        badHex["body"] = "#12345G"
        rejects(.badHex("x", "body")) { o in o["palettes"] = ["x": badHex] }
        var partial = palette
        partial["outline"] = nil
        rejects(.missingColor("x", "outline")) { o in o["palettes"] = ["x": partial] }
        // Characters.
        rejects(.missingState("crate", "error")) { o in crate { c in var st = c["states"] as? [String: Any] ?? [:]; st["error"] = nil; c["states"] = st }(&o) }
        rejects(.mustNotLoop("crate", "done")) { o in crate { c in
            var st = c["states"] as? [String: Any] ?? [:]; var d = st["done"] as? [String: Any] ?? [:]; d["loop"] = true; st["done"] = d; c["states"] = st }(&o) }
        rejects(.badFrames("crate", "idle")) { o in crate { c in
            var st = c["states"] as? [String: Any] ?? [:]; st["idle"] = ["loop": true, "frames": [["rows": ["."]]]]; c["states"] = st }(&o) }
        rejects(.unknownOutfit("crate", "jetpack")) { o in crate { c in c["outfits"] = ["cap", "jetpack"] }(&o) }
        rejects(.missingColor("colors", "screen")) { o in crate { _ in }(&o); o["colors"] = ["screenInk": "#0F380F", "bezel": "#2E3440"] }
        rejects(.tooManyBases(5)) { o in crate { _ in }(&o)
            let c = (o["bases"] as? [String: Any])?["crate"] as Any
            o["bases"] = Dictionary(uniqueKeysWithValues: (0..<5).map { ("c\($0)", c) }) }
    }

    @Test func declaredLegendCharIsAccepted() throws {
        var rows = Self.blank
        rows[4] = "Q" + String(repeating: ".", count: 31)
        let s = try skin { o in o["legend"] = ["Q": "body"]; o["outfits"] = ["q": ["rows": rows]] }
        #expect(try Self.base.merged([s]).legend["Q"] == "body")
    }
}

@Suite struct MixTests {
    private static let loaded = Result {
        let base = try SkinTests.base
        return base.merged([try SkinLoader.validate(Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json")), base: base)])
    }
    static var sheet: SpriteSheet { get throws { try loaded.get() } }
    static let both = ["clawd", "crate/crate"]

    @Test func stablePerProjectAndUsesBoth() throws {
        let sheet = try Self.sheet
        let picks = (0..<24).map { LookPicker.pick(cwd: "/p/\($0)", sheet: sheet, bases: Self.both) }
        #expect(Set(picks.map(\.base)) == Set(Self.both))
        #expect(picks == (0..<24).map { LookPicker.pick(cwd: "/p/\($0)", sheet: sheet, bases: Self.both) })
        for l in picks { if let o = l.outfit { #expect(sheet.outfits(fitting: l.base).contains(o)) } }
    }

    @Test func uniqueCharacterFirstAndFitsRespected() throws {
        let sheet = try Self.sheet
        let mine = Look(base: "clawd", palette: "teal", outfit: "glasses")
        let other = Look(base: "clawd", palette: "mint", outfit: nil)
        let l = LookAssigner.assign(preferred: mine, seed: "/a", taken: [other], sheet: sheet, bases: Self.both)
        #expect(l == Look(base: "crate/crate", palette: "teal", outfit: nil))
        // Every character taken: palette uniqueness counts only buddies with the same character.
        let full = LookAssigner.assign(preferred: Look(base: "crate/crate", palette: "teal", outfit: nil), seed: "/a",
                                       taken: [Look(base: "clawd", palette: "teal", outfit: nil), Look(base: "crate/crate", palette: "mint", outfit: nil)],
                                       sheet: sheet, bases: Self.both)
        #expect(full.base == "crate/crate" && full.palette == "teal")
        var g = SystemRandomNumberGenerator()
        let rolled = LookAssigner.reroll(current: l, taken: [other], sheet: sheet, bases: Self.both, using: &g)
        #expect(rolled != l)
        if rolled.base == "crate/crate", let o = rolled.outfit { #expect(sheet.outfits(fitting: "crate/crate").contains(o)) }
    }

    @Test func fallbackWhenACharacterIsGone() throws {
        let sheet = try Self.sheet
        let l = LookPicker.pick(cwd: "/p/1", sheet: sheet, bases: ["clawd"])
        #expect(l.base == "clawd")
        // The default (no Mix) never picks a skin character.
        for i in 0..<12 { #expect(LookPicker.pick(cwd: "/q/\(i)", sheet: sheet).base == "clawd") }
    }

    @Test func singleCharacterUnchanged() throws {
        let sheet = try Self.sheet, base = try SkinTests.base
        let looks = (0..<10).map { LookPicker.pick(cwd: "/r/\($0)", sheet: base) }
        for (i, l) in looks.enumerated() {
            let taken = Array(looks.prefix(i))
            #expect(LookAssigner.assign(preferred: l, seed: "/r/\(i)", taken: taken, sheet: sheet)
                    == LookAssigner.assign(preferred: l, seed: "/r/\(i)", taken: taken, sheet: sheet, bases: ["clawd"]))
            #expect(LookPicker.pick(cwd: "/r/\(i)", sheet: sheet) == l)
        }
    }
}

/// A class, so each test's temp folder goes away in `deinit`.
@Suite final class UsageTests {
    private let home: String = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-usage-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d + "/proj/sess/subagents", withIntermediateDirectories: true)
        return d
    }()

    deinit { try? FileManager.default.removeItem(atPath: home) }

    private func line(_ id: String, model: String = "claude-opus-5-5", input: Int = 10, output: Int = 100, write: Int = 1000, read: Int = 0) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read)}}}"# + "\n"
    }

    private func append(_ path: String, _ text: String) throws {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    @Test func incrementalDedupedWithSubagents() throws {
        let main = home + "/proj/sess.jsonl"
        try append(main, #"{"type":"user","message":{"content":"SECRET"}}"# + "\n" + line("m1") + line("m1"))
        var m = UsageMeter()
        do { let ok = m.update(transcript: main, home: home); #expect(ok) }
        #expect(m.byModel["claude-opus-5-5"] == TokenCounts(input: 10, output: 100, cacheWrite: 1000, cacheRead: 0))
        // A partial line waits for its newline; a repeated id adds only its growth.
        let next = line("m2", read: 500)
        try append(main, line("m1", output: 140) + String(next.prefix(30)))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1150)
        try append(main, String(next.dropFirst(30)))
        try append(home + "/proj/sess/subagents/agent-a1.jsonl", line("s1", model: "claude-haiku-5-5", input: 1, output: 2, write: 3, read: 4) + line("m2", read: 500))
        try append(home + "/proj/sess/subagents/other.jsonl", line("x9"))
        _ = m.update(transcript: main, home: home)
        #expect(m.byModel["claude-opus-5-5"]?.total == 1150 + 1610)
        #expect(m.byModel["claude-haiku-5-5"]?.total == 10)
        // Nothing new: nothing changes.
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1150 + 1610 + 10)
        // A rewritten file counts from zero again.
        try Data((line("n1")).utf8).write(to: URL(fileURLWithPath: main))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1110 + 10 + 1610)
    }

    @Test func costAndFormat() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/prices.json"))
        let prices = try JSONDecoder().decode(PriceTable.self, from: data)
        #expect(prices.note?.contains("anthropic.com/pricing") == true)
        for m in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] { #expect(prices.models[m] != nil) }
        let table = PriceTable(note: nil, models: ["m": .init(input: 1, output: 10, cacheWrite: 2, cacheRead: 0.5)])
        let usage = ["m": TokenCounts(input: 10_000, output: 20_000, cacheWrite: 10_000, cacheRead: 2_100)]
        #expect(UsageFormat.line(usage, prices: table) == "42.1k tok · $0.23")
        #expect(UsageFormat.line(usage.merging(["new-model": TokenCounts(input: 5)]) { $1 }, prices: table) == "42.1k tok")
        #expect(UsageFormat.line(usage, prices: nil) == "42.1k tok")
        #expect(UsageFormat.tokens(999) == "999 tok")
        #expect(UsageFormat.tokens(999_960) == "1.0M tok")
        #expect(UsageFormat.tokens(3_240_000) == "3.2M tok")
    }

    @Test func hugeOrNegativeCountsAreClampedAndNeverTrap() throws {
        let main = home + "/proj/big.jsonl"
        let huge = #"{"type":"assistant","message":{"id":"h1","model":"m","usage":{"input_tokens":9223372036854775807,"output_tokens":-5,"cache_creation_input_tokens":9000000000000000000,"cache_read_input_tokens":9000000000000000000}}}"#
        try append(main, huge + "\n" + huge.replacingOccurrences(of: "h1", with: "h2") + "\n")
        var m = UsageMeter()
        _ = m.update(transcript: main, home: home)
        let max = TokenCounts.maxField
        #expect(m.byModel["m"] == TokenCounts(input: 2 * max, output: 0, cacheWrite: 2 * max, cacheRead: 2 * max))
        #expect(TokenCounts.add(.max, 1) == .max)
        #expect(TokenCounts(input: .max, output: .max).total == .max)
        #expect(UsageFormat.line(["a": TokenCounts(input: .max), "b": TokenCounts(input: .max)], prices: nil).hasSuffix("M tok"))
    }

    @Test func giantLineIsSkippedNotKept() throws {
        let main = home + "/proj/giant.jsonl"
        try append(main, line("m1"))
        // A line over 8 MB, written in two parts: the reader skips it to its newline, also across updates.
        let giant = #"{"type":"assistant","x":""# + String(repeating: "a", count: 9 << 20)
        try append(main, String(giant.prefix(5 << 20)))
        var m = UsageMeter()
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1110)
        try append(main, String(giant.dropFirst(5 << 20)) + #"","usage":{"input_tokens":7}}"# + "\n" + line("m2"))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 2220)
        try append(main, line("m3"))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 3330)
    }

    @Test func pricesOutsideTheRangeAreRejected() {
        func decode(_ v: String) -> PriceTable? {
            try? JSONDecoder().decode(PriceTable.self, from: Data(#"{"models":{"m":{"input":\#(v),"output":1,"cacheWrite":1,"cacheRead":1}}}"#.utf8))
        }
        #expect(decode("0") != nil && decode("1000") != nil && decode("3.5") != nil)
        for bad in ["-0.01", "1000.01", "1e308", "1e400"] { #expect(decode(bad) == nil, "\(bad)") }
    }

    @Test func unsafePathsAreNotRead() throws {
        let real = home + "/proj/real.jsonl"
        try append(real, line("m1"))
        let link = home + "/proj/link.jsonl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        var m = UsageMeter()
        do { let ok = m.update(transcript: link, home: home); #expect(!ok) }
        do { let ok = m.update(transcript: home + "/proj/../proj/real.jsonl", home: home); #expect(!ok) }
        do { let ok = m.update(transcript: real, home: home + "/elsewhere"); #expect(!ok) }
        do { let ok = m.update(transcript: real, home: home, uid: getuid() + 1); #expect(!ok) }
        let txt = home + "/proj/real.txt"
        try append(txt, line("m1"))
        do { let ok = m.update(transcript: txt, home: home); #expect(!ok) }
        #expect(m.tokens == 0)
        do { let ok = m.update(transcript: home + "/proj/missing.jsonl", home: home); #expect(!ok) }
    }
}

import Foundation
import Testing
@testable import BuddyCore

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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

@Suite struct HookTrustTests {
    let hook = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"
    let app = "/Applications/Buddy.app/Contents/MacOS/Buddy"

    @Test func onlyOurUserAndTheAppNextToTheHook() {
        let uid: uid_t = 501
        #expect(HookTrust.serverAllowed(peerUid: uid, ownUid: uid, peerPath: app, selfPath: hook, names: HookTrust.releaseNames))
        #expect(!HookTrust.serverAllowed(peerUid: 502, ownUid: uid, peerPath: app, selfPath: hook, names: HookTrust.releaseNames))
        #expect(!HookTrust.serverAllowed(peerUid: nil, ownUid: uid, peerPath: app, selfPath: hook, names: HookTrust.releaseNames))
        #expect(!HookTrust.serverAllowed(peerUid: uid, ownUid: uid, peerPath: "/tmp/Buddy.app/Contents/MacOS/Buddy", selfPath: hook,
                                         names: HookTrust.releaseNames))
        #expect(!HookTrust.serverAllowed(peerUid: uid, ownUid: uid, peerPath: nil, selfPath: hook, names: HookTrust.releaseNames))
        #expect(!HookTrust.serverAllowed(peerUid: uid, ownUid: uid, peerPath: app, selfPath: nil, names: HookTrust.releaseNames))
    }

    @Test func releaseNamesRejectTheDebugBinary() {
        let debug = "/Applications/Buddy.app/Contents/MacOS/BuddyApp"
        #expect(!HookTrust.serverAllowed(peerUid: 501, ownUid: 501, peerPath: debug, selfPath: hook, names: HookTrust.releaseNames))
        #expect(HookTrust.serverAllowed(peerUid: 501, ownUid: 501, peerPath: debug, selfPath: hook, names: HookTrust.debugNames))
    }
}

@Suite struct IdleTickTests {
    @Test func sleepingAloneNeedsNoTimer() {
        #expect(TickPolicy.interval(mascots: 1, moving: false, fps: 8, paused: false, idle: true) == nil)
        #expect(TickPolicy.interval(mascots: 1, moving: false, fps: 8, paused: false, idle: false) == 1.0 / 8)
        // Something moves: the timer runs, idle or not.
        #expect(TickPolicy.interval(mascots: 1, moving: true, fps: 8, paused: false, idle: true) == 1.0 / 30)
    }
}

@Suite struct RedactionTests {
    @Test func homeBeforeAPeriodIsRedacted() {
        let home = "/Users/me"
        #expect(DiagnosticsReport.redact("Look in /Users/me.", home: home) == "Look in ~.")
        #expect(DiagnosticsReport.redact("/Users/me/x.", home: home) == "~/x.")
        #expect(DiagnosticsReport.redact("/Users/me.old/x", home: home) == "/Users/me.old/x")
        #expect(DiagnosticsReport.redact("/Users/meta", home: home) == "/Users/meta")
        #expect(DiagnosticsReport.redact("/Users/me..", home: home) == "~..")
    }
}

/// Shared with the extension's tests: `Tests/Fixtures/sanitize-vectors.json`, `[{"in": "...", "out": "..."}]`.
@Suite struct SanitizeVectorTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sanitize-vectors.json")

    struct Vector: Decodable { let `in`: String; let out: String }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: file.path), "Tests/Fixtures/sanitize-vectors.json is not there yet"))
    func sharedVectors() throws {
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: Self.file))
        #expect(!vectors.isEmpty)
        for v in vectors { #expect(PromptGuard.sanitize(v.in) == v.out, "\(v.in.debugDescription)") }
    }
}

@Suite struct SkinLoaderNegativeTests {
    private static let loaded = Result { try SpriteSheet.load(Data(contentsOf: repoRoot.appendingPathComponent("design/sprites.json"))) }
    static var base: SpriteSheet { get throws { try loaded.get() } }
    static let blank = Array(repeating: String(repeating: ".", count: 32), count: 32)

    /// A valid one-palette skin, changed by `patch`.
    func data(_ patch: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        var o: [String: Any] = ["name": "neg", "palettes": ["p": try Self.base.palettes["claude"] ?? [:]]]
        try patch(&o)
        return try JSONSerialization.data(withJSONObject: o)
    }

    func rejects(_ error: SkinError, _ patch: (inout [String: Any]) throws -> Void) throws {
        let d = try data(patch)
        let base = try Self.base
        #expect(throws: error) { try SkinLoader.validate(d, base: base) }
    }

    /// The crate character from design/skins, with one state changed.
    func crate(_ state: String, _ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) throws -> Void {
        { o in
            let file = try JSONSerialization.jsonObject(with: Data(contentsOf: repoRoot.appendingPathComponent("design/skins/crate.json")))
            let src = try #require(file as? [String: Any])
            var bases = try #require(src["bases"] as? [String: Any])
            var c = try #require(bases["crate"] as? [String: Any])
            var states = try #require(c["states"] as? [String: Any])
            var st = try #require(states[state] as? [String: Any])
            change(&st)
            states[state] = st
            c["states"] = states
            bases["crate"] = c
            o["bases"] = bases
            o["legend"] = src["legend"]
            o["colors"] = src["colors"]
            o["palettes"] = src["palettes"]
        }
    }

    @Test func legendKeys() throws {
        try rejects(.legendClash(".")) { $0["legend"] = [".": "body"] }
        try rejects(.badKey("QQ")) { $0["legend"] = ["QQ": "body"] }
    }

    @Test func badFrames() throws {
        func frames(_ f: Any) -> (inout [String: Any]) -> Void { { $0["frames"] = f } }
        let row = Self.blank
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "head": [0, 99]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "head": [0]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "fx": ["...."]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([[String: Any]]())))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames(Array(repeating: ["rows": row], count: 17))))
        // 16 frames is the limit, not over it.
        let d = try data(crate("idle", frames(Array(repeating: ["rows": row], count: 16))))
        #expect(throws: Never.self) { try SkinLoader.validate(d, base: try Self.base) }
    }

    @Test func badHexAndBadKeys() throws {
        try rejects(.badHex("colors", "ink")) { $0["colors"] = ["ink": "red"] }
        try rejects(.badKey("bad key")) { $0["colors"] = ["bad key": "#000000"] }
        try rejects(.badKey("bad/p")) { o in o["palettes"] = ["bad/p": (o["palettes"] as? [String: Any])?["p"] as Any] }
        try rejects(.badKey("bad.o")) { $0["outfits"] = ["bad.o": ["rows": Self.blank]] }
        try rejects(.badKey("bad base")) { o in
            try crate("idle") { _ in }(&o)
            var bases = o["bases"] as? [String: Any] ?? [:]
            bases["bad base"] = bases.removeValue(forKey: "crate")
            o["bases"] = bases
        }
        try rejects(.badKey("bad!")) { $0["legend"] = ["Q": "bad!"] }
    }

    @Test func sizeLimitIsInclusive() throws {
        let base = try Self.base
        var d = try data()
        d.append(Data(repeating: 0x20, count: SkinLoader.maxBytes - d.count))
        #expect(d.count == SkinLoader.maxBytes)
        #expect(throws: Never.self) { try SkinLoader.validate(d, base: base) }
    }

    @Test func duplicateNameIsRefused() throws {
        let base = try Self.base
        var names = Set<String>()
        _ = try SkinLoader.validate(try data(), base: base, names: &names)
        #expect(throws: SkinError.duplicate("neg")) { try SkinLoader.validate(try data(), base: base, names: &names) }
        #expect(names == ["neg"])
    }
}

@Suite struct WireLimitTests {
    @Test func lineOfExactlyTheLimitPasses() throws {
        var buf = LineBuffer()
        let line = Data(repeating: 0x41, count: wireMaxLine)
        #expect(try buf.append(line + Data([0x0A])) == [line])
    }

    @Test func longLineOverChunksFailsBeforeItsNewline() throws {
        var buf = LineBuffer()
        let half = Data(repeating: 0x41, count: wireMaxLine / 2)
        #expect(try buf.append(half).isEmpty)
        #expect(try buf.append(half).isEmpty)
        #expect(throws: WireError.lineTooLong) { try buf.append(Data([0x41])) }
    }

    @Test func emptyLinesAreSkipped() throws {
        var buf = LineBuffer()
        #expect(try buf.append(Data("\n\na\n\nb\n".utf8)) == [Data("a".utf8), Data("b".utf8)])
    }

    @Test func decodeOverTheLimitFails() {
        #expect(throws: WireError.lineTooLong) { try WireMessage.decode(Data(repeating: 0x20, count: wireMaxLine + 1)) }
    }
}

/// A class, so each test's temp folder goes away in `deinit`.
@Suite final class UsageReplaceTests {
    let home: String = {
        let d = PeerCheck.resolved(NSTemporaryDirectory()) + "/buddy-usage-r-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d + "/p", withIntermediateDirectories: true)
        return d
    }()

    deinit { try? FileManager.default.removeItem(atPath: home) }

    func line(_ id: String, type: String = "assistant", model: String = "m", out: Int = 10) -> String {
        #"{"type":"\#(type)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"# + "\n"
    }

    /// Writes a new file under the same name (atomic rename: a new inode).
    func replace(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }

    @Test func replacedTranscriptIsNotDoubleCounted() throws {
        let path = home + "/p/s.jsonl"
        try replace(path, line("a") + line("b"))
        var m = UsageMeter()
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 22)
        // Same size, new inode: counted from zero, not skipped and not added to the old sum.
        try replace(path, line("c", out: 20) + line("d", out: 20))
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 42)
        // Larger, new inode, the same lines plus one more: still no double count.
        try replace(path, line("c", out: 20) + line("d", out: 20) + line("e"))
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 53)
    }

    @Test func syntheticAndNonAssistantLinesAreIgnored() throws {
        let path = home + "/p/t.jsonl"
        try replace(path, line("a", model: "<synthetic>") + line("b", type: "user") + line("c"))
        var m = UsageMeter()
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 11)
        #expect(m.byModel.keys.sorted() == ["m"])
    }
}

@Suite struct ReviewSixTests {
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

import Foundation
import Testing
@testable import BuddyCore

@Suite struct MultiLinePromptTests {
    @Test func newlinesKeptAndControlsDropped() {
        #expect(PromptGuard.sanitize("one\ntwo\r\nthree\rfour") == "one\ntwo\nthree\nfour")
        // No ESC (C0) or CSI (C1) survives, so the text cannot end a bracketed paste.
        #expect(PromptGuard.sanitize("x\u{1B}[201~y\u{9B}201~z") == "x[201~y201~z")
        #expect(PromptGuard.sanitize("\t\n") == "\t\n")
    }

    @Test func inboxKeepsNewlinesInJSON() throws {
        let data = try InboxClient.lines(token: nil, text: PromptGuard.sanitize("a\nb"))
        let msg = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(msg["message"]?["content"]?.string == "a\nb")
    }
}

@Suite struct NotificationActionTests {
    @Test func actionsMapToAnswers() {
        #expect(NotificationActions.decide(.deny, requestId: "r1", pendingId: "r1", enabled: true) == .answer(HookOutput.deny("")))
        #expect(NotificationActions.decide(.review, requestId: "r1", pendingId: "r1", enabled: true) == .open)
        #expect(NotificationActions.decide(.answer, requestId: "r1", pendingId: "r1", enabled: true) == .open)
        #expect(NotificationActions.decide(.open, requestId: "r1", pendingId: "r1", enabled: true) == .open)
    }

    /// Review H1: Allow needs the card. The old `allow` id from an older notification only opens it.
    @Test func noNotificationPathAllows() {
        #expect(NotificationAction(rawValue: "allow") == nil)
        let actions: [NotificationAction] = [.open, .deny, .review, .answer, .reply]
        for a in actions {
            for (req, pending) in [("r1", "r1"), ("old", "r1"), ("r1", nil)] as [(String, String?)] {
                for enabled in [true, false] {
                    let out = NotificationActions.decide(a, requestId: req, pendingId: pending, enabled: enabled, text: "go")
                    if case .answer(let o) = out { #expect(o == HookOutput.deny(""), "\(a)") }
                }
            }
        }
    }

    @Test func staleOrMissingRequestIdRefused() {
        #expect(NotificationActions.decide(.deny, requestId: "old", pendingId: "new", enabled: true) == .alreadyAnswered)
        #expect(NotificationActions.decide(.deny, requestId: "old", pendingId: nil, enabled: true) == .alreadyAnswered)
        #expect(NotificationActions.decide(.deny, requestId: nil, pendingId: "r1", enabled: true) == .alreadyAnswered)
    }

    @Test func actionsNeedTheSetting() {
        #expect(NotificationActions.decide(.deny, requestId: "r1", pendingId: "r1", enabled: false) == .open)
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: false, text: "go") == .open)
    }

    @Test func textReplyGoesThroughPromptGuard() {
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: true,
                                           text: "run tests\r\nthen \u{1B}[2Jcommit") == .sendPrompt("run tests\nthen [2Jcommit"))
        #expect(NotificationActions.decide(.reply, requestId: nil, pendingId: nil, enabled: true, text: " \n\u{7}") == .open)
    }

    @Test func subagentLabelIsMarkedRevealedAndClipped() {
        let note = NotificationActions.subagentNote("Fix\u{202E}gnp.exe\nnow " + String(repeating: "x", count: 60))
        #expect(note.hasPrefix("Claude says: Fix\\u{202E}gnp.exe now "))
        #expect(!note.contains("\u{202E}") && !note.contains("\n"))
        #expect(note.count == "Claude says: ".count + 40 && note.hasSuffix("…"))
    }
}

/// Shared with the extension's tests: `Tests/Fixtures/sanitize-vectors.json`, `[{"in": "...", "out": "..."}]`.
@Suite struct SanitizeVectorTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sanitize-vectors.json")

    struct Vector: Decodable { let `in`: String; let out: String }

    @Test
    func sharedVectors() throws {
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: Self.file))
        #expect(!vectors.isEmpty)
        for v in vectors { #expect(PromptGuard.sanitize(v.in) == v.out, "\(v.in.debugDescription)") }
    }
}

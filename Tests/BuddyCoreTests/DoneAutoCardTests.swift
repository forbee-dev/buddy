import Testing
@testable import BuddyCore

@Suite struct DoneAutoCardTests {
    @Test func opensOnlyOnChangeIntoDone() {
        #expect(DoneAutoCard.shouldOpen(from: .working, to: .done, hasPending: false, cardOpen: false, hidden: false))
        #expect(!DoneAutoCard.shouldOpen(from: .done, to: .done, hasPending: false, cardOpen: false, hidden: false))
        #expect(!DoneAutoCard.shouldOpen(from: nil, to: .done, hasPending: false, cardOpen: false, hidden: false))  // mascot switched sessions
        #expect(!DoneAutoCard.shouldOpen(from: .working, to: .idle, hasPending: false, cardOpen: false, hidden: false))
        #expect(!DoneAutoCard.shouldOpen(from: .working, to: .done, hasPending: true, cardOpen: false, hidden: false))
        #expect(!DoneAutoCard.shouldOpen(from: .working, to: .done, hasPending: false, cardOpen: true, hidden: false))
        #expect(!DoneAutoCard.shouldOpen(from: .working, to: .done, hasPending: false, cardOpen: false, hidden: true))
    }

    @Test func closesOnlyUntouchedAfterDelay() {
        #expect(!DoneAutoCard.shouldClose(elapsed: 7.9, touched: false))
        #expect(DoneAutoCard.shouldClose(elapsed: 8, touched: false))
        #expect(!DoneAutoCard.shouldClose(elapsed: 30, touched: true))
    }

    @Test func doneOutlivesIdlePrompt() {
        var s = SessionStore()
        _ = s.apply(hook("Stop", session: "d", pid: 1))
        _ = s.apply(hook("Notification", session: "d", pid: 1, extra: ["notification_type": "idle_prompt"]))
        #expect(s.sessions["d"]?.state == .done)
    }
}

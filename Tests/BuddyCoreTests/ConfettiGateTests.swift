import Testing
@testable import BuddyCore

@Suite struct ConfettiGateTests {
    @Test func burstsOnlyOnChangeIntoDone() {
        #expect(ConfettiGate.shouldBurst(from: .working, to: .done, reduceMotion: false, hidden: false, live: 0))
        #expect(!ConfettiGate.shouldBurst(from: .done, to: .done, reduceMotion: false, hidden: false, live: 0))
        #expect(!ConfettiGate.shouldBurst(from: nil, to: .done, reduceMotion: false, hidden: false, live: 0))
        #expect(!ConfettiGate.shouldBurst(from: .working, to: .idle, reduceMotion: false, hidden: false, live: 0))
    }

    @Test func respectsReduceMotionHiddenAndCap() {
        #expect(!ConfettiGate.shouldBurst(from: .working, to: .done, reduceMotion: true, hidden: false, live: 0))
        #expect(!ConfettiGate.shouldBurst(from: .working, to: .done, reduceMotion: false, hidden: true, live: 0))
        #expect(ConfettiGate.shouldBurst(from: .working, to: .done, reduceMotion: false, hidden: false, live: ConfettiGate.maxLive - 1))
        #expect(!ConfettiGate.shouldBurst(from: .working, to: .done, reduceMotion: false, hidden: false, live: ConfettiGate.maxLive))
    }
}

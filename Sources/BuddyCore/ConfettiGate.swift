import Foundation

/// When a finish throws confetti out of the buddy's frame.
public enum ConfettiGate {
    public static let maxLive = 3

    /// Only on the change into done, with motion allowed, visible buddies, and a free burst slot.
    public static func shouldBurst(from old: SessionState?, to new: SessionState, reduceMotion: Bool, hidden: Bool, live: Int) -> Bool {
        new == .done && old != nil && old != .done && !reduceMotion && !hidden && live < maxLive
    }
}

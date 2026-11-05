import Foundation

/// When the done card opens and closes by itself.
public enum DoneAutoCard {
    public static let closeAfter = 8.0

    /// Only on the change into done, with no request pending, a closed card, and visible buddies.
    public static func shouldOpen(from old: SessionState?, to new: SessionState, hasPending: Bool, cardOpen: Bool, hidden: Bool) -> Bool {
        new == .done && old != nil && old != .done && !hasPending && !cardOpen && !hidden
    }

    public static func shouldClose(elapsed: Double, touched: Bool) -> Bool {
        !touched && elapsed >= closeAfter
    }
}

import Foundation

/// Whether a banner is worth posting: Buddy's own card and sound already tell a user who sees the mascot.
public enum NotificationGate {
    /// `away` covers screen sleep, a locked or switched-out session, and system idle.
    public static func shouldPost(buddiesHidden: Bool, away: Bool, alsoWhenVisible: Bool) -> Bool {
        alsoWhenVisible || buddiesHidden || away
    }
}

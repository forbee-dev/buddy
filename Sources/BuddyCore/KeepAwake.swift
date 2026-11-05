import Foundation

/// When Buddy holds the "no idle sleep" assertion.
public enum KeepAwake {
    /// Only for a visible local session that starts or works; remote ones run on another machine.
    public static func shouldHold(sessions: some Collection<Session>, enabled: Bool) -> Bool {
        enabled && sessions.contains { !$0.hidden && $0.remote == nil && ($0.state == .working || $0.state == .starting) }
    }
}

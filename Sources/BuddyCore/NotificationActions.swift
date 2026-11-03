import Foundation

/// Action identifiers on Buddy's notifications. Anything else (the default click, or the old `allow`) is `open`.
/// No notification action can allow a request: Allow needs the card.
public enum NotificationAction: String, Sendable { case open, deny, review, answer, reply }

public enum NotificationOutcome: Equatable, Sendable {
    case open
    case answer(JSONValue)
    case sendPrompt(String)
    /// The notification's request is no longer the pending one: send nothing, say so.
    case alreadyAnswered
}

public enum NotificationActions {
    public static let armDelay: TimeInterval = 0.7

    /// `requestId` comes from the notification; `pendingId` is the session's pending request now.
    public static func decide(_ action: NotificationAction, requestId: String?, pendingId: String?,
                              enabled: Bool, text: String? = nil) -> NotificationOutcome {
        guard enabled else { return .open }
        switch action {
        case .open, .review, .answer:
            return .open
        case .deny:
            guard let requestId, requestId == pendingId else { return .alreadyAnswered }
            return .answer(HookOutput.deny(""))
        case .reply:
            let clean = PromptGuard.sanitize(text ?? "")
            return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .open : .sendPrompt(clean)
        }
    }

    /// Model-written subagent label for a notification body: revealed, one line, max 40 characters, marked as Claude's.
    public static func subagentNote(_ label: String) -> String { "Claude says: \(Activity.clip(label.replacingOccurrences(of: "\n", with: " "), 40))" }
}

import AppKit
import UserNotifications
import BuddyCore

/// macOS notifications. A click opens the session bubble and jumps to the terminal.
/// Actions (Deny, Review…, Answer…, Reply…) carry the session id and the request id. Only Deny answers, through
/// `AppModel.answer`; Allow exists only on the card, where the user sees the full request.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    static let permissionCategory = "buddy.permission", questionCategory = "buddy.question", doneCategory = "buddy.done"
    /// Request id of the last request notification per session, so a replaced request gets a new one.
    private var posted: [String: String] = [:]
    /// Sessions with a request alert out, so `clear` skips the notification center for the others.
    private var alerted: Set<String> = []

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Unlock first: nothing is answered from the lock screen.
        let deny = UNNotificationAction(identifier: NotificationAction.deny.rawValue, title: "Deny", options: [.authenticationRequired, .destructive])
        let review = UNNotificationAction(identifier: NotificationAction.review.rawValue, title: "Review…", options: [.foreground])
        let answer = UNNotificationAction(identifier: NotificationAction.answer.rawValue, title: "Answer…", options: [.foreground])
        let reply = UNTextInputNotificationAction(identifier: NotificationAction.reply.rawValue, title: "Reply…", options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Next prompt")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [deny, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.questionCategory, actions: [answer], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.doneCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    private static func requestId(_ sid: String) -> String { "buddy-\(sid)" }

    /// Removes the request alert (delivered or still scheduled) once the request is answered or gone.
    func clear(sessionId: String) {
        posted[sessionId] = nil
        guard alerted.remove(sessionId) != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestId(sessionId)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestId(sessionId)])
    }

    func isNewRequest(_ s: Session) -> Bool { s.pending.map { posted[s.id] != $0.id } ?? false }

    /// The body names the tool and the project only, never the command (lock screen privacy).
    /// `stillWaiting`: minutes, for the one reminder of an impatient buddy. Focus and Do Not Disturb are left to macOS.
    func post(for s: Session, model: AppModel, stillWaiting: Int? = nil) {
        guard !s.hidden else { return }
        // The subagent label is model-written: marked, revealed, and clipped.
        let note = s.pending?.agentId.map { " " + NotificationActions.subagentNote(s.subagentLabel($0)) } ?? ""
        let tool = DisplayText.reveal(s.pending?.toolName ?? "A tool")
        let body: String
        var category: String?
        var id = Self.requestId(s.id)
        switch s.state {
        case .needsPermission where model.notifyPermission:
            body = note.isEmpty ? "\(tool) needs your permission." : "A subagent wants to run \(tool).\(note)"
            if s.pending?.kind == .permission { category = Self.permissionCategory }
        case .asking where model.notifyQuestion:
            body = note.isEmpty ? "Claude has a question for you." : "A subagent has a question for you.\(note)"
            if s.pending?.kind == .question { category = Self.questionCategory }
        case .done where model.notifyDone:
            body = "Claude finished."
            id = "buddy-done-\(s.id)"
            if model.route(for: s) != .none { category = Self.doneCategory }
        default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = s.projectName
        content.body = stillWaiting.map { "Still waiting (\($0)m). \(body)" } ?? body
        var info = ["session": s.id]
        if let p = s.pending, s.state != .done { info["request"] = p.id; posted[s.id] = p.id }
        content.userInfo = info
        if model.notifyActions, let category { content.categoryIdentifier = category }
        if id == Self.requestId(s.id) { alerted.insert(s.id) }
        // A permission alert shows up 700 ms after the request, like an armed card.
        let trigger = category == Self.permissionCategory ? UNTimeIntervalNotificationTrigger(timeInterval: NotificationActions.armDelay, repeats: false) : nil
        add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// A one-line follow-up, e.g. "Already answered".
    func info(_ sid: String, project: String?, _ text: String) {
        let content = UNMutableNotificationContent()
        content.title = project ?? "Buddy"
        content.body = text
        content.userInfo = ["session": sid]
        add(UNNotificationRequest(identifier: "buddy-info-\(sid)", content: content, trigger: nil))
    }

    private func add(_ req: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(req) { error in
            if let error { log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let sid = info["session"] as? String else { return }
        let request = info["request"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            AppModel.shared.notificationAction(action, sessionId: sid, requestId: request, text: text)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

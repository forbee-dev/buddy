import AppKit
import UserNotifications
import BuddyCore

/// macOS notifications. Clicking one opens the session bubble and jumps to the terminal.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Removes the delivered alert once the request is answered or gone.
    func clear(sessionId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["buddy-\(sessionId)"])
    }

    func post(for s: Session, model: AppModel) {
        guard !s.hidden else { return }
        let body: String
        switch s.state {
        case .needsPermission where model.notifyPermission:
            body = "\(s.pending?.toolName ?? "A tool") needs your permission."
        case .asking where model.notifyQuestion:
            body = "Claude has a question for you."
        case .done where model.notifyDone:
            body = "Claude finished."
        default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = s.projectName
        content.body = body
        content.userInfo = ["session": s.id]
        let req = UNNotificationRequest(identifier: "buddy-\(s.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let sid = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run {
            AppModel.shared.director?.openBubble(sessionId: sid)
            AppModel.shared.jump(sid)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

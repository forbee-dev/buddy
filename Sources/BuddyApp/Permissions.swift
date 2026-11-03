import AppKit
import ApplicationServices
import UserNotifications

enum PermissionState: String { case granted = "Granted", denied = "Denied", unknown = "Not asked" }

/// Notifications, Accessibility, Automation status and requests.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()
    var notifications: PermissionState = .unknown
    var accessibility: PermissionState = .unknown
    var automation: PermissionState = .unknown
    var notificationError: String?

    func refresh() async {
        accessibility = AXIsProcessTrusted() ? .granted : .unknown
        if Notifier.available {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional: notifications = .granted; notificationError = nil
            case .denied: notifications = .denied
            default: notifications = .unknown
            }
        }
        automation = await Task.detached { Self.automationStatus(ask: false) }.value
    }

    func requestNotifications() async {
        guard Notifier.available else { return }
        if notifications == .denied { openNotificationSettings(); return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationError = nil
        } catch {
            log.error("Notification request failed: \(error.localizedDescription, privacy: .public)")
            let ns = error as NSError
            notificationError = ns.domain == UNErrorDomain && ns.code == UNError.Code.notificationsNotAllowed.rawValue
                ? "macOS refused. This usually happens with an unsigned build. Sign it with a local certificate (see docs/INSTALL.md → Local signing certificate), or turn Buddy on in Notification Settings."
                : error.localizedDescription
        }
        await refresh()
    }

    func openNotificationSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.notifications"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }

    func requestAccessibility() {
        // String literal: the kAXTrustedCheckOptionPrompt global is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Asks for Apple Events to System Events, so macOS shows the Automation prompt.
    func requestAutomation() async {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) } catch {
            log.error("Could not start System Events: \(error.localizedDescription, privacy: .public)")
        }
        automation = await Task.detached { Self.automationStatus(ask: true) }.value
    }

    nonisolated static func automationStatus(ask: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }
}

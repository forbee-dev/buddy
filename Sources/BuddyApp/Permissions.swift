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

    func refresh() async {
        accessibility = AXIsProcessTrusted() ? .granted : .unknown
        if Notifier.available {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional: notifications = .granted
            case .denied: notifications = .denied
            default: notifications = .unknown
            }
        }
        automation = await Task.detached { Self.automationStatus(ask: false) }.value
    }

    func requestNotifications() async {
        guard Notifier.available else { return }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } catch {
            log.error("Notification request failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
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

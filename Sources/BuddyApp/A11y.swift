import AppKit
import Carbon.HIToolbox

/// VoiceOver announcements (review A2).
@MainActor
enum Announcer {
    static func say(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case off, ctrlOptB, ctrlOptSpace, ctrlOptCmdB
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .ctrlOptB: "⌃⌥B"
        case .ctrlOptSpace: "⌃⌥Space"
        case .ctrlOptCmdB: "⌃⌥⌘B"
        }
    }
    var keyAndModifiers: (UInt32, UInt32)? {
        switch self {
        case .off: nil
        case .ctrlOptB: (UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey))
        case .ctrlOptSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .ctrlOptCmdB: (UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey | cmdKey))
        }
    }
}

/// Global hotkey that focuses the newest pending card (review A1).
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func apply(_ choice: HotkeyChoice) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let (key, mods) = choice.keyAndModifiers else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4255_4459), id: 1) // "BUDY"
        let status = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { log.error("Hotkey registration failed: \(status)") }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { Hotkey.fire() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
        if status != noErr { log.error("Hotkey handler failed: \(status)") }
    }

    static func fire() {
        let model = AppModel.shared
        guard let s = model.newestPending else { Announcer.say("No Claude session is waiting."); return }
        model.director?.openBubble(sessionId: s.id)
    }
}

/// Tracks the system Reduce Motion setting (review A3).
@MainActor
final class ReduceMotion {
    static let shared = ReduceMotion()
    private var token: NSObjectProtocol?

    func start(model: AppModel) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                model.director?.wake()
            }
        }
    }
}

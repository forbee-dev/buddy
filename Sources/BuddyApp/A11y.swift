import AppKit
import Carbon.HIToolbox

/// VoiceOver announcements.
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

/// Global hotkeys: id 1 opens the newest pending card, id 2 toggles the command palette.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    /// Re-registers both, so a swap between the two never collides with the old registration.
    func apply(card: HotkeyChoice, palette: HotkeyChoice) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        for (id, choice) in [(UInt32(1), card), (2, palette)] {
            guard let (key, mods) = choice.keyAndModifiers else { continue }
            installHandler()
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x4255_4459), id: id), // "BUDY"
                                             GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
            if status != noErr { log.error("Hotkey registration failed: \(status)") }
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let id = hk.id
            MainActor.assumeIsolated { Hotkey.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
        if status != noErr { log.error("Hotkey handler failed: \(status)") }
    }

    static func fire(_ id: UInt32) {
        let model = AppModel.shared
        if id == 2 { PaletteController.shared.toggle(model: model); return }
        guard let s = model.newestPending else { Announcer.say("No Claude session is waiting."); return }
        model.director?.openBubble(sessionId: s.id)
    }
}

/// Tracks the system Reduce Motion setting.
@MainActor
final class ReduceMotion {
    static let shared = ReduceMotion()
    private var token: NSObjectProtocol?

    func start(model: AppModel) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                model.director?.motionChanged()
            }
        }
    }
}

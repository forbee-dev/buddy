import Foundation
import BuddyCore

enum MascotMode: String, CaseIterable, Identifiable {
    case perSession, single
    var id: String { rawValue }
    var label: String { self == .perSession ? "One per session" : "Single buddy" }
}

/// UserDefaults-backed settings.
enum PrefKey {
    static let mode = "mode", walking = "walking", scale = "scale", sleepMascot = "sleepMascot"
    static let notifyPermission = "notify.permission", notifyQuestion = "notify.question", notifyDone = "notify.done"
    static let onboarded = "onboarded", looks = "lookOverrides", hotkey = "hotkey"
    static let size = "size", buddiesHidden = "buddiesHidden"
}

extension UserDefaults {
    func bool(_ key: String, default value: Bool) -> Bool { object(forKey: key) == nil ? value : bool(forKey: key) }

    var lookOverrides: [String: Look] {
        get {
            guard let data = data(forKey: PrefKey.looks) else { return [:] }
            do { return try JSONDecoder().decode([String: Look].self, from: data) } catch {
                log.error("Look overrides unreadable: \(String(describing: error), privacy: .public)")
                return [:]
            }
        }
        set { set(try? JSONEncoder().encode(newValue), forKey: PrefKey.looks) }
    }
}

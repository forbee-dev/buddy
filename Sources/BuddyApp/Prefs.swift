import Foundation
import BuddyCore

enum MascotMode: String, CaseIterable, Identifiable {
    case perSession, single
    var id: String { rawValue }
    var label: String { self == .perSession ? "One per session" : "Single buddy" }
}

enum Arrangement: String, CaseIterable, Identifiable {
    case free, groupedVertical, groupedHorizontal
    var id: String { rawValue }
    var label: String { switch self { case .free: "Free"; case .groupedVertical: "Stacked"; case .groupedHorizontal: "Row" } }
    var hint: String {
        switch self {
        case .free: "Buddies walk around. Drag each one alone."
        case .groupedVertical: "Buddies stack in one column. Drag one to move them all."
        case .groupedHorizontal: "Buddies stand side by side. Drag one to move them all."
        }
    }
}

/// UserDefaults-backed settings.
enum PrefKey {
    static let mode = "mode", walking = "walking", scale = "scale", sleepMascot = "sleepMascot", keepAwake = "keepAwake"
    static let notifyPermission = "notify.permission", notifyQuestion = "notify.question", notifyDone = "notify.done", notifyWhileVisible = "notify.whileVisible"
    static let notifyActions = "notify.actions", notifyPlanUsage = "notify.plan", showPlanUsage = "plan.show"
    static let onboarded = "onboarded", looks = "lookOverrides", hotkey = "hotkey", paletteHotkey = "hotkey.palette"
    static let size = "size", buddiesHidden = "buddiesHidden", arrangement = "arrangement"
    static let showMinis = "minis.show", showShells = "minis.shells"
    static let escalateMinutes = "escalate.minutes", awayMinutes = "away.minutes", funExtras = "fun.extras"
    static let costOnTag = "usage.tag"
    static let showUsage = "usage.show", skinsEnabled = "skins.enabled", character = "character"
    static let sshEnabled = "ssh.enabled", sshClients = "ssh.clients"
    static let beeUnlocked = "beeUnlocked", beeHidden = "bee.hidden", forgeBeeMinis = "bee.forgeBeeMinis"
    static func anchor(_ a: Arrangement) -> String { "groupAnchor.\(a.rawValue)" }
}

extension UserDefaults {
    func bool(_ key: String, default value: Bool) -> Bool { object(forKey: key) == nil ? value : bool(forKey: key) }
    func int(_ key: String, default value: Int) -> Int { object(forKey: key) == nil ? value : integer(forKey: key) }

    func groupAnchor(_ a: Arrangement) -> CGPoint? {
        guard let v = array(forKey: PrefKey.anchor(a)) as? [Double], v.count == 2, v.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }

    func setGroupAnchor(_ p: CGPoint, for a: Arrangement) { set([Double(p.x), Double(p.y)], forKey: PrefKey.anchor(a)) }

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

import Foundation

/// The hidden Bee: a bundled skin that stays out of every list until it is found (docs/SKINS.md, "Hidden extras").
public enum BeeEgg {
    public static let skinName = "bee"
    public static let fileName = "bee.json"
    /// The Bee's character as it appears in the merged sheet.
    public static let base = "bee/bee"
    public static let agentPrefix = "forgebee:"

    /// The palette search unlocks it with `buzz`, the whole query, any case.
    public static func unlocks(query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "buzz"
    }

    /// A project whose name contains "bee" (forgebee, forbee, beehive) unlocks it. So does "beer-app": a plain substring
    /// match is the documented choice.
    public static func unlocks(project: String) -> Bool { project.lowercased().contains("bee") }

    public enum Trigger: Sendable {
        case palette(query: String)
        case project(String, remote: Bool)
    }

    /// After "Hide Bee again" (`hidden`) only the palette's `buzz` unlocks it. An SSH project never does: its name comes
    /// from another host.
    public static func unlocks(_ t: Trigger, hidden: Bool) -> Bool {
        switch t {
        case .palette(let q): unlocks(query: q)
        case .project(let p, let remote): !hidden && !remote && unlocks(project: p)
        }
    }

    /// The bundled skin files Buddy loads: the Bee only once it is unlocked. Locked, it is not even read,
    /// so it never shows in Settings → Skins, Character, Mix, or a look.
    public static func bundledFiles(_ paths: [String], unlocked: Bool) -> [String] {
        unlocked ? paths : paths.filter { ($0 as NSString).lastPathComponent != fileName }
    }

    /// Bundled skins are off until switched on; the Bee is on as soon as it is found.
    public static func onByDefault(skin: String, bundled: Bool) -> Bool { !bundled || skin == skinName }

    /// A `forgebee:` subagent flies as a bee mini whatever its parent's character: only when the Bee is unlocked,
    /// the setting is on, and the Bee skin is applied (`available`).
    public static func miniBase(agentType: String, parent: String, unlocked: Bool, enabled: Bool, available: Bool) -> String {
        unlocked && enabled && available && agentType.lowercased().hasPrefix(agentPrefix) ? base : parent
    }
}

import Foundation
import Testing
@testable import BuddyCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let skinsDir = repo.appendingPathComponent("design/skins").path

@Suite struct BeeEggTests {
    private static let loaded = Result { try SpriteSheet.load(Data(contentsOf: repo.appendingPathComponent("design/sprites.json"))) }
    static var base: SpriteSheet { get throws { try loaded.get() } }

    /// The bundled skins as SkinStore loads them: only the files `bundledFiles` lets through, merged in order.
    static func sheet(unlocked: Bool) throws -> SpriteSheet {
        let files = try FileManager.default.contentsOfDirectory(atPath: skinsDir).filter { $0.hasSuffix(".json") }.sorted().map { skinsDir + "/" + $0 }
        var names = Set<String>()
        let skins = try BeeEgg.bundledFiles(files, unlocked: unlocked).map {
            try SkinLoader.validate(Data(contentsOf: URL(fileURLWithPath: $0)), base: base, names: &names)
        }
        return try base.merged(skins)
    }

    @Test func paletteQueryUnlocks() {
        for q in ["buzz", "BUZZ", "Buzz", " buzz "] { #expect(BeeEgg.unlocks(query: q), "\(q)") }
        for q in ["", "buz", "buzzz", "abuzz", "buzz off", "b u z z", "bee"] { #expect(!BeeEgg.unlocks(query: q), "\(q)") }
    }

    @Test func projectNameUnlocks() {
        for p in ["forgebee", "forbee", "beehive", "BeeHive", "my-BEE-app", "ForgeBee"] { #expect(BeeEgg.unlocks(project: p), "\(p)") }
        for p in ["", "buddy", "be-e", "b.e.e", "web-app"] { #expect(!BeeEgg.unlocks(project: p), "\(p)") }
        // Documented choice: a plain substring match, so "beer-app" unlocks it too.
        #expect(BeeEgg.unlocks(project: "beer-app"))
    }

    /// Hide Bee again: a project name no longer unlocks it, the palette's `buzz` does. SSH projects never do.
    @Test func hiddenBeeOnlyBuzzUnlocks() {
        #expect(BeeEgg.unlocks(.project("forgebee", remote: false), hidden: false))
        #expect(!BeeEgg.unlocks(.project("forgebee", remote: false), hidden: true))
        #expect(BeeEgg.unlocks(.palette(query: "buzz"), hidden: true))
        #expect(!BeeEgg.unlocks(.palette(query: "forgebee"), hidden: false))
        // Found again with buzz: `hidden` is cleared, and project names work again.
        #expect(BeeEgg.unlocks(.project("forgebee", remote: false), hidden: false))
    }

    @Test func remoteProjectNeverUnlocks() {
        #expect(!BeeEgg.unlocks(.project("forgebee", remote: true), hidden: false))
        #expect(!BeeEgg.unlocks(.project("forgebee", remote: true), hidden: true))
    }

    @Test func lockedBeeIsNotLoaded() {
        let files = ["/x/skins/bee.json", "/x/skins/crate.json", "/x/skins/beehive.json"]
        #expect(BeeEgg.bundledFiles(files, unlocked: false) == ["/x/skins/crate.json", "/x/skins/beehive.json"])
        #expect(BeeEgg.bundledFiles(files, unlocked: true) == files)
    }

    @Test func onByDefault() {
        #expect(BeeEgg.onByDefault(skin: "bee", bundled: true))
        #expect(!BeeEgg.onByDefault(skin: "crate", bundled: true))
        #expect(BeeEgg.onByDefault(skin: "mine", bundled: false))
    }

    /// Locked: no Bee in the skin list, Character, Mix, outfits, or any look. Unlocked: all of them.
    @Test func hiddenUntilUnlocked() throws {
        let locked = try Self.sheet(unlocked: false)
        #expect(!locked.baseNames.contains(BeeEgg.base))
        #expect(locked.bases[BeeEgg.base] == nil)
        #expect(!locked.outfits.keys.contains { $0.hasPrefix("bee/") })
        #expect(!locked.legend.keys.contains("J"))
        // Mix picks from every base in the sheet; none is the Bee.
        for i in 0..<200 {
            let look = LookPicker.pick(cwd: "/p/\(i)", sheet: locked, bases: locked.baseNames)
            #expect(look.base != BeeEgg.base && look.outfit?.hasPrefix("bee/") != true)
        }
        let assigned = LookAssigner.assign(preferred: Look(base: "clawd", palette: "claude", outfit: nil), seed: "s",
                                           taken: [Look(base: "clawd", palette: "claude", outfit: nil), Look(base: "crate/crate", palette: "claude", outfit: nil)],
                                           sheet: locked, bases: locked.baseNames)
        #expect(assigned.base != BeeEgg.base)

        let open = try Self.sheet(unlocked: true)
        #expect(open.baseNames.contains(BeeEgg.base))
        #expect(open.outfits(fitting: BeeEgg.base).contains("bee/honey-pot"))
        #expect(!open.outfits(fitting: "clawd").contains("bee/honey-pot"))
        #expect(Set((0..<200).map { LookPicker.pick(cwd: "/p/\($0)", sheet: open, bases: open.baseNames).base }).contains(BeeEgg.base))
        // Mix: with every other character taken, the free Bee comes first.
        let free = LookAssigner.assign(preferred: Look(base: "clawd", palette: "claude", outfit: nil), seed: "s",
                                       taken: open.baseNames.filter { $0 != BeeEgg.base }.map { Look(base: $0, palette: "claude", outfit: nil) },
                                       sheet: open, bases: open.baseNames)
        #expect(free.base == BeeEgg.base)
    }

    /// Hide Bee again: the sheet drops it like a removed skin; a stale bee look still draws (as the first base) and loses the bee outfit.
    @Test func relockFallsBack() throws {
        let relocked = try Self.sheet(unlocked: false)
        let stale = Look(base: BeeEgg.base, palette: "teal", outfit: "bee/honey-pot")
        #expect(!relocked.outfits(fitting: stale.base).contains("bee/honey-pot"))
        let f = try #require(relocked.anim(base: stale.base, chain: ["idle"])?.frames.first)
        let r = SpriteRenderer.render(sheet: relocked, frame: f, look: Look(base: stale.base, palette: stale.palette, outfit: nil), mirrored: false)
        #expect(r.missing.isEmpty && r.width > 0)
        #expect(LookPicker.pick(cwd: "/forgebee", sheet: relocked, bases: relocked.baseNames).base != BeeEgg.base)
    }

    @Test func forgeBeeMiniRule() {
        func mini(_ type: String, unlocked: Bool = true, enabled: Bool = true, available: Bool = true) -> String {
            BeeEgg.miniBase(agentType: type, parent: "crate/crate", unlocked: unlocked, enabled: enabled, available: available)
        }
        #expect(mini("forgebee:reviewer") == BeeEgg.base)
        #expect(mini("ForgeBee:Coder") == BeeEgg.base)
        #expect(mini("general-purpose") == "crate/crate")
        #expect(mini("forgebee") == "crate/crate")
        #expect(mini("my-forgebee:x") == "crate/crate")
        #expect(mini("forgebee:reviewer", unlocked: false) == "crate/crate")
        #expect(mini("forgebee:reviewer", enabled: false) == "crate/crate")
        #expect(mini("forgebee:reviewer", available: false) == "crate/crate")
    }

    /// The hook's `agent_type` reaches the subagent's `type` that the rule reads.
    @Test func agentTypeFromHook() {
        var s = SessionStore()
        _ = s.apply(hook("SubagentStart", extra: ["agent_id": "a1", "agent_type": "forgebee:tester"]))
        let a = s.sessions["s1"]?.subagents["a1"]
        #expect(a?.type == "forgebee:tester")
        #expect(BeeEgg.miniBase(agentType: a?.type ?? "", parent: "clawd", unlocked: true, enabled: true, available: true) == BeeEgg.base)
    }

    @Test func beeSkinValidates() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("design/skins/bee.json"))
        let bee = try SkinLoader.validate(data, base: Self.base)
        let crate = try SkinLoader.validate(Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json")), base: Self.base)
        #expect(bee.name == BeeEgg.skinName)
        #expect(Array(bee.bases.keys) == ["bee"])
        #expect(SkinLoader.conflict(bee, with: [crate]) == nil && SkinLoader.conflict(crate, with: [bee]) == nil)
        let fits = bee.baseOutfits["bee"] ?? []
        #expect(fits.contains("crown") && !fits.contains("glasses") && !fits.contains("scarf") && !fits.contains("bowtie"))
        let merged = try Self.base.merged([crate, bee])
        for st in SkinLoader.states {
            let anim = try #require(merged.anim(base: BeeEgg.base, chain: [st]))
            #expect(anim.loop == !["done", "goodbye"].contains(st), "\(st)")
            for (i, f) in anim.frames.enumerated() {
                for look in [Look(base: BeeEgg.base, palette: "claude", outfit: "bee/honey-pot"), Look(base: BeeEgg.base, palette: "charcoal", outfit: "crown")] {
                    let r = SpriteRenderer.render(sheet: merged, frame: f, look: look, mirrored: i % 2 == 1)
                    #expect(r.missing.isEmpty, "\(st)[\(i)] \(r.missing)")
                }
            }
        }
    }
}

import Foundation
import Testing
@testable import BuddyCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct SkinTests {
    private static let loaded = Result { try SpriteSheet.load(Data(contentsOf: repo.appendingPathComponent("design/sprites.json"))) }
    static var base: SpriteSheet { get throws { try loaded.get() } }
    static let blank = Array(repeating: String(repeating: ".", count: 32), count: 32)
    static var crateJSON: [String: Any] {
        let data = (try? Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json"))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A small outfit-and-palette skin, changed by `patch`.
    private func skin(_ patch: (inout [String: Any]) -> Void) throws -> Skin {
        var rows = Self.blank
        rows[9] = String(repeating: ".", count: 14) + "KAAK" + String(repeating: ".", count: 14)
        var obj: [String: Any] = ["name": "example", "author": "Buddy", "palettes": ["mint-neon": try Self.base.palettes["claude"] ?? [:]],
                                  "outfits": ["antenna": ["label": "Antenna", "rows": rows]]]
        patch(&obj)
        return try SkinLoader.validate(JSONSerialization.data(withJSONObject: obj), base: Self.base)
    }

    private func rejects(_ e: SkinError, _ patch: (inout [String: Any]) -> Void, line: Int = #line) {
        do {
            _ = try skin(patch)
            Issue.record("accepted, expected \(e) (line \(line))")
        } catch {
            #expect(error as? SkinError == e, "line \(line)")
        }
    }

    /// Crate with one state changed.
    private func crate(_ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { o in
            o = Self.crateJSON
            var bases = o["bases"] as? [String: Any] ?? [:]
            var c = bases["crate"] as? [String: Any] ?? [:]
            change(&c)
            bases["crate"] = c
            o["bases"] = bases
        }
    }

    @Test func outfitSkinMergesUnderItsName() throws {
        let s = try skin { _ in }
        let merged = try Self.base.merged([s])
        #expect(merged.outfits["example/antenna"]?.label == "Antenna (example)")
        #expect(merged.paletteNames.contains("example/mint-neon"))
        #expect(merged.outfits(fitting: "clawd").contains("example/antenna"))
        // Same names as built-ins stay apart.
        let clash = try skin { o in o["outfits"] = ["cap": (o["outfits"] as? [String: Any])?["antenna"] as Any]; o["palettes"] = nil }
        let both = try Self.base.merged([clash])
        #expect(both.outfits["cap"]?.label == (try Self.base).outfits["cap"]?.label)
        #expect(both.outfits["example/cap"] != nil)
        let f = try #require(merged.anim(base: "clawd", chain: ["idle"])?.frames.first)
        let r = SpriteRenderer.render(sheet: merged, frame: f, look: Look(base: "clawd", palette: "example/mint-neon", outfit: "example/antenna"), mirrored: false)
        #expect(r.missing.isEmpty)
    }

    @Test func charOrColorKeyOfAnotherSkinIsRefused() throws {
        let crate = try SkinLoader.validate(Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json")), base: Self.base)
        let plain = try skin { _ in }
        #expect(SkinLoader.conflict(plain, with: [crate]) == nil)
        let sameChar = try skin { o in o["legend"] = ["Q": "glow"]; o["colors"] = ["glow": "#00FF00"] }
        #expect(SkinLoader.conflict(sameChar, with: [crate]) == .charTaken("Q", "crate"))
        let sameKey = try skin { o in o["legend"] = ["X": "screen"]; o["colors"] = ["screen": "#00FF00"] }
        #expect(SkinLoader.conflict(sameKey, with: [plain, crate]) == .colorTaken("screen", "crate"))
        #expect(SkinLoader.conflict(sameKey, with: []) == nil)
        // A built-in palette key cannot become a fixed color.
        rejects(.builtInColor("body")) { o in o["colors"] = ["body": "#00FF00"] }
    }

    @Test func outfitLabelsAreRevealedAndClipped() throws {
        let s = try skin { o in
            var outfits = o["outfits"] as? [String: Any] ?? [:]
            var a = outfits["antenna"] as? [String: Any] ?? [:]
            a["label"] = "Ant\u{202E}enna " + String(repeating: "x", count: 60)
            outfits["antenna"] = a
            o["outfits"] = outfits
        }
        let label = try #require(s.outfits["antenna"]?.label)
        #expect(label.hasPrefix("Ant\\u{202E}enna") && label.count == 40 && !label.contains("\u{202E}"))
    }

    @Test func crateCharacter() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json"))
        let crate = try SkinLoader.validate(data, base: Self.base)
        let merged = try Self.base.merged([crate])
        #expect(merged.baseNames == ["clawd", "crate/crate"])
        let fits = merged.outfits(fitting: "crate/crate")
        #expect(fits.contains("cap") && fits.contains("crown") && !fits.contains("glasses") && !fits.contains("scarf"))
        #expect(merged.outfits(fitting: "clawd").contains("glasses"))
        for st in SkinLoader.states {
            let f = try #require(merged.anim(base: "crate/crate", chain: [st])?.frames.first)
            let r = SpriteRenderer.render(sheet: merged, frame: f, look: Look(base: "crate/crate", palette: "teal", outfit: "cap"), mirrored: false)
            #expect(r.missing.isEmpty, "\(st)")
        }
        // Without the skin, a crate look still renders (the first base), never crashes.
        #expect(try Self.base.anim(base: "crate/crate", chain: ["idle"]) != nil)
    }

    @Test func rejections() throws {
        #expect(throws: SkinError.tooBig(SkinLoader.maxBytes + 1)) { try SkinLoader.validate(Data(count: SkinLoader.maxBytes + 1), base: Self.base) }
        #expect(throws: SkinError.notJSON) { try SkinLoader.validate(Data("{".utf8), base: Self.base) }
        rejects(.badName) { $0["name"] = "a/b" }
        rejects(.badName) { $0["name"] = nil }
        rejects(.empty) { $0["outfits"] = nil; $0["palettes"] = nil }
        let outfit = ["rows": Self.blank]
        rejects(.tooManyOutfits(65)) { o in o["outfits"] = Dictionary(uniqueKeysWithValues: (0..<65).map { ("o\($0)", outfit) }) }
        let palette = try Self.base.palettes["claude"] ?? [:]
        rejects(.tooManyPalettes(33)) { o in o["palettes"] = Dictionary(uniqueKeysWithValues: (0..<33).map { ("p\($0)", palette) }) }
        rejects(.badKey("bad/key")) { o in o["outfits"] = ["bad/key": outfit] }
        rejects(.badGrid("short")) { o in o["outfits"] = ["short": ["rows": ["...."]]] }
        rejects(.badGrid("wide")) { o in o["outfits"] = ["wide": ["rows": Array(repeating: String(repeating: ".", count: 33), count: 32)]] }
        var odd = Self.blank
        odd[5] = "Q" + String(repeating: ".", count: 31)
        rejects(.unknownChar("odd", "Q")) { o in o["outfits"] = ["odd": ["rows": odd]] }
        rejects(.legendClash("K")) { o in o["legend"] = ["K": "body"] }
        var badHex = palette
        badHex["body"] = "#12345G"
        rejects(.badHex("x", "body")) { o in o["palettes"] = ["x": badHex] }
        var partial = palette
        partial["outline"] = nil
        rejects(.missingColor("x", "outline")) { o in o["palettes"] = ["x": partial] }
        // Characters.
        rejects(.missingState("crate", "error")) { o in crate { c in var st = c["states"] as? [String: Any] ?? [:]; st["error"] = nil; c["states"] = st }(&o) }
        rejects(.mustNotLoop("crate", "done")) { o in crate { c in
            var st = c["states"] as? [String: Any] ?? [:]; var d = st["done"] as? [String: Any] ?? [:]; d["loop"] = true; st["done"] = d; c["states"] = st }(&o) }
        rejects(.badFrames("crate", "idle")) { o in crate { c in
            var st = c["states"] as? [String: Any] ?? [:]; st["idle"] = ["loop": true, "frames": [["rows": ["."]]]]; c["states"] = st }(&o) }
        rejects(.unknownOutfit("crate", "jetpack")) { o in crate { c in c["outfits"] = ["cap", "jetpack"] }(&o) }
        rejects(.missingColor("colors", "screen")) { o in crate { _ in }(&o); o["colors"] = ["screenInk": "#0F380F", "bezel": "#2E3440"] }
        rejects(.tooManyBases(5)) { o in crate { _ in }(&o)
            let c = (o["bases"] as? [String: Any])?["crate"] as Any
            o["bases"] = Dictionary(uniqueKeysWithValues: (0..<5).map { ("c\($0)", c) }) }
    }

    @Test func declaredLegendCharIsAccepted() throws {
        var rows = Self.blank
        rows[4] = "Q" + String(repeating: ".", count: 31)
        let s = try skin { o in o["legend"] = ["Q": "body"]; o["outfits"] = ["q": ["rows": rows]] }
        #expect(try Self.base.merged([s]).legend["Q"] == "body")
    }
}

@Suite struct MixTests {
    private static let loaded = Result {
        let base = try SkinTests.base
        return base.merged([try SkinLoader.validate(Data(contentsOf: repo.appendingPathComponent("design/skins/crate.json")), base: base)])
    }
    static var sheet: SpriteSheet { get throws { try loaded.get() } }
    static let both = ["clawd", "crate/crate"]

    @Test func stablePerProjectAndUsesBoth() throws {
        let sheet = try Self.sheet
        let picks = (0..<24).map { LookPicker.pick(cwd: "/p/\($0)", sheet: sheet, bases: Self.both) }
        #expect(Set(picks.map(\.base)) == Set(Self.both))
        #expect(picks == (0..<24).map { LookPicker.pick(cwd: "/p/\($0)", sheet: sheet, bases: Self.both) })
        for l in picks { if let o = l.outfit { #expect(sheet.outfits(fitting: l.base).contains(o)) } }
    }

    @Test func uniqueCharacterFirstAndFitsRespected() throws {
        let sheet = try Self.sheet
        let mine = Look(base: "clawd", palette: "teal", outfit: "glasses")
        let other = Look(base: "clawd", palette: "mint", outfit: nil)
        let l = LookAssigner.assign(preferred: mine, seed: "/a", taken: [other], sheet: sheet, bases: Self.both)
        #expect(l == Look(base: "crate/crate", palette: "teal", outfit: nil))
        // Every character taken: palette uniqueness counts only buddies with the same character.
        let full = LookAssigner.assign(preferred: Look(base: "crate/crate", palette: "teal", outfit: nil), seed: "/a",
                                       taken: [Look(base: "clawd", palette: "teal", outfit: nil), Look(base: "crate/crate", palette: "mint", outfit: nil)],
                                       sheet: sheet, bases: Self.both)
        #expect(full.base == "crate/crate" && full.palette == "teal")
        var g = SystemRandomNumberGenerator()
        let rolled = LookAssigner.reroll(current: l, taken: [other], sheet: sheet, bases: Self.both, using: &g)
        #expect(rolled != l)
        if rolled.base == "crate/crate", let o = rolled.outfit { #expect(sheet.outfits(fitting: "crate/crate").contains(o)) }
    }

    @Test func fallbackWhenACharacterIsGone() throws {
        let sheet = try Self.sheet
        let l = LookPicker.pick(cwd: "/p/1", sheet: sheet, bases: ["clawd"])
        #expect(l.base == "clawd")
        // The default (no Mix) never picks a skin character.
        for i in 0..<12 { #expect(LookPicker.pick(cwd: "/q/\(i)", sheet: sheet).base == "clawd") }
    }

    @Test func singleCharacterUnchanged() throws {
        let sheet = try Self.sheet, base = try SkinTests.base
        let looks = (0..<10).map { LookPicker.pick(cwd: "/r/\($0)", sheet: base) }
        for (i, l) in looks.enumerated() {
            let taken = Array(looks.prefix(i))
            #expect(LookAssigner.assign(preferred: l, seed: "/r/\(i)", taken: taken, sheet: sheet)
                    == LookAssigner.assign(preferred: l, seed: "/r/\(i)", taken: taken, sheet: sheet, bases: ["clawd"]))
            #expect(LookPicker.pick(cwd: "/r/\(i)", sheet: sheet) == l)
        }
    }
}

@Suite struct SkinLoaderNegativeTests {
    private static let loaded = Result { try SpriteSheet.load(Data(contentsOf: repoRoot.appendingPathComponent("design/sprites.json"))) }
    static var base: SpriteSheet { get throws { try loaded.get() } }
    static let blank = Array(repeating: String(repeating: ".", count: 32), count: 32)

    /// A valid one-palette skin, changed by `patch`.
    func data(_ patch: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        var o: [String: Any] = ["name": "neg", "palettes": ["p": try Self.base.palettes["claude"] ?? [:]]]
        try patch(&o)
        return try JSONSerialization.data(withJSONObject: o)
    }

    func rejects(_ error: SkinError, _ patch: (inout [String: Any]) throws -> Void) throws {
        let d = try data(patch)
        let base = try Self.base
        #expect(throws: error) { try SkinLoader.validate(d, base: base) }
    }

    /// The crate character from design/skins, with one state changed.
    func crate(_ state: String, _ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) throws -> Void {
        { o in
            let file = try JSONSerialization.jsonObject(with: Data(contentsOf: repoRoot.appendingPathComponent("design/skins/crate.json")))
            let src = try #require(file as? [String: Any])
            var bases = try #require(src["bases"] as? [String: Any])
            var c = try #require(bases["crate"] as? [String: Any])
            var states = try #require(c["states"] as? [String: Any])
            var st = try #require(states[state] as? [String: Any])
            change(&st)
            states[state] = st
            c["states"] = states
            bases["crate"] = c
            o["bases"] = bases
            o["legend"] = src["legend"]
            o["colors"] = src["colors"]
            o["palettes"] = src["palettes"]
        }
    }

    @Test func legendKeys() throws {
        try rejects(.legendClash(".")) { $0["legend"] = [".": "body"] }
        try rejects(.badKey("QQ")) { $0["legend"] = ["QQ": "body"] }
    }

    @Test func badFrames() throws {
        func frames(_ f: Any) -> (inout [String: Any]) -> Void { { $0["frames"] = f } }
        let row = Self.blank
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "head": [0, 99]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "head": [0]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([["rows": row, "fx": ["...."]]])))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames([[String: Any]]())))
        try rejects(.badFrames("crate", "idle"), crate("idle", frames(Array(repeating: ["rows": row], count: 17))))
        // 16 frames is the limit, not over it.
        let d = try data(crate("idle", frames(Array(repeating: ["rows": row], count: 16))))
        #expect(throws: Never.self) { try SkinLoader.validate(d, base: try Self.base) }
    }

    @Test func badHexAndBadKeys() throws {
        try rejects(.badHex("colors", "ink")) { $0["colors"] = ["ink": "red"] }
        try rejects(.badKey("bad key")) { $0["colors"] = ["bad key": "#000000"] }
        try rejects(.badKey("bad/p")) { o in o["palettes"] = ["bad/p": (o["palettes"] as? [String: Any])?["p"] as Any] }
        try rejects(.badKey("bad.o")) { $0["outfits"] = ["bad.o": ["rows": Self.blank]] }
        try rejects(.badKey("bad base")) { o in
            try crate("idle") { _ in }(&o)
            var bases = o["bases"] as? [String: Any] ?? [:]
            bases["bad base"] = bases.removeValue(forKey: "crate")
            o["bases"] = bases
        }
        try rejects(.badKey("bad!")) { $0["legend"] = ["Q": "bad!"] }
    }

    @Test func sizeLimitIsInclusive() throws {
        let base = try Self.base
        var d = try data()
        d.append(Data(repeating: 0x20, count: SkinLoader.maxBytes - d.count))
        #expect(d.count == SkinLoader.maxBytes)
        #expect(throws: Never.self) { try SkinLoader.validate(d, base: base) }
    }

    @Test func duplicateNameIsRefused() throws {
        let base = try Self.base
        var names = Set<String>()
        _ = try SkinLoader.validate(try data(), base: base, names: &names)
        #expect(throws: SkinError.duplicate("neg")) { try SkinLoader.validate(try data(), base: base, names: &names) }
        #expect(names == ["neg"])
    }
}

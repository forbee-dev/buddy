import Foundation

/// A community skin: extra palettes and outfits from `~/Library/Application Support/Buddy/skins/*.json`.
public struct Skin: Sendable {
    public var name: String
    public var author: String?
    public var palettes: [String: [String: String]]
    public var outfits: [String: SpriteSheet.Outfit]
    /// New legend chars only; a skin never changes a built-in char.
    public var legend: [String: String?]
    /// Whole characters, with the same states as the built-in one.
    public var bases: [String: SpriteSheet.Base] = [:]
    /// Per skin base: the built-in outfits that fit it. Missing: all of them.
    public var baseOutfits: [String: [String]] = [:]
    /// Fixed colors for the skin's own legend keys.
    public var colors: [String: String] = [:]
}

public enum SkinError: Error, Equatable, CustomStringConvertible {
    case unreadable, tooBig(Int), notJSON, badName, empty, tooManyOutfits(Int), tooManyPalettes(Int)
    case badKey(String), badGrid(String), unknownChar(String, String), legendClash(String)
    case badHex(String, String), missingColor(String, String), duplicate(String)
    case tooManyBases(Int), missingState(String, String), badFrames(String, String), mustNotLoop(String, String), unknownOutfit(String, String)
    case builtInColor(String), charTaken(String, String), colorTaken(String, String)

    public var description: String {
        switch self {
        case .unreadable: "The file is not a regular file that you own, or a symlink."
        case .tooBig(let n): "The file is \(n / 1024) KB. The limit is 512 KB."
        case .notJSON: "The file is not valid skin JSON."
        case .badName: "\"name\" must be 1 to 32 letters, digits, spaces, \"-\" or \"_\"."
        case .empty: "The skin has no outfits and no palettes."
        case .tooManyOutfits(let n): "The skin has \(n) outfits. The limit is 64."
        case .tooManyPalettes(let n): "The skin has \(n) palettes. The limit is 32."
        case .badKey(let k): "The name \"\(k)\" is not valid. Use 1 to 40 letters, digits, \"-\" or \"_\"."
        case .badGrid(let o): "Outfit \"\(o)\" is not a 32×32 grid."
        case .unknownChar(let o, let c): "Outfit \"\(o)\" uses \"\(c)\", which the legend does not have."
        case .legendClash(let c): "Legend char \"\(c)\" is built in. A skin cannot change it."
        case .badHex(let p, let k): "Palette \"\(p)\" has an invalid color for \"\(k)\". Use #RRGGBB."
        case .missingColor(let p, let k): "Palette \"\(p)\" has no color for \"\(k)\"."
        case .duplicate(let n): "Another skin already uses the name \"\(n)\"."
        case .tooManyBases(let n): "The skin has \(n) characters. The limit is 4."
        case .missingState(let b, let st): "Character \"\(b)\" has no \"\(st)\" state."
        case .badFrames(let b, let st): "Character \"\(b)\", state \"\(st)\": every frame needs 32×32 rows (and fx), a head of 2 numbers, and 1 to 16 frames."
        case .mustNotLoop(let b, let st): "Character \"\(b)\", state \"\(st)\" must have \"loop\": false."
        case .unknownOutfit(let b, let o): "Character \"\(b)\" lists \"\(o)\", which is not a built-in outfit."
        case .builtInColor(let k): "Color key \"\(k)\" is built in. Use a new key in \"colors\"."
        case .charTaken(let c, let other): "Legend char \"\(c)\" is already used by the skin \"\(other)\". Turn that skin off or pick another char."
        case .colorTaken(let k, let other): "Color key \"\(k)\" is already used by the skin \"\(other)\". Turn that skin off or rename the key."
        }
    }
}

public enum SkinLoader {
    public static let maxBytes = 512 * 1024
    public static let maxOutfits = 64
    public static let maxPalettes = 32
    public static let maxBases = 4
    /// Every character has these; `done` and `goodbye` play once.
    public static let states = ["idle", "walk", "working", "question", "done", "sleep", "goodbye", "dragged", "permission", "error"]
    static let once: Set<String> = ["done", "goodbye"]

    private struct FileBase: Decodable {
        var states: [String: SpriteSheet.Anim]
        var outfits: [String]?
    }

    private struct File: Decodable {
        var name: String?
        var author: String?
        var palettes: [String: [String: String]]?
        var outfits: [String: SpriteSheet.Outfit]?
        var legend: [String: String?]?
        var bases: [String: FileBase]?
        var colors: [String: String]?
    }

    /// Strict checks, so a bad file can never break the bundled sheet.
    public static func validate(_ data: Data, base: SpriteSheet) throws -> Skin {
        guard data.count <= maxBytes else { throw SkinError.tooBig(data.count) }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { throw SkinError.notJSON }
        guard let name = f.name, validName(name, max: 32, spaces: true) else { throw SkinError.badName }
        let palettes = f.palettes ?? [:], outfits = f.outfits ?? [:], legend = f.legend ?? [:]
        let bases = f.bases ?? [:], colors = f.colors ?? [:]
        guard !palettes.isEmpty || !outfits.isEmpty || !bases.isEmpty else { throw SkinError.empty }
        guard bases.count <= maxBases else { throw SkinError.tooManyBases(bases.count) }
        guard outfits.count <= maxOutfits else { throw SkinError.tooManyOutfits(outfits.count) }
        guard palettes.count <= maxPalettes else { throw SkinError.tooManyPalettes(palettes.count) }
        for (char, slot) in legend.sorted(by: { $0.key < $1.key }) {
            guard char.count == 1 else { throw SkinError.badKey(char) }
            guard char != "." else { throw SkinError.legendClash(char) }
            if let built = base.legend[char], built != slot { throw SkinError.legendClash(char) }
            if let slot, !validName(slot, max: 40, spaces: false) { throw SkinError.badKey(slot) }
        }
        let chars = base.legend.merging(legend) { a, _ in a }
        for (key, o) in outfits.sorted(by: { $0.key < $1.key }) {
            guard validName(key, max: 40, spaces: false) else { throw SkinError.badKey(key) }
            guard o.rows.count == base.grid.h, o.rows.allSatisfy({ $0.count == base.grid.w }) else { throw SkinError.badGrid(key) }
            if let c = o.rows.joined().first(where: { chars[String($0)] == nil }) { throw SkinError.unknownChar(key, String(c)) }
        }
        for (key, b) in bases.sorted(by: { $0.key < $1.key }) {
            guard validName(key, max: 40, spaces: false) else { throw SkinError.badKey(key) }
            for st in states {
                guard let anim = b.states[st] else { throw SkinError.missingState(key, st) }
                guard (1...16).contains(anim.frames.count), anim.frames.allSatisfy({ frameOK($0, base.grid) }) else { throw SkinError.badFrames(key, st) }
                if once.contains(st) && anim.loop { throw SkinError.mustNotLoop(key, st) }
                for fr in anim.frames {
                    if let c = (fr.rows + (fr.fx ?? [])).joined().first(where: { chars[String($0)] == nil }) { throw SkinError.unknownChar(key, String(c)) }
                }
            }
            if let bad = b.outfits?.first(where: { base.outfits[$0] == nil }) { throw SkinError.unknownOutfit(key, bad) }
        }
        let builtInKeys = Set(base.palettes.values.flatMap(\.keys)).union(base.colors.keys)
        for (key, hex) in colors.sorted(by: { $0.key < $1.key }) {
            guard validName(key, max: 40, spaces: false) else { throw SkinError.badKey(key) }
            guard !builtInKeys.contains(key) else { throw SkinError.builtInColor(key) }
            guard SpriteRenderer.parseHex(hex) != nil else { throw SkinError.badHex("colors", key) }
        }
        // A new legend key needs a fixed color, or every palette (built-in ones too) would draw it transparent.
        if let gap = Set(legend.values.compactMap { $0 }).subtracting(builtInKeys).sorted().first(where: { colors[$0] == nil }) {
            throw SkinError.missingColor("colors", gap)
        }
        let slots = Set(chars.values.compactMap { $0 }).subtracting(colors.keys)
        for (key, pal) in palettes.sorted(by: { $0.key < $1.key }) {
            guard validName(key, max: 40, spaces: false) else { throw SkinError.badKey(key) }
            if let bad = pal.keys.sorted().first(where: { SpriteRenderer.parseHex(pal[$0] ?? "") == nil }) { throw SkinError.badHex(key, bad) }
            if let gap = slots.sorted().first(where: { pal[$0] == nil }) { throw SkinError.missingColor(key, gap) }
        }
        // Labels are file text shown in menus: revealed and clipped.
        let labeled = outfits.mapValues { o in var o = o; o.label = o.label.map { Activity.clip($0, 40) }; return o }
        return Skin(name: name, author: f.author.map { Activity.clip($0, 60) }, palettes: palettes, outfits: labeled,
                    legend: legend.filter { base.legend[$0.key] == nil },
                    bases: bases.mapValues { SpriteSheet.Base(states: $0.states) },
                    baseOutfits: bases.compactMapValues(\.outfits), colors: colors)
    }

    /// `validate`, plus a name no earlier skin in `names` has. Adds the name to `names`.
    public static func validate(_ data: Data, base: SpriteSheet, names: inout Set<String>) throws -> Skin {
        let skin = try validate(data, base: base)
        guard names.insert(skin.name).inserted else { throw SkinError.duplicate(skin.name) }
        return skin
    }

    /// A skin's new legend chars and color keys must be its own: the merge keeps the first one, so a second skin
    /// that reuses one would draw with another skin's colors. `earlier`: the skins already applied, in order.
    public static func conflict(_ skin: Skin, with earlier: [Skin]) -> SkinError? {
        for other in earlier {
            if let c = skin.legend.keys.sorted().first(where: { other.legend[$0] != nil }) { return .charTaken(c, other.name) }
            if let k = skin.colors.keys.sorted().first(where: { other.colors[$0] != nil }) { return .colorTaken(k, other.name) }
        }
        return nil
    }

    static func frameOK(_ f: SpriteSheet.Frame, _ grid: SpriteSheet.Grid) -> Bool {
        let fits = { (rows: [String]) in rows.count == grid.h && rows.allSatisfy { $0.count == grid.w } }
        let headOK = f.head.map { $0.count == 2 && $0.allSatisfy { abs($0) <= grid.h / 2 } } ?? true
        return fits(f.rows) && (f.fx.map(fits) ?? true) && headOK
    }

    static func validName(_ s: String, max: Int, spaces: Bool) -> Bool {
        !s.isEmpty && s.count <= max && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || (spaces && $0 == " ")) }
    }
}

extension SpriteSheet {
    /// The bundled sheet plus `skins`, under `<skin>/<key>` names, so a skin cannot replace a built-in.
    /// A skin outfit's `fits` may name the skin's own characters; they get the prefix too.
    /// A skin character that lists built-in outfits keeps the other built-in outfits off it.
    public func merged(_ skins: [Skin]) -> SpriteSheet {
        var out = self
        var allow: [String: Set<String>] = [:]
        for skin in skins {
            let ns = { (k: String) in "\(skin.name)/\(k)" }
            for (c, slot) in skin.legend where out.legend[c] == nil { out.legend[c] = slot }
            for (k, v) in skin.colors where out.colors[k] == nil { out.colors[k] = v }
            for (k, p) in skin.palettes { out.palettes[ns(k)] = p }
            for (k, b) in skin.bases { out.bases[ns(k)] = b }
            for (k, list) in skin.baseOutfits { allow[ns(k)] = Set(list) }
            for (k, o) in skin.outfits {
                var o = o
                o.label = "\(o.label ?? k) (\(skin.name))"
                o.fits = o.fits?.map { skin.bases[$0] != nil ? ns($0) : $0 }
                out.outfits[ns(k)] = o
            }
        }
        let names = out.bases.keys.sorted()
        for (k, o) in outfits where !allow.isEmpty {
            out.outfits[k]?.fits = (o.fits ?? names).filter { allow[$0]?.contains(k) ?? true }
        }
        out.reindex()
        return out
    }
}

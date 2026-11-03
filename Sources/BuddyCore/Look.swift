public struct Look: Sendable, Hashable, Codable {
    public var base: String
    public var palette: String
    public var outfit: String?
    public init(base: String, palette: String, outfit: String?) { self.base = base; self.palette = palette; self.outfit = outfit }
}

public enum LookPicker {
    /// FNV-1a 64-bit. Stable across runs, unlike Swift's seeded `hashValue`.
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// Names come from sprites.json; sorting makes the pick independent of dictionary order.
    public static func pick(cwd: String, sheet: SpriteSheet) -> Look {
        let h = fnv1a(cwd)
        let bases = sheet.baseNames
        let base = bases.isEmpty ? "" : bases[Int(h % UInt64(bases.count))]
        let palettes = sheet.paletteNames
        let palette = palettes.isEmpty ? "" : palettes[Int((h >> 16) % UInt64(palettes.count))]
        let outfits = sheet.outfits(fitting: base)
        // Index == count means "no outfit".
        let i = Int((h >> 32) % UInt64(outfits.count + 1))
        return Look(base: base, palette: palette, outfit: i < outfits.count ? outfits[i] : nil)
    }
}

/// Gives each visible buddy a look no other visible buddy has. Color first: it is the easiest to tell apart.
public enum LookAssigner {
    /// The project's look when its palette is free (so the first session of a project keeps it).
    /// Else the first free palette in a cwd-seeded order, with an outfit nobody uses if one is left.
    /// With every palette taken, palettes repeat but the palette + outfit pair stays unique.
    public static func assign(preferred: Look, seed: String, taken: [Look], sheet: SpriteSheet) -> Look {
        let usedPalettes = Set(taken.map(\.palette))
        guard usedPalettes.contains(preferred.palette) else { return preferred }
        let usedOutfits = Set(taken.map(\.outfit))
        let usedPairs = Set(taken.map(pair))
        let outfits = [preferred.outfit] + rotated(choices(sheet, base: preferred.base), seed: seed).filter { $0 != preferred.outfit }
        let palettes = rotated(sheet.paletteNames, seed: seed)
        if let p = palettes.first(where: { !usedPalettes.contains($0) }) {
            return Look(base: preferred.base, palette: p, outfit: outfits.first { !usedOutfits.contains($0) } ?? preferred.outfit)
        }
        for p in [preferred.palette] + palettes.filter({ $0 != preferred.palette }) {
            if let o = outfits.first(where: { !usedPairs.contains(pair(Look(base: preferred.base, palette: p, outfit: $0))) }) {
                return Look(base: preferred.base, palette: p, outfit: o)
            }
        }
        return preferred
    }

    /// A random look unlike `current`: a free palette if any, else a pair nobody uses.
    public static func reroll<G: RandomNumberGenerator>(current: Look, taken: [Look], sheet: SpriteSheet, using g: inout G) -> Look {
        let usedPalettes = Set(taken.map(\.palette))
        let usedPairs = Set(taken.map(pair))
        let all = sheet.paletteNames.flatMap { p in choices(sheet, base: current.base).map { Look(base: current.base, palette: p, outfit: $0) } }
            .filter { $0 != current }
        let fresh = all.filter { !usedPalettes.contains($0.palette) }
        return (fresh.isEmpty ? all.filter { !usedPairs.contains(pair($0)) } : fresh).randomElement(using: &g) ?? current
    }

    /// Outfits for `base` plus "no outfit".
    static func choices(_ sheet: SpriteSheet, base: String) -> [String?] { sheet.outfits(fitting: base).map { $0 } + [nil] }

    static func pair(_ l: Look) -> String { "\(l.palette)|\(l.outfit ?? "")" }

    static func rotated<T>(_ a: [T], seed: String) -> [T] {
        guard !a.isEmpty else { return a }
        let k = Int(LookPicker.fnv1a(seed) % UInt64(a.count))
        return Array(a[k...] + a[..<k])
    }
}

/// Per-session looks, keyed by `Session.mascotKey` (it survives /clear and resume). Set once, never recomputed.
public struct LookBook: Sendable {
    public private(set) var looks: [String: Look] = [:]
    public init() {}

    public mutating func look(for key: String, preferred: Look, seed: String, visible: Set<String>, sheet: SpriteSheet) -> Look {
        if let l = looks[key] { return l }
        let l = LookAssigner.assign(preferred: preferred, seed: seed, taken: taken(except: key, visible: visible), sheet: sheet)
        looks[key] = l
        return l
    }

    public func taken(except key: String, visible: Set<String>) -> [Look] {
        looks.filter { $0.key != key && visible.contains($0.key) }.map(\.value)
    }

    public mutating func set(_ key: String, _ look: Look) { looks[key] = look }
    /// Drops looks of sessions that are gone.
    public mutating func keep(_ keys: Set<String>) { looks = looks.filter { keys.contains($0.key) } }
    public mutating func clear() { looks = [:] }
}

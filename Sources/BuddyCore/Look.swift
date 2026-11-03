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

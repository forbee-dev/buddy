import Foundation

public struct SpriteSheet: Decodable, Sendable {
    public struct Grid: Decodable, Sendable { public var w: Int; public var h: Int }
    public struct Frame: Decodable, Sendable {
        public var rows: [String]
        public var head: [Int]?
        /// Optional effects layer, drawn last at its absolute position.
        public var fx: [String]?
    }
    public struct Anim: Decodable, Sendable { public var loop: Bool; public var frames: [Frame] }
    public struct Base: Decodable, Sendable { public var states: [String: Anim] }
    public struct Outfit: Decodable, Sendable { public var label: String?; public var fits: [String]?; public var rows: [String] }

    public var grid: Grid
    public var fps: Double
    /// Char -> palette key; null = transparent. New chars/keys may appear, so both stay dynamic.
    public var legend: [String: String?]
    public var palettes: [String: [String: String]]
    public var bases: [String: Base]
    public var outfits: [String: Outfit]
    /// Fixed colors of skin legend keys that palettes do not have (e.g. a screen color).
    public var colors: [String: String] = [:]
    /// Sorted once at load.
    public private(set) var baseNames: [String] = []
    public private(set) var paletteNames: [String] = []
    private var outfitNames: [String] = []

    enum CodingKeys: String, CodingKey { case grid, fps, legend, palettes, bases, outfits }

    public static func load(_ data: Data) throws -> SpriteSheet {
        var sheet = try JSONDecoder().decode(SpriteSheet.self, from: data)
        sheet.reindex()
        return sheet
    }

    mutating func reindex() {
        baseNames = bases.keys.sorted()
        paletteNames = palettes.keys.sorted()
        outfitNames = outfits.keys.sorted()
    }

    public func outfits(fitting base: String) -> [String] {
        outfitNames.filter { outfits[$0]?.fits?.contains(base) ?? true }
    }

    /// First state in `chain` that the base has, e.g. ["permission", "question", "idle"].
    public func anim(base: String, chain: [String]) -> Anim? {
        guard let b = bases[base] ?? bases.values.first else { return nil }
        for name in chain + ["idle"] { if let a = b.states[name], !a.frames.isEmpty { return a } }
        return b.states.values.first { !$0.frames.isEmpty }
    }
}

public enum AnimClock {
    /// Frame for `elapsed` seconds into an animation. Never negative, never past the last frame.
    public static func frameIndex(elapsed: Double, fps: Double, count: Int, loop: Bool) -> (index: Int, finished: Bool) {
        guard count > 0 else { return (0, true) }
        let t = elapsed.isFinite ? max(0, elapsed) : 0
        let raw = Int(min(t * max(fps, 0.001), 1e9).rounded(.down))
        if loop { return (((raw % count) + count) % count, false) }
        return (min(raw, count - 1), raw >= count)
    }
}

public struct RenderedFrame: Sendable {
    public var width: Int
    public var height: Int
    /// RGBA, 4 bytes per pixel, alpha 0 or 255.
    public var rgba: [UInt8]
    /// Legend chars or palette keys that could not be resolved (drawn transparent).
    public var missing: Set<String>

    public func isOpaque(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return rgba[(y * width + x) * 4 + 3] != 0
    }
}

public enum SpriteRenderer {
    static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    public static func render(sheet: SpriteSheet, frame: SpriteSheet.Frame, look: Look, mirrored: Bool) -> RenderedFrame {
        let w = sheet.grid.w, h = sheet.grid.h
        var out = RenderedFrame(width: w, height: h, rgba: [UInt8](repeating: 0, count: w * h * 4), missing: [])
        let palette = sheet.palettes[look.palette] ?? sheet.palettes.values.first ?? [:]
        draw(frame.rows, dx: 0, dy: 0, sheet: sheet, palette: palette, mirrored: mirrored, into: &out)
        if let name = look.outfit, let outfit = sheet.outfits[name] {
            let head = frame.head ?? [0, 0]
            draw(outfit.rows, dx: head.first ?? 0, dy: head.count > 1 ? head[1] : 0,
                 sheet: sheet, palette: palette, mirrored: mirrored, into: &out)
        }
        if let fx = frame.fx {
            draw(fx, dx: 0, dy: 0, sheet: sheet, palette: palette, mirrored: mirrored, into: &out)
        }
        return out
    }

    private static func draw(_ rows: [String], dx: Int, dy: Int, sheet: SpriteSheet, palette: [String: String],
                             mirrored: Bool, into out: inout RenderedFrame) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                let key = String(ch)
                guard key != "." else { continue }
                guard let slot = sheet.legend[key] else { out.missing.insert("char \(key)"); continue }
                guard let slotName = slot else { continue }
                guard let hex = palette[slotName] ?? sheet.colors[slotName], let rgb = parseHex(hex) else { out.missing.insert("key \(slotName)"); continue }
                let tx = x + dx, ty = y + dy
                guard tx >= 0, ty >= 0, tx < out.width, ty < out.height else { continue }
                let px = mirrored ? out.width - 1 - tx : tx
                let i = (ty * out.width + px) * 4
                out.rgba[i] = rgb.0; out.rgba[i + 1] = rgb.1; out.rgba[i + 2] = rgb.2; out.rgba[i + 3] = 255
            }
        }
    }
}

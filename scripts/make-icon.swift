// Renders the app icon from design/sprites.json: idle frame 0, "claude" palette (else the first one),
// nearest-neighbor upscale on a rounded tile. Writes an .iconset folder for `iconutil`.
// Usage: swift scripts/make-icon.swift <sprites.json> <out.iconset>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make-icon.swift <sprites.json> <out.iconset>") }
guard let data = FileManager.default.contents(atPath: args[1]),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let legend = json["legend"] as? [String: Any],
      let palettes = json["palettes"] as? [String: [String: String]],
      let bases = json["bases"] as? [String: Any],
      let baseName = bases.keys.sorted().first,
      let base = bases[baseName] as? [String: Any],
      let states = base["states"] as? [String: Any],
      let idle = states["idle"] as? [String: Any],
      let frames = idle["frames"] as? [[String: Any]],
      let rows = frames.first?["rows"] as? [String] else { fail("sprites.json: no idle frame") }

let palette = palettes["claude"] ?? palettes[palettes.keys.sorted().first ?? ""] ?? [:]

func rgb(_ hex: String?) -> (CGFloat, CGFloat, CGFloat)? {
    guard var h = hex else { return nil }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return (CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
}

/// Opaque pixels as (x, y, color), y from the top.
var pixels: [(Int, Int, (CGFloat, CGFloat, CGFloat))] = []
for (y, row) in rows.enumerated() {
    for (x, ch) in row.enumerated() where ch != "." {
        guard let slot = legend[String(ch)] as? String, let c = rgb(palette[slot]) else { continue }
        pixels.append((x, y, c))
    }
}
guard !pixels.isEmpty else { fail("sprites.json: idle frame is empty") }
let minX = pixels.map(\.0).min()!, maxX = pixels.map(\.0).max()!
let minY = pixels.map(\.1).min()!, maxY = pixels.map(\.1).max()!
let spriteW = maxX - minX + 1, spriteH = maxY - minY + 1

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(size)
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = rgb(palette["white"]) ?? (1, 0.96, 0.93)
    ctx.setFillColor(CGColor(srgbRed: bg.0, green: bg.1, blue: bg.2, alpha: 1))
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
    ctx.fillPath()
    // Whole device pixels per sprite pixel when the tile is big enough; fractional only for tiny sizes.
    let fit = (s * 0.62) / CGFloat(max(spriteW, spriteH))
    let px = fit >= 1 ? fit.rounded(.down) : fit
    let ox = ((s - CGFloat(spriteW) * px) / 2).rounded(.down), oy = ((s - CGFloat(spriteH) * px) / 2).rounded(.down)
    ctx.setShouldAntialias(false)
    for (x, y, c) in pixels {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        let fx = ox + CGFloat(x - minX) * px
        let fy = s - oy - CGFloat(y - minY + 1) * px
        ctx.fill(CGRect(x: fx, y: fy, width: px, height: px))
    }
    return ctx.makeImage()
}

let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        guard let img = render(size: pt * scale),
              let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fail("could not render \(name)") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { fail("could not write \(name)") }
    }
}
print("Wrote \(out.path)")

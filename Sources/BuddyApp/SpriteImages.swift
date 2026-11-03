import Foundation
import CoreGraphics
import BuddyCore

/// Caches rendered frames as CGImages. Logs each unknown legend char / palette key once.
@MainActor
final class SpriteImages {
    private var cache: [String: (CGImage, RenderedFrame)] = [:]
    private var loggedMissing: Set<String> = []

    func frame(_ sheet: SpriteSheet, frame: SpriteSheet.Frame, key: String, look: Look, mirrored: Bool) -> (CGImage, RenderedFrame)? {
        let k = "\(look.base)|\(look.palette)|\(look.outfit ?? "-")|\(key)|\(mirrored)"
        if let hit = cache[k] { return hit }
        let r = SpriteRenderer.render(sheet: sheet, frame: frame, look: look, mirrored: mirrored)
        for m in r.missing.subtracting(loggedMissing) {
            log.warning("sprites.json: unresolved \(m, privacy: .public); drawn transparent")
            loggedMissing.insert(m)
        }
        guard let img = makeImage(r) else { return nil }
        cache[k] = (img, r)
        return (img, r)
    }

    func clear() { cache.removeAll() }

    /// Drops frames for looks no mascot uses any more.
    func prune(keeping looks: Set<Look>) {
        let keys = Set(looks.map { "\($0.base)|\($0.palette)|\($0.outfit ?? "-")|" })
        cache = cache.filter { entry in keys.contains { entry.key.hasPrefix($0) } }
    }

    private func makeImage(_ r: RenderedFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(r.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}


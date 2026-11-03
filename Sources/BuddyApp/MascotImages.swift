import AppKit
import BuddyCore

/// Small still images of a mascot: menu thumbnails, the Settings preview, and the menu bar template icon.
@MainActor
enum MascotImages {
    private static var thumbs: [Look: NSImage] = [:]

    static func cgImage(_ sheet: SpriteSheet, look: Look, state: String = "idle") -> (CGImage, RenderedFrame)? {
        guard let frame = sheet.anim(base: look.base, chain: [state])?.frames.first else { return nil }
        let r = SpriteRenderer.render(sheet: sheet, frame: frame, look: look, mirrored: false)
        guard let provider = CGDataProvider(data: Data(r.rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let img = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return (img, r)
    }

    /// Idle frame 0 at 0.5 pt per sprite pixel (16 pt; 1 device pixel each on Retina).
    static func thumbnail(_ sheet: SpriteSheet, look: Look) -> NSImage? {
        if let hit = thumbs[look] { return hit }
        guard let (img, r) = cgImage(sheet, look: look) else { return nil }
        let image = NSImage(cgImage: img, size: NSSize(width: CGFloat(r.width) / 2, height: CGFloat(r.height) / 2))
        thumbs[look] = image
        return image
    }

    /// Template icon from the first base's idle silhouette. `filled` (attention) adds a dot.
    static func menuIcon(_ sheet: SpriteSheet?, filled: Bool) -> NSImage {
        guard let sheet, let base = sheet.baseNames.first, let palette = sheet.paletteNames.first,
              let (_, r) = cgImage(sheet, look: Look(base: base, palette: palette, outfit: nil)) else {
            return NSImage(systemSymbolName: filled ? "face.smiling.inverse" : "face.smiling", accessibilityDescription: "Buddy") ?? NSImage()
        }
        let mask = Silhouette.mask(r, outlineOnly: !filled)
        let w = mask.width, h = mask.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return NSImage() }
        for i in 0..<(w * h) where mask.on[i] { data[i * 4 + 3] = 255 }
        if filled { Silhouette.dot(into: data, width: w, height: h) }
        let image = NSImage(size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = filled ? "Buddy, a session needs you" : "Buddy"
        return image
    }
}

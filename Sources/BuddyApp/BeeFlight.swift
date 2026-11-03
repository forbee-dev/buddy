import AppKit
import SwiftUI
import BuddyCore

/// The Bee's one flight across the screen when it is found: about 3 s on a gentle sine path, stepped by the director
/// tick (which runs only while it flies). Click-through and hidden from VoiceOver: the callout says the same.
@MainActor
final class BeeFlight {
    static let duration = 3.0
    private let panel: MascotPanel
    private let image = CALayer()
    private let look: Look
    private let side: CGFloat
    private let path: NSRect
    private var elapsed = 0.0
    private var frameIndex = -1

    init?(model: AppModel) {
        guard let sheet = model.sheet, sheet.bases[BeeEgg.base] != nil, let palette = sheet.paletteNames.first else { return nil }
        look = Look(base: BeeEgg.base, palette: palette, outfit: nil)
        side = 32 * model.pointScale
        let screen = NSScreen.visibleFrame()
        path = NSRect(x: screen.minX - side, y: screen.minY + screen.height * 0.45, width: screen.width + side, height: screen.height * 0.08)
        panel = MascotPanel(size: NSSize(width: side, height: side), canKey: false)
        panel.ignoresMouseEvents = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        root.wantsLayer = true
        image.magnificationFilter = .nearest
        image.contentsGravity = .resize
        image.frame = root.bounds
        root.layer?.addSublayer(image)
        root.setAccessibilityElement(false)
        panel.contentView = root
        panel.setFrameOrigin(path.origin)
        panel.orderFrontRegardless()
    }

    /// False once the flight is over (the panel is gone).
    func step(dt: Double, model: AppModel, images: SpriteImages) -> Bool {
        elapsed += dt
        let p = min(elapsed / Self.duration, 1)
        guard p < 1, let sheet = model.sheet, let anim = sheet.anim(base: look.base, chain: ["walk", "idle"]) else {
            panel.orderOut(nil)
            return false
        }
        let x = path.minX + path.width * p
        let y = path.minY + path.height * sin(p * .pi * 4)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        let index = AnimClock.frameIndex(elapsed: elapsed, fps: sheet.fps, count: anim.frames.count, loop: anim.loop).index
        // The walk frames' cache key: a buddy that walks as the Bee shares these images.
        if index != frameIndex, let (img, _) = images.frame(sheet, frame: anim.frames[index], key: "walk#\(index)", look: look, mirrored: false) {
            image.contents = img
            frameIndex = index
        }
        return true
    }

    func close() { panel.orderOut(nil) }
}

/// "You found the Bee!": short and announced. It closes itself after 20 s unattended (`MascotDirector.beeFound`).
struct BeeFoundView: View {
    static let text = "You found the Bee! Pick it in Settings → General → Character."
    /// No arrows: VoiceOver reads them as "right arrow".
    static let spoken = "You found the Bee! Pick it in Settings, General, Character."
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Self.spoken)
            CloseButton(action: close)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 5)
        .calloutBackground(radius: 10)
    }
}

import AppKit

/// One-shot confetti when a session finishes: square pixels fly out of the sprite's frame, then fall and fade (about 1.8 s).
/// Core Animation runs it, so no timer exists. The panel is click-through and closes itself.
@MainActor
enum ConfettiBurst {
    private(set) static var live = 0
    private static let duration = 1.8
    private static let count = 56
    // Legend Y, Z, R, G, U, V, N of design/sprites.json (the same in every palette).
    private static let colors = ["#FFC83D", "#4FC3F7", "#E5484D", "#3DDC84", "#2F6FDE", "#8B5CF6", "#FFD60A"].map(NSColor.init(hex:))

    /// `sprite` is the sprite's rect in screen points; `scale` is points per sprite pixel.
    static func play(around sprite: NSRect, scale: CGFloat) {
        let side = sprite.width
        let want = NSSize(width: side * 4, height: side * 4.5)
        let screen = NSScreen.visibleFrame(holding: sprite)
        var origin = NSPoint(x: sprite.midX - want.width / 2, y: sprite.midY - want.height * 0.3)
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - want.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - want.height))
        let panel = MascotPanel(size: want, canKey: false)
        panel.ignoresMouseEvents = true
        // Above the done card, which opens at the same moment next to the sprite and would cover the burst.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let root = NSView(frame: NSRect(origin: .zero, size: want))
        root.wantsLayer = true
        root.setAccessibilityElement(false)
        panel.contentView = root
        panel.setFrameOrigin(origin)
        let start = CGPoint(x: sprite.midX - origin.x, y: sprite.midY - origin.y)
        let g = 3 * side
        for _ in 0..<count {
            let size = scale * CGFloat(Int.random(in: 2...3))
            let vx = CGFloat.random(in: -1.1...1.1) * side
            let vy = CGFloat.random(in: 2.4...3.6) * side
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.backgroundColor = colors.randomElement()?.cgColor
            layer.magnificationFilter = .nearest
            layer.opacity = 0
            root.layer?.addSublayer(layer)

            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = (0...24).map { i -> NSValue in
                let t = duration * Double(i) / 24
                let px = start.x + vx * t
                let py = start.y + vy * t - 0.5 * g * t * t
                // Whole sprite pixels, so the confetti steps like the art.
                return NSValue(point: NSPoint(x: (px / scale).rounded() * scale, y: (py / scale).rounded() * scale))
            }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.7, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            layer.add(group, forKey: "burst")
        }
        live += 1
        panel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(duration + 0.2))
            panel.orderOut(nil)
            live -= 1
        }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

import AppKit
import BuddyCore

/// A buddy's subagents as small copies of it, plus a `>_ N` chip for running background shells.
/// One panel per buddy, moved and animated by the buddy's step (the director tick); no timer of its own.
@MainActor
final class MiniStrip {
    static let maxShown = 4
    /// Done and failed minis stay this long, then fade out.
    static let linger: TimeInterval = 3
    static let gap: CGFloat = 3

    @MainActor private final class Mini {
        let view = SpriteView(frame: .zero)
        var agent: Subagent
        var animKey = ""
        var elapsed = 0.0
        var frameIndex = -1
        init(_ a: Subagent) { agent = a }
    }

    private let panel = MascotPanel(size: .zero, canKey: false)
    private let root = NSView()
    private var minis: [Mini] = []
    private let more = MiniStrip.chip()
    private let shellChip = MiniStrip.chip()
    private var all: [Subagent] = []
    private var shells = 0
    private var project = ""
    private var look: Look?
    private var shownIds: [String] = []
    private var onLeft = true
    private var visible = true
    /// Opens the parent's Activity tab; the agent id marks the row.
    var onOpen: ((String?) -> Void)?
    /// Reserved width next to the buddy; 0 when the strip is empty.
    private(set) var width: CGFloat = 0

    init() {
        panel.contentView = root
        for c in [more, shellChip] {
            root.addSubview(c)
            c.onClick = { [weak self] in self?.onOpen?(nil) }
        }
    }

    private static func chip() -> ChipView {
        let c = ChipView()
        c.label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        return c
    }

    func update(subagents: [Subagent], shells: Int, project: String, look: Look) {
        all = subagents
        self.shells = shells
        self.project = project
        if look != self.look { self.look = look; for m in minis { m.frameIndex = -1 } }
        refresh(now: Date())
    }

    func setVisible(_ v: Bool) {
        visible = v
        if v && width > 0 { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func close() { panel.orderOut(nil) }

    /// Live and recently ended subagents: those waiting on the user first, then by start time.
    private func pick(now: Date) -> [Subagent] {
        let rank: (Subagent) -> Int = { $0.state == .needsPermission || $0.state == .asking ? 0 : $0.state.isActive ? 1 : 2 }
        return all.filter { a in a.endedAt.map { now.timeIntervalSince($0) < Self.linger } ?? true }
            .sorted { (rank($0), $0.startedAt, $0.id) < (rank($1), $1.startedAt, $1.id) }
    }

    /// Rebuilds the row when the set of minis or the chips change.
    private func refresh(now: Date) {
        let list = pick(now: now)
        let shown = Array(list.prefix(Self.maxShown))
        for m in minis { if let a = shown.first(where: { $0.id == m.agent.id }) { m.agent = a } }
        let ids = shown.map(\.id)
        let extra = list.count - shown.count
        let key = ids + ["+\(extra)", ">\(shells)", "\(AppModel.shared.miniScale)"]
        for m in minis { label(m) }
        guard key != shownIds else { return }
        shownIds = key
        let old = minis
        minis = shown.map { a in old.first { $0.agent.id == a.id } ?? Mini(a) }
        for m in old where !minis.contains(where: { $0 === m }) { fadeOut(m.view) }
        let side = 32 * AppModel.shared.miniScale
        var x: CGFloat = 0
        for m in minis {
            if m.view.superview == nil {
                root.addSubview(m.view)
                let id = m.agent.id
                m.view.onClick = { [weak self] in self?.onOpen?(id) }
            }
            m.view.frame = NSRect(x: x, y: 0, width: side, height: side)
            label(m)
            x += side + Self.gap
        }
        x = place(more, text: extra > 0 ? "+\(extra)" : nil, at: x, side: side,
                  a11y: "\(extra) more subagents of \(project)")
        x = place(shellChip, text: shells > 0 ? ">_ \(shells)" : nil, at: x, side: side,
                  a11y: "\(shells) background \(shells == 1 ? "shell" : "shells") running in \(project)")
        width = x > 0 ? x - Self.gap : 0
        panel.setContentSize(NSSize(width: max(width, 1), height: side))
        root.frame = NSRect(x: 0, y: 0, width: max(width, 1), height: side)
        setVisible(visible)
    }

    private func place(_ c: ChipView, text: String?, at x: CGFloat, side: CGFloat, a11y: String) -> CGFloat {
        c.isHidden = text == nil
        guard let text else { return x }
        c.label.stringValue = text
        let w = ceil(c.label.intrinsicContentSize.width) + 10
        let h = min(side, 18)
        c.frame = NSRect(x: x, y: 0, width: w, height: h)
        c.label.frame = NSRect(x: 0, y: (h - c.label.intrinsicContentSize.height) / 2, width: w, height: c.label.intrinsicContentSize.height)
        c.setAccessibilityLabel(a11y)
        return x + w + Self.gap
    }

    private func label(_ m: Mini) {
        m.view.setAccessibilityLabel("subagent \(m.agent.label) of \(project): \(m.agent.state.label)")
        m.view.setAccessibilityHelp("Press to open the Activity list.")
    }

    private func fadeOut(_ v: NSView) {
        guard !AppModel.shared.reduceMotion else { v.removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            v.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { v.removeFromSuperview() } })
    }

    /// Next to the buddy's sprite, feet level, on the side with more room (grouped: always left, inside the slot).
    func step(dt: Double, sprite: NSRect, forceLeft: Bool) {
        guard !all.isEmpty || shells > 0 || width > 0 else { return }
        if all.contains(where: { $0.endedAt != nil }) { refresh(now: Date()) }
        guard width > 0 else { return }
        let screen = (NSScreen.screens.first { $0.frame.intersects(sprite) } ?? NSScreen.main)?.visibleFrame ?? .zero
        onLeft = forceLeft || sprite.midX - screen.minX >= screen.maxX - sprite.midX
        let x = onLeft ? sprite.minX - width - Self.gap : sprite.maxX + Self.gap
        let origin = NSPoint(x: x.rounded(), y: sprite.minY)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        animate(dt)
    }

    private func animate(_ dt: Double) {
        let model = AppModel.shared
        guard let sheet = model.sheet, let parent = look else { return }
        let look = Look(base: parent.base, palette: parent.palette, outfit: nil)
        for m in minis {
            let names = Self.chain(m.agent.state)
            guard let anim = sheet.anim(base: look.base, chain: names) else { continue }
            if names[0] != m.animKey { m.animKey = names[0]; m.elapsed = 0; m.frameIndex = -1 }
            m.elapsed += max(0, dt)
            let clock = AnimClock.frameIndex(elapsed: m.elapsed, fps: sheet.fps, count: anim.frames.count, loop: anim.loop)
            let index = model.reduceMotion && anim.loop ? 0 : clock.index
            guard index != m.frameIndex,
                  let (img, _) = model.director?.images.frame(sheet, frame: anim.frames[index], key: "\(names[0])#\(index)",
                                                              look: look, mirrored: !onLeft) else { continue }
            m.view.layer?.contents = img
            m.frameIndex = index
        }
    }

    static func chain(_ s: Subagent.State) -> [String] {
        switch s {
        case .running: ["working"]
        case .needsPermission: ["permission", "question"]
        case .asking: ["question"]
        case .done: ["done"]
        case .failed: ["error"]
        }
    }
}

/// Small rounded label that opens the Activity tab on click or VoiceOver press.
final class ChipView: NSView {
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.alignment = .center
        label.textColor = .white
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() { layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

extension Subagent.State {
    var label: String {
        switch self {
        case .running: "working"
        case .needsPermission: "needs permission"
        case .asking: "has a question"
        case .done: "done"
        case .failed: "failed"
        }
    }

    /// Same colors as the session dots in the menu.
    var sessionState: SessionState {
        switch self {
        case .running: .working
        case .needsPermission: .needsPermission
        case .asking: .asking
        case .done: .done
        case .failed: .error
        }
    }
}

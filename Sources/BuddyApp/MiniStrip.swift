import AppKit
import BuddyCore

/// A buddy's subagents as small copies of it, plus a `>_ N` chip for running background shells.
/// One panel per buddy, moved and animated by the buddy's step (the director tick); no timer of its own.
@MainActor
final class MiniStrip {
    static let maxShown = 4
    /// Done, failed, and stopped minis stay this long, then fade out.
    static let linger: TimeInterval = 3
    static let gap: CGFloat = 3
    /// Smallest click target (WCAG 2.5.8); a smaller mini is drawn at its size inside it.
    static let minHit: CGFloat = 24

    /// The view is the click target; `image` draws the sprite at the mini size, feet on the bottom edge.
    @MainActor private final class Mini {
        let view = SpriteView(frame: .zero)
        let image = CALayer()
        var agent: Subagent
        /// The character it draws, resolved when the agent, the parent look, or a setting changes (`update`).
        var base = ""
        /// The base and state name of the frames on screen.
        var drawnBase = ""
        var drawnAnim = ""
        var elapsed = 0.0
        var frameIndex = -1
        var a11y = ""
        init(_ a: Subagent) {
            agent = a
            image.magnificationFilter = .nearest
            image.contentsGravity = .resize
            view.layer?.addSublayer(image)
            view.setAccessibilityHelp("Press to open the Activity list.")
        }
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
    /// When the next ended mini's linger runs out; the strip rebuilds only then.
    private var nextExpiry: Date?
    /// Opens the parent's Activity tab; the agent id marks the row.
    var onOpen: ((String?, Int) -> Void)?
    /// Reserved width next to the buddy; 0 when the strip is empty.
    private(set) var width: CGFloat = 0

    init() {
        panel.contentView = root
        for c in [more, shellChip] {
            root.addSubview(c)
            c.onClick = { [weak self] _ in self?.onOpen?(nil, 1) }
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
        nextExpiry = all.compactMap { $0.endedAt?.addingTimeInterval(Self.linger) }.filter { $0 > now }.min()
        let list = pick(now: now)
        let shown = Array(list.prefix(Self.maxShown))
        for m in minis { if let a = shown.first(where: { $0.id == m.agent.id }) { m.agent = a } }
        let ids = shown.map(\.id)
        let extra = list.count - shown.count
        let key = ids + ["+\(extra)", ">\(shells)", "\(AppModel.shared.miniScale)"]
        for m in minis { label(m); resolveBase(m) }
        guard key != shownIds else { return }
        shownIds = key
        let old = minis
        minis = shown.map { a in old.first { $0.agent.id == a.id } ?? Mini(a) }
        for m in old where !minis.contains(where: { $0 === m }) { fadeOut(m.view) }
        let side = 32 * AppModel.shared.miniScale
        let hit = max(side, Self.minHit)
        var x: CGFloat = 0
        for m in minis {
            if m.view.superview == nil {
                root.addSubview(m.view)
                let id = m.agent.id
                m.view.onClick = { [weak self] n in self?.onOpen?(id, n) }
            }
            m.view.frame = NSRect(x: x, y: 0, width: hit, height: hit)
            m.image.frame = NSRect(x: (hit - side) / 2, y: 0, width: side, height: side)
            label(m)
            resolveBase(m)
            x += hit + Self.gap
        }
        x = place(more, text: extra > 0 ? "+\(extra)" : nil, at: x,
                  a11y: "\(extra) more subagents of \(project)")
        x = place(shellChip, text: shells > 0 ? ">_ \(shells)" : nil, at: x,
                  a11y: "\(shells) background \(shells == 1 ? "shell" : "shells") running in \(project)")
        width = x > 0 ? x - Self.gap : 0
        panel.setContentSize(NSSize(width: max(width, 1), height: hit))
        root.frame = NSRect(x: 0, y: 0, width: max(width, 1), height: hit)
        setVisible(visible)
    }

    private func place(_ c: ChipView, text: String?, at x: CGFloat, a11y: String) -> CGFloat {
        c.isHidden = text == nil
        guard let text else { return x }
        c.label.stringValue = text
        let w = max(ceil(c.label.intrinsicContentSize.width) + 10, Self.minHit)
        let h = Self.minHit
        c.frame = NSRect(x: x, y: 0, width: w, height: h)
        c.label.frame = NSRect(x: 0, y: (h - c.label.intrinsicContentSize.height) / 2, width: w, height: c.label.intrinsicContentSize.height)
        c.setAccessibilityLabel(a11y)
        return x + w + Self.gap
    }

    private func resolveBase(_ m: Mini) {
        if let parent = look { m.base = AppModel.shared.miniBase(m.agent, parent: parent.base) }
    }

    private func label(_ m: Mini) {
        let text = "subagent \(m.agent.label) of \(project): \(m.agent.state.label)"
        guard text != m.a11y else { return }
        m.a11y = text
        m.view.setAccessibilityLabel(text)
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
        if let e = nextExpiry, Date() >= e { refresh(now: Date()) }
        guard width > 0 else { return }
        let screen = NSScreen.visibleFrame(holding: sprite)
        onLeft = forceLeft || sprite.midX - screen.minX >= screen.maxX - sprite.midX
        let x = onLeft ? sprite.minX - width - Self.gap : sprite.maxX + Self.gap
        let origin = NSPoint(x: x.rounded(), y: sprite.minY)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        animate(dt)
    }

    private func animate(_ dt: Double) {
        let model = AppModel.shared
        guard let sheet = model.sheet, let parent = look else { return }
        for m in minis {
            let look = Look(base: m.base, palette: parent.palette, outfit: nil)
            let names = Self.chain(m.agent.state)
            guard let anim = sheet.anim(base: look.base, chain: names) else { continue }
            // A mini that turns into a bee (or back) draws again at once.
            if m.base != m.drawnBase || names[0] != m.drawnAnim { m.drawnBase = m.base; m.drawnAnim = names[0]; m.elapsed = 0; m.frameIndex = -1 }
            m.elapsed += max(0, dt)
            let clock = AnimClock.frameIndex(elapsed: m.elapsed, fps: sheet.fps, count: anim.frames.count, loop: anim.loop)
            let index = model.reduceMotion && anim.loop ? 0 : clock.index
            guard index != m.frameIndex,
                  let (img, _) = model.director?.images.frame(sheet, frame: anim.frames[index], key: "\(names[0])#\(index)",
                                                              look: look, mirrored: !onLeft) else { continue }
            m.image.contents = img
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
        case .stopped: ["goodbye", "idle"]
        }
    }
}

/// Small rounded label that opens the Activity tab on click or VoiceOver press.
final class ChipView: NSView {
    let label = NSTextField(labelWithString: "")
    var onClick: ((Int) -> Void)?

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
    override func mouseUp(with event: NSEvent) { onClick?(event.clickCount) }
    override func accessibilityPerformPress() -> Bool { onClick?(1); return true }
}

extension Subagent.State {
    var label: String {
        switch self {
        case .running: "working"
        case .needsPermission: "needs permission"
        case .asking: "has a question"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
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
        case .stopped: .ended
        }
    }
}

import AppKit
import BuddyCore

struct MascotSpec {
    var key: String
    var sessionId: String?
    var state: SessionState
    var look: Look
    var label: String
    var badge: Int
    var sleeping: Bool
}

/// Reconciles mascots with sessions and runs the shared animation loop.
/// The timer exists only while mascots exist: 8 Hz (sprite fps) at rest, 30 Hz while something moves (review P1).
@MainActor
final class MascotDirector {
    unowned let model: AppModel
    private(set) var controllers: [String: MascotController] = [:]
    private(set) var timer: Timer?
    private var interval: Double?
    private var paused = false
    private var last = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []
    let images = SpriteImages()
    private var seen: [String: Int] = [:]
    private var seenCount = 0
    private var slots: [String: NSPoint] = [:]
    private var anchor: CGPoint?
    private var anchorFor: Arrangement?
    private var wasGrouped = false
    private var dragStart: CGPoint?
    var isGroupDragging: Bool { dragStart != nil }

    init(model: AppModel) {
        self.model = model
        let nc = NSWorkspace.shared.notificationCenter
        let pausing: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, pause) in pausing {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paused = pause; self?.wake() }
            })
        }
    }

    func specs() -> [MascotSpec] {
        guard let sheet = model.sheet else { return [] }
        let visible = model.sessions.filter { !$0.hidden }
        guard let top = visible.max(by: { urgency($0) < urgency($1) }) else {
            guard model.sleepMascot, let look = sleepLook(sheet) else { return [] }
            return [MascotSpec(key: "sleep", sessionId: nil, state: .idle, look: look, label: "zzz", badge: 0, sleeping: true)]
        }
        if model.mode == .single {
            guard let look = model.look(for: top) else { return [] }
            let badge = visible.filter { $0.state.needsAttention || $0.state == .done }.count
            let label = visible.count == 1 ? top.projectName : "\(visible.count) sessions"
            return [MascotSpec(key: "single", sessionId: top.id, state: top.state, look: look, label: label, badge: badge, sleeping: false)]
        }
        return visible.compactMap { s in
            model.look(for: s).map {
                MascotSpec(key: s.mascotKey, sessionId: s.id, state: s.state, look: $0,
                           label: s.terminal == .claudeDesktop ? "\(s.projectName) · Claude Desktop" : s.projectName,
                           badge: s.state == .done ? 1 : 0, sleeping: false)
            }
        }
    }

    private func sleepLook(_ sheet: SpriteSheet) -> Look? {
        guard let base = sheet.baseNames.first, let palette = sheet.paletteNames.first else { return nil }
        return Look(base: base, palette: palette, outfit: nil)
    }

    private func urgency(_ s: Session) -> Int {
        switch s.state {
        case .needsPermission, .asking: 4
        case .done, .error: 3
        case .working: 2
        default: 1
        }
    }

    func sync() {
        let specs = specs()
        let keys = Set(specs.map(\.key))
        for spec in specs where seen[spec.key] == nil { seen[spec.key] = seenCount; seenCount += 1 }
        seen = seen.filter { keys.contains($0.key) || controllers[$0.key] != nil }
        for (key, c) in controllers where !keys.contains(key) { c.leave() }
        var fresh: [MascotController] = []
        for spec in specs {
            if let c = controllers[spec.key], !c.isLeaving { c.update(spec) }
            else {
                controllers[spec.key]?.close()
                let width = 32 * model.pointScale
                let c = MascotController(spec: spec, director: self, startX: grouped ? groupBounds().maxX + 10 : freeX(width: width))
                controllers[spec.key] = c
                fresh.append(c)
            }
        }
        relayoutGroup()
        for c in fresh { if let slot = slot(for: c) { c.setY(slot.y) } }
        images.prune(keeping: Set(controllers.values.map(\.spec.look)))
        wake()
    }

    /// Scale or look changed: recreate every mascot at its current spot.
    func rebuild() {
        images.clear()
        for c in controllers.values { c.relayout() }
        sync()
    }

    func cardChanged(_ sid: String) {
        controllers.values.first { $0.spec.sessionId == sid }?.cardChanged()
    }

    func openBubble(sessionId: String) {
        controllers.values.first { $0.spec.sessionId == sessionId }?.showBubble(focus: true)
    }

    /// Orders every mascot and bubble out (or back in) for "Hide buddies".
    func applyHidden() {
        for c in controllers.values { c.setVisible(!model.buddiesHidden) }
        wake()
    }

    func removed(_ c: MascotController) {
        if controllers[c.key] === c { controllers[c.key] = nil }
        wake()
    }

    // MARK: Grouped arrangement

    var grouped: Bool { model.arrangement != .free && model.mode != .single }

    func slot(for c: MascotController) -> NSPoint? { grouped ? slots[c.key] : nil }

    func arrangementChanged() {
        relayoutGroup()
        wake()
    }

    private func currentAnchor() -> CGPoint {
        if anchorFor != model.arrangement || anchor == nil {
            anchorFor = model.arrangement
            anchor = model.defaults.groupAnchor(model.arrangement) ?? GroupLayout.defaultAnchor(bounds: floor)
        }
        return anchor ?? GroupLayout.defaultAnchor(bounds: floor)
    }

    /// Visible frame of the screen holding `p`; the probe sits just inside the group's bottom-right corner.
    private func bounds(holding p: CGPoint) -> NSRect {
        let probe = CGPoint(x: p.x - 1, y: p.y + 1)
        return (NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main)?.visibleFrame ?? floor
    }

    private func groupBounds() -> NSRect { bounds(holding: currentAnchor()) }

    private func currentLayout(_ members: [MascotController]) -> GroupLayout? {
        guard let first = members.first else { return nil }
        let a = currentAnchor()
        return GroupLayout.layout(count: members.count, item: first.panelSize, spacing: CGFloat(model.size.groupSpacing),
                                  vertical: model.arrangement == .groupedVertical, anchor: a, bounds: bounds(holding: a))
    }

    private func members() -> [MascotController] {
        controllers.values.filter(\.holdsSlot).sorted { (seen[$0.key] ?? .max, $0.key) < (seen[$1.key] ?? .max, $1.key) }
    }

    /// Recomputes slots; cheap, so it runs on every sync and tick.
    func relayoutGroup() {
        guard grouped else {
            if wasGrouped { for c in controllers.values { c.leaveGroup() } }
            wasGrouped = false
            slots = [:]
            dragStart = nil
            return
        }
        wasGrouped = true
        let list = members()
        for c in controllers.values where !list.contains(where: { $0 === c }) { c.setPosition(nil, of: 0) }
        guard let layout = currentLayout(list) else { slots = [:]; return }
        anchor = layout.anchor
        slots = Dictionary(uniqueKeysWithValues: zip(list.map(\.key), layout.origins.map { NSPoint(x: $0.x, y: $0.y) }))
        for (i, c) in list.enumerated() { c.setPosition(i + 1, of: list.count) }
    }

    func beginGroupDrag() { dragStart = currentAnchor() }

    func dragGroup(by d: NSPoint) {
        guard let start = dragStart else { return }
        anchor = CGPoint(x: start.x + d.x, y: start.y + d.y)
        relayoutGroup()
    }

    func endGroupDrag() {
        dragStart = nil
        relayoutGroup()
        saveAnchor()
        wake()
    }

    func moveGroupToEdge(left: Bool) {
        let b = groupBounds()
        let width = currentLayout(members())?.size.width ?? 0
        anchor = CGPoint(x: left ? b.minX + width : b.maxX, y: currentAnchor().y)
        relayoutGroup()
        saveAnchor()
        wake()
    }

    private func saveAnchor() {
        if let anchor { model.defaults.setGroupAnchor(anchor, for: model.arrangement) }
    }

    func bubblePlacement(for sprite: NSRect) -> BubblePlacement? {
        guard grouped else { return nil }
        return BubblePlacement.choose(sprite: sprite, screen: bounds(holding: currentAnchor()), vertical: model.arrangement == .groupedVertical)
    }

    var floor: NSRect { NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// A spot on the floor not taken by another mascot, scanning from the right.
    func freeX(width: CGFloat, excluding: MascotController? = nil) -> CGFloat {
        let f = floor
        let others = controllers.values.filter { $0 !== excluding }.map(\.centerX)
        var x = f.maxX - width * 2
        while x > f.minX + width {
            if others.allSatisfy({ abs($0 - x) > width }) { return x }
            x -= width
        }
        return CGFloat.random(in: (f.minX + width)...max(f.minX + width + 1, f.maxX - width))
    }

    // MARK: Timer

    /// Recomputes the tick rate; starts, retimes, or stops the timer.
    func wake() {
        let moving = controllers.values.contains(where: \.isMoving)
        let next = TickPolicy.interval(mascots: controllers.count, moving: moving, fps: model.sheet?.fps ?? 8,
                                       paused: paused || model.buddiesHidden)
        guard next != interval else { return }
        interval = next
        timer?.invalidate()
        timer = nil
        guard let next else { return }
        last = CACurrentMediaTime()
        let t = Timer.scheduledTimer(withTimeInterval: next, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = next * TickPolicy.tolerance
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(0, now - last), 0.1)
        last = now
        let all = Array(controllers.values)
        let active = all.filter { !$0.isLeaving }
        if !isGroupDragging { relayoutGroup() }
        let mouse = NSEvent.mouseLocation
        for c in all {
            c.step(dt: dt, others: active)
            c.updateMousePassthrough(mouse)
        }
        wake()
    }
}

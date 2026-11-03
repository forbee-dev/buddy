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
        for (key, c) in controllers where !keys.contains(key) { c.leave() }
        for spec in specs {
            if let c = controllers[spec.key], !c.isLeaving { c.update(spec) }
            else {
                controllers[spec.key]?.close()
                controllers[spec.key] = MascotController(spec: spec, director: self, startX: freeX(width: 32 * model.pointScale))
            }
        }
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
        let mouse = NSEvent.mouseLocation
        for c in all {
            c.step(dt: dt, others: active)
            c.updateMousePassthrough(mouse)
        }
        wake()
    }
}

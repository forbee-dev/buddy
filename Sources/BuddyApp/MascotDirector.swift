import AppKit
import BuddyCore

struct MascotSpec: Equatable {
    var key: String
    var sessionId: String?
    var state: SessionState
    var look: Look
    var label: String
    var badge: Int
    var sleeping: Bool
    var subagents: [Subagent] = []
    var shells = 0
    var waitingSince: Date?
    /// "42.1k tok · $0.31" for the tooltip and VoiceOver; `tagUsage` is the short form on the tag (opt-in).
    var usage: String?
    var spokenUsage: String?
    var tagUsage: String?
}

/// Reconciles mascots with sessions and runs the shared animation loop.
/// The timer exists only while mascots exist: 8 Hz (sprite fps) at rest, 30 Hz while something moves, and none at all
/// while every buddy stands still alone (its loop then plays in the render server; idle walks start from a delayed task).
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
    private var finishes: [HighFive.Finish] = []
    private var partied = false
    /// Mouse monitors for click-through while the timer is off; none otherwise.
    private var mouseMonitors: [Any] = []
    /// The found Bee's flight; the timer runs while it is set.
    private var flight: BeeFlight?
    private var beeCallout: Callout?
    private var beeCalloutTimer: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        let nc = NSWorkspace.shared.notificationCenter
        let pausing: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, pause) in pausing {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if pause { self?.endFlight() }
                    self?.paused = pause
                    self?.wake()
                }
            })
        }
    }

    func specs() -> [MascotSpec] {
        guard let sheet = model.sheet else { return [] }
        let visible = model.sessions.filter { !$0.hidden }
        guard let top = visible.max(by: { urgency($0.state) < urgency($1.state) }) else {
            guard model.sleepMascot, let look = sleepLook(sheet) else { return [] }
            return [MascotSpec(key: "sleep", sessionId: nil, state: .idle, look: look, label: "zzz", badge: 0, sleeping: true)]
        }
        if model.mode == .single {
            // Single mode keeps the project look; per-session uniqueness is for several buddies.
            guard let look = model.projectLook(cwd: top.lookKey) else { return [] }
            let badge = visible.filter { $0.state.needsAttention || $0.state == .done }.count
            let label = visible.count == 1 ? top.projectName : "\(visible.count) sessions"
            // The tag and tooltip count every visible session, not only the one shown.
            return [withActivity(MascotSpec(key: "single", sessionId: top.id, state: top.state, look: look, label: label, badge: badge, sleeping: false),
                                 top, usageOf: visible.map(\.id))]
        }
        return visible.compactMap { s in
            model.look(for: s).map {
                withActivity(MascotSpec(key: s.mascotKey, sessionId: s.id, state: s.state, look: $0,
                                        label: s.terminal == .claudeDesktop ? "\(s.projectName) · Claude Desktop" : s.projectName,
                                        badge: s.state == .done ? 1 : 0, sleeping: false), s, usageOf: [s.id])
            }
        }
    }

    private func withActivity(_ spec: MascotSpec, _ s: Session, usageOf sids: [String]) -> MascotSpec {
        var spec = spec
        if model.showMinis { spec.subagents = Array(s.subagents.values) }
        if model.showShells { spec.shells = s.runningShells }
        spec.waitingSince = s.waitingSince
        spec.usage = model.usageText(sids)
        spec.spokenUsage = model.usageText(sids, spoken: true)
        spec.tagUsage = model.tagUsage(sids)
        return spec
    }

    private func sleepLook(_ sheet: SpriteSheet) -> Look? {
        guard let base = model.characters.first, let palette = sheet.paletteNames.first else { return nil }
        return Look(base: base, palette: palette, outfit: nil)
    }

    private func urgency(_ state: SessionState) -> Int {
        switch state {
        case .needsPermission, .asking: 4
        case .done, .error: 3
        case .working: 2
        default: 1
        }
    }

    /// `force`: update every buddy even when its spec did not change (sizes, skins, or settings the spec does not hold).
    func sync(force: Bool = false) {
        let specs = specs()
        let keys = Set(specs.map(\.key))
        for spec in specs where seen[spec.key] == nil { seen[spec.key] = seenCount; seenCount += 1 }
        seen = seen.filter { keys.contains($0.key) || controllers[$0.key] != nil }
        for (key, c) in controllers where !keys.contains(key) { c.leave() }
        var fresh: [MascotController] = []
        var finished: [MascotController] = []
        for spec in specs {
            if let c = controllers[spec.key], !c.isLeaving {
                if spec.state == .done && c.spec.state != .done { finished.append(c) }
                if force || spec != c.spec { c.update(spec) }
            }
            else {
                controllers[spec.key]?.close()
                let width = 32 * model.pointScale
                let c = MascotController(spec: spec, director: self, startX: grouped ? groupBounds().maxX + 10 : freeX(width: width))
                // freeX gives a center; the label is known now, so the spot keeps its tag clear too.
                if !grouped { c.setX(freeX(width: c.footprint, excluding: c) - c.panelSize.width / 2) }
                controllers[spec.key] = c
                fresh.append(c)
            }
        }
        relayoutGroup()
        for c in fresh { if let slot = slot(for: c) { c.setY(slot.y) } }
        celebrate(finished)
        images.prune(keeping: Set(controllers.values.flatMap { c in
            [c.spec.look, Look(base: c.spec.look.base, palette: c.spec.look.palette, outfit: nil),
             Look(base: BeeEgg.base, palette: c.spec.look.palette, outfit: nil)]
        }))
        wake()
    }

    /// Scale or look changed: recreate every mascot at its current spot.
    func rebuild() {
        images.clear()
        for c in controllers.values { c.relayout() }
        sync(force: true)
    }

    /// High-five for two buddies that finish within 3 s and 300 pt (or next to each other in a group);
    /// a party when every buddy (2 or more) is done. Fun extras only, never with Reduce Motion.
    private func celebrate(_ finished: [MascotController]) {
        let live = controllers.values.filter { !$0.isLeaving && !$0.spec.sleeping }
        let allDone = live.count >= 2 && live.allSatisfy { $0.spec.state == .done }
        defer { if !allDone { partied = false } }
        guard model.funExtras, !model.reduceMotion, !finished.isEmpty else { return }
        let now = Date()
        finishes.removeAll { now.timeIntervalSince($0.at) > HighFive.window || controllers[$0.key] == nil }
        let order = members()
        var fived = false
        for c in finished {
            let f = HighFive.Finish(key: c.key, at: now, x: Double(c.centerX), slot: grouped ? order.firstIndex { $0 === c } : nil)
            if let p = HighFive.partner(for: f, among: finishes), let other = controllers[p.key], !other.isLeaving {
                let (l, r) = other.centerX <= c.centerX ? (other, c) : (c, other)
                l.highFive(mirrored: false, spark: true)
                r.highFive(mirrored: true, spark: false)
                finishes.removeAll { $0.key == p.key }
                fived = true
            } else {
                finishes.append(f)
            }
        }
        if allDone && !partied {
            partied = true
            if !fived { live.forEach { $0.replayDone() } }
        }
    }

    /// On the session's buddy; when it is gone (the last digest, shown again later), on any buddy.
    func showDigest(_ lines: [DigestLine], sessionId: String) {
        let live = controllers.values.filter { !$0.isLeaving }
        (live.first { $0.spec.sessionId == sessionId } ?? live.first)?.showDigest(lines)
        wake()
    }

    /// The Bee was just found: it flies across once (not with Reduce Motion), and a callout says where to pick it.
    func beeFound() {
        if !model.reduceMotion, !model.buddiesHidden { flight?.close(); flight = BeeFlight(model: model) }
        closeBeeCallout()
        let c = Callout(BeeFoundView { [weak self] in self?.closeBeeCallout() }, interactive: true)
        let screen = NSScreen.visibleFrame()
        c.place(above: NSRect(x: screen.midX, y: screen.maxY, width: 0, height: 0))
        beeCallout = c
        Announcer.say(BeeFoundView.spoken)
        Sounds.shared.play(.bee, session: nil, model: model)
        // 20 s unattended: the count starts again while the pointer is on it or it has focus.
        beeCalloutTimer = Task { [weak self, weak c] in
            var unattended = 0
            while unattended < 20 {
                guard (try? await Task.sleep(for: .seconds(1))) != nil, let c else { return }
                unattended = c.isKey || NSMouseInRect(NSEvent.mouseLocation, c.frame, false) ? 0 : unattended + 1
            }
            self?.closeBeeCallout()
        }
        wake()
    }

    private func closeBeeCallout() {
        beeCalloutTimer?.cancel()
        beeCalloutTimer = nil
        beeCallout?.close()
        beeCallout = nil
    }

    /// The flight stops at once: hidden buddies or a sleeping screen never leave a frozen bee.
    private func endFlight() {
        flight?.close()
        flight = nil
    }

    func showTip(_ text: String, sessionId: String) {
        controllers.values.first { $0.spec.sessionId == sessionId }?.showTip(text)
        wake()
    }

    func bubbleOpen(_ sid: String) -> Bool { controllers.values.contains { $0.spec.sessionId == sid && $0.hasBubble } }

    func cardChanged(_ sid: String) {
        controllers.values.first { $0.spec.sessionId == sid }?.cardChanged()
    }

    func openBubble(sessionId: String) {
        controllers.values.first { $0.spec.sessionId == sessionId }?.showBubble(focus: true)
    }

    func openActivity(sessionId: String, highlight: String?, focus: Bool = true) {
        controllers.values.first { $0.spec.sessionId == sessionId }?.showActivity(highlight: highlight, focus: focus)
    }

    /// Orders every mascot and bubble out (or back in) for "Hide buddies".
    func applyHidden() {
        if model.buddiesHidden { endFlight() }
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
    private func bounds(holding p: CGPoint) -> NSRect { NSScreen.visibleFrame(holding: NSRect(x: p.x - 1, y: p.y + 1, width: 1, height: 1)) }

    private func groupBounds() -> NSRect { bounds(holding: currentAnchor()) }

    /// Room left of each grouped buddy for its minis; the widest strip sets it for all slots.
    private func stripRoom(_ members: [MascotController]) -> CGFloat { members.map(\.minis.width).max().map { $0 > 0 ? $0 + MiniStrip.gap : 0 } ?? 0 }

    private func currentLayout(_ members: [MascotController]) -> GroupLayout? {
        guard let first = members.first else { return nil }
        let a = currentAnchor()
        let item = NSSize(width: first.panelSize.width + stripRoom(members), height: first.panelSize.height)
        return GroupLayout.layout(count: members.count, item: item, spacing: CGFloat(model.size.groupSpacing),
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
        let room = stripRoom(list)
        slots = Dictionary(uniqueKeysWithValues: zip(list.map(\.key), layout.origins.map { NSPoint(x: $0.x + room, y: $0.y) }))
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

    var floor: NSRect { NSScreen.visibleFrame() }

    /// A spot on the floor not taken by another mascot, scanning from the right.
    func freeX(width: CGFloat, excluding: MascotController? = nil) -> CGFloat {
        let f = floor
        let others = controllers.values.filter { $0 !== excluding }
        var x = f.maxX - width * 2
        while x > f.minX + width {
            if others.allSatisfy({ abs($0.centerX - x) >= TagLayout.minDistance(width, $0.footprint) }) { return x }
            x -= width
        }
        return CGFloat.random(in: (f.minX + width)...max(f.minX + width + 1, f.maxX - width))
    }

    // MARK: Timer

    /// Reduce Motion changed: a parked sleep loop starts again with the new setting.
    func motionChanged() {
        for c in controllers.values { c.unpark() }
        wake()
    }

    /// Recomputes the tick rate; starts, retimes, or stops the timer.
    func wake() {
        let moving = flight != nil || controllers.values.contains(where: \.isMoving)
        let idle = flight == nil && !controllers.isEmpty && controllers.values.allSatisfy(\.isIdle)
        if idle {
            let fresh = controllers.values.filter(\.needsPark)
            if !fresh.isEmpty {
                fresh.forEach { $0.unpark() }
                // One last step draws the frame, the position, and the tags; then nothing changes until an event.
                advance(dt: 0)
                fresh.forEach { $0.park() }
            }
        } else {
            for c in controllers.values { c.unpark() }
        }
        watchMouse(idle && !paused && !model.buddiesHidden)
        let next = TickPolicy.interval(mascots: controllers.count + (flight == nil ? 0 : 1), moving: moving, fps: model.sheet?.fps ?? 8,
                                       paused: paused || model.buddiesHidden, idle: idle)
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
        advance(dt: min(max(0, now - last), 0.1))
        last = now
        wake()
    }

    private func advance(dt: Double) {
        if let f = flight, !f.step(dt: dt, model: model, images: images) { flight = nil }
        let all = Array(controllers.values)
        let active = all.filter { !$0.isLeaving }
        if !isGroupDragging { relayoutGroup() }
        let mouse = NSEvent.mouseLocation
        for c in all {
            c.step(dt: dt, others: active)
            c.updateMousePassthrough(mouse)
        }
        // Free mode: tags that still overlap (dragged or pinned buddies) get cut or stacked.
        let fits = grouped ? [:] : TagLayout.resolve(active.map { TagLayout.Tag(id: $0.key, rect: $0.tagRect, priority: urgency($0.spec.state)) })
        for c in all { c.setTagFit(fits[c.key]) }
    }

    /// While the timer is off, mouse moves keep the sprite's click-through right.
    private func watchMouse(_ on: Bool) {
        guard on == mouseMonitors.isEmpty else { return }
        guard on else {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
            return
        }
        let update = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                for c in self.controllers.values { c.updateMousePassthrough(mouse) }
            }
        }
        // Moves over other apps reach the global monitor; moves while Buddy is active reach the local one.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in update() }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { e in update(); return e }) { mouseMonitors.append(l) }
    }
}

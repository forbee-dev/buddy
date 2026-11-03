import AppKit
import BuddyCore

/// One mascot: panel, animation state, walking, dragging, bubble.
@MainActor
final class MascotController {
    let key: String
    private(set) var spec: MascotSpec
    unowned let director: MascotDirector
    private var panel: MascotPanel
    private let sprite = SpriteView(frame: .zero)
    private let tag = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var x: CGFloat
    private var y: CGFloat
    private var facingLeft = false
    private var walkTarget: CGFloat?
    private var pinned = false
    private var dragging = false
    private var dragOrigin = NSPoint.zero
    private(set) var isLeaving = false
    private var goodbyeDone = false
    private var leavingFor = 0.0
    private var animKey = ""
    private var frameIndex = -1
    private var renderedMirror = false
    private var animElapsed = 0.0
    private var finishedKey: String?
    private var wanderIn = Double.random(in: 3...8)
    private var current: RenderedFrame?
    private var sliding = false
    private var bubble: BubbleController?
    private var position: (n: Int, of: Int)?

    var model: AppModel { director.model }
    private var scale: CGFloat { model.pointScale }
    private var spriteSize: CGFloat { 32 * scale }
    private var tagHeight: CGFloat { CGFloat(model.size.tagFontSize) + 8 }
    var panelSize: NSSize { NSSize(width: max(spriteSize, 100 + 10 * CGFloat(model.size.factor)), height: spriteSize + tagHeight + 4) }
    var centerX: CGFloat { x + panelSize.width / 2 }
    /// Walking, dragged, or walking off: needs the fast tick.
    var isMoving: Bool { dragging || walkTarget != nil || (isLeaving && goodbyeDone) || offSlot }
    /// Still holds its place in a group: a leaving mascot keeps it until its goodbye ends.
    var holdsSlot: Bool { !isLeaving || !goodbyeDone }
    private var slot: NSPoint? { isLeaving ? nil : director.slot(for: self) }
    private var offSlot: Bool { slot.map { abs($0.x - x) > 0.5 || abs($0.y - y) > 0.5 } ?? false }
    private var spriteScreenRect: NSRect {
        NSRect(x: x + (panelSize.width - spriteSize) / 2, y: y + tagHeight + 4, width: spriteSize, height: spriteSize)
    }

    init(spec: MascotSpec, director: MascotDirector, startX: CGFloat) {
        self.key = spec.key
        self.spec = spec
        self.director = director
        self.x = startX
        self.y = director.floor.minY
        panel = MascotPanel(size: .zero, canKey: false)
        layout()
        wireEvents()
        update(spec)
        setVisible(!director.model.buddiesHidden)
    }

    private func layout() {
        let size = panelSize
        panel.setContentSize(size)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        sprite.frame = NSRect(x: (size.width - spriteSize) / 2, y: tagHeight + 4, width: spriteSize, height: spriteSize)
        tag.frame = NSRect(x: 4, y: 2, width: size.width - 8, height: tagHeight)
        tag.alignment = .center
        tag.font = .systemFont(ofSize: CGFloat(model.size.tagFontSize), weight: .semibold)
        tag.textColor = .labelColor
        tag.lineBreakMode = .byTruncatingTail
        tag.wantsLayer = true
        tag.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        tag.layer?.cornerRadius = 6
        badge.frame = NSRect(x: sprite.frame.maxX - 18, y: sprite.frame.maxY - 18, width: 20, height: 18)
        badge.alignment = .center
        badge.font = .boldSystemFont(ofSize: 11)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(srgbRed: 0.70, green: 0.0, blue: 0.0, alpha: 1).cgColor
        badge.layer?.cornerRadius = 9
        // The sprite carries the label and count for VoiceOver; tag and badge are decoration.
        tag.setAccessibilityElement(false)
        badge.setAccessibilityElement(false)
        [sprite, tag, badge].forEach(root.addSubview)
        panel.contentView = root
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func relayout() {
        layout()
        current = nil
        animKey = ""
        frameIndex = -1
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil); bubble?.close(); bubble = nil }
    }

    private func wireEvents() {
        sprite.onClick = { [weak self] in self?.toggleBubble() }
        sprite.onDragBegan = { [weak self] in
            guard let self else { return }
            dragging = true; walkTarget = nil; dragOrigin = NSPoint(x: x, y: y)
            if director.grouped { director.beginGroupDrag() }
            director.wake()
        }
        sprite.onDrag = { [weak self] d in
            guard let self else { return }
            if director.grouped { director.dragGroup(by: d); return }
            x = dragOrigin.x + d.x; y = dragOrigin.y + d.y
        }
        sprite.onDrop = { [weak self] in
            guard let self else { return }
            dragging = false
            if director.grouped { director.endGroupDrag() } else { pinned = true }
        }
        sprite.onDoubleClick = { [weak self] in
            guard let self, !director.grouped else { return }
            pinned = false; y = director.floor.minY
        }
        sprite.onMenu = { [weak self] p in self?.showMenu(at: p) }
    }

    func update(_ new: MascotSpec) {
        let sessionChanged = new.sessionId != spec.sessionId
        let stateChanged = new.state != spec.state || sessionChanged
        spec = new
        tag.stringValue = new.label
        badge.isHidden = new.badge == 0
        badge.stringValue = "\(new.badge)"
        updateLabel()
        sprite.setAccessibilityHelp("Press to open the bubble. Use the actions menu for more.")
        if sessionChanged, let sid = new.sessionId { bubble?.retarget(sid) }
        if new.state == .ended { leave(); return }
        guard stateChanged else { return }
        finishedKey = nil
        cardChanged()
    }

    private func updateLabel() {
        let count = spec.badge > 0 ? ", \(spec.badge) waiting" : ""
        let place = position.map { ", position \($0.n) of \($0.of)" } ?? ""
        sprite.setAccessibilityLabel("Buddy for \(spec.label), \(spec.sleeping ? "sleeping" : spec.state.label)\(count)\(place)")
    }

    func setPosition(_ n: Int?, of total: Int) {
        let new = n.map { (n: $0, of: total) }
        guard new?.n != position?.n || new?.of != position?.of else { return }
        position = new
        updateLabel()
    }

    /// Group handed back to free mode: a mascot off the floor stays where it is.
    func leaveGroup() {
        if y > director.floor.minY + 1 { pinned = true }
        setPosition(nil, of: 0)
    }

    func setY(_ v: CGFloat) { y = v }

    private func isCrowded() -> Bool {
        director.controllers.values.contains { $0 !== self && abs($0.centerX - centerX) < spriteSize }
    }

    /// Opens the bubble on its own (without focus) only for a pending request; "done" gets a badge and animation.
    /// A mascot with an open card does not walk away from under the cursor (review S2).
    func cardChanged() {
        guard let sid = spec.sessionId, let s = model.session(sid) else { return }
        if let p = s.pending {
            walkTarget = nil
            let wasOpen = bubble != nil
            showBubble(focus: false)
            if !wasOpen { Announcer.say("\(s.projectName): \(p.kind == .question ? "Claude has a question" : "\(p.toolName) needs permission")") }
        } else if spec.state.needsAttention, !director.grouped, isCrowded(), !model.reduceMotion {
            walkTarget = director.freeX(width: spriteSize, excluding: self) - panelSize.width / 2
            director.wake()
        }
    }

    // MARK: Bubble

    func showBubble(focus: Bool) {
        guard spec.sessionId != nil, !model.buddiesHidden || focus else { return }
        if model.buddiesHidden { model.buddiesHidden = false }
        if bubble == nil {
            bubble = BubbleController(model: model, sessionId: spec.sessionId, single: model.mode == .single) { [weak self] in
                self?.bubble = nil
            }
        }
        followBubble()
        bubble?.show(focus: focus)
    }

    private func followBubble() {
        bubble?.follow(spriteScreenRect, placement: director.bubblePlacement(for: spriteScreenRect))
    }

    private func toggleBubble() {
        if let b = bubble { b.close(); bubble = nil } else { showBubble(focus: true) }
    }

    // MARK: Leaving

    func leave() {
        guard !isLeaving else { return }
        isLeaving = true
        bubble?.close()
        bubble = nil
        walkTarget = nil
        pinned = false
    }

    func close() {
        bubble?.close()
        panel.orderOut(nil)
        director.removed(self)
    }
}

// MARK: Motion and animation

extension MascotController {
    private var walkSpeed: CGFloat { 21 * scale }

    func step(dt: Double, others: [MascotController]) {
        if isLeaving { leavingFor += dt; if leavingFor > 3 { goodbyeDone = true } }
        move(dt: dt, others: others)
        animate(dt: dt)
        if panel.frame.origin != NSPoint(x: x, y: y) { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
        followBubble()
    }

    private func move(dt: Double, others: [MascotController]) {
        if let slot {
            walkTarget = nil
            follow(slot: slot, dt: dt)
            return
        }
        guard !dragging else { return }
        if isLeaving && goodbyeDone && walkTarget == nil {
            let f = director.floor
            walkTarget = centerX < f.midX ? f.minX - panelSize.width - 10 : f.maxX + 10
        }
        guard let target = walkTarget else { wander(dt); return }
        if model.reduceMotion { arrive(at: target); return }
        let dir: CGFloat = target < x ? -1 : 1
        facingLeft = dir < 0
        let nx = x + dir * walkSpeed * CGFloat(dt)
        let blocked = !isLeaving && others.contains { o in
            guard o !== self else { return false }
            let gap = o.centerX - (nx + panelSize.width / 2)
            return abs(gap) < spriteSize * 0.8 && gap * dir > 0
        }
        if blocked {
            walkTarget = x - dir * spriteSize * 2
            return
        }
        x = nx
        if (dir > 0 && x >= target) || (dir < 0 && x <= target) { arrive(at: target) }
    }

    private func follow(slot: NSPoint, dt: Double) {
        let dx = slot.x - x, dy = slot.y - y
        let dist = hypot(dx, dy)
        let step = walkSpeed * 3 * CGFloat(dt)
        if director.isGroupDragging || model.reduceMotion || dist <= step { x = slot.x; y = slot.y; sliding = false; return }
        x += dx / dist * step
        y += dy / dist * step
        sliding = abs(dx) > 0.5
        if sliding { facingLeft = dx < 0 }
    }

    private func arrive(at target: CGFloat) {
        x = target
        walkTarget = nil
        if isLeaving && goodbyeDone { close() }
    }

    private func wander(_ dt: Double) {
        guard !pinned, !isLeaving, model.walking, !model.reduceMotion, !spec.sleeping else { return }
        guard spec.state == .idle || spec.state == .starting || (spec.state == .done && finishedKey == "done") else { return }
        wanderIn -= dt
        guard wanderIn <= 0 else { return }
        wanderIn = Double.random(in: 4...12)
        let f = director.floor
        let span = (f.width - panelSize.width) / 4
        walkTarget = min(max(f.minX, x + CGFloat.random(in: -span...span)), f.maxX - panelSize.width)
    }

    func chain() -> [String] {
        if dragging { return ["dragged"] }
        if isLeaving { return goodbyeDone ? ["walk"] : ["goodbye"] }
        if walkTarget != nil || (sliding && offSlot) { return ["walk"] }
        if spec.sleeping { return ["sleep"] }
        switch spec.state {
        case .working: return ["working"]
        case .needsPermission: return ["permission", "question"]
        case .asking: return ["question"]
        case .done: return finishedKey == "done" ? ["idle"] : ["done"]
        case .error: return ["error"]
        case .ended: return ["goodbye"]
        case .idle, .starting: return ["idle"]
        }
    }

    private func animate(dt: Double) {
        guard let sheet = model.sheet else { return }
        let names = chain()
        guard let anim = sheet.anim(base: spec.look.base, chain: names) else { return }
        let key = names[0]
        if key != animKey { animKey = key; animElapsed = 0; frameIndex = -1 }
        animElapsed += max(0, dt)
        let clock = AnimClock.frameIndex(elapsed: animElapsed, fps: sheet.fps, count: anim.frames.count, loop: anim.loop)
        if clock.finished && finishedKey != key { finishedKey = key; if key == "goodbye" { goodbyeDone = true } }
        // Reduce Motion: looping animations hold their first frame.
        let index = model.reduceMotion && anim.loop ? 0 : clock.index
        let mirrored = facingLeft && key == "walk"
        guard index != frameIndex || mirrored != renderedMirror else { return }
        guard let (img, rendered) = director.images.frame(sheet, frame: anim.frames[index], key: "\(key)#\(index)",
                                                          look: spec.look, mirrored: mirrored) else { return }
        sprite.layer?.contents = img
        current = rendered
        frameIndex = index
        renderedMirror = mirrored
    }

    /// Clicks pass through everything except opaque sprite pixels.
    func updateMousePassthrough(_ mouse: NSPoint) {
        if dragging { panel.ignoresMouseEvents = false; return }
        let r = spriteScreenRect
        var hit = false
        if r.contains(mouse), let frame = current {
            let px = Int((mouse.x - r.minX) / scale)
            let py = Int((r.maxY - mouse.y) / scale)
            hit = frame.isOpaque(x: px, y: py)
        }
        if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
    }
}

// MARK: Context menu (also VoiceOver "show menu")

extension MascotController {
    private func showMenu(at point: NSPoint) {
        let menu = NSMenu()
        guard let sid = spec.sessionId, let s = model.session(sid), let sheet = model.sheet else {
            menu.addItem(ActionItem("Turn off sleeping buddy") { [weak self] in self?.model.sleepMascot = false })
            menu.popUp(positioning: nil, at: point, in: sprite)
            return
        }
        let cwd = s.cwd
        menu.addItem(ActionItem("Open bubble") { [weak self] in self?.showBubble(focus: true) })
        menu.addItem(ActionItem("Re-roll look") { [weak self] in self?.model.rerollLook(cwd: cwd) })
        let palettes = NSMenu()
        for name in sheet.paletteNames {
            palettes.addItem(ActionItem(name, checked: name == spec.look.palette) { [weak self] in self?.model.setLook(cwd: cwd, palette: name) })
        }
        menu.addItem(submenu("Palette", palettes))
        let outfits = NSMenu()
        outfits.addItem(ActionItem("None", checked: spec.look.outfit == nil) { [weak self] in self?.model.setLook(cwd: cwd, outfit: .some(nil)) })
        for name in sheet.outfits(fitting: spec.look.base) {
            let label = sheet.outfits[name]?.label ?? name
            outfits.addItem(ActionItem(label, checked: name == spec.look.outfit) { [weak self] in self?.model.setLook(cwd: cwd, outfit: .some(name)) })
        }
        menu.addItem(submenu("Outfit", outfits))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Move to left edge") { [weak self] in self?.moveToEdge(left: true) })
        menu.addItem(ActionItem("Move to right edge") { [weak self] in self?.moveToEdge(left: false) })
        menu.addItem(ActionItem("Jump to session") { [weak self] in self?.model.jump(sid) })
        if pinned, !director.grouped { menu.addItem(ActionItem("Unpin") { [weak self] in self?.pinned = false; self?.y = self?.director.floor.minY ?? 0 }) }
        menu.addItem(ActionItem("Hide this buddy") { [weak self] in self?.model.setHidden(sid, true) })
        menu.popUp(positioning: nil, at: point, in: sprite)
    }

    /// Keyboard/VoiceOver alternative to dragging (WCAG 2.5.7).
    private func moveToEdge(left: Bool) {
        if director.grouped { director.moveGroupToEdge(left: left); return }
        let f = director.floor
        x = left ? f.minX : f.maxX - panelSize.width
        walkTarget = nil
        pinned = true
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }
}

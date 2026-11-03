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
    private let tag = TagLabel(labelWithString: "")
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
    let minis = MiniStrip()
    /// Impatience: seconds to the next hop or tap, the running one, sprite growth, and the hop height.
    private var nudgeIn = 0.0
    private var nudgeT: Double?
    private var grow: CGFloat = 1
    private var lift: CGFloat = 0
    private var waitText = ""
    /// High-five: time into it, which way it faces, and whether this side shows the spark.
    private var five: (t: Double, mirrored: Bool, spark: Bool)?
    private let spark = NSTextField(labelWithString: "✦")
    private var tip: Callout?
    private var tipAge = 0.0
    private var digest: Callout?
    private var digestAge = 0.0
    /// Width the tag's text needs, and the cut or stack the director asks for when tags still overlap.
    private var tagNatural: CGFloat = 0
    private var tagFit: TagLayout.Fit?
    /// The sleep loop runs as a layer animation and the director's timer is off.
    private(set) var isParked = false
    static let nudgeEvery = 20.0

    var model: AppModel { director.model }
    private var scale: CGFloat { model.pointScale }
    private var spriteSize: CGFloat { 32 * scale }
    private var tagHeight: CGFloat { CGFloat(model.size.tagFontSize) + 8 }
    var panelSize: NSSize { NSSize(width: max(spriteSize, 100 + 10 * CGFloat(model.size.factor)), height: spriteSize + tagHeight + 4) }
    var centerX: CGFloat { x + panelSize.width / 2 }
    /// Room this buddy takes on the floor: its sprite or its full tag, whichever is wider.
    var footprint: CGFloat { TagLayout.footprint(sprite: spriteSize, tag: tagNatural) }
    /// The full (uncut) tag on screen, at its normal row.
    var tagRect: NSRect { NSRect(x: centerX - tagNatural / 2, y: y + 2, width: tagNatural, height: tagHeight) }
    /// Walking, dragged, or walking off: needs the fast tick.
    var isMoving: Bool { dragging || walkTarget != nil || (isLeaving && goodbyeDone) || offSlot || nudgeT != nil }
    /// Still holds its place in a group: a leaving mascot keeps it until its goodbye ends.
    var holdsSlot: Bool { !isLeaving || !goodbyeDone }
    private var slot: NSPoint? { isLeaving ? nil : director.slot(for: self) }
    private var offSlot: Bool { slot.map { abs($0.x - x) > 0.5 || abs($0.y - y) > 0.5 } ?? false }
    private var spriteScreenRect: NSRect {
        let side = sprite.frame.width
        return NSRect(x: x + (panelSize.width - side) / 2, y: y + lift + tagHeight + 4, width: side, height: side)
    }
    var hasBubble: Bool { bubble != nil }
    /// Asleep, still, and alone: nothing for the tick to do.
    var isIdle: Bool {
        spec.sleeping && !isMoving && !isLeaving && tip == nil && digest == nil && bubble == nil && five == nil && minis.width == 0
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
        minis.onOpen = { [weak self] id, n in
            guard let self else { return }
            if id != nil, ClickAction.decide(clickCount: n, isDrag: false, kind: .mini) == .jumpToParent { jumpNow(); return }
            showActivity(highlight: id)
        }
        update(spec)
        setVisible(!director.model.buddiesHidden)
    }

    private func layout() {
        let size = panelSize
        panel.setContentSize(size)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        sprite.frame = NSRect(x: (size.width - spriteSize) / 2, y: tagHeight + 4, width: spriteSize, height: spriteSize)
        tag.alignment = .center
        tag.font = .systemFont(ofSize: CGFloat(model.size.tagFontSize), weight: .semibold)
        tag.textColor = .labelColor
        tag.lineBreakMode = .byTruncatingTail
        tag.wantsLayer = true
        tag.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        spark.font = .boldSystemFont(ofSize: max(12, spriteSize / 4))
        spark.textColor = .systemYellow
        spark.isHidden = true
        spark.setAccessibilityElement(false)
        [sprite, tag, badge, spark].forEach(root.addSubview)
        panel.contentView = root
        panel.allowsToolTipsWhenApplicationIsInactive = true
        layoutTag()
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        grow = 1
    }

    /// Level 2 grows the sprite; the panel grows up and to both sides, so the feet stay put.
    private func applyGrow(_ g: CGFloat) {
        guard g != grow else { return }
        grow = g
        let side = (spriteSize * g).rounded()
        let w = max(panelSize.width, side)
        let size = NSSize(width: w, height: side + tagHeight + 4)
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        sprite.frame = NSRect(x: (w - side) / 2, y: tagHeight + 4, width: side, height: side)
        layoutTag()
        badge.frame = NSRect(x: sprite.frame.maxX - 18, y: sprite.frame.maxY - 18, width: 20, height: 18)
    }

    /// 1.25× in whole device pixels per sprite pixel where the screen allows it.
    private var grownFactor: CGFloat {
        let backing = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(1, (scale * 1.25 * backing).rounded() / backing / scale)
    }

    func relayout() {
        unpark()
        layout()
        current = nil
        animKey = ""
        frameIndex = -1
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil); bubble?.close(); bubble = nil; closeTip(); closeDigest() }
        minis.setVisible(visible)
    }

    private func wireEvents() {
        sprite.onClick = { [weak self] n in self?.handleClick(n, kind: .buddy) }
        tag.onClick = { [weak self] n in self?.handleClick(n, kind: .buddy) }
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
        sprite.onMenu = { [weak self] p in self?.showMenu(at: p) }
    }

    func update(_ new: MascotSpec) {
        let sessionChanged = new.sessionId != spec.sessionId
        let stateChanged = new.state != spec.state || sessionChanged
        spec = new
        showTag()
        badge.isHidden = new.badge == 0
        badge.stringValue = "\(new.badge)"
        updateLabel()
        minis.update(subagents: new.subagents, shells: new.shells,
                     project: new.sessionId.flatMap { model.session($0)?.projectName } ?? new.label, look: new.look)
        sprite.setAccessibilityHelp("Press to open the bubble. Use the actions menu for more.")
        var actions = [NSAccessibilityCustomAction(name: "Jump to terminal") { [weak self] in self?.jumpNow(); return true }]
        if pinned, !director.grouped { actions.append(NSAccessibilityCustomAction(name: "Unpin") { [weak self] in self?.unpin(); return true }) }
        sprite.setAccessibilityCustomActions(spec.sleeping ? [] : actions)
        if sessionChanged, let sid = new.sessionId { bubble?.retarget(sid) }
        if new.state == .ended { leave(); return }
        guard stateChanged else { return }
        finishedKey = nil
        cardChanged()
    }

    private func updateLabel() {
        let count = spec.badge > 0 ? ", \(spec.badge) waiting" : ""
        let place = position.map { ", position \($0.n) of \($0.of)" } ?? ""
        let wait = waitText.isEmpty ? "" : ", \(waitText)"
        sprite.setAccessibilityLabel("Buddy for \(spec.label), \(spec.sleeping ? "sleeping" : spec.state.label)\(wait)\(count)\(place)")
    }

    /// "waiting 6m · api" while impatient: the timer stays readable when a long name truncates.
    private func showTag() {
        tag.stringValue = waitText.isEmpty ? spec.label : "\(waitText) · \(spec.label)"
        layoutTag()
    }

    /// The tag hugs its text (at most the panel width minus 8), centered under the sprite; cut or stacked per `tagFit`.
    private func layoutTag() {
        let font = tag.font ?? .systemFont(ofSize: CGFloat(model.size.tagFontSize), weight: .semibold)
        let text = (tag.stringValue as NSString).size(withAttributes: [.font: font]).width
        tagNatural = TagLayout.tagWidth(text: text, max: panelSize.width - 8)
        var width = tagNatural
        var row: CGFloat = 2
        switch tagFit {
        case .truncate(let w)?: width = min(w, tagNatural)
        case .stack?: row += tagHeight + 2
        case nil: break
        }
        let contentWidth = panel.contentView?.frame.width ?? panelSize.width
        tag.frame = NSRect(x: ((contentWidth - width) / 2).rounded(), y: row, width: width, height: tagHeight)
        tag.toolTip = width < tagNatural ? tag.stringValue : nil
    }

    /// Set by the director in free mode; nil = the tag fits as it is.
    func setTagFit(_ fit: TagLayout.Fit?) {
        guard fit != tagFit else { return }
        tagFit = fit
        layoutTag()
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
    func setX(_ v: CGFloat) { x = v }

    private func isCrowded() -> Bool {
        director.controllers.values.contains { $0 !== self && abs($0.centerX - centerX) < TagLayout.minDistance(footprint, $0.footprint) }
    }

    /// Opens the bubble on its own (without focus) only for a pending request; "done" gets a badge and animation.
    /// A mascot with an open card does not walk away from under the cursor.
    func cardChanged() {
        guard let sid = spec.sessionId, let s = model.session(sid) else { return }
        if let p = s.pending {
            walkTarget = nil
            let wasOpen = bubble != nil
            showBubble(focus: false)
            let who = p.agentId.map { "\(s.subagentLabel($0)) (subagent)" } ?? "Claude"
            if !wasOpen { Announcer.say("\(s.projectName): \(p.kind == .question ? "\(who) has a question" : "\(who) wants to run \(DisplayText.reveal(p.toolName))")") }
        } else if spec.state.needsAttention, !director.grouped, isCrowded(), !model.reduceMotion {
            walkTarget = director.freeX(width: footprint, excluding: self) - panelSize.width / 2
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

    /// Mini or shell chip click: the bubble opens on Activity with that row marked.
    func showActivity(highlight: String?, focus: Bool = true) {
        showBubble(focus: focus)
        bubble?.showActivity(highlight: highlight)
    }

    private func followBubble() {
        bubble?.follow(spriteScreenRect, placement: director.bubblePlacement(for: spriteScreenRect))
    }

    private func toggleBubble() {
        closeTip()
        if let b = bubble { b.close(); bubble = nil } else { showBubble(focus: true) }
    }

    private func handleClick(_ count: Int, kind: ClickAction.Kind) {
        switch ClickAction.decide(clickCount: count, isDrag: false, kind: spec.sleeping ? .sleeping : kind) {
        case .openBubble: toggleBubble()
        case .jump, .jumpToParent: jumpNow()
        case .none: break
        }
    }

    /// The first click of a double-click opened the bubble; close it before the terminal comes up.
    private func jumpNow() {
        guard let sid = spec.sessionId else { return }
        bubble?.close(); bubble = nil
        model.jump(sid)
    }

    private func unpin() { pinned = false; y = director.floor.minY }

    // MARK: Fun extras and the away digest

    /// Turns to the other buddy and plays done frames 0, 1, 3, 5 (raise, raise, slap). Drawn from existing frames.
    func highFive(mirrored: Bool, spark: Bool) {
        five = (0, mirrored, spark)
        director.wake()
    }

    /// Party: the done confetti once more, in step with the others.
    func replayDone() {
        guard spec.state == .done else { return }
        finishedKey = nil
        animKey = ""
    }

    func showTip(_ text: String) {
        closeTip()
        let c = Callout(TipView(text: text), interactive: false)
        c.place(above: spriteScreenRect)
        tip = c
        tipAge = 0
        Announcer.say("Tip: \(text)")
    }

    func closeTip() { tip?.close(); tip = nil }

    /// The card bubble steps aside; a line of the digest opens it again. It takes key focus: the user just came back,
    /// and Esc closes it.
    func showDigest(_ lines: [DigestLine]) {
        bubble?.close()
        bubble = nil
        closeTip()
        digest?.close()
        let c = Callout(DigestView(lines: lines, model: model) { [weak self] in self?.closeDigest() }, interactive: true)
        c.place(above: spriteScreenRect)
        c.makeKey()
        digest = c
        digestAge = 0
        if !director.grouped {
            walkTarget = director.floor.midX - panelSize.width / 2
            director.wake()
        }
        Announcer.say("While you were away: " + lines.map(\.text).joined(separator: ", "))
    }

    func closeDigest() {
        guard let d = digest else { return }
        d.close()
        digest = nil
        if spec.sessionId.flatMap({ model.session($0)?.pending }) != nil { showBubble(focus: false) }
    }

    /// The tip hides after 20 s or a click on the buddy. The digest hides after 60 s unattended: never while it is key,
    /// while VoiceOver runs (its cursor may be in it), or while the pointer is on it.
    private func stepCallouts(dt: Double) {
        if let t = tip {
            tipAge += dt
            if tipAge > 20 { closeTip() } else { t.place(above: spriteScreenRect) }
        }
        if let d = digest {
            let attended = d.isKey || NSWorkspace.shared.isVoiceOverEnabled || NSMouseInRect(NSEvent.mouseLocation, d.frame, false)
            digestAge = attended ? 0 : digestAge + dt
            if digestAge > 60 { closeDigest() } else { d.place(above: spriteScreenRect) }
        }
    }

    /// Level 1: a big hop every 20 s and a timer on the tag. Level 2: 1.25× and two taps on the glass.
    /// Reduce Motion keeps only the timer.
    private func stepImpatience(dt: Double) {
        let waited = spec.waitingSince.map { Date().timeIntervalSince($0) }
        let level = waited.map { Impatience.level(waited: $0, after: model.escalateAfter) } ?? 0
        let text = level > 0 ? Impatience.label(waited: waited ?? 0) : ""
        if text != waitText { waitText = text; showTag(); updateLabel() }
        lift = 0
        guard level > 0, !model.reduceMotion, !isLeaving, !dragging else { nudgeT = nil; nudgeIn = 0; applyGrow(1); return }
        nudgeIn -= dt
        if nudgeT == nil, nudgeIn <= 0 { nudgeT = 0; nudgeIn = Self.nudgeEvery }
        var pulse: CGFloat = 1
        if let t = nudgeT {
            let nt = t + dt
            nudgeT = nt < 0.5 ? nt : nil
            let p = min(nt, 0.5)
            if level == 1 { lift = (CGFloat(sin(.pi * p / 0.5)) * 8 * scale).rounded() }
            else { pulse = 1 + 0.06 * CGFloat(max(0, sin(2 * .pi * p / 0.25))) }
        }
        applyGrow(level == 2 ? grownFactor * pulse : 1)
    }

    // MARK: Leaving

    func leave() {
        guard !isLeaving else { return }
        isLeaving = true
        bubble?.close()
        bubble = nil
        minis.close()
        walkTarget = nil
        pinned = false
    }

    func close() {
        bubble?.close()
        minis.close()
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
        stepImpatience(dt: dt)
        animate(dt: dt)
        let origin = NSPoint(x: x - (panel.frame.width - panelSize.width) / 2, y: y + lift)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        stepCallouts(dt: dt)
        if !isLeaving { minis.step(dt: dt, sprite: spriteScreenRect, forceLeft: director.grouped) }
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
            return abs(gap) < TagLayout.minDistance(footprint, o.footprint) && gap * dir > 0
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
        guard !pinned, !isLeaving, model.walking, !model.reduceMotion, !spec.sleeping, digest == nil else { return }
        guard spec.state == .idle || spec.state == .starting || (spec.state == .done && finishedKey == "done") else { return }
        wanderIn -= dt
        guard wanderIn <= 0 else { return }
        wanderIn = Double.random(in: 4...12)
        let f = director.floor
        let span = (f.width - panelSize.width) / 4
        let target = min(max(f.minX, x + CGFloat.random(in: -span...span)), f.maxX - panelSize.width)
        let center = target + panelSize.width / 2
        // Never pick a spot where this buddy's sprite or tag would cover another's.
        guard director.controllers.values.allSatisfy({ $0 === self || abs($0.centerX - center) >= TagLayout.minDistance(footprint, $0.footprint) })
        else { return }
        walkTarget = target
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
        if animateFive(dt: dt, sheet: sheet) { return }
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

    /// True while the high-five plays. The spark shows on the left buddy, by the raised hand.
    private func animateFive(dt: Double, sheet: SpriteSheet) -> Bool {
        guard var f = five, let done = sheet.anim(base: spec.look.base, chain: ["done"]), !isLeaving, !dragging else {
            if five != nil { five = nil; spark.isHidden = true }
            return false
        }
        let seq = [0, 1, 3, 5].map { min($0, done.frames.count - 1) }
        #if DEBUG
        f.t += max(0, dt) * (Demo.on ? 0.2 : 1)  // slow enough for a demo screenshot
        #else
        f.t += max(0, dt)
        #endif
        let i = Int(f.t * sheet.fps)
        guard i < seq.count else {
            five = nil
            spark.isHidden = true
            animKey = ""
            return false
        }
        five = f
        let s = sprite.frame
        spark.sizeToFit()
        spark.setFrameOrigin(NSPoint(x: s.maxX - spark.frame.width / 2, y: s.maxY - spark.frame.height - s.height / 4))
        spark.isHidden = !(f.spark && i >= 2)
        guard animKey != "five" || frameIndex != i,
              let (img, rendered) = director.images.frame(sheet, frame: done.frames[seq[i]], key: "done#\(seq[i])",
                                                          look: spec.look, mirrored: f.mirrored) else { return true }
        sprite.layer?.contents = img
        current = rendered
        animKey = "five"
        frameIndex = i
        renderedMirror = f.mirrored
        return true
    }

    /// Plays the sleep loop in the render server, so no timer runs. Reduce Motion keeps the still frame the tick drew.
    func park() {
        isParked = true
        guard !model.reduceMotion, let sheet = model.sheet, let anim = sheet.anim(base: spec.look.base, chain: ["sleep"]),
              anim.loop, anim.frames.count > 1 else { return }
        let images = anim.frames.indices.compactMap {
            director.images.frame(sheet, frame: anim.frames[$0], key: "sleep#\($0)", look: spec.look, mirrored: false)?.0
        }
        guard images.count == anim.frames.count else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = images
        a.calculationMode = .discrete
        a.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
        a.duration = Double(images.count) / sheet.fps
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        sprite.layer?.add(a, forKey: "sleep")
    }

    func unpark() {
        guard isParked else { return }
        isParked = false
        sprite.layer?.removeAnimation(forKey: "sleep")
        frameIndex = -1
    }

    /// Clicks pass through everything except opaque sprite pixels.
    func updateMousePassthrough(_ mouse: NSPoint) {
        if dragging { panel.ignoresMouseEvents = false; return }
        let r = spriteScreenRect
        var hit = false
        if r.contains(mouse), let frame = current {
            let pps = r.width / CGFloat(max(1, frame.width))
            let px = Int((mouse.x - r.minX) / pps)
            let py = Int((r.maxY - mouse.y) / pps)
            hit = frame.isOpaque(x: px, y: py)
        }
        // The tag takes the mouse: it clicks like the sprite, and a cut one shows its tooltip.
        if !hit { hit = tag.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY).contains(mouse) }
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
        menu.addItem(ActionItem("Open bubble") { [weak self] in self?.showBubble(focus: true) })
        menu.addItem(ActionItem("Re-roll look") { [weak self] in self?.model.rerollLook(s) })
        if model.character == AppModel.mix, model.characters.count > 1 {
            let chars = NSMenu()
            let used = model.charactersInUse(except: s)
            for name in model.characters {
                let title = model.characterLabel(name) + (used.contains(name) ? " (in use)" : "")
                chars.addItem(ActionItem(title, checked: name == spec.look.base) { [weak self] in self?.model.setLook(s, base: name) })
            }
            menu.addItem(submenu("Character", chars))
        }
        let palettes = NSMenu()
        let inUse = model.palettesInUse(except: s)
        for name in sheet.paletteNames {
            let title = inUse.contains(name) ? "\(name) (in use)" : name
            palettes.addItem(ActionItem(title, checked: name == spec.look.palette) { [weak self] in self?.model.setLook(s, palette: name) })
        }
        menu.addItem(submenu("Palette", palettes))
        let outfits = NSMenu()
        outfits.addItem(ActionItem("None", checked: spec.look.outfit == nil) { [weak self] in self?.model.setLook(s, outfit: .some(nil)) })
        for name in sheet.outfits(fitting: spec.look.base) {
            let label = sheet.outfits[name]?.label ?? name
            outfits.addItem(ActionItem(label, checked: name == spec.look.outfit) { [weak self] in self?.model.setLook(s, outfit: .some(name)) })
        }
        menu.addItem(submenu("Outfit", outfits))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Move to left edge") { [weak self] in self?.moveToEdge(left: true) })
        menu.addItem(ActionItem("Move to right edge") { [weak self] in self?.moveToEdge(left: false) })
        menu.addItem(ActionItem("Jump to session") { [weak self] in self?.model.jump(sid) })
        if pinned, !director.grouped { menu.addItem(ActionItem("Unpin") { [weak self] in self?.unpin() }) }
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

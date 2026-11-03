import AppKit

/// Borderless, transparent, non-activating, floating on every Space.
final class MascotPanel: NSPanel {
    init(size: NSSize, canKey: Bool) {
        self.canKey = canKey
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Keeps commands and answers out of screen sharing and screenshots.
        sharingType = .none
        #if DEBUG
        // `--demo-cards` only: fake data, and the card screenshots need the windows to be capturable.
        if Demo.on { sharingType = .readOnly }
        #endif
    }

    private let canKey: Bool
    override var canBecomeKey: Bool { canKey }
    override var canBecomeMain: Bool { false }
}

/// Runs a closure from an NSMenu.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The name tag. Forwards clicks, so the tag acts like the sprite.
final class TagLabel: NSTextField {
    var onClick: ((Int) -> Void)?
    override func mouseUp(with event: NSEvent) { onClick?(event.clickCount) }
}

/// The sprite. Handles click (with count), drag, right-click, and VoiceOver press.
final class SpriteView: NSView {
    var onClick: ((Int) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    var onMenu: ((NSPoint) -> Void)?
    private var downAt: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let now = NSEvent.mouseLocation
        if !dragging, hypot(now.x - start.x, now.y - start.y) > 3 { dragging = true; onDragBegan?() }
        if dragging { onDrag?(NSPoint(x: now.x - start.x, y: now.y - start.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging { onDrop?() } else { onClick?(event.clickCount) }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(convert(event.locationInWindow, from: nil)) }

    override func accessibilityPerformPress() -> Bool { onClick?(1); return true }

    override func accessibilityPerformShowMenu() -> Bool { onMenu?(NSPoint(x: bounds.midX, y: bounds.midY)); return true }
}

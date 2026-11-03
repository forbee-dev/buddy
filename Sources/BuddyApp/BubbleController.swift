import AppKit
import SwiftUI
import BuddyCore

/// Bubble state that outlives SwiftUI view updates. Replaces `@State`, which is a macro in the macOS 27 SDK
/// and its plugin is not in the Command Line Tools.
@MainActor
@Observable
final class BubbleSelection {
    var sessionId: String?
    var requestId: String?
    var reason = ""
    var picks: [Int: Set<String>] = [:]
    var others: [Int: String] = [:]
    var prompt = ""
    var expanded = false
    var sending = false
    /// Allow / Always / Submit stay disabled until 700 ms after the card appears, changes, or stops moving (H1, S2).
    var armed = false
    @ObservationIgnored private var armAt = Date.distantPast
    @ObservationIgnored private var arming = false
    /// Permission detail text and stats, built once per request id (PF4).
    @ObservationIgnored private var detailCache: (id: String, text: String, lines: Int, chars: Int)?

    init(_ id: String?) { sessionId = id }

    func disarm() {
        if armed { armed = false }
        armAt = Date().addingTimeInterval(0.7)
        guard !arming else { return }
        arming = true
        Task { @MainActor [weak self] in
            while let self, Date() < self.armAt {
                try? await Task.sleep(for: .seconds(max(0.01, self.armAt.timeIntervalSinceNow)))
            }
            self?.arming = false
            self?.armed = true
        }
    }

    /// Clears answers typed for an older request.
    func reset(for request: String?) {
        guard request != requestId else { return }
        requestId = request
        disarm()
        reason = ""
        picks = [:]
        others = [:]
    }

    /// Picker or mascot moved to another session: nothing typed for the old one carries over (C5).
    func switchTo(_ sid: String?) {
        guard sid != sessionId else { return }
        sessionId = sid
        requestId = nil
        reason = ""
        picks = [:]
        others = [:]
        prompt = ""
        expanded = false
        sending = false
        disarm()
    }

    func detail(for p: PendingRequest) -> (text: String, lines: Int, chars: Int) {
        if let c = detailCache, c.id == p.id { return (c.text, c.lines, c.chars) }
        let text = PermissionDisplay.detail(p.toolInput)
        let stats = PermissionDisplay.stats(text)
        detailCache = (p.id, text, stats.lines, stats.chars)
        return (text, stats.lines, stats.chars)
    }
}

/// Key-capable, non-activating panel that hosts the SwiftUI bubble above a mascot.
@MainActor
final class BubbleController {
    private let panel = MascotPanel(size: NSSize(width: 360, height: 120), canKey: true)
    private let selection: BubbleSelection
    private let onClose: () -> Void
    private var anchor = NSRect.zero
    private var lastSize = NSSize.zero

    init(model: AppModel, sessionId: String?, single: Bool, onClose: @escaping () -> Void) {
        self.selection = BubbleSelection(sessionId)
        self.onClose = onClose
        let view = BubbleView(model: model, selection: selection, single: single) { [weak self] in self?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.level = .floating
    }

    func show(focus: Bool) {
        if !focus && !panel.isVisible { selection.disarm() }
        panel.orderFrontRegardless()
        // Focus only on a user click, so a new card never steals keystrokes from the terminal.
        if focus { panel.makeKey() }
    }

    func retarget(_ sid: String) { selection.switchTo(sid) }

    func follow(_ sprite: NSRect) {
        guard sprite != anchor || panel.frame.size != lastSize else { return }
        let moved = anchor != .zero && sprite.origin != anchor.origin
        anchor = sprite
        lastSize = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(sprite) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        var x = sprite.midX - size.width / 2
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        var y = sprite.maxY + 4
        if y + size.height > screen.maxY { y = max(screen.minY, sprite.minY - size.height - 4) }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // A moving card must not take a click aimed at something else (review S2).
        if moved { selection.disarm() }
    }

    func close() {
        panel.orderOut(nil)
        onClose()
    }
}

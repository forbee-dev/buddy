import AppKit
import Carbon.HIToolbox
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
    var showReason = false
    var flow = QuestionFlow()
    /// Option row under the pointer, for the preview panel.
    var hovered: Int?
    /// Context line for `requestId` (what Claude said before the request).
    var context: (id: String, text: String)?
    var contextExpanded = false
    /// Measured content heights, so long content scrolls instead of growing past the screen.
    var heights: [String: CGFloat] = [:]
    var prompt = ""
    var expanded = false
    var sending = false
    /// The tab the user picked, valid while `tabFor` is still the pending request id (a new request shows its card).
    var tab: BubbleTab?
    var tabFor: String?
    /// Activity row to mark (the clicked mini).
    var highlight: String?
    var shownResults: Set<String> = []
    /// Set by the question card. Gets plain keys (no ⌘/⌃/⌥) while the bubble is key; returns true when it used the key.
    @ObservationIgnored var onKey: (@MainActor (QuestionKey, _ textFocused: Bool, _ controlFocused: Bool) -> Bool)?
    /// The request whose card already said "Ready".
    @ObservationIgnored var readyFor: String?
    @ObservationIgnored private var markdownCache: (source: String, text: AttributedString)?
    /// Allow / Always / Submit stay disabled until 700 ms after the card appears, changes, or stops moving.
    var armed = false
    @ObservationIgnored private var armAt = Date.distantPast
    @ObservationIgnored private var arming = false
    /// Permission detail text and stats, built once per request id.
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
    func reset(for request: String?, questions: [AskQuestion] = []) {
        guard request != requestId else { return }
        requestId = request
        disarm()
        clearRequestState()
        flow = QuestionFlow(questions)
        #if DEBUG
        if let request, let preset = Demo.presets[request] { preset(&flow) }
        #endif
    }

    private func clearRequestState() {
        reason = ""
        showReason = false
        flow = QuestionFlow()
        hovered = nil
        context = nil
        contextExpanded = false
    }

    /// Picker or mascot moved to another session: nothing typed for the old one carries over.
    func switchTo(_ sid: String?) {
        guard sid != sessionId else { return }
        sessionId = sid
        requestId = nil
        clearRequestState()
        prompt = ""
        expanded = false
        sending = false
        tab = nil
        highlight = nil
        shownResults = []
        disarm()
    }

    func detail(for p: PendingRequest) -> (text: String, lines: Int, chars: Int) {
        if let c = detailCache, c.id == p.id { return (c.text, c.lines, c.chars) }
        let text = PermissionDisplay.detail(p.toolInput)
        let stats = PermissionDisplay.stats(text)
        detailCache = (p.id, text, stats.lines, stats.chars)
        return (text, stats.lines, stats.chars)
    }

    /// Last message as inline markdown, built once per text. Links are removed so nothing opens from a click.
    func markdown(_ raw: String) -> AttributedString {
        if let c = markdownCache, c.source == raw { return c.text }
        let shown = DisplayText.reveal(raw)
        var text = (try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(shown)
        let linked = text.runs.filter { $0.link != nil }.map(\.range)
        for r in linked { text[r].link = nil }
        markdownCache = (raw, text)
        return text
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
    private var lastPlacement: BubblePlacement?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    init(model: AppModel, sessionId: String?, single: Bool, onClose: @escaping () -> Void) {
        self.selection = BubbleSelection(sessionId)
        self.onClose = onClose
        let view = BubbleView(model: model, selection: selection, single: single) { [weak self] in self?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.level = .floating
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e  // local monitors run on the main thread
            let used = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return used ? nil : e
        }
        // The card grows from its bottom edge; place it again so it stays on screen.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.anchor != .zero else { return }
                self.follow(self.anchor, placement: self.lastPlacement)
            }
        }
    }

    /// True when the question card (or a focused text field) used the key.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === panel else { return false }
        let editor = panel.firstResponder as? NSTextView
        // Return during IME composition confirms the composition, not the card.
        if editor?.hasMarkedText() == true { return false }
        if TextFieldKeys.keepInField(keyCode: Int(e.keyCode), command: e.modifierFlags.contains(.command), textFocused: editor != nil) {
            editor?.keyDown(with: e)
            return true
        }
        guard let onKey = selection.onKey, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        guard let key = Self.questionKey(e) else { return false }
        return onKey(key, editor != nil, Self.controlFocused(panel))
    }

    /// A control (not the hosting view or a text field) has keyboard focus: Space is the control's.
    static func controlFocused(_ window: NSWindow) -> Bool {
        guard let r = window.firstResponder else { return false }
        return r !== window && r !== window.contentView && !(r is NSTextView)
    }

    /// Tab and Shift-Tab are not card keys: they move keyboard focus.
    static func questionKey(_ e: NSEvent) -> QuestionKey? {
        switch Int(e.keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Tab: return nil
        case kVK_Space: return .space
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        default:
            guard let c = e.charactersIgnoringModifiers, c.count == 1, let d = Int(c) else { return nil }
            return .digit(d)
        }
    }

    func show(focus: Bool) {
        // A card that comes into view arms again, also when Review… on a notification opens it.
        if !panel.isVisible { selection.disarm() }
        panel.orderFrontRegardless()
        // Focus only on a user click, so a new card never steals keystrokes from the terminal.
        if focus { panel.makeKey() }
    }

    func retarget(_ sid: String) { selection.switchTo(sid) }

    func showActivity(highlight: String?) {
        selection.tab = .activity
        selection.tabFor = selection.sessionId.flatMap { AppModel.shared.session($0)?.pending?.id }
        selection.highlight = highlight
    }

    func follow(_ sprite: NSRect, placement: BubblePlacement? = nil) {
        guard sprite != anchor || panel.frame.size != lastSize || placement != lastPlacement else { return }
        lastPlacement = placement
        let moved = anchor != .zero && sprite.origin != anchor.origin
        anchor = sprite
        lastSize = panel.frame.size
        let screen = NSScreen.visibleFrame(holding: sprite)
        let size = panel.frame.size
        var x = sprite.midX - size.width / 2
        var y = sprite.maxY + 4
        switch placement {
        case .left, .right:
            x = placement == .left ? sprite.minX - size.width - 4 : sprite.maxX + 4
            y = min(max(sprite.midY - size.height / 2, screen.minY), screen.maxY - size.height)
        case .below:
            y = max(screen.minY, sprite.minY - size.height - 4)
        case .above, nil:
            if y + size.height > screen.maxY { y = max(screen.minY, sprite.minY - size.height - 4) }
        }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = max(min(y, screen.maxY - size.height), screen.minY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // A moving card must not take a click aimed at something else.
        if moved { selection.disarm() }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver); self.resizeObserver = nil }
        panel.orderOut(nil)
        onClose()
    }
}

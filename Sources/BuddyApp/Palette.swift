import AppKit
import Carbon.HIToolbox
import SwiftUI
import BuddyCore

/// Palette state that outlives view updates (no `@State` in this toolchain).
@MainActor
@Observable
final class PaletteModel {
    var query = ""
    var selectedId: String?
    /// The session whose card shows below the list.
    var openId: String?
    /// Mirrors the search field's focus both ways.
    var searchFocused = true
    let draft = BubbleSelection(nil)

    func rows(_ model: AppModel) -> [Session] { PaletteOrder.filter(PaletteOrder.sorted(model.sessions), query: query) }

    /// The selected row, else the first one (the most urgent).
    func current(_ rows: [Session]) -> Session? { rows.first { $0.id == selectedId } ?? rows.first }

    func open(_ id: String) {
        selectedId = id
        openId = id
        draft.switchTo(id)
        // Keys go to the card now: digits pick options, ⌘↩ answers.
        searchFocused = false
    }

    func closeCard() {
        openId = nil
        draft.switchTo(nil)
        searchFocused = true
    }
}

struct PaletteView: View {
    let model: AppModel
    @Bindable var palette: PaletteModel
    @FocusState private var searchFocus: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let rows = palette.rows(model)
        let selected = palette.current(rows)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Filter by project or state", text: $palette.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocus)
                    .accessibilityLabel("Filter sessions")
                PlanUsageChip(model: model)
            }
            Divider()
            if rows.isEmpty {
                Text(model.sessions.isEmpty ? "No Claude sessions right now." : "No session matches.")
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollViewReader { proxy in
                    FitScroll(key: "palette", maxHeight: palette.openId == nil ? 320 : 140, draft: palette.draft) {
                        // One clock for every row's age, and for the spoken labels too.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            VStack(spacing: 2) { ForEach(rows) { row($0, selected: $0.id == selected?.id, now: ctx.date) } }
                        }
                    }
                    .onChange(of: selected?.id) { _, id in
                        guard let id, let s = rows.first(where: { $0.id == id }) else { return }
                        proxy.scrollTo(id)
                        Announcer.say(label(s, summary: PaletteOrder.summary(s), now: Date()))
                    }
                }
            }
            if let sid = palette.openId, let s = model.session(sid) {
                Divider()
                SessionCard(model: model, session: s, draft: palette.draft)
                if let note = s.note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            }
            if model.lastDigest != nil {
                Button("Show last digest") {
                    PaletteController.shared.close()
                    model.showLastDigest()
                }
                .buttonStyle(.link)
                .accessibilityHint("Shows what happened while you were away")
            }
            Text("↑↓ select · ↩ open · ⌘↩ allow · ⌘J jump · ⇥ next waiting · esc close")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Arrows select. Return opens the card. Command Return allows. Command J jumps. Tab goes to the next waiting session. Escape closes.")
        }
        .padding(12)
        .frame(width: 600)
        .calloutBackground()
        .onChange(of: palette.searchFocused, initial: true) { _, v in if searchFocus != v { searchFocus = v } }
        .onChange(of: searchFocus) { _, v in if palette.searchFocused != v { palette.searchFocused = v } }
        .onChange(of: palette.query) { _, q in model.findBee(.palette(query: q)) }
    }

    private func row(_ s: Session, selected: Bool, now: Date) -> some View {
        let summary = PaletteOrder.summary(s)
        return HStack(spacing: 10) {
            if let sheet = model.sheet, let look = model.look(for: s), let img = MascotImages.thumbnail(sheet, look: look) {
                Image(nsImage: img).resizable().interpolation(.none).frame(width: 32, height: 32).accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.displayName).fontWeight(.semibold).lineLimit(1)
                    Circle().fill(s.state.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(s.state.label).font(.callout).foregroundStyle(.secondary)
                }
                if let line = summary {
                    Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.age(s, now: now))
                if let u = model.usageText(s.id) { Text(u) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor.opacity(contrast == .increased ? 1 : 0.7) : .clear, lineWidth: contrast == .increased ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { palette.open(s.id) }
        .id(s.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(s, summary: summary, now: now))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the card")
        .accessibilityAction { palette.open(s.id) }
    }

    static func age(_ s: Session, now: Date) -> String {
        if let since = s.waitingSince { return "waiting " + ActivityList.duration(now.timeIntervalSince(since)) }
        return ActivityList.duration(now.timeIntervalSince(s.updated)) + " ago"
    }

    private func label(_ s: Session, summary: String?, now: Date) -> String {
        [s.displayName, s.state.label, Self.age(s, now: now), summary, model.usageText(s.id, spoken: true)].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Spotlight-like panel: key window, Esc closes, closes when it loses focus.
@MainActor
final class PaletteController {
    static let shared = PaletteController()
    private var panel: MascotPanel?
    private let palette = PaletteModel()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var top = NSPoint.zero

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(model: AppModel) { if isOpen { close() } else { show(model: model) } }

    func show(model: AppModel) {
        let panel = self.panel ?? make(model)
        self.panel = panel
        palette.query = ""
        palette.selectedId = nil
        palette.closeCard()
        let screen = NSScreen.visibleFrame()
        top = NSPoint(x: screen.midX - 302, y: screen.maxY - screen.height * 0.18)
        panel.setFrameTopLeftPoint(top)
        panel.orderFrontRegardless()
        panel.makeKey()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e  // local monitors run on the main thread
            let used = MainActor.assumeIsolated { self?.handleKey(event, model: model) ?? false }
            return used ? nil : e
        }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            // The palette grows downward from a fixed top edge.
            nc.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.panel?.setFrameTopLeftPoint(self.top) } }
            },
        ]
        Announcer.say("Command palette")
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        panel?.orderOut(nil)
        palette.closeCard()
    }

    #if DEBUG
    func demoOpenFirst(model: AppModel) { if let s = palette.current(palette.rows(model)) { palette.open(s.id) } }
    #endif

    private func make(_ model: AppModel) -> MascotPanel {
        let p = MascotPanel(size: NSSize(width: 604, height: 120), canKey: true)
        let host = NSHostingController(rootView: PaletteView(model: model, palette: palette))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.level = .modalPanel
        p.setAccessibilityLabel("Buddy command palette")
        return p
    }

    /// True when the palette used the key.
    private func handleKey(_ e: NSEvent, model: AppModel) -> Bool {
        guard let panel, e.window === panel else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let editor = panel.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        if TextFieldKeys.keepInField(keyCode: Int(e.keyCode), command: mods.contains(.command), textFocused: editor != nil) {
            editor?.keyDown(with: e)
            return true
        }
        let rows = palette.rows(model)
        let current = palette.current(rows)
        let inSearch = palette.searchFocused
        switch Int(e.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_ANSI_J where mods == .command:
            if let current { model.jump(current.id) }
            close()
            return true
        case kVK_Return where mods.isEmpty || mods == .command, kVK_ANSI_KeypadEnter where mods.isEmpty || mods == .command:
            // ⌘↩ never allows a request the user has not seen: it opens the card first; the card's own ⌘↩ (armed) answers.
            if let current, palette.openId != current.id { palette.open(current.id); return true }
        case kVK_Tab where mods.isEmpty:
            // A pending card and a typed prompt keep Tab for themselves.
            if editor != nil && !inSearch { return false }
            if let open = palette.openId, model.session(open)?.pending != nil { break }
            if let next = PaletteOrder.nextWaiting(after: current?.id, in: rows) { palette.open(next.id) }
            else { Announcer.say("No other session is waiting.") }
            return true
        case kVK_UpArrow where mods.isEmpty, kVK_DownArrow where mods.isEmpty:
            if editor != nil && !inSearch { return false }
            if palette.openId != nil, palette.draft.onKey != nil, !inSearch { break }
            guard let i = rows.firstIndex(where: { $0.id == current?.id }) else { return true }
            let j = min(max(i + (Int(e.keyCode) == kVK_UpArrow ? -1 : 1), 0), rows.count - 1)
            palette.selectedId = rows[j].id
            if palette.openId != nil { palette.closeCard() }
            return true
        default:
            break
        }
        // The question card's own keys (digits, arrows, space, Return) while its card is open.
        if mods.isEmpty, palette.openId != nil, !inSearch, let onKey = palette.draft.onKey, let key = BubbleController.questionKey(e) {
            return onKey(key, editor != nil, BubbleController.controlFocused(panel))
        }
        return false
    }
}

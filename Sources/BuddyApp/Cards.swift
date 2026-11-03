import AppKit
import SwiftUI
import BuddyCore

extension NSPasteboard {
    /// For text that can hold secrets: clipboard managers skip concealed and transient items (nspasteboard.org).
    func setConcealed(_ text: String) {
        clearContents()
        setString(text, forType: .string)
        setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }
}

/// Monospaced, selectable, scrollable code block with a line count and a copy button. Never truncated.
struct CodeBox: View {
    let text: String
    let lines: Int
    var accent: Color = .secondary
    /// Spoken with the label, e.g. "changes files".
    var risk: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lines == 1 ? "1 line" : "\(lines) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.setConcealed(text)
                    Announcer.say("Copied")
                } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy tool input")
                    .help("Copy")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            // Wraps instead of scrolling sideways, so the end of a long command is never out of view.
            ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(minHeight: 36, maxHeight: 220)
            .accessibilityLabel(risk.map { "Tool input, \($0)" } ?? "Tool input")
            .accessibilityValue(text)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.5)))
    }
}

/// "Claude: …" — what Claude said before this request. Two lines; click to expand.
struct ContextLine: View {
    let requestId: String
    @Bindable var draft: BubbleSelection

    var body: some View {
        if let c = draft.context, c.id == requestId {
            Button { draft.contextExpanded.toggle() } label: {
                Text("Claude: \(c.text)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(draft.contextExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Claude said: \(c.text)")
            .accessibilityHint(draft.contextExpanded ? "Shows less" : "Shows all of it")
            .help(draft.contextExpanded ? "Show less" : "Show all")
        }
    }
}

extension View {
    /// Loads the context line for `requestId`. Sits on the card, not on the (often empty) line itself.
    func loadsContext(_ model: AppModel, _ session: Session, _ requestId: String, _ draft: BubbleSelection) -> some View {
        task(id: requestId) {
            let text = await model.context(for: session, requestId: requestId)
            if let text, draft.requestId == requestId { draft.context = (requestId, text) }
        }
    }
}

/// Grows with its content up to `maxHeight`, then scrolls.
struct FitScroll<Content: View>: View {
    let key: String
    let maxHeight: CGFloat
    let draft: BubbleSelection
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                if draft.heights[key] != h { draft.heights[key] = h }
            }
        }
        .frame(height: draft.heights[key].map { min($0, maxHeight) })
    }

    /// About 70% of the screen, minus the header and the footer.
    static var screenCap: CGFloat { max(200, (NSScreen.main?.visibleFrame.height ?? 800) * 0.7 - 160) }
}

private let armHint = "Available a moment after the card appears or stops moving."

struct PermissionCard: View {
    let model: AppModel
    let session: Session
    let pending: PendingRequest
    @Bindable var draft: BubbleSelection
    @FocusState private var focus: Bool
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let detail = draft.detail(for: pending)
        let risk = PermissionDisplay.risk(tool: pending.toolName, input: pending.toolInput)
        VStack(alignment: .leading, spacing: 10) {
            if risk == .sandboxOff {
                Label("Runs OUTSIDE the sandbox (dangerouslyDisableSandbox)", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.bold()).foregroundStyle(.white).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.70, green: 0, blue: 0)))
            }
            ContextLine(requestId: pending.id, draft: draft)
            if let d = pending.toolInput["description"]?.string {
                Text(DisplayText.reveal(d)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Claude says: \(DisplayText.reveal(d))")
            }
            if risk == .writes { WarningText(text: "Changes files") }
            CodeBox(text: detail.text, lines: detail.lines, accent: risk.color, risk: risk.label)
            if detail.lines > 10 || detail.chars > 500 {
                WarningText(text: "\(detail.chars) characters. Scroll to read all of it.")
            }
            HStack(spacing: 8) {
                Button { send(HookOutput.allow()) } label: { Text("Allow").frame(minWidth: 56) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).help("Allow (⌘↩)")
                    .disabled(!draft.armed).accessibilityHint(draft.armed ? "" : armHint)
                Button(role: .destructive) { send(HookOutput.deny(draft.reason)) } label: { Text("Deny").frame(minWidth: 56) }
                    .keyboardShortcut(.delete, modifiers: .command).help("Deny (⌘⌫)")
                    .focused($focus)
                if !pending.suggestions.isEmpty {
                    Menu("Always allow…") {
                        ForEach(Array(pending.suggestions.enumerated()), id: \.offset) { _, sug in
                            Button(DisplayText.reveal(HookOutput.suggestionLabel(sug))) {
                                guard draft.armed else { return }
                                send(HookOutput.allowAlways(sug))
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(!draft.armed)
                    .accessibilityHint(draft.armed ? "Saves a rule and allows" : armHint)
                }
                Spacer(minLength: 0)
            }
            HStack {
                if draft.showReason {
                    TextField("Reason for deny (optional)", text: $draft.reason).textFieldStyle(.roundedBorder)
                        .focused($reasonFocused)
                        .onAppear { reasonFocused = true }
                } else {
                    Button("Add a reason") { draft.showReason = true }.buttonStyle(.link).font(.callout)
                        .accessibilityHint("Shows a field for a deny reason")
                    Spacer()
                }
                Button("Answer in \(session.answerPlace)") { model.deferToTerminal(session.id, requestId: pending.id) }
                    .buttonStyle(.link).font(.callout)
                    .keyboardShortcut("t", modifiers: .command).help("Answer in \(session.answerPlace) (⌘T)")
            }
        }
        .defaultFocus($focus, true)
        .onChange(of: pending.id, initial: true) { draft.reset(for: pending.id) }
        .onChange(of: draft.armed) { _, armed in
            guard armed, draft.readyFor != pending.id else { return }
            draft.readyFor = pending.id
            Announcer.say("Ready")
        }
        .loadsContext(model, session, pending.id, draft)
    }

    /// Bound to the request this card shows, so a newer request is never answered by mistake.
    private func send(_ output: JSONValue) { model.answer(session.id, requestId: pending.id, output: output) }
}

extension PermissionDisplay.Risk {
    var color: Color {
        switch self {
        case .sandboxOff: .red
        case .writes: .orange
        case .readOnly: .secondary
        }
    }

    var label: String {
        switch self {
        case .sandboxOff: "runs outside the sandbox"
        case .writes: "changes files"
        case .readOnly: "reads only"
        }
    }
}

/// Full-width option row: hover, pressed, and selected states that read in light and dark mode.
struct OptionRowStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    let focused: Bool
    /// Increase Contrast: a stronger border on unselected rows.
    var highContrast = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = selected ? Color.accentColor.opacity(configuration.isPressed ? 0.28 : 0.16)
            : Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0.03)
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected || focused ? Color.accentColor : Color.primary.opacity(highContrast ? 0.6 : 0.3),
                              lineWidth: selected || focused ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct QuestionCard: View {
    let model: AppModel
    let session: Session
    let pending: PendingRequest
    let questions: [AskQuestion]
    @Bindable var draft: BubbleSelection
    @FocusState private var otherFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private var flow: QuestionFlow { draft.flow }
    private var highContrast: Bool { contrast == .increased }

    /// Preview panel beside the options; below them when the screen is narrow.
    static func previewBeside(_ flow: QuestionFlow) -> Bool {
        flow.current?.hasPreview == true && (NSScreen.main?.visibleFrame.width ?? 0) >= 900
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if flow.questions == questions {
                ContextLine(requestId: pending.id, draft: draft)
                if flow.count > 1 { tabs }
                if flow.isReview { review } else if let q = flow.current { step(q) }
                if !flow.uniqueTexts { WarningText(text: "Two questions have the same text. Answer in the terminal.") }
                footer
            }
        }
        .onChange(of: pending.id, initial: true) {
            draft.reset(for: pending.id, questions: questions)
            draft.onKey = { [self] key, textFocused, controlFocused in handle(key, textFocused: textFocused, controlFocused: controlFocused) }
        }
        .onChange(of: draft.flow.step) { _, _ in
            draft.hovered = nil
            if flow.isReview { Announcer.say("Review your answers") }
            else if let q = flow.current { Announcer.say("Question \(flow.progress): \(DisplayText.reveal(q.question))") }
        }
        .onDisappear { draft.onKey = nil }
        .loadsContext(model, session, pending.id, draft)
    }

    // MARK: Parts

    private var tabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                        let current = flow.step == i
                        let title = q.header.map { DisplayText.reveal($0) } ?? "Q\(i + 1)"
                        Button { draft.flow.go(to: i) } label: {
                            HStack(spacing: 4) {
                                if flow.answered(i) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                Text(title).lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(current ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(current ? Color.accentColor : .clear))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Question \(i + 1): \(title), \(flow.answered(i) ? "answered" : "not answered")")
                        .accessibilityAddTraits(current ? .isSelected : [])
                        .id(i)
                    }
                }
            }
            .onChange(of: flow.step) { _, step in proxy.scrollTo(min(step, questions.count - 1)) }
        }
    }

    @ViewBuilder private func step(_ q: AskQuestion) -> some View {
        let options = FitScroll(key: "q\(flow.step)", maxHeight: FitScroll<EmptyView>.screenCap, draft: draft) {
            VStack(alignment: .leading, spacing: 6) {
                Text(DisplayText.reveal(q.question)).font(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if q.multiSelect { Text("Choose one or more.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(q.options.enumerated()), id: \.offset) { r, o in optionRow(q, r, o) }
                otherRow(q)
            }
            .padding(.horizontal, 1)
        }
        if q.hasPreview {
            if Self.previewBeside(flow) {
                HStack(alignment: .top, spacing: 12) { options.frame(width: 352); preview(q) }
            } else {
                VStack(alignment: .leading, spacing: 8) { options; preview(q) }
            }
        } else {
            options
        }
    }

    private func optionRow(_ q: AskQuestion, _ r: Int, _ o: AskQuestion.Option) -> some View {
        let selected = flow.isPicked(flow.step, o.label)
        let label = DisplayText.reveal(o.label)
        let desc = o.description.map { DisplayText.reveal($0) }
        return Button { choose(r) } label: {
            HStack(alignment: .top, spacing: 10) {
                badge(r)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.body.weight(.semibold))
                    if let desc { Text(desc).font(.callout).foregroundStyle(.secondary) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                mark(selected: selected, multi: q.multiSelect)
            }
            .padding(10)
        }
        .buttonStyle(OptionRowStyle(selected: selected, hovered: draft.hovered == r, focused: flow.cursor[flow.step] == r,
                                    highContrast: highContrast))
        .onHover { inside in
            if inside { draft.hovered = r } else if draft.hovered == r { draft.hovered = nil }
        }
        .accessibilityLabel(desc.map { "\(label). \($0)" } ?? label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(optionHint(r, rows: q.options.count + 1, multi: q.multiSelect))
    }

    /// What picking does: it never moves to the next question by itself.
    private func optionHint(_ r: Int, rows: Int, multi: Bool) -> String {
        let key = r < 9 ? " Press \(r + 1)." : ""
        let action = multi ? "Picking adds or removes it." : "Picking selects it. Return or Next goes on."
        return "Option \(r + 1) of \(rows).\(key) \(action)"
    }

    @ViewBuilder private func otherRow(_ q: AskQuestion) -> some View {
        let r = q.options.count
        let on = flow.otherOn.contains(flow.step)
        Button { choose(r) } label: {
            HStack(spacing: 10) {
                badge(r)
                Text("Other…").font(.body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                mark(selected: on, multi: q.multiSelect)
            }
            .padding(10)
        }
        .buttonStyle(OptionRowStyle(selected: on, hovered: draft.hovered == r, focused: flow.cursor[flow.step] == r,
                                    highContrast: highContrast))
        .onHover { inside in
            if inside { draft.hovered = r } else if draft.hovered == r { draft.hovered = nil }
        }
        .accessibilityLabel("Other answer")
        .accessibilityHint(optionHint(r, rows: r + 1, multi: q.multiSelect) + " Shows a field for your answer.")
        .accessibilityAddTraits(on ? .isSelected : [])
        if on {
            TextField("Type your answer", text: Binding(get: { draft.flow.others[flow.step] ?? "" },
                                                         set: { draft.flow.others[draft.flow.step] = $0 }))
                .textFieldStyle(.roundedBorder)
                .focused($otherFocused)
                .accessibilityLabel("Other answer for \(DisplayText.reveal(q.question))")
                .accessibilityHint("Return confirms")
        }
    }

    private func badge(_ r: Int) -> some View {
        Text(r < 9 ? "\(r + 1)" : "·")
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }

    private func mark(selected: Bool, multi: Bool) -> some View {
        Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "checkmark.circle.fill" : "circle"))
            .foregroundStyle(selected ? Color.accentColor : highContrast ? Color.primary : Color.secondary)
            .font(.title3)
            .accessibilityHidden(true)
    }

    /// The hovered row, else the keyboard row, else the selected one, else the first option with a preview.
    private func preview(_ q: AskQuestion) -> some View {
        let picked = q.options.firstIndex { flow.isPicked(flow.step, $0.label) }
        let row = [draft.hovered, flow.cursor[flow.step], picked].compactMap { $0 }.first { $0 < q.options.count }
            ?? q.options.firstIndex { $0.preview != nil }
        let o = row.map { q.options[$0] }
        let body = o?.preview.map { DisplayText.reveal($0.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") }.joined(separator: "\n")) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(o.map { "Preview: \(DisplayText.reveal($0.label))" } ?? "Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(body ?? "No preview for this option.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(body == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview")
        .accessibilityValue(body ?? "No preview for this option.")
    }

    private var review: some View {
        FitScroll(key: "review", maxHeight: FitScroll<EmptyView>.screenCap, draft: draft) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review your answers").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                    let a = flow.answer(i)
                    Button { draft.flow.go(to: i) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DisplayText.reveal(q.question)).font(.callout).foregroundStyle(.secondary)
                                if a.isEmpty {
                                    WarningText(text: "Not answered").font(.body.weight(.semibold))
                                } else {
                                    Text(DisplayText.reveal(a)).font(.body.weight(.semibold))
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "pencil").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .padding(10)
                    }
                    .buttonStyle(OptionRowStyle(selected: false, hovered: false, focused: false))
                    .accessibilityLabel("\(DisplayText.reveal(q.question)): \(a.isEmpty ? "not answered" : DisplayText.reveal(a))")
                    .accessibilityHint("Edits this answer")
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var footer: some View {
        HStack {
            if flow.count > 1 {
                Button("‹ Back") { draft.flow.back() }.disabled(flow.step == 0).help("Back (←)")
                    .accessibilityLabel("Back")
                Spacer()
            }
            Button("Answer in \(session.answerPlace)") { model.deferToTerminal(session.id, requestId: pending.id) }
                .buttonStyle(.link).font(.callout)
                .keyboardShortcut("t", modifiers: .command).help("Answer in \(session.answerPlace) (⌘T)")
            Spacer()
            if flow.showsSubmit {
                Button("Submit", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).help("Submit (⌘↩)")
                    .disabled(!flow.complete || !draft.armed)
                    .accessibilityHint(flow.complete ? (draft.armed ? "" : armHint) : "Answer every question first")
            } else {
                Button(flow.isLastQuestion ? "Review" : "Next ›") { draft.flow.next() }
                    .disabled(!flow.canAdvance).help("Next (Return or →)")
                    .accessibilityLabel(flow.isLastQuestion ? "Review" : "Next")
                    .accessibilityHint(flow.canAdvance ? "" : "Answer this question first")
            }
        }
    }

    // MARK: Actions

    /// Picks only; Return, →, or Next moves on, so a pick never changes the question under the user.
    private func choose(_ row: Int) {
        let step = flow.step
        draft.flow.pick(row)
        if row == flow.current?.options.count, flow.otherOn.contains(step) {
            Task { @MainActor in otherFocused = true }
        }
    }

    private func submit() {
        guard draft.armed, draft.flow.complete else { return }
        model.answer(session.id, requestId: pending.id, output: HookOutput.answer(toolInput: pending.toolInput, answers: draft.flow.answers))
    }

    private func handle(_ key: QuestionKey, textFocused: Bool, controlFocused: Bool) -> Bool {
        guard model.session(session.id)?.pending?.id == pending.id, draft.requestId == pending.id else { return false }
        switch QuestionKeys.action(key, flow: draft.flow, textFocused: textFocused, controlFocused: controlFocused) {
        case .pick(let r): choose(r)
        case .back: draft.flow.back()
        case .next: draft.flow.next()
        case .cursor(let d):
            draft.flow.moveCursor(d)
            if let q = draft.flow.current, let r = draft.flow.cursor[draft.flow.step] {
                let label = r < q.options.count ? DisplayText.reveal(q.options[r].label) : "Other answer"
                Announcer.say("\(label), option \(r + 1) of \(q.options.count + 1)")
            }
        case .primary:
            if draft.flow.showsSubmit { submit() } else if draft.flow.canAdvance { draft.flow.next() }
            if textFocused { otherFocused = false }
        case .ignore: return false
        }
        return true
    }
}

struct DoneCard: View {
    let model: AppModel
    let session: Session
    @Bindable var draft: BubbleSelection
    @FocusState private var promptFocused: Bool

    var body: some View {
        let desktopHeld = session.terminal == .claudeDesktop && session.permissionMode == "bypassPermissions"
        let route = desktopHeld ? .none : model.route(for: session)
        VStack(alignment: .leading, spacing: 8) {
            if let m = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                let long = m.count > 360 || m.split(separator: "\n").count > 6
                let text = Text(draft.markdown(m)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if draft.expanded && long {
                    FitScroll(key: "done", maxHeight: min(320, FitScroll<EmptyView>.screenCap), draft: draft) { text }
                } else {
                    text.lineLimit(6)
                }
                if long {
                    Button(draft.expanded ? "Show less" : "Show more") { draft.expanded.toggle() }.buttonStyle(.link).font(.callout)
                }
            }
            Text("Next prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextEditor(text: $draft.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .disabled(route == .none)
                .accessibilityLabel("Next prompt")
            .frame(height: 64)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(promptFocused ? Color.accentColor : Color.primary.opacity(0.15)))
            HStack(alignment: .firstTextBaseline) {
                if desktopHeld || (session.terminal == .claudeDesktop && route == .none) {
                    WarningText(text: "Answer in Claude Desktop: Buddy cannot deliver a prompt to this session.")
                } else {
                    Text(session.remote != nil ? PromptGuard.remoteRefusal : routeText(route)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).help("Send (⌘↩)")
                    .disabled(route == .none || draft.sending || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint(route == .none ? "Buddy cannot reach this terminal" : "")
            }
            if route == .inbox && session.permissionMode == "bypassPermissions" {
                WarningText(text: "This session runs in bypassPermissions mode. Claude may hold this message until you approve it in the terminal.")
            }
            // State only here; the process checks run when you press Send.
            if let refusal = PromptGuard.stateRefusal(session.state) { WarningText(text: refusal) }
            if let status = model.sendStatus[session.id] { Text(status).font(.caption) }
            JumpButton(model: model, session: session)
        }
        .defaultFocus($promptFocused, true)
        // TextEditor ignores defaultFocus in this panel; ask again once the window has settled.
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            if route != .none { promptFocused = true }
        }
    }

    private func routeText(_ r: PromptRoute) -> String {
        switch r {
        case .editor(let name): "Types into your \(name) terminal."
        case .inbox: "Sends as a peer message."
        case .none: "Buddy cannot reach this terminal. Use Jump."
        }
    }

    private func send() {
        let text = draft.prompt
        guard !text.isEmpty, !draft.sending else { return }
        draft.sending = true
        Task {
            let result = await model.sendPrompt(text, to: session.id)
            draft.sending = false
            if result == .sent { draft.prompt = "" }
        }
    }
}

import SwiftUI
import BuddyCore

/// Monospaced, selectable, scrollable. Never truncated.
struct CodeBox: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .frame(minHeight: 44, maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))
        .accessibilityLabel("Tool input")
        .accessibilityValue(text)
    }
}

private let armHint = "Available a moment after the card appears or stops moving."

struct PermissionCard: View {
    let model: AppModel
    let session: Session
    let pending: PendingRequest
    @Bindable var draft: BubbleSelection
    @FocusState private var focus: Bool

    var body: some View {
        let detail = draft.detail(for: pending)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(DisplayText.reveal(pending.toolName)) wants permission").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
            if PermissionDisplay.sandboxDisabled(pending.toolInput) {
                Label("Runs OUTSIDE the sandbox (dangerouslyDisableSandbox)", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.bold()).foregroundStyle(.white).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.70, green: 0, blue: 0)))
            }
            if let d = pending.toolInput["description"]?.string {
                Text("Claude says: \(DisplayText.reveal(d))").font(.callout).foregroundStyle(.secondary)
            }
            CodeBox(text: detail.text)
            if detail.lines > 10 || detail.chars > 500 {
                WarningText(text: "\(detail.lines) lines, \(detail.chars) chars. Scroll to read all of it.")
            }
            ForEach(Array(pending.suggestions.enumerated()), id: \.offset) { _, sug in
                Button(DisplayText.reveal(HookOutput.suggestionLabel(sug))) { send(HookOutput.allowAlways(sug)) }
                    .disabled(!draft.armed).accessibilityHint(draft.armed ? "Saves a rule and allows" : armHint)
            }
            TextField("Reason for deny (optional)", text: $draft.reason).textFieldStyle(.roundedBorder)
            HStack {
                Button("Allow") { send(HookOutput.allow()) }
                    .keyboardShortcut(.return, modifiers: .command).help("Allow (⌘↩)")
                    .disabled(!draft.armed).accessibilityHint(draft.armed ? "" : armHint)
                Button("Deny", role: .destructive) { send(HookOutput.deny(draft.reason)) }
                    .keyboardShortcut(.delete, modifiers: .command).help("Deny (⌘⌫)")
                    .focused($focus)
                Spacer()
                Button("Answer in \(session.answerPlace)") { model.deferToTerminal(session.id, requestId: pending.id) }
                    .keyboardShortcut("t", modifiers: .command).help("Answer in \(session.answerPlace) (⌘T)")
            }
        }
        .defaultFocus($focus, true)
        .onChange(of: pending.id, initial: true) { draft.reset(for: pending.id) }
    }

    /// Bound to the request this card shows, so a newer request is never answered by mistake.
    private func send(_ output: JSONValue) { model.answer(session.id, requestId: pending.id, output: output) }
}

struct QuestionCard: View {
    let model: AppModel
    let session: Session
    let pending: PendingRequest
    let questions: [AskQuestion]
    let draft: BubbleSelection
    private var picks: [Int: Set<String>] { draft.picks }
    private var others: [Int: String] { draft.others }

    private func answer(_ i: Int) -> String {
        let q = questions[i]
        let other = others[i] ?? ""
        let chosen = q.options.map(\.label).filter { picks[i]?.contains($0) ?? false }
        if !q.multiSelect && !other.trimmingCharacters(in: .whitespaces).isEmpty { return other.trimmingCharacters(in: .whitespaces) }
        return HookOutput.answerText(selected: chosen, other: q.multiSelect ? other : "")
    }

    /// Answers are keyed by question text, so duplicate texts cannot be answered safely.
    private var uniqueTexts: Bool { Set(questions.map(\.question)).count == questions.count }
    private var complete: Bool { !questions.isEmpty && uniqueTexts && questions.indices.allSatisfy { !answer($0).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in questionView(i, q) }
            if !uniqueTexts { WarningText(text: "Two questions have the same text. Answer in the terminal.") }
            HStack {
                Button("Submit") {
                    var answers: [String: String] = [:]
                    for i in questions.indices { answers[questions[i].question] = answer(i) }
                    model.answer(session.id, requestId: pending.id, output: HookOutput.answer(toolInput: pending.toolInput, answers: answers))
                }
                .keyboardShortcut(.return, modifiers: .command).help("Submit (⌘↩)")
                .disabled(!complete || !draft.armed)
                .accessibilityHint(complete ? (draft.armed ? "" : armHint) : "Answer every question first")
                Spacer()
                Button("Answer in \(session.answerPlace)") { model.deferToTerminal(session.id, requestId: pending.id) }
                    .keyboardShortcut("t", modifiers: .command).help("Answer in \(session.answerPlace) (⌘T)")
            }
        }
        .onChange(of: pending.id, initial: true) { draft.reset(for: pending.id) }
    }

    private func questionView(_ i: Int, _ q: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let h = q.header { Text(DisplayText.reveal(h).uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
            Text(DisplayText.reveal(q.question)).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
            if q.multiSelect {
                ForEach(q.options, id: \.label) { o in
                    Toggle(isOn: binding(i, o.label)) { optionLabel(o) }.toggleStyle(.checkbox)
                }
            } else {
                Picker(DisplayText.reveal(q.question), selection: single(i)) {
                    ForEach(q.options, id: \.label) { o in optionLabel(o).tag(o.label) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            TextField("Other", text: Binding(get: { others[i] ?? "" }, set: { draft.others[i] = $0 }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Other answer for \(DisplayText.reveal(q.question))")
        }
    }

    private func optionLabel(_ o: AskQuestion.Option) -> some View {
        VStack(alignment: .leading) {
            Text(DisplayText.reveal(o.label))
            if let d = o.description { Text(DisplayText.reveal(d)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func binding(_ i: Int, _ label: String) -> Binding<Bool> {
        Binding(get: { picks[i]?.contains(label) ?? false }, set: { on in
            var set = picks[i] ?? []
            if on { set.insert(label) } else { set.remove(label) }
            draft.picks[i] = set
        })
    }

    private func single(_ i: Int) -> Binding<String> {
        Binding(get: { picks[i]?.first ?? "" }, set: { draft.picks[i] = [$0] })
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
                if draft.expanded || m.count <= 280 {
                    ScrollView { Text(m).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
                } else {
                    Text(m.prefix(280) + "…")
                }
                if m.count > 280 { Button(draft.expanded ? "Show less" : "Show more") { draft.expanded.toggle() }.buttonStyle(.link) }
            }
            HStack {
                TextField("Next prompt", text: $draft.prompt).textFieldStyle(.roundedBorder).onSubmit(send)
                    .disabled(route == .none).focused($promptFocused)
                Button("Send", action: send).disabled(route == .none || draft.sending || draft.prompt.isEmpty)
                    .accessibilityHint(route == .none ? "Buddy cannot reach this terminal" : "")
            }
            if desktopHeld || (session.terminal == .claudeDesktop && route == .none) {
                WarningText(text: "Answer in Claude Desktop: Buddy cannot deliver a prompt to this session.")
            } else {
                Text(routeText(route)).font(.caption).foregroundStyle(.secondary)
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
    }

    private func routeText(_ r: PromptRoute) -> String {
        switch r {
        case .editor(let name): "Types into the \(name) terminal as your input."
        case .inbox: "Arrives as a peer message from another session, not as your own typing."
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

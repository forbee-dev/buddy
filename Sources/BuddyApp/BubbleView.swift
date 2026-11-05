import SwiftUI
import BuddyCore

struct BubbleView: View {
    let model: AppModel
    let selection: BubbleSelection
    let single: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if single { sessionPicker }
            if let sid = selection.sessionId, let s = model.session(sid) {
                header(s)
                if s.hasActivity { tabs(s) }
                if activeTab(s) == .activity {
                    ActivityList(session: s, draft: selection, usage: model.usageText(s.id), spokenUsage: model.usageText(s.id, spoken: true))
                } else {
                    SessionCard(model: model, session: s, draft: selection)
                    if let note = s.note {
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                header(nil)
                Text("No Claude sessions right now.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: wide ? 640 : 380)
        .calloutBackground(border: border.color, lineWidth: border.width)
    }

    private var pending: PendingRequest? { selection.sessionId.flatMap { model.session($0)?.pending } }

    /// Room for the option preview panel.
    private var wide: Bool {
        guard let p = pending, p.kind == .question, selection.requestId == p.id,
              let s = model.session(selection.sessionId ?? ""), activeTab(s) == .card else { return false }
        return QuestionCard.previewBeside(selection.flow)
    }

    /// Red when the sandbox is off, orange for tools that change things.
    private var border: (color: AnyShapeStyle, width: CGFloat) {
        guard let p = pending, p.kind == .permission else { return (AnyShapeStyle(.separator), 1) }
        let risk = PermissionDisplay.risk(tool: p.toolName, input: p.toolInput)
        return risk == .readOnly ? (AnyShapeStyle(.separator), 1) : (AnyShapeStyle(risk.color.opacity(0.75)), 2)
    }

    @ViewBuilder private var sessionPicker: some View {
        let sessions = model.menuSessions.filter { !$0.hidden }
        if sessions.count > 1 {
            Picker("Session", selection: Binding(get: { selection.sessionId ?? "" }, set: { selection.switchTo($0) })) {
                ForEach(sessions) { s in Text("\(s.projectName) · \(s.state.label)").tag(s.id) }
            }
            .accessibilityLabel("Choose a session")
        }
    }

    private func header(_ s: Session?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s?.projectName ?? "Buddy").font(.headline)
                if let s {
                    HStack(spacing: 4) {
                        Text(subtitle(s)).font(.callout)
                        if let u = model.usageText(s.id) {
                            Text("· \(u)").font(.caption.monospacedDigit()).accessibilityLabel(model.usageText(s.id, spoken: true) ?? u)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            // One header for VoiceOver: project, state, then tokens and cost.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if let p = s?.pending, p.kind == .question, selection.requestId == p.id, selection.flow.count > 1 {
                Text(selection.flow.progress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .accessibilityLabel("Question \(selection.flow.progress)")
            }
            CloseButton(label: "Close bubble", action: close)
        }
    }

    /// Activity is the default only when nothing waits for the user.
    private func activeTab(_ s: Session) -> BubbleTab {
        if let t = selection.tab, selection.tabFor == s.pending?.id, s.hasActivity { return t }
        // A finished turn shows its done card first; Activity stays one click away.
        return s.pending == nil && s.hasActivity && s.state != .done ? .activity : .card
    }

    private func tabs(_ s: Session) -> some View {
        let first = s.pending.map { $0.kind == .question ? "Question" : "Permission" } ?? (s.state == .done ? "Result" : "Status")
        let count = s.subagents.count + s.shells.count
        return Picker("View", selection: Binding(get: { activeTab(s) }, set: { t in
            selection.tab = t
            selection.tabFor = s.pending?.id
            if t == .card { selection.disarm() }
        })) {
            Text(first).tag(BubbleTab.card)
            Text("Activity (\(count))").tag(BubbleTab.activity)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Bubble view")
    }

    private func subtitle(_ s: Session) -> String {
        let who = s.pending?.agentId.map { "\(s.subagentLabel($0)) (subagent)" } ?? "Claude"
        if let p = s.pending { return p.kind == .question ? "\(who) asks" : "\(who) wants to run \(DisplayText.reveal(p.toolName))" }
        return s.state == .done ? "Claude finished" : "\(s.terminal.displayName) · \(s.state.label)"
    }
}

/// The card for a session's current state. Shared by the bubble and the command palette.
struct SessionCard: View {
    let model: AppModel
    let session: Session
    let draft: BubbleSelection

    var body: some View {
        if let p = session.pending, p.kind == .permission {
            PermissionCard(model: model, session: session, pending: p, draft: draft)
        } else if let p = session.pending, p.kind == .question {
            QuestionCard(model: model, session: session, pending: p, questions: AskQuestion.parse(p.toolInput), draft: draft)
        } else if session.state == .done || session.state == .idle || session.state == .starting {
            DoneCard(model: model, session: session, draft: draft)
        } else {
            StatusCard(model: model, session: session)
        }
    }
}

enum BubbleTab: Hashable { case card, activity }

/// Subagents and background shells of one session, running ones first.
struct ActivityList: View {
    let session: Session
    @Bindable var draft: BubbleSelection
    /// "42.1k tok · $0.31" for the whole session, subagents included, and its VoiceOver form.
    var usage: String?
    var spokenUsage: String?

    private struct Row: Identifiable {
        let id: String
        let running: Bool
        let started: Date
        let agent: Subagent?
        let shell: Shell?
    }

    /// A shell started inside a subagent comes right after that subagent's row (E1).
    private var rows: [Row] {
        let agents = session.subagents.values.map { Row(id: $0.id, running: $0.state.isActive, started: $0.startedAt, agent: $0, shell: nil) }
        let shells = session.shells.values.map { Row(id: $0.id, running: $0.state == .running, started: $0.startedAt, agent: nil, shell: $0) }
        let owned = shells.filter { $0.shell?.owner.map { session.subagents[$0] != nil } ?? false }
        let order = { (a: Row, b: Row) in (a.running ? 0 : 1, b.started, a.id) < (b.running ? 0 : 1, a.started, b.id) }
        return (agents + shells.filter { r in !owned.contains { $0.id == r.id } }).sorted(by: order).flatMap { r in
            [r] + (r.agent.map { a in owned.filter { $0.shell?.owner == a.id }.sorted(by: order) } ?? [])
        }
    }

    var body: some View {
        if let usage {
            Label(usage, systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Session usage: \(spokenUsage ?? usage)")
        }
        FitScroll(key: "activity", maxHeight: min(360, FitScroll<EmptyView>.screenCap), draft: draft) {
            // One clock for the list; it ticks only while the bubble is on screen.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { r in
                        if let a = r.agent { agentRow(a, now: ctx.date) } else if let s = r.shell { shellRow(s, now: ctx.date) }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private func agentRow(_ a: Subagent, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            line(id: a.id, color: a.state.sessionState.color, label: Text(a.label),
                 kind: a.background ? "\(a.type) · background" : a.type, state: a.state.label, start: a.startedAt, end: a.endedAt, now: now,
                 a11y: "subagent \(a.label), \(a.type), \(a.state.label)", selected: draft.highlight == a.id)
            if let m = a.lastMessage, !a.state.isActive {
                DisclosureGroup("Show result", isExpanded: Binding(get: { draft.shownResults.contains(a.id) }, set: { on in
                    if on { draft.shownResults.insert(a.id) } else { draft.shownResults.remove(a.id) }
                })) {
                    Text(m).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .padding(.leading, 15)
                .accessibilityLabel("Result of \(a.label)")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(draft.highlight == a.id ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(draft.highlight == a.id ? Color.accentColor : .clear))
    }

    private func shellRow(_ s: Shell, now: Date) -> some View {
        let owner = s.owner.flatMap { session.subagents[$0]?.label }
        return line(id: s.id, color: s.state == .running ? .blue : s.state == .finished ? .green : .gray,
                    label: Text(">_ ").font(.system(.body, design: .monospaced).bold()) + Text(s.label),
                    kind: owner == nil ? "shell" : "shell of this subagent", state: s.state.rawValue, start: s.startedAt, end: s.endedAt, now: now,
                    a11y: "background shell \(s.label), \(s.state.rawValue)" + (owner.map { ", started by subagent \($0)" } ?? ""))
            .padding(6)
            .padding(.leading, owner == nil ? 0 : 18)
    }

    private func line(id: String, color: Color, label: Text, kind: String, state: String, start: Date, end: Date?, now: Date,
                      a11y: String, selected: Bool = false) -> some View {
        let took = Self.duration((end ?? now).timeIntervalSince(start))
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                label.lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(took).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("\(kind) · \(state)").font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a11y), \(end == nil ? "running for" : "took") \(took)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, s % 3600 / 60)
    }
}

/// Warning line: readable primary text with an orange icon.
struct WarningText: View {
    let text: String
    var body: some View {
        Label { Text(text).foregroundStyle(.primary) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
    }
}

struct StatusCard: View {
    let model: AppModel
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.state == .needsPermission || session.state == .asking {
                Text("Claude is waiting in the terminal. Buddy has no card for this request.")
            }
            if session.state == .error, let e = session.lastError {
                ScrollView {
                    Text(DisplayText.reveal(e)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .accessibilityLabel("Error output")
            }
            JumpButton(model: model, session: session)
        }
    }
}

struct JumpButton: View {
    let model: AppModel
    let session: Session
    var body: some View {
        if session.terminal == .claudeDesktop {
            Button("Open Claude Desktop") { model.jump(session.id) }
                .help("Claude Desktop has no link to a single session. Pick the session in its sidebar.")
        } else {
            Button("Jump to terminal") { model.jump(session.id) }
        }
    }
}

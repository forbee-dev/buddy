import SwiftUI
import BuddyCore

struct BubbleView: View {
    let model: AppModel
    let selection: BubbleSelection
    let single: Bool
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if single { sessionPicker }
            if let sid = selection.sessionId, let s = model.session(sid) {
                header(s)
                card(s)
                if let note = s.note {
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                header(nil)
                Text("No Claude sessions right now.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 14).fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .padding(2)
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
                Text(s?.projectName ?? "Buddy").font(.headline).accessibilityAddTraits(.isHeader)
                if let s { Text("\(s.terminal.displayName) · \(s.state.label)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close bubble")
            .help("Close (Esc)")
        }
    }

    @ViewBuilder private func card(_ s: Session) -> some View {
        if let p = s.pending, p.kind == .permission {
            PermissionCard(model: model, session: s, pending: p, draft: selection)
        } else if let p = s.pending, p.kind == .question {
            QuestionCard(model: model, session: s, pending: p, questions: AskQuestion.parse(p.toolInput), draft: selection)
        } else if s.state == .done || s.state == .idle || s.state == .starting {
            DoneCard(model: model, session: s, draft: selection)
        } else {
            StatusCard(model: model, session: s)
        }
    }
}

extension SessionState {
    var label: String {
        switch self {
        case .starting: "starting"
        case .working: "working"
        case .needsPermission: "needs permission"
        case .asking: "has a question"
        case .done: "done"
        case .idle: "idle"
        case .error: "tool failed"
        case .ended: "ended"
        }
    }
}

/// Warning line: readable primary text with an orange icon (review A4).
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

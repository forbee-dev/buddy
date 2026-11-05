import SwiftUI
import BuddyCore

/// Menu bar dropdown: hide/show, the buddies list, Settings, Welcome, Quit.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.buddiesHidden.toggle()
            } label: {
                Label(model.buddiesHidden ? "Show buddies" : "Hide buddies",
                      systemImage: model.buddiesHidden ? "eye" : "eye.slash")
            }
            .keyboardShortcut("b")
            .help(model.buddiesHidden ? "Show buddies (⌘B)" : "Hide buddies (⌘B)")
            Divider()
            if model.hooksOutdated {
                Button { SettingsWindow.show(model: model, tab: .hooks) } label: {
                    WarningText(text: "New hook events available: click Install hooks")
                }
                .help("Opens Settings → Hooks")
            }
            buddies
            if model.lastDigest != nil {
                Button("Show last digest") { model.showLastDigest() }
                    .help("What happened while you were away")
            }
            Divider()
            Button("Settings…") { SettingsWindow.show(model: model) }.keyboardShortcut(",")
            Button("Welcome…") { OnboardingWindow.show(model: model) }
            Button("Uninstall Buddy…") { UninstallWindow.show(model: model) }
                .help("Removes hooks, the extension, the login item, and Buddy's data folder, after you confirm")
            HStack {
                Button("Quit Buddy") { NSApp.terminate(nil) }.keyboardShortcut("q")
                Spacer()
                Text("v\(AppServices.version)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private var buddies: some View {
        let sessions = model.menuSessions
        HStack {
            Text("Buddies").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            PlanUsageChip(model: model)
        }
        if model.planChip != nil, let u = model.planUsage {
            // The windows with their reset times; the chip above carries the color.
            ForEach(u.lines(), id: \.self) { Text($0).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        if let err = model.sheetError {
            Label { Text(err) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }.font(.caption)
        }
        if sessions.isEmpty { Text("No Claude sessions yet.").foregroundStyle(.secondary) }
        ForEach(sessions) { s in BuddyRow(model: model, session: s) }
    }
}

struct BuddyRow: View {
    let model: AppModel
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if session.hidden { model.setHidden(session.id, false) }
                model.director?.openBubble(sessionId: session.id)
            } label: {
                HStack(spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(session.displayName).fontWeight(.medium).lineLimit(1)
                            Spacer(minLength: 4)
                            if let u = model.usageText(session.id) { Text(u).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        HStack(spacing: 4) {
                            Circle().fill(session.state.color).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(session.state.label)
                            Text("· \(session.terminal.displayName)").foregroundStyle(.secondary)
                            if !activity.isEmpty { Text(activity).foregroundStyle(.secondary) }
                            if session.hidden { Text("· hidden").foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(session.displayName), \(session.state.label), \(session.terminal.displayName)\(activity)"
                                + (model.usageText(session.id, spoken: true).map { ", \($0)" } ?? ""))
            .accessibilityHint("Opens this buddy's bubble")
            Menu {
                Button("Jump to session") { model.jump(session.id) }
                if session.hidden {
                    Button("Show this buddy") { model.setHidden(session.id, false) }
                } else {
                    Button("Hide this buddy") { model.setHidden(session.id, true) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 24, minHeight: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(session.displayName)")
        }
    }

    /// "· 2 agents · 1 shell" for running ones; empty when none run.
    private var activity: String {
        let a = session.activeSubagents, sh = session.runningShells
        return (a > 0 ? " · \(a) agent\(a == 1 ? "" : "s")" : "") + (sh > 0 ? " · \(sh) shell\(sh == 1 ? "" : "s")" : "")
    }

    @ViewBuilder private var thumbnail: some View {
        if let sheet = model.sheet, let look = model.look(for: session), let img = MascotImages.thumbnail(sheet, look: look) {
            Image(nsImage: img).interpolation(.none).frame(width: 16, height: 16).accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

extension SessionState {
    /// Dot color in the buddies list; the text label carries the meaning too.
    var color: Color {
        switch self {
        case .working: .blue
        case .needsPermission: .orange
        case .asking: .purple
        case .done: .green
        case .error: .red
        case .idle, .starting, .ended: .gray
        }
    }
}

/// Status rows with Request buttons. Used by Settings and onboarding.
struct PermissionRows: View {
    let permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Notifications (optional)", "Alerts when a session needs you. If no prompt appears, open System Settings → Notifications → Buddy and turn on Allow notifications. If Buddy is not in that list, sign the app first (docs/INSTALL.md → Local signing certificate).", permissions.notifications) {
                Task { await permissions.requestNotifications() }
            } extra: {
                if let err = permissions.notificationError {
                    Text(err).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Notification Settings") { permissions.openNotificationSettings() }
                    .accessibilityLabel("Open Notification Settings")
            }
            row("Accessibility", "Jump raises the editor window that has the project open.", permissions.accessibility) {
                permissions.requestAccessibility()
            }
            row("Automation", "Jump picks the right iTerm2 or Terminal tab. macOS asks once per app.", permissions.automation) {
                Task { await permissions.requestAutomation() }
            }
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private func row<Extra: View>(_ name: String, _ why: String, _ state: PermissionState, request: @escaping () -> Void,
                                  @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).accessibilityAddTraits(.isHeader)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state != .granted { extra() }
            }
            Spacer()
            if state == .granted {
                Label { Text("Granted") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                Text(state.rawValue).font(.caption).foregroundStyle(.secondary)
                Button("Request", action: request).accessibilityLabel("Request \(name) permission")
            }
        }
    }
}

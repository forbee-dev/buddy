import AppKit
import Security
import SwiftUI
import BuddyCore

/// Settings → Diagnostics: status rows with a fix each, the last hook events, and a plain-text report.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()
    static let managedSettings = "/Library/Application Support/ClaudeCode/managed-settings.json"
    /// Rows that read files; built again on Refresh and when the tab appears.
    var fileRows: [DiagRow] = []
    var copied = false

    func refresh(_ model: AppModel) {
        fileRows = Self.hookRows(model)
        copied = false
        Task { await Permissions.shared.refresh() }
    }

    func rows(_ model: AppModel) -> [DiagRow] {
        [Self.appRow] + fileRows + Self.liveRows(model)
    }

    func report(_ model: AppModel) -> String {
        DiagnosticsReport.format(rows: rows(model), events: model.events.items, generated: Date(), home: NSHomeDirectory())
    }

    private static func hookRows(_ model: AppModel) -> [DiagRow] {
        let read = { (path: String) in try? Data(contentsOf: URL(fileURLWithPath: path).resolvingSymlinksInPath()) }
        let home = NSHomeDirectory()
        let settings = read(model.settingsURL.path)
        let install = "Settings → Hooks & Extension → Install hooks. Then start a new Claude session."
        var rows: [DiagRow] = []
        if !model.canInstallHooks {
            rows.append(DiagRow(.bad, "Hooks", "buddy-hook is missing from this app", fix: "Run Buddy from Buddy.app."))
        } else if HookInstaller.status(settings: settings, hookPath: model.hookPath) == .invalid {
            rows.append(DiagRow(.bad, "Hooks", "~/.claude/settings.json is not valid JSON or has an unexpected shape",
                                fix: "Fix the file. Buddy does not change it. Then install hooks."))
        } else {
            let missing = HookInstaller.missingEvents(settings: settings, hookPath: model.hookPath)
            let all = HookInstaller.eventCount
            rows.append(missing.isEmpty ? DiagRow(.ok, "Hooks", "Installed for all \(all) events")
                : missing.count == all ? DiagRow(.bad, "Hooks", "Not installed for this app", fix: install)
                : DiagRow(.warn, "Hooks", "Missing events: \(missing.joined(separator: ", "))", fix: install))
        }
        // Never the percentages: the report is meant for a public issue.
        let bridge = HookInstaller.statusLineStatus(settings: settings, previousSaved: FileManager.default.fileExists(atPath: model.previousStatusLineURL.path))
        let got = model.planUsage.map { "a value arrived at \($0.updatedAt.formatted(date: .omitted, time: .standard))" } ?? "no value yet"
        rows.append(!model.showPlanUsage ? DiagRow(.ok, "Plan usage bridge", "off")
            : bridge == .installed ? DiagRow(.ok, "Plan usage bridge", "installed, \(got)")
            : DiagRow(.warn, "Plan usage bridge", bridge.label, fix: "Turn Show plan usage off and on in Settings → General."))
        let check = HookBlockers.check([
            .init(name: "~/.claude/settings.json", data: settings, managed: false),
            .init(name: "~/.claude/settings.local.json", data: read(home + "/.claude/settings.local.json"), managed: false),
            .init(name: managedSettings, data: read(managedSettings), managed: true),
        ])
        if !check.blockers.isEmpty {
            rows.append(DiagRow(.bad, "Hooks disabled", check.blockers.joined(separator: "; "),
                                fix: "Remove the key or set it to false. Your administrator owns managed settings."))
        } else if !check.unreadable.isEmpty {
            rows.append(DiagRow(.warn, "Hooks disabled", "Not valid JSON: \(check.unreadable.joined(separator: ", "))",
                                fix: "Fix the JSON. Claude Code may ignore that file."))
        } else {
            rows.append(DiagRow(.ok, "Hooks disabled", "No disableAllHooks or allowManagedHooksOnly"))
        }
        return rows
    }

    private static func liveRows(_ model: AppModel) -> [DiagRow] {
        var rows: [DiagRow] = []
        rows.append(model.socketListening ? DiagRow(.ok, "Socket", "Listening on \(model.displaySocket)")
            : DiagRow(.bad, "Socket", "Not listening", fix: "Quit every Buddy copy, then open Buddy again."))
        rows += sshRows(model)
        let clients = model.extClients
        let names = ["vscode": "VS Code", "cursor": "Cursor"]
        let groups = Dictionary(grouping: clients) { "\(names[$0.editor] ?? Activity.clip($0.editor, 32)) \($0.version)" }
            .sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value.count) window\($0.value.count == 1 ? "" : "s"))" }
        let bundled = AppServices.shared.bundledExtensionVersion
        let old = bundled.map { b in clients.contains { $0.version.compare(b, options: .numeric) == .orderedAscending } } ?? false
        rows.append(clients.isEmpty
            ? DiagRow(.warn, "Extension", "No editor connected",
                      fix: "Settings → Hooks & Extension → Install in VS Code or Cursor. Then reload the editor window.")
            : DiagRow(old ? .warn : .ok, "Extension", groups.joined(separator: ", "),
                      fix: "Install the extension again (\(bundled ?? "")) and reload the editor window."))
        let p = Permissions.shared
        let perms: [(String, PermissionState, String)] = [
            ("Notifications", p.notifications, "Settings → Permissions → Request, or System Settings → Notifications → Buddy."),
            ("Accessibility", p.accessibility, "Settings → Permissions → Request. Jump needs it to raise editor windows."),
            ("Automation", p.automation, "Settings → Permissions → Request. Jump needs it for iTerm2 and Terminal tabs."),
        ]
        for (name, state, fix) in perms {
            rows.append(DiagRow(state == .granted ? .ok : .warn, name, state.rawValue, fix: fix))
        }
        let versions = model.claudeVersions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        let seen = versions + (model.claudeVersionUnknown ? ["unknown"] : [])
        rows.append(DiagRow(versions.isEmpty ? .warn : .ok, "Claude Code", seen.isEmpty ? "unknown (no session seen yet)" : seen.joined(separator: ", "),
                            fix: "Buddy reads the version from the claude binary path. Native installs show it; npm installs show unknown."))
        return rows
    }

    /// Never shows the token, only whether one is loaded.
    private static func sshRows(_ model: AppModel) -> [DiagRow] {
        guard model.sshEnabled else { return [DiagRow(.ok, "SSH sessions", "off")] }
        let time = { (d: Date) in d.formatted(date: .omitted, time: .standard) }
        var rows = [DiagRow(.ok, "SSH sessions", "on")]
        rows.append(model.remoteListening ? DiagRow(.ok, "Remote socket", "Listening on \(model.displayRemoteSocket)")
            : DiagRow(.bad, "Remote socket", "Not listening", fix: "Turn SSH sessions off and on in Settings → SSH, or quit and open Buddy."))
        if let r = model.lastRemoteRejection, r.time > model.lastRemoteEvent ?? .distantPast {
            let fix = r.reason.contains("token") ? "Settings → SSH → Copy remote install command, and run it again for that host."
                : r.reason.contains("ssh client") ? "Add your ssh binary in Settings → SSH → Allowed ssh clients."
                : "See docs/SSH.md → Troubleshooting."
            rows.append(DiagRow(.warn, "Last remote event", "\(r.reason) at \(time(r.time))", fix: fix))
        } else {
            rows.append(DiagRow(model.lastRemoteEvent == nil ? .warn : .ok, "Last remote event", model.lastRemoteEvent.map { "accepted at \(time($0))" } ?? "none yet",
                                fix: "Connect with the RemoteForward line from Settings → SSH, then start claude on the host. See docs/SSH.md."))
        }
        rows.append(model.remoteTokenPresent ? DiagRow(.ok, "Remote token", "present in the Keychain")
            : DiagRow(.bad, "Remote token", "missing", fix: "Settings → SSH → Rotate token, then run the install command again on each host."))
        return rows
    }

    /// App version and the kind of the app's own code signature.
    static let appRow: DiagRow = {
        let version = AppServices.version
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return DiagRow(.bad, "App", "\(version), unsigned", fix: "Build with ./scripts/build-app.sh.")
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        guard let leaf, flags & SecCodeSignatureFlags.adhoc.rawValue == 0 else {
            return DiagRow(.warn, "App", "\(version), ad-hoc signature",
                           fix: "macOS resets Accessibility on every build. See docs/INSTALL.md → Local signing certificate.")
        }
        return DiagRow(.ok, "App", "\(version), signed: \(leaf.hasPrefix("Developer ID Application") ? "Developer ID (\(leaf))" : leaf)")
    }()
}

struct DiagnosticsTab: View {
    let model: AppModel
    let diag = Diagnostics.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Copy diagnostics report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diag.report(model), forType: .string)
                        diag.copied = true
                        Announcer.say("Diagnostics report copied")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Plain text: app version and signature, hook, socket, extension, permission, Claude Code and SSH status, and the last 50 events (time, session id cut to 8 characters, project alias, event, tool, result). Projects become project-1, hosts ssh-1, home paths ~. No prompts, commands, or tokens.")
                    Button("Refresh") { diag.refresh(model) }
                    if diag.copied { Text("Copied. No prompts, commands, or tokens are in it.").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(Array(diag.rows(model).enumerated()), id: \.offset) { _, r in row(r) }
                Divider()
                Text("Last events").font(.headline).accessibilityAddTraits(.isHeader)
                events
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { diag.refresh(model) }
    }

    private func row(_ r: DiagRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: r.level.symbol).foregroundStyle(r.level.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                (Text(r.title).fontWeight(.semibold) + Text(" · \(r.level.word)") + Text("  ") + Text(r.detail).foregroundStyle(.secondary))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let fix = r.fix, r.level != .ok {
                    Text("Fix: \(fix)").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.title), \(r.level.word): \(r.detail)\(r.fix.map { r.level == .ok ? "" : ". Fix: \($0)" } ?? "")")
    }

    @ViewBuilder private var events: some View {
        let items = model.events.items.reversed()
        if items.isEmpty {
            Text("No hook events yet. Start a Claude session.").font(.callout).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Time", "Project", "Event", "Tool", "Result"], id: \.self) { Text($0).fontWeight(.semibold) }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                    let project = e.host.map { "\($0):\(e.project)" } ?? e.project
                    GridRow {
                        Text(e.time, format: .dateTime.hour().minute().second()).monospacedDigit()
                        Text(project).lineLimit(1)
                        Text(e.event).lineLimit(1)
                        Text(e.tool ?? "–").lineLimit(1)
                        Text(e.result).lineLimit(1)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Time \(e.time.formatted(date: .omitted, time: .standard)), project \(project), event \(e.event), "
                                        + "tool \(e.tool ?? "none"), result \(e.result)")
                }
            }
            .textSelection(.enabled)
        }
    }
}

extension DiagRow.Level {
    var color: Color { switch self { case .ok: .green; case .warn: .orange; case .bad: .red } }
    var word: String { switch self { case .ok: "OK"; case .warn: "warning"; case .bad: "problem" } }
    var symbol: String {
        switch self { case .ok: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .bad: "xmark.octagon.fill" }
    }
}

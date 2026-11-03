import AppKit
import ServiceManagement
import SwiftUI
import BuddyCore

/// Runs the uninstall steps one by one and keeps each result for the sheet.
@MainActor
@Observable
final class UninstallRun {
    let steps = UninstallPlan.steps(editors: AppServices.shared.editorCLIs.map { (name: $0.0, cli: $0.1) },
                                    home: NSHomeDirectory(), appPath: Bundle.main.bundlePath)
    var results: [Int: (ok: Bool, text: String)] = [:]
    var running = false
    var finished = false
    var deleteToken = true
    /// Index of the folder step while Buddy asks whether to remove the folder after a failed hook removal.
    var asking: Int?

    private var hooksFailed: Bool { steps.firstIndex(of: .removeHooks).flatMap { results[$0] }?.ok == false }

    /// From `first` on. With hooks still installed, it stops before the folder step and asks (`asking`).
    /// When the folder is gone, Buddy shows the app in Finder and quits.
    func run(model: AppModel, from first: Int = 0, removeFolder: Bool = true) async {
        running = true
        asking = nil
        for (i, step) in steps.enumerated() where i >= first {
            switch step {
            case .quitAndReveal:
                continue
            case .removeSupportFolder where i > first && hooksFailed:
                asking = i
                running = false
                Announcer.say("Buddy could not remove its hooks. Remove the data folder anyway?")
                return
            case .removeSupportFolder where !removeFolder:
                results[i] = (true, "Kept, as you chose.")
            default:
                results[i] = await perform(step, model: model)
            }
            Announcer.say("\(step.title): \(results[i]?.text ?? "")")
        }
        running = false
        finished = true
        let folderGone = steps.indices.contains { i in
            if case .removeSupportFolder = steps[i] { return removeFolder && results[i]?.ok == true }
            return false
        }
        if folderGone {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            NSApp.terminate(nil)
        }
    }

    private func perform(_ step: UninstallStep, model: AppModel) async -> (ok: Bool, text: String) {
        switch step {
        case .removeHooks:
            defer { model.refreshHookStatus() }
            do {
                switch try HookInstaller.apply(install: false, settingsURL: model.settingsURL, hookPath: model.hookPath) {
                case .unchanged: return (true, "No Buddy hooks were installed.")
                case .written(let backup): return (true, "Removed." + (backup.map { " Backup: \(($0 as NSString).lastPathComponent)" } ?? ""))
                }
            } catch {
                return (false, "\(error)")
            }
        case .uninstallExtension(let editor, let cli):
            guard let cli else { return (true, "Skipped: no code or cursor command found.") }
            let list = await AppServices.run(cli, ["--list-extensions"])
            guard list.0 == 0 else { return (false, "Could not list the \(editor) extensions: \(AppServices.lastLine(list.1))") }
            guard UninstallPlan.listsExtension(list.1) else { return (true, "Not installed in \(editor).") }
            let r = await AppServices.run(cli, ["--uninstall-extension", UninstallPlan.extensionId])
            return r.0 == 0 ? (true, "Removed from \(editor). Reload its windows.") : (false, "\(editor): \(AppServices.lastLine(r.1))")
        case .unregisterLoginItem:
            guard SMAppService.mainApp.status != .notRegistered else { return (true, "It was already off.") }
            do {
                try await SMAppService.mainApp.unregister()
                AppServices.shared.launchAtLogin = false
                return (true, "Turned off.")
            } catch {
                return (false, error.localizedDescription)
            }
        case .removeRemoteToken:
            guard deleteToken else { return (true, "Kept, as you chose.") }
            return RemoteKeychain.delete() ? (true, "Deleted.")
                : (false, "The Keychain did not delete it. Delete \"Buddy SSH token\" in Keychain Access.")
        case .removeSupportFolder(let path):
            guard FileManager.default.fileExists(atPath: path) else { return (true, "It was already gone.") }
            do { try FileManager.default.removeItem(atPath: path); return (true, "Removed.") } catch { return (false, error.localizedDescription) }
        case .quitAndReveal:
            return (true, "")
        }
    }
}

struct UninstallView: View {
    let model: AppModel
    @Bindable var run: UninstallRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall Buddy?").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(run.finished ? "Done. Each step shows its result." : "Buddy does these steps in order and shows the result of each.")
                .foregroundStyle(.secondary)
            ForEach(Array(run.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(i)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).fixedSize(horizontal: false, vertical: true)
                        if let r = run.results[i] {
                            Text(r.text).font(.caption).foregroundStyle(r.ok ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Toggle("Also delete the SSH token from the Keychain", isOn: $run.deleteToken)
                .disabled(run.running || run.finished || !run.results.isEmpty)
            if let i = run.asking {
                WarningText(text: "Buddy could not remove its hooks, so Claude Code still calls buddy-hook. Remove them from ~/.claude/settings.json by hand. Remove the data folder anyway?")
                HStack {
                    Button("Keep the folder") { Task { await run.run(model: model, from: i, removeFolder: false) } }
                    Button("Remove the folder", role: .destructive) { Task { await run.run(model: model, from: i) } }
                }
            }
            Text("Buddy never deletes the app itself. When the data folder is gone, Buddy shows Buddy.app in Finder and quits. Then drag it to the Trash.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            if Demo.on { WarningText(text: "Demo mode: Uninstall is turned off.") }
            #endif
            HStack {
                Spacer()
                if run.finished {
                    Button("Close", action: close)
                    Button("Quit and Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(run.running)
                    Button("Uninstall", role: .destructive) { Task { await run.run(model: model) } }
                        .disabled(run.running || demo || !run.results.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var demo: Bool {
        #if DEBUG
        Demo.on
        #else
        false
        #endif
    }

    @ViewBuilder private func mark(_ i: Int) -> some View {
        if let r = run.results[i] {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.ok ? .green : .red)
                .accessibilityLabel(r.ok ? "Done" : "Failed")
        } else {
            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
        }
    }
}

@MainActor
enum UninstallWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        let run = UninstallRun()
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: UninstallView(model: model, run: run) { window?.close() })
        w.title = "Uninstall Buddy"
        w.isReleasedWhenClosed = false
        if window == nil { w.center() }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

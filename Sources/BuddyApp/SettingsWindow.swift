import SwiftUI
import BuddyCore

enum SettingsTab: String { case general, size, notifications, hooks, permissions, about }

/// Selected tab, outside the view so a launch argument or a menu item can pick it.
@MainActor
@Observable
final class SettingsNav {
    static let shared = SettingsNav()
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var nav = SettingsNav.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            SizeTab(model: model).tabItem { Label("Size", systemImage: "arrow.up.left.and.arrow.down.right") }.tag(SettingsTab.size)
            NotificationsTab(model: model).tabItem { Label("Notifications", systemImage: "bell") }.tag(SettingsTab.notifications)
            HooksTab(model: model).tabItem { Label("Hooks & Extension", systemImage: "link") }.tag(SettingsTab.hooks)
            PermissionRows().padding(20).tabItem { Label("Permissions", systemImage: "lock") }.tag(SettingsTab.permissions)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralTab: View {
    @Bindable var model: AppModel
    let services = AppServices.shared

    var body: some View {
        Form {
            Picker("Mascots", selection: $model.mode) {
                ForEach(MascotMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Walk around when idle", isOn: $model.walking)
            if model.reduceMotion { Text("Reduce Motion is on: buddies stand still.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Sleeping buddy when no sessions", isOn: $model.sleepMascot)
            Toggle("Start Buddy at login", isOn: Binding(get: { services.launchAtLogin }, set: { services.setLaunchAtLogin($0) }))
            Picker("Open newest card", selection: $model.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            .help("Global shortcut that opens the newest permission or question card")
            if let m = services.message { Text(m).font(.caption) }
        }
        .formStyle(.grouped)
    }
}

private struct SizeTab: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Buddy size", selection: $model.size) {
                ForEach(BuddySize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Preview").font(.headline).accessibilityAddTraits(.isHeader)
            preview
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            Text("Small 1.5× stays pixel-sharp on Retina screens; on other screens it shows as 2×.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder private var preview: some View {
        if let sheet = model.sheet, let look = previewLook(sheet), let (img, r) = MascotImages.cgImage(sheet, look: look) {
            let side = CGFloat(r.width) * model.pointScale
            VStack(spacing: 4) {
                Image(decorative: img, scale: 1).resizable().interpolation(.none).frame(width: side, height: side)
                Text("my-project").font(.system(size: CGFloat(model.size.tagFontSize), weight: .semibold))
                    .padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 6).fill(.background))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of a buddy at \(model.size.label)")
        } else {
            Text("No sprites loaded.").foregroundStyle(.secondary)
        }
    }

    private func previewLook(_ sheet: SpriteSheet) -> Look? {
        if let s = model.menuSessions.first, let look = model.look(for: s) { return look }
        guard let base = sheet.baseNames.first, let palette = sheet.paletteNames.first else { return nil }
        return Look(base: base, palette: palette, outfit: nil)
    }
}

private struct NotificationsTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Text("Notify me when").font(.headline)
            Toggle("Claude needs permission", isOn: $model.notifyPermission)
            Toggle("Claude asks a question", isOn: $model.notifyQuestion)
            Toggle("Claude finishes", isOn: $model.notifyDone)
        }
        .formStyle(.grouped)
    }
}

/// Hooks install/uninstall plus the companion extension; shared with onboarding.
struct HooksSection: View {
    let model: AppModel
    let services = AppServices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !services.isInApplications {
                WarningText(text: "Buddy runs from outside Applications. Hooks point at the app's path, so move it first.")
                Button("Move to Applications") { services.moveToApplications() }
            }
            Text("Claude Code hooks: \(model.hooksInstalled ? "installed" : "not installed")").font(.headline)
            HStack {
                Button("Install hooks") { model.installHooks(true) }.disabled(model.hooksInstalled)
                Button("Uninstall hooks") { model.installHooks(false) }
            }
            if let m = model.installMessage { Text(m).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("VS Code / Cursor extension").font(.headline)
            Text("Lets Buddy type your next prompt into the right editor terminal.").font(.callout).foregroundStyle(.secondary)
            if services.bundledExtension == nil {
                Text("This build has no bundled extension.").font(.caption).foregroundStyle(.secondary)
            } else if services.editorCLIs.isEmpty {
                Text("No `code` or `cursor` command found.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(services.editorCLIs, id: \.1) { name, cli in
                        Button("Install in \(name)") { Task { await services.installExtension(editor: name, cli: cli) } }
                            .disabled(services.busy)
                    }
                }
            }
            if let m = services.message { Text(m).font(.caption).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { model.refreshHookStatus() }
    }
}

private struct HooksTab: View {
    let model: AppModel
    var body: some View { ScrollView { HooksSection(model: model).padding(20).frame(maxWidth: .infinity, alignment: .leading) } }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Buddy").font(.title.bold())
            Text("Version \(AppServices.version)").textSelection(.enabled)
            Text("One mascot per Claude Code session.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A standard window: an accessory (LSUIElement) app must activate itself to bring it forward.
@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?

    static func show(model: AppModel, tab: SettingsTab? = nil) {
        if let tab { SettingsNav.shared.tab = tab }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Buddy Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

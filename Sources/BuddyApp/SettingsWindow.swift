import SwiftUI
import BuddyCore

enum SettingsTab: String { case general, size, notifications, sounds, hooks, ssh, permissions, skins, diagnostics, about }

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
            SoundsTab(model: model).tabItem { Label("Sounds", systemImage: "speaker.wave.2") }.tag(SettingsTab.sounds)
            HooksTab(model: model).tabItem { Label("Hooks & Extension", systemImage: "link") }.tag(SettingsTab.hooks)
            SSHTab(model: model).tabItem { Label("SSH", systemImage: "network") }.tag(SettingsTab.ssh)
            PermissionRows().padding(20).tabItem { Label("Permissions", systemImage: "lock") }.tag(SettingsTab.permissions)
            SkinsTab(model: model).tabItem { Label("Skins", systemImage: "paintpalette") }.tag(SettingsTab.skins)
            DiagnosticsTab(model: model).tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SettingsTab.diagnostics)
            AboutTab(model: model).tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 760, height: 440)
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
            Picker("Arrangement", selection: $model.arrangement) {
                ForEach(Arrangement.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.mode == .single)
            Text(model.mode == .single ? "Single buddy mode has one buddy, so there is nothing to arrange." : model.arrangement.hint)
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Walk around when idle", isOn: $model.walking)
            if model.reduceMotion { Text("Reduce Motion is on: buddies stand still.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Sleeping buddy when no sessions", isOn: $model.sleepMascot)
            Toggle("Keep the Mac awake while a session works", isOn: $model.keepAwake)
                .help("Stops idle sleep while a visible local session starts or works. The display can still sleep.")
            Toggle("Show subagents as minis", isOn: $model.showMinis)
            Toggle("Show background shells", isOn: $model.showShells)
            Picker("Character", selection: Binding(get: { model.character == AppModel.mix ? AppModel.mix : model.characters.first ?? "clawd" },
                                                   set: { model.character = $0 })) {
                ForEach(model.sheet?.baseNames ?? ["clawd"], id: \.self) { Text(model.characterLabel($0)).tag($0) }
                Text("Mix").tag(AppModel.mix)
            }
            .help("The buddy character. Mix gives each session one of all enabled characters. Turn on skins in Settings → Skins.")
            Picker("Get impatient after", selection: $model.escalateMinutes) {
                ForEach(AppModel.escalateChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
            }
            .help("A buddy that waits on you longer hops and shows a timer. At twice the time it grows and sends one reminder.")
            Picker("While you were away", selection: $model.awayMinutes) {
                ForEach(AppModel.awayChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
            }
            .help("After this much time away, one buddy tells you what happened.")
            Toggle("Fun extras", isOn: $model.funExtras)
            Text("High-fives, a party when all sessions finish, and rare tips. Reduce Motion turns off the moving ones.")
                .font(.caption).foregroundStyle(.secondary)
            if model.beeUnlocked {
                Toggle("ForgeBee subagents fly as bees", isOn: $model.forgeBeeMinis)
                    .help("Subagents whose type starts with forgebee: show as small bees next to any buddy.")
            }
            Toggle("Show tokens and cost", isOn: $model.showUsage)
            Toggle("Show cost on the buddy's name tag", isOn: $model.costOnTag)
                .disabled(!model.showUsage)
                .help("The tag reads \"project · $0.31\", or \"42k\" tokens when a model has no price.")
            HStack {
                Text(model.pricesError ?? "Prices come from prices.json. Placeholders: check them for your plan.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Edit prices…") { NSWorkspace.shared.open(URL(fileURLWithPath: model.pricesPath)) }
                    .help("Opens prices.json. Buddy reads it at start.")
            }
            Toggle("Start Buddy at login", isOn: Binding(get: { services.launchAtLogin }, set: { services.setLaunchAtLogin($0) }))
            Picker("Open newest card", selection: $model.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            .help("Global shortcut that opens the newest permission or question card")
            Picker("Open command palette", selection: $model.paletteHotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            .help("Global shortcut for the session list.")
            Text("Picking the other shortcut's key swaps the two.").font(.caption).foregroundStyle(.secondary)
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
            Text("Notify me when").font(.headline).accessibilityAddTraits(.isHeader)
            Toggle("Claude needs permission", isOn: $model.notifyPermission)
            Toggle("Claude asks a question", isOn: $model.notifyQuestion)
            Toggle("Claude finishes", isOn: $model.notifyDone)
            Toggle("Allow answering from notifications", isOn: $model.notifyActions)
            Text("Adds Deny and Review… to permission alerts, Answer… to questions, and Reply… to finished sessions. Allow is only on the card, where you see the whole request: Review… opens it. Deny and Reply… need an unlocked Mac. Alerts show the tool and the project, never the command.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}

private struct SoundsTab: View {
    let model: AppModel
    @Bindable var sounds = Sounds.shared

    var body: some View {
        Form {
            Toggle("Play sounds", isOn: $sounds.on)
            Group {
                Picker("Sound set", selection: $sounds.set) {
                    ForEach(SoundSet.allCases) { Text($0.label).tag($0) }
                }
                .help("Buddy chiptune: short 8-bit sounds made for Buddy. macOS sounds: pick one per event.")
                Section("Play a sound when") {
                    // The Bee row stays hidden until the Bee is found.
                    ForEach(SoundEvent.allCases.filter { $0 != .bee || model.beeUnlocked }) { row($0) }
                }
                Slider(value: $sounds.volume, in: 0...1) { Text("Volume") }
                    .accessibilityValue("\(Int((sounds.volume * 100).rounded())) percent")
                Toggle("Only when the session's app is not in front", isOn: $sounds.onlyWhenNotFront)
                    .help("No sound when the session's terminal, editor, or Claude Desktop is the front app: you already see it.")
                Toggle("Also when notifications are off", isOn: $sounds.alsoWhenNotificationsOff)
                    .help("Permission, question, and done sounds play even when their notification is off in Settings → Notifications.")
            }
            .disabled(!sounds.on)
            // Stays on with "Play sounds" off: it is the notification's own sound.
            Toggle("Notification banner sound", isOn: $sounds.bannerSound)
            Text("The macOS alert sound on notifications, only for events Buddy plays no sound for. So you hear one sound, never two.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Sounds add to the buddy, the card, and VoiceOver. They never replace them. At most one sound plays every 1.5 s; the most important one wins.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private func row(_ e: SoundEvent) -> some View {
        HStack {
            Toggle(e.label, isOn: Binding(get: { sounds.isOn(e) }, set: { sounds.setOn(e, $0) }))
            if sounds.set == .system {
                Picker("\(e.label) sound", selection: Binding(get: { sounds.systemName(e) }, set: { sounds.setSystemName(e, $0) })) {
                    ForEach(SoundSet.systemNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            Button { sounds.preview(e) } label: { Image(systemName: "play.fill").frame(minWidth: 24, minHeight: 24) }
                .buttonStyle(.borderless)
                .disabled(sounds.set == .none)
                .accessibilityLabel("Play the \(e.label) sound")
                .help("Play")
        }
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
                .accessibilityAddTraits(.isHeader)
            if model.hooksOutdated { WarningText(text: "New hook events available: click Install hooks.") }
            if model.hooksInvalid {
                WarningText(text: "~/.claude/settings.json is not valid JSON or has an unexpected shape. Buddy does not change it: fix the file first.")
            }
            HStack {
                Button("Install hooks") { model.installHooks(true) }.disabled(model.hooksInstalled || !services.isInApplications)
                Button("Uninstall hooks") { model.installHooks(false) }
            }
            if let m = model.installMessage { Text(m).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("VS Code / Cursor extension").font(.headline).accessibilityAddTraits(.isHeader)
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

private struct SkinsTab: View {
    let model: AppModel
    let skins = SkinStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skins add palettes, outfits, and characters. Built-in looks never change. See docs/SKINS.md for the format.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(skins.entries) { e in row(e) }
                .frame(minHeight: 200)
                .accessibilityLabel("Skins")
            HStack {
                Button("Open skins folder") { skins.openFolder() }
                Button("Reload") { skins.reload() }
                Spacer()
                Text("\(skins.enabled.count) on").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder private func row(_ e: SkinStore.Entry) -> some View {
        if let skin = e.skin {
            Toggle(isOn: Binding(get: { skins.isOn(e) }, set: { skins.setOn(e, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skin.name + (e.bundled ? " (example)" : "")).fontWeight(.medium)
                    Text(summary(skin)).font(.caption).foregroundStyle(.secondary)
                    if let why = skins.conflicts[e.id] { WarningText(text: "Not applied: \(why)") }
                }
            }
            .accessibilityLabel("\(skin.name), \(summary(skin))" + (skins.conflicts[e.id].map { ", not applied: \($0)" } ?? ""))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.file).fontWeight(.medium)
                WarningText(text: "Not loaded: \(e.error ?? "unknown error")")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func summary(_ s: Skin) -> String {
        let parts = [(s.bases.count, "character"), (s.outfits.count, "outfit"), (s.palettes.count, "palette")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return ([s.author.map { "by \($0)" }].compactMap { $0 } + parts).joined(separator: " · ")
    }
}

private struct AboutTab: View {
    let model: AppModel
    static let repo = URL(string: "https://github.com/forbee-dev/buddy")!

    var body: some View {
        VStack(spacing: 8) {
            Text("Buddy").font(.title.bold())
            Text("Version \(AppServices.version)").textSelection(.enabled)
            Text("One mascot per Claude Code session.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(["Releases", "Issues", "Discussions"], id: \.self) { page in
                    Link(page, destination: Self.repo.appendingPathComponent(page.lowercased()))
                }
            }
            .font(.callout)
            // No network calls from the app: the browser shows what is new.
            Button("Check for updates…") { NSWorkspace.shared.open(Self.repo.appendingPathComponent("releases")) }
                .controlSize(.small)
            // The row stays after "Hide Bee again", so the button keeps keyboard focus.
            if model.beeUnlocked || model.beeHidden {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.beeUnlocked ? "Bee unlocked. Pick it in Settings → General → Character." : "Bee hidden.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(model.beeUnlocked ? "Bee unlocked. Pick it in Settings, General, Character." : "Bee hidden.")
                        Button("Hide Bee again") {
                            model.hideBee()
                            Announcer.say("Bee hidden.")
                        }
                        .controlSize(.small)
                    }
                    Text("Hides the Bee until you find it again. Buddies that wear it get another character.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
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

import SwiftUI
import AppKit

@main
struct BuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Mascot silhouette; filled with a dot and the count while a session needs you (also when buddies are hidden).
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let count = model.attentionCount
        HStack(spacing: 2) {
            Image(nsImage: MascotImages.menuIcon(model.sheet, filled: count > 0))
            if count > 0 { Text("\(count)") }
        }
        .accessibilityLabel(count > 0 ? "Buddy, \(count) waiting" : "Buddy")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        if Notifier.available { model.notifier = Notifier() }
        model.start()
        ReduceMotion.shared.start(model: model)
        // `--open-settings=<tab>` opens Settings at launch (support and screenshots).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings") }) {
            SettingsWindow.show(model: model, tab: SettingsTab(rawValue: String(arg.split(separator: "=").last ?? "")))
        } else if !model.onboarded {
            OnboardingWindow.show(model: model)
        }
    }
}

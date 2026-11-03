import SwiftUI
import AppKit

struct OnboardingView: View {
    let model: AppModel
    let services = AppServices.shared
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hi, I'm Buddy").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("One small mascot floats on your desktop for each Claude Code session. It tells you when Claude asks a question, needs permission, or is done, and you can answer right from the bubble.")
                    .fixedSize(horizontal: false, vertical: true)
                PermissionRows()
                Divider()
                Text("Buddy adds its entries to ~/.claude/settings.json. It backs up the file first and keeps all your other settings and hooks. If Buddy is not running, Claude works as normal.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HooksSection(model: model)
                Toggle("Start Buddy at login", isOn: Binding(get: { services.launchAtLogin }, set: { services.setLaunchAtLogin($0) }))
                HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
            }
            .padding(24)
        }
        .frame(width: 520, height: 600)
    }
}

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model) {
                model.onboarded = true
                window?.close()
            }))
            w.title = "Welcome to Buddy"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

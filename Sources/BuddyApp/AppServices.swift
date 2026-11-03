import AppKit
import ServiceManagement

/// Version, start at login, companion extension install, move to Applications.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var message: String? { didSet { if let message { Announcer.say(message) } } }
    var busy = false

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    // MARK: Start at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Start at login failed: \(error.localizedDescription)"
            log.error("SMAppService failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Applications folder

    /// Hooks point at the app's path, so it should live in an Applications folder first.
    var isInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    func moveToApplications() {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: "/Applications/Buddy.app")
        do {
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: target)
        } catch {
            message = "Could not copy Buddy to /Applications: \(error.localizedDescription)"
            return
        }
        // The single-instance lock is ours until we quit, so the copy starts a moment later.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", target.path]
        do { try relaunch.run() } catch { message = "Copied. Open /Applications/Buddy.app yourself."; return }
        NSApp.terminate(nil)
    }

    // MARK: Companion extension

    var bundledExtension: URL? {
        guard let dir = Bundle.main.resourceURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasPrefix("buddy-companion-") && $0.hasSuffix(".vsix") }.sorted().last
            .map { dir.appendingPathComponent($0) }
    }

    /// Editor CLIs found on this Mac: (display name, path).
    var editorCLIs: [(String, String)] {
        let candidates: [(String, [String])] = [
            ("VS Code", ["/usr/local/bin/code", "/opt/homebrew/bin/code",
                         "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]),
            ("Cursor", ["/usr/local/bin/cursor", "/opt/homebrew/bin/cursor",
                        "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"]),
        ]
        return candidates.compactMap { name, paths in
            paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { (name, $0) }
        }
    }

    /// Runs `<cli> --install-extension <vsix>` (args array, no shell). Only on a user click.
    func installExtension(editor: String, cli: String) async {
        guard let vsix = bundledExtension else { message = "No extension is bundled with this build."; return }
        busy = true
        defer { busy = false }
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["--install-extension", vsix.path, "--force"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        let tail = result.1.split(separator: "\n").last.map(String.init) ?? ""
        message = result.0 == 0 ? "Installed in \(editor). Reload the editor window." : "\(editor) install failed: \(tail)"
    }
}

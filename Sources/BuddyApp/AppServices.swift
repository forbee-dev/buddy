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
        let result = await Self.run(cli, ["--install-extension", vsix.path, "--force"])
        message = result.0 == 0 ? "Installed in \(editor). Reload the editor window." : "\(editor) install failed: \(Self.lastLine(result.1))"
    }

    /// Runs a tool with an args array (no shell). Returns the exit status and the combined output.
    /// After `timeout` the tool gets terminate(). The output is read as it comes, and only until the tool exits:
    /// a helper process that keeps the pipe open (editor CLIs start some) cannot hang Buddy.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) async -> (Int32, String) {
        await Task.detached { runBlocking(tool, args, timeout: timeout) }.value
    }

    /// Blocks its thread (semaphores), so it stays off the async executor.
    private nonisolated static func runBlocking(_ tool: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let collected = Collected()
        let reader = out.fileHandleForReading
        let eof = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        // The handler is the only reader. Empty data is EOF; the handler would be called again at once, forever.
        reader.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.signal() } else { collected.append(d) }
        }
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            reader.readabilityHandler = nil
            return (-1, error.localizedDescription)
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        // A child that outlives the process can hold the pipe open, so EOF gets a short limit.
        _ = eof.wait(timeout: .now() + 0.25)
        reader.readabilityHandler = nil
        try? reader.close()
        let text = String(decoding: collected.data, as: UTF8.self)
        if timedOut { return (-2, text + "\nStopped after \(Int(timeout)) s.") }
        return (p.terminationStatus, text)
    }

    /// Pipe output from the reader thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ d: Data) { lock.withLock { bytes.append(d) } }
        var data: Data { lock.withLock { bytes } }
    }

    /// A file or folder from the app bundle; debug builds also take `devPath` in the source checkout.
    static func bundledResource(_ name: String, ext: String? = nil, subdirectory: String? = nil, devPath: String) -> URL? {
        var candidates = [Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)]
        #if DEBUG
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + devPath))
        #endif
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func lastLine(_ s: String) -> String { s.split(separator: "\n").last.map(String.init) ?? "" }

    /// Version of the bundled .vsix, from its file name.
    var bundledExtensionVersion: String? {
        bundledExtension.map { $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "buddy-companion-", with: "") }
    }
}

import AppKit
import ApplicationServices
import BuddyCore

/// Brings the terminal of a session to the front.
@MainActor
enum Jumper {
    static let windowNote = "Jump could not find the window. Grant Accessibility for exact window focus."

    /// Returns a note for the bubble when the right window could not be raised. AppleScript and AX calls run off main.
    @discardableResult
    static func jump(to s: Session, ext: ExtensionHub, ticket: JumpTicket, current: @MainActor () -> Int) async -> String? {
        func fresh() -> Bool { ticket.isCurrent(jumpGenerationNow: current()) }
        let app = s.terminal == .claudeDesktop
            ? NSRunningApplication.runningApplications(withBundleIdentifier: TerminalApp.desktopBundleId).first
            : s.env.claudePid.flatMap(terminalApp(above:))
        if app == nil { log.info("Jump: no GUI app found above the claude process") }
        switch s.terminal {
        case .vscode, .cursor:
            let pick = ext.jumpTarget(shellPid: s.env.shellPid, cwd: s.cwd)
            let raised = await raiseEditorWindow(app: app, terminal: s.terminal, pick: pick, projectName: s.projectName, fresh: fresh)
            guard fresh() else { return nil }
            if let shell = s.env.shellPid, ext.hasTerminal(shellPid: shell) {
                log.info("Jump: route=extension-focus")
                ext.focus(shellPid: shell)
            }
            return raised ? nil : windowNote
        case .iterm:
            activate(app)
            if let tty = s.env.tty { await runScript(itermScript(tty: tty), fresh: fresh) }
        case .terminal:
            activate(app)
            if let tty = s.env.tty { await runScript(terminalScript(tty: tty), fresh: fresh) }
        case .other:
            activate(app)
            if let pid = app?.processIdentifier {
                let name = s.projectName
                guard fresh() else { return nil }
                _ = await Task.detached { raiseWindow(pid: pid, titleContains: name) }.value
            }
        case .claudeDesktop: activate(app)  // no per-session link: Desktop comes forward, the user picks the session
        }
        return nil
    }

    private static func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Raises the window of `pick.folder` without activating the app first: activation shows the wrong window.
    private static func raiseEditorWindow(app: NSRunningApplication?, terminal: TerminalApp, pick: JumpTarget.Pick, projectName: String, fresh: @MainActor () -> Bool) async -> Bool {
        let trusted = AXIsProcessTrusted()
        log.info("Jump: route=editor-window ax-trusted=\(trusted ? "yes" : "no", privacy: .public) folder-known=\(pick.isOpen ? "yes" : "no", privacy: .public)")
        if trusted, let app {
            let folderName = (pick.folder as NSString).lastPathComponent
            let names = [folderName, projectName].filter { !$0.isEmpty }
            let pid = app.processIdentifier
            guard fresh() else { return true }
            let matched = await Task.detached { names.contains { raiseWindow(pid: pid, titleContains: $0) } }.value
            log.info("Jump: title-matched=\(matched ? "yes" : "no", privacy: .public)")
            guard fresh() else { return true }
            if matched { activate(app); return true }
        }
        if pick.isOpen {
            let used = runEditorCLI(terminal: terminal, folder: pick.folder)
            log.info("Jump: cli-used=\(used ? "yes" : "no", privacy: .public)")
            if used { return true }
        } else {
            log.info("Jump: folder not open in any window; cli skipped")
        }
        activate(app)
        return false
    }

    /// Plain folder argument focuses the window that already has it open. `-r` would load it into the last active window.
    private static func runEditorCLI(terminal: TerminalApp, folder: String) -> Bool {
        guard let args = JumpTarget.cliArgs(folder: folder),
              let bin = JumpTarget.cliCandidates(for: terminal).first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch {
            log.error("Jump: editor CLI failed to start")
            return false
        }
    }

    /// Walks the parents of claude until a regular (Dock) app owns the process.
    static func terminalApp(above pid: Int32) -> NSRunningApplication? {
        for p in ProcInfo.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
        }
        return nil
    }

    /// Only [a-z0-9] reaches the script, so a tty name cannot inject AppleScript.
    static func safeTTY(_ tty: String) -> String { "/dev/" + tty.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    static func itermScript(tty: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(safeTTY(tty))" then
                  select w
                  select t
                  select s
                  activate
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(safeTTY(tty))" then
                set selected of t to true
                set index of w to 1
                activate
                return
              end if
            end repeat
          end repeat
        end tell
        """
    }

    /// The same script text through osascript, so a slow or hung terminal app never blocks the main thread.
    static func runScript(_ source: String, fresh: @MainActor () -> Bool) async {
        guard fresh() else { return }
        let (status, _) = await AppServices.run("/usr/bin/osascript", ["-e", source], timeout: 5)
        if status != 0 { log.error("Jump AppleScript failed: exit \(status)") }
    }

    /// Off main: an app that does not answer AX costs at most 1 s per call.
    @discardableResult
    nonisolated static func raiseWindow(pid: Int32, titleContains name: String) -> Bool {
        guard AXIsProcessTrusted() else { log.info("Jump: Accessibility not granted"); return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for w in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            guard let t = title as? String, t.localizedCaseInsensitiveContains(name) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            return true
        }
        return false
    }
}

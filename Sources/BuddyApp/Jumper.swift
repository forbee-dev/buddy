import AppKit
import ApplicationServices
import BuddyCore

/// Brings the terminal of a session to the front.
@MainActor
enum Jumper {
    static func jump(to s: Session, ext: ExtensionHub) {
        let app = s.terminal == .claudeDesktop
            ? NSRunningApplication.runningApplications(withBundleIdentifier: TerminalApp.desktopBundleId).first
            : s.env.claudePid.flatMap(terminalApp(above:))
        if let app {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            log.info("Jump: no GUI app found above the claude process")
        }
        switch s.terminal {
        case .vscode, .cursor:
            if let shell = s.env.shellPid, ext.hasTerminal(shellPid: shell) { ext.focus(shellPid: shell) }
            else if let app { raiseWindow(pid: app.processIdentifier, titleContains: s.projectName) }
        case .iterm: if let tty = s.env.tty { runScript(itermScript(tty: tty)) }
        case .terminal: if let tty = s.env.tty { runScript(terminalScript(tty: tty)) }
        case .other: if let app { raiseWindow(pid: app.processIdentifier, titleContains: s.projectName) }
        case .claudeDesktop: break  // no per-session link: Desktop comes forward, the user picks the session
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

    static func runScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("Jump AppleScript failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0)") }
    }

    static func raiseWindow(pid: Int32, titleContains name: String) {
        guard AXIsProcessTrusted() else { log.info("Jump: Accessibility not granted"); return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            guard let t = title as? String, t.localizedCaseInsensitiveContains(name) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }
}

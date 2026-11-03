import AppKit
import BuddyCore

extension AppModel {
    // MARK: Next prompt

    /// Claude Desktop sessions use the inbox only: never the editor route, never keystrokes.
    func route(for s: Session) -> PromptRoute {
        if s.terminal == .claudeDesktop { return s.env.messagingSocket != nil ? .inbox : .none }
        if let shell = s.env.shellPid, ext.hasTerminal(shellPid: shell) { return .editor(s.terminal.displayName) }
        if s.env.messagingSocket != nil { return .inbox }
        return .none
    }

    /// nil when a next prompt can go to this session now; else the reason to show (review H2).
    func promptRefusal(_ s: Session) -> String? {
        guard let pid = s.env.claudePid else { return "Buddy does not know the Claude process." }
        let desktop = s.terminal == .claudeDesktop
        return PromptGuard.refusal(state: s.state, status: ProcInfo.status(of: pid), desktop: desktop,
                                   underClaudeApp: desktop && Self.underClaudeApp(pid))
    }

    func sendPrompt(_ raw: String, to sid: String) async -> SendResult {
        let text = PromptGuard.sanitize(raw)
        guard let s = session(sid), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .failed }
        if let reason = promptRefusal(s) { return status(sid, "Not sent. \(reason) Use Jump.", .failed) }
        switch route(for: s) {
        case .editor:
            guard let shell = s.env.shellPid else { return .failed }
            let ack = await ext.send(shellPid: shell, text: text)
            return ack.ok ? status(sid, "Sent to the terminal.", .sent) : status(sid, "Not sent: \(ack.error ?? "error").", .failed)
        case .inbox:
            return await sendInbox(text, session: s)
        case .none:
            return status(sid, "No route to this session. Use Jump.", .failed)
        }
    }

    /// Shows and announces the result line.
    private func status(_ sid: String, _ text: String, _ result: SendResult) -> SendResult {
        sendStatus[sid] = text
        Announcer.say(text)
        return result
    }

    private func sendInbox(_ text: String, session s: Session) async -> SendResult {
        guard let path = s.env.messagingSocket else { return status(s.id, "No inbox socket.", .failed) }
        let token = s.env.messagingToken
        let result: Result<Void, Error> = await Task.detached {
            Result { try InboxClient.send(socketPath: path, token: token, text: text) }
        }.value
        switch result {
        case .success: return status(s.id, "Sent as a peer message.", .sent)
        case .failure(let e):
            log.error("Inbox send failed: \(String(describing: e), privacy: .public)")
            let place = s.terminal == .claudeDesktop ? " Answer in Claude Desktop." : ""
            return status(s.id, "Not sent: the session inbox did not accept it.\(place)", .failed)
        }
    }

    // MARK: Jump

    func jump(_ sid: String) {
        guard let s = session(sid) else { return }
        Jumper.jump(to: s, ext: ext)
    }

    // MARK: Looks

    func rerollLook(cwd: String) {
        guard let sheet else { return }
        let outfits = sheet.outfits(fitting: LookPicker.pick(cwd: cwd, sheet: sheet).base)
        setLook(cwd: cwd, palette: sheet.paletteNames.randomElement(), outfit: .some(outfits.randomElement()))
    }

    // MARK: Hooks

    var hookPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/buddy-hook").path }
    var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    var canInstallHooks: Bool { FileManager.default.isExecutableFile(atPath: hookPath) }

    func refreshHookStatus() {
        hooksInstalled = canInstallHooks && HookInstaller.isInstalled(settingsURL: settingsURL, hookPath: hookPath)
    }

    func installHooks(_ install: Bool) {
        guard canInstallHooks else { installMessage = "buddy-hook not found. Run Buddy from Buddy.app."; return }
        do {
            switch try HookInstaller.apply(install: install, settingsURL: settingsURL, hookPath: hookPath) {
            case .unchanged: installMessage = install ? "Hooks already installed." : "No Buddy hooks to remove."
            case .written(let backup):
                installMessage = (install ? "Hooks installed." : "Hooks removed.")
                    + (backup.map { " Backup: \(($0 as NSString).lastPathComponent)" } ?? "")
                    + " New Claude sessions use them."
            }
        } catch {
            installMessage = "\(error)"
            log.error("Hook install failed: \(String(describing: error), privacy: .public)")
        }
        refreshHookStatus()
    }
}

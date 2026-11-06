import AppKit
import BuddyCore

extension AppModel {
    // MARK: Next prompt

    /// Claude Desktop sessions use the inbox only: never the editor route, never keystrokes.
    func route(for s: Session) -> PromptRoute {
        if s.remote != nil || s.env.agent != nil { return .none }
        #if DEBUG
        if Demo.on { return s.terminal == .claudeDesktop ? .inbox : .editor(s.terminal.displayName) }
        #endif
        if s.terminal == .claudeDesktop { return s.env.messagingSocket != nil ? .inbox : .none }
        if let shell = s.env.shellPid, ext.hasTerminal(shellPid: shell) { return .editor(s.terminal.displayName) }
        if s.env.messagingSocket != nil { return .inbox }
        return .none
    }

    /// nil when a next prompt can go to this session now; else the reason to show.
    func promptRefusal(_ s: Session) -> String? {
        if s.remote != nil { return PromptGuard.refusal(state: s.state, status: nil, remote: true) }
        guard let pid = s.env.claudePid else { return "Buddy does not know the Claude process." }
        let desktop = s.terminal == .claudeDesktop
        return PromptGuard.refusal(state: s.state, status: ProcInfo.status(of: pid), desktop: desktop,
                                   underClaudeApp: desktop && Self.underClaudeApp(pid))
    }

    func sendPrompt(_ raw: String, to sid: String) async -> SendResult {
        let text = PromptGuard.sanitize(raw)
        guard let s = session(sid), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed }
        if let reason = promptRefusal(s) {
            record(sid, "NextPrompt", nil, "not sent: refused")
            return status(sid, "Not sent. \(reason) Use Jump.", .failed)
        }
        let result: SendResult
        switch route(for: s) {
        case .editor:
            guard let shell = s.env.shellPid else { return .failed }
            let ack = await ext.send(shellPid: shell, text: text)
            // The extension's error text is untrusted: revealed and clipped.
            let why = Activity.clip(ack.error ?? "error", 64)
            result = ack.ok ? status(sid, "Sent to the terminal.", .sent) : status(sid, "Not sent: \(why).", .failed)
            record(sid, "NextPrompt", nil, ack.ok ? "sent via editor" : "not sent: \(why)")
        case .inbox:
            result = await sendInbox(text, session: s)
            record(sid, "NextPrompt", nil, result == .sent ? "sent via inbox" : "not sent: inbox refused")
        case .none:
            result = status(sid, "No route to this session. Use Jump.", .failed)
            record(sid, "NextPrompt", nil, "not sent: no route")
        }
        return result
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

    // MARK: Context line

    /// What Claude said before `requestId`, read off the main thread from the validated transcript. nil on any failure.
    func context(for s: Session, requestId: String) async -> String? {
        if let hit = contextCache[requestId] { return hit.isEmpty ? nil : hit }
        guard let path = s.transcriptPath else { return nil }
        let text = await Task.detached(priority: .utility) { TranscriptTail.lastAssistantText(path: path) }.value
        if contextCache.count >= 32 { contextCache.removeAll() }
        contextCache[requestId] = text ?? ""
        return text
    }

    // MARK: Jump

    func jump(_ sid: String) {
        guard var s = session(sid) else { return }
        if let r = s.remote {
            // The local terminal that runs the ssh client, never a remote pid.
            guard let env = RemoteJump.env(ancestors: ProcInfo.ancestors(of: r.sshPid), tty: ProcInfo.tty(of: r.sshPid),
                                           bundleId: Jumper.terminalApp(above: r.sshPid)?.bundleIdentifier, extShells: ext.shellPids) else { return }
            s.env = env
        }
        let target = s
        jumpTask?.cancel()
        jumpGeneration += 1
        let ticket = JumpTicket(generation: jumpGeneration)
        jumpTask = Task {
            let note = await Jumper.jump(to: target, ext: ext, ticket: ticket, current: { [weak self] in self?.jumpGeneration ?? -1 })
            if let note, ticket.isCurrent(jumpGenerationNow: jumpGeneration) { showNote(sid, note) }
        }
    }

    // MARK: Hooks

    var hookPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/buddy-hook").path }
    var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    var canInstallHooks: Bool { FileManager.default.isExecutableFile(atPath: hookPath) }

    func refreshHookStatus() {
        let status = canInstallHooks ? HookInstaller.status(settingsURL: settingsURL, hookPath: hookPath) : .missing
        hooksInstalled = status == .current
        hooksOutdated = status == .outdated
        hooksInvalid = status == .invalid
        statusLineStatus = HookInstaller.statusLineStatus(settingsURL: settingsURL, home: NSHomeDirectory())
        openCodeStatus = OpenCodeInstaller.status(url: openCodePluginURL, template: openCodeTemplate, hookPath: hookPath)
    }

    // MARK: OpenCode plugin

    var openCodePluginURL: URL { OpenCodeInstaller.pluginURL(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) }
    var openCodeTemplate: String? {
        AppServices.bundledResource("buddy", ext: "js", subdirectory: "opencode", devPath: "opencode-plugin/buddy.js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func installOpenCode(_ install: Bool) {
        guard !install || canInstallHooks else { installMessage = "buddy-hook not found. Run Buddy from Buddy.app."; return }
        guard !install || AppServices.shared.isInApplications else { installMessage = "Move Buddy to Applications first."; return }
        do {
            let r = install ? try OpenCodeInstaller.install(url: openCodePluginURL, template: openCodeTemplate, hookPath: hookPath)
                            : try OpenCodeInstaller.remove(url: openCodePluginURL)
            switch r {
            case .unchanged: installMessage = install ? "OpenCode plugin already installed." : "No Buddy OpenCode plugin to remove."
            case .written: installMessage = (install ? "OpenCode plugin installed." : "OpenCode plugin removed.")
                + " Run `opencode service restart` or restart OpenCode."
            }
        } catch {
            installMessage = "\(error)"
            log.error("OpenCode plugin install failed: \(String(describing: error), privacy: .public)")
        }
        refreshHookStatus()
    }

    var previousStatusLineURL: URL { HookInstaller.previousStatusLineURL(home: NSHomeDirectory()) }

    /// Settings → General → Show plan usage. A failed install turns the setting off again.
    func installStatusLine(_ install: Bool) {
        statusLineBusy = true
        defer { statusLineBusy = false; refreshHookStatus() }
        guard canInstallHooks else { installMessage = "buddy-hook not found. Run Buddy from Buddy.app."; showPlanUsage = false; return }
        guard !install || AppServices.shared.isInApplications else { installMessage = "Move Buddy to Applications first."; showPlanUsage = false; return }
        do {
            switch try HookInstaller.applyStatusLine(install: install, settingsURL: settingsURL, hookPath: hookPath, previousURL: previousStatusLineURL) {
            case .unchanged: installMessage = install ? "Plan usage bridge already installed." : "No Buddy status line to remove."
            case .written(let backup):
                installMessage = (install ? "Plan usage bridge installed." : "Previous status line restored.") + Self.backupNote(backup)
                    + " New Claude sessions use it."
            }
        } catch {
            installMessage = "\(error)"
            log.error("Status line install failed: \(String(describing: error), privacy: .public)")
            if install { showPlanUsage = false }
        }
    }

    /// " Backup: settings.json.buddy-backup-…" after a written settings file, else "".
    static func backupNote(_ backup: String?) -> String { backup.map { " Backup: \(($0 as NSString).lastPathComponent)" } ?? "" }

    func installHooks(_ install: Bool) {
        guard canInstallHooks else { installMessage = "buddy-hook not found. Run Buddy from Buddy.app."; return }
        // A translocated, mounted-image, or Downloads path dies with the next launch; uninstall stays allowed.
        guard !install || AppServices.shared.isInApplications else { installMessage = "Move Buddy to Applications first."; return }
        do {
            switch try HookInstaller.apply(install: install, settingsURL: settingsURL, hookPath: hookPath) {
            case .unchanged: installMessage = install ? "Hooks already installed." : "No Buddy hooks to remove."
            case .written(let backup):
                installMessage = (install ? "Hooks installed." : "Hooks removed.")
                    + Self.backupNote(backup)
                    + " New Claude sessions use them."
            }
        } catch {
            installMessage = "\(error)"
            log.error("Hook install failed: \(String(describing: error), privacy: .public)")
        }
        refreshHookStatus()
    }
}

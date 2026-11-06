import AppKit
import Observation
import BuddyCore

enum PromptRoute: Equatable {
    case editor(String), inbox, none
}

enum SendResult { case sent, failed }

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var store = SessionStore()
    private(set) var sheet: SpriteSheet?
    var sheetError: String?
    var installMessage: String? { didSet { if let m = installMessage { Announcer.say(m) } } }
    var hooksInstalled = false
    /// Buddy hooks exist but lack events this version uses.
    var hooksOutdated = false
    /// settings.json has a shape Install refuses to change.
    var hooksInvalid = false
    var openCodeStatus: OpenCodeInstaller.Status = .missing
    private(set) var editorsConnected: [String] = []
    /// Connected extensions (editor, version), one per editor window. For Diagnostics.
    var extClients: [(editor: String, version: String)] = []
    /// Claude Code versions read from the claude binary path; `claudeVersionUnknown` when one could not be read.
    var claudeVersions: Set<String> = []
    var claudeVersionUnknown = false
    /// Bumped by each Jump; an older Jump that is still running drops its results.
    var jumpGeneration = 0
    var jumpTask: Task<Void, Never>?
    /// The last 50 hook events and replies, for Diagnostics. No commands, prompts, or tokens.
    private(set) var events = RingBuffer<DiagEvent>(capacity: 50)
    var socketListening: Bool { server != nil }
    /// Per-session result line for the "Next prompt" box.
    var sendStatus: [String: String] = [:]
    /// Accessibility setting, kept current by `ReduceMotion`.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var mode: MascotMode { didSet { defaults.set(mode.rawValue, forKey: PrefKey.mode); changed() } }
    var arrangement: Arrangement { didSet { defaults.set(arrangement.rawValue, forKey: PrefKey.arrangement); director?.arrangementChanged() } }
    /// Parked buddies start (or stop) their idle walks at once.
    var walking: Bool { didSet { defaults.set(walking, forKey: PrefKey.walking); director?.motionChanged() } }
    var size: BuddySize { didSet { defaults.set(size.rawValue, forKey: PrefKey.size); director?.rebuild() } }
    /// All mascot and bubble panels ordered out; menu and notifications keep working.
    var buddiesHidden: Bool { didSet { defaults.set(buddiesHidden, forKey: PrefKey.buddiesHidden); director?.applyHidden() } }
    var sleepMascot: Bool { didSet { defaults.set(sleepMascot, forKey: PrefKey.sleepMascot); changed() } }
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: PrefKey.keepAwake); changed() } }
    @ObservationIgnored let sleepAssertion = SleepAssertion()
    var showMinis: Bool { didSet { defaults.set(showMinis, forKey: PrefKey.showMinis); changed() } }
    var showShells: Bool { didSet { defaults.set(showShells, forKey: PrefKey.showShells); changed() } }
    var notifyPermission: Bool { didSet { defaults.set(notifyPermission, forKey: PrefKey.notifyPermission) } }
    var notifyQuestion: Bool { didSet { defaults.set(notifyQuestion, forKey: PrefKey.notifyQuestion) } }
    var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: PrefKey.notifyDone) } }
    var notifyWhileVisible: Bool { didSet { defaults.set(notifyWhileVisible, forKey: PrefKey.notifyWhileVisible) } }
    var notifyActions: Bool { didSet { defaults.set(notifyActions, forKey: PrefKey.notifyActions) } }
    var notifyPlanUsage: Bool { didSet { defaults.set(notifyPlanUsage, forKey: PrefKey.notifyPlanUsage) } }
    /// Settings → General, off by default: installs the status line bridge (`buddy-hook statusline`) when on.
    var showPlanUsage: Bool {
        didSet {
            defaults.set(showPlanUsage, forKey: PrefKey.showPlanUsage)
            if showPlanUsage != oldValue, !statusLineBusy { installStatusLine(showPlanUsage) }
        }
    }
    /// A failed install turns the toggle off without a second install call.
    @ObservationIgnored var statusLineBusy = false
    /// The plan limits from the last status line update; windows drop when their reset time passes.
    private(set) var planUsage: PlanUsage?
    var statusLineStatus: HookInstaller.StatusLineStatus = .missing
    /// Windows (keyed by name and reset time) that already got their one 90% notification.
    @ObservationIgnored private var planReminded: Set<String> = []
    /// Minutes of waiting before a buddy gets impatient; 0 = off.
    var escalateMinutes: Int { didSet { defaults.set(escalateMinutes, forKey: PrefKey.escalateMinutes) } }
    /// Minutes away before Buddy shows a digest on return; 0 = off.
    var awayMinutes: Int { didSet { defaults.set(awayMinutes, forKey: PrefKey.awayMinutes) } }
    static let escalateChoices = [0, 1, 3, 5, 10], awayChoices = [0, 5, 10, 30]
    /// A stale pref snaps to a picker value, so the Picker never shows blank.
    static func nearest(_ v: Int, in choices: [Int]) -> Int { choices.min { abs($0 - v) < abs($1 - v) } ?? v }
    var funExtras: Bool { didSet { defaults.set(funExtras, forKey: PrefKey.funExtras) } }
    /// The hidden Bee skin was found (BeeEgg). Locked again from Settings → About.
    var beeUnlocked: Bool { didSet { defaults.set(beeUnlocked, forKey: PrefKey.beeUnlocked); SkinStore.shared.reload() } }
    /// "Hide Bee again" was used: only the palette's `buzz` unlocks it now.
    var beeHidden: Bool { didSet { defaults.set(beeHidden, forKey: PrefKey.beeHidden) } }
    /// `forgebee:` subagents fly as bee minis (only while the Bee is unlocked).
    var forgeBeeMinis: Bool { didSet { defaults.set(forgeBeeMinis, forKey: PrefKey.forgeBeeMinis); director?.rebuild() } }
    /// A base name, or `AppModel.mix` for a character per session from every enabled one.
    var character: String { didSet { defaults.set(character, forKey: PrefKey.character); refreshLooks() } }
    var showUsage: Bool {
        didSet {
            defaults.set(showUsage, forKey: PrefKey.showUsage)
            if showUsage { sessions.forEach { refreshUsage($0.id, force: true) } }
            changed()
        }
    }
    /// "project · $0.31" on the name tag; needs `showUsage`.
    var costOnTag: Bool { didSet { defaults.set(costOnTag, forKey: PrefKey.costOnTag); changed() } }
    /// Token sums per session and model, from the transcripts.
    private(set) var usage: [String: [String: TokenCounts]] = [:]
    private(set) var prices: PriceTable?
    var pricesError: String?
    /// The two hotkeys never share a key: picking the other one's key swaps them.
    var hotkey: HotkeyChoice {
        didSet {
            if hotkey != .off, hotkey == paletteHotkey, oldValue != hotkey { paletteHotkey = oldValue }
            defaults.set(hotkey.rawValue, forKey: PrefKey.hotkey)
            Hotkey.shared.apply(card: hotkey, palette: paletteHotkey)
        }
    }
    var paletteHotkey: HotkeyChoice {
        didSet {
            if paletteHotkey != .off, paletteHotkey == hotkey, oldValue != paletteHotkey { hotkey = oldValue }
            defaults.set(paletteHotkey.rawValue, forKey: PrefKey.paletteHotkey)
            Hotkey.shared.apply(card: hotkey, palette: paletteHotkey)
        }
    }

    /// Settings → SSH, off by default. Only when on does `remote.sock` exist (docs/SSH.md).
    var sshEnabled: Bool { didSet { defaults.set(sshEnabled, forKey: PrefKey.sshEnabled); applySSH() } }
    /// ssh client binaries allowed next to /usr/bin/ssh, e.g. Homebrew's. Resolved paths.
    var sshClients: [String] { didSet { defaults.set(sshClients, forKey: PrefKey.sshClients) } }
    private(set) var remoteListening = false
    private(set) var remoteTokenPresent = false
    private(set) var lastRemoteEvent: Date?
    /// Why the last remote connection was refused. Never holds the token.
    private(set) var lastRemoteRejection: (time: Date, reason: String)?
    /// When `remote-install.env` (it holds the token) goes away; nil when there is none.
    private(set) var installFileExpires: Date?

    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private var remoteServer: SocketServer?
    /// In memory only while SSH sessions are on; loaded from the Keychain.
    @ObservationIgnored private(set) var remoteToken: String?
    @ObservationIgnored private var socketDir: String?
    @ObservationIgnored private(set) var socketPath: String?
    @ObservationIgnored private var lockFD: Int32 = -1
    @ObservationIgnored private var replies = PendingReplies<Connection>()
    @ObservationIgnored private var removals: Set<String> = []
    @ObservationIgnored private var reaper: Timer?
    @ObservationIgnored private var lookCache: [String: Look] = [:]
    @ObservationIgnored private var lookBook = LookBook()
    /// Card context line per request id ("" = nothing to show).
    @ObservationIgnored var contextCache: [String: String] = [:]
    @ObservationIgnored private lazy var expectedHookPath: String? =
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("buddy-hook").path
    @ObservationIgnored let ext = ExtensionHub()
    @ObservationIgnored var director: MascotDirector?
    @ObservationIgnored var notifier: Notifier?
    /// sprites.json as shipped; `sheet` is this plus the enabled skins.
    @ObservationIgnored private(set) var baseSheet: SpriteSheet?
    @ObservationIgnored private let usageWorker = UsageWorker()
    @ObservationIgnored private var usageAt: [String: Date] = [:]
    @ObservationIgnored private var usageBusy: Set<String> = []
    @ObservationIgnored private var usageAgain: Set<String> = []
    @ObservationIgnored private var tipLimiter = TipLimiter()
    /// Requests (or waits) that already got their one "still waiting" notification.
    @ObservationIgnored private var renotified: Set<String> = []
    @ObservationIgnored let away = AwayWatch()
    /// The digest shown on the last return, kept until the next away period starts.
    private(set) var lastDigest: (lines: [DigestLine], sessionId: String)?
    @ObservationIgnored private var installFileTimer: Task<Void, Never>?

    private init() {
        let d = UserDefaults.standard
        mode = MascotMode(rawValue: d.string(forKey: PrefKey.mode) ?? "") ?? .perSession
        arrangement = Arrangement(rawValue: d.string(forKey: PrefKey.arrangement) ?? "") ?? .free
        walking = d.bool(PrefKey.walking, default: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        size = BuddySize(rawValue: d.string(forKey: PrefKey.size) ?? "")
            ?? (d.object(forKey: PrefKey.scale) != nil ? .migrate(scale: d.integer(forKey: PrefKey.scale)) : .medium)
        buddiesHidden = d.bool(forKey: PrefKey.buddiesHidden)
        sleepMascot = d.bool(PrefKey.sleepMascot, default: true)
        keepAwake = d.bool(forKey: PrefKey.keepAwake)
        showMinis = d.bool(PrefKey.showMinis, default: true)
        showShells = d.bool(PrefKey.showShells, default: true)
        notifyPermission = d.bool(PrefKey.notifyPermission, default: true)
        notifyQuestion = d.bool(PrefKey.notifyQuestion, default: true)
        notifyDone = d.bool(PrefKey.notifyDone, default: false)
        notifyWhileVisible = d.bool(PrefKey.notifyWhileVisible, default: false)
        notifyActions = d.bool(PrefKey.notifyActions, default: true)
        notifyPlanUsage = d.bool(PrefKey.notifyPlanUsage, default: true)
        showPlanUsage = d.bool(forKey: PrefKey.showPlanUsage)
        escalateMinutes = Self.nearest(d.int(PrefKey.escalateMinutes, default: 3), in: Self.escalateChoices)
        awayMinutes = Self.nearest(d.int(PrefKey.awayMinutes, default: 5), in: Self.awayChoices)
        funExtras = d.bool(PrefKey.funExtras, default: true)
        showUsage = d.bool(PrefKey.showUsage, default: true)
        costOnTag = d.bool(forKey: PrefKey.costOnTag)
        character = d.string(forKey: PrefKey.character) ?? "clawd"
        beeUnlocked = d.bool(forKey: PrefKey.beeUnlocked)
        beeHidden = d.bool(forKey: PrefKey.beeHidden)
        forgeBeeMinis = d.bool(PrefKey.forgeBeeMinis, default: true)
        let card = HotkeyChoice(rawValue: d.string(forKey: PrefKey.hotkey) ?? "") ?? .ctrlOptB
        hotkey = card
        let palette = HotkeyChoice(rawValue: d.string(forKey: PrefKey.paletteHotkey) ?? "") ?? .ctrlOptSpace
        paletteHotkey = palette != .off && palette == card ? .off : palette
        sshEnabled = d.bool(forKey: PrefKey.sshEnabled)
        sshClients = RemoteAuth.savedClients(d.stringArray(forKey: PrefKey.sshClients) ?? [])
    }

    var sessions: [Session] { store.sessions.values.sorted { $0.id < $1.id } }
    var menuSessions: [Session] { SessionOrder.menu(store.sessions.values.filter { $0.state != .ended }) }
    var attentionCount: Int { store.sessions.values.filter { $0.state.needsAttention && !$0.hidden }.count }

    /// Points per sprite pixel for the main screen.
    var pointScale: CGFloat {
        CGFloat(size.pointsPerPixel(backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2)))
    }
    var miniScale: CGFloat {
        CGFloat(size.miniPointsPerPixel(backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2)))
    }
    func session(_ id: String) -> Session? { store.sessions[id] }
    var escalateAfter: TimeInterval? { escalateMinutes > 0 ? Double(escalateMinutes) * 60 : nil }
    var onboarded: Bool {
        get { defaults.bool(forKey: PrefKey.onboarded) }
        set { defaults.set(newValue, forKey: PrefKey.onboarded) }
    }

    /// Newest session with an open card, for the global hotkey.
    var newestPending: Session? { store.sessions.values.filter { $0.pending != nil && !$0.hidden }.max { $0.updated < $1.updated } }

    // MARK: Start

    func start() {
        // A file left by a crash still holds the token.
        deleteInstallFile()
        loadSprites()
        loadPrices()
        SkinStore.shared.start(model: self)
        refreshHookStatus()
        ext.onChange = { [weak self] in
            guard let self else { return }
            self.editorsConnected = self.ext.connectedEditors
            self.extClients = self.ext.clientVersions
        }
        #if DEBUG
        let demo = Demo.on
        #else
        let demo = false
        #endif
        // The demo never opens the socket, so it runs next to an installed Buddy and gets no real hooks.
        if !demo { startServer() }
        director = MascotDirector(model: self)
        director?.sync()
        if !demo { Hotkey.shared.apply(card: hotkey, palette: paletteHotkey) }
    }

    #if DEBUG
    /// `--demo-ssh`: the SSH rows without a socket or the Keychain.
    func demoSSH() {
        sshEnabled = true
        remoteListening = true
        remoteTokenPresent = true
        lastRemoteEvent = Date().addingTimeInterval(-120)
        lastRemoteRejection = (Date(), "rejected: token mismatch")
    }

    func applyDemo(_ msg: HookMessage, origin: RemoteOrigin? = nil, now: Date = Date()) {
        _ = store.apply(msg, origin: origin, now: now, isAlive: { _ in true })
        let sid = msg.payload["session_id"]?.string
        record(sid, msg.payload["hook_event_name"]?.string, msg.payload["tool_name"]?.string,
               msg.wantsReply ? "waiting for card" : "received")
        if let sid { afterChange(sid, before: nil); refreshUsage(sid, force: true) }
    }
    #endif

    private func loadSprites() {
        guard let url = AppServices.bundledResource("sprites", ext: "json", devPath: "design/sprites.json") else {
            sheetError = "sprites.json not found in the app bundle."
            log.error("sprites.json missing")
            return
        }
        do { baseSheet = try SpriteSheet.load(Data(contentsOf: url)); sheet = baseSheet } catch {
            sheetError = "sprites.json is invalid: \(error)"
            log.error("sprites.json invalid: \(String(describing: error), privacy: .public)")
        }
        lookCache.removeAll()
        lookBook.clear()
        MascotImages.clear()
    }

    private func startServer() {
        #if DEBUG
        let path = UnixSocket.defaultPath(allowOverride: true)
        #else
        let path = UnixSocket.defaultPath(allowOverride: false)
        #endif
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try UnixSocket.prepareDirectory(dir)
            lockFD = try UnixSocket.acquireLock(dir)
        } catch {
            log.error("Another Buddy is running or the socket folder is unsafe: \(String(describing: error), privacy: .public)")
            let me = ProcessInfo.processInfo.processIdentifier
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != me }) {
                other.activate()
            } else {
                let alert = NSAlert()
                alert.messageText = "Buddy is already running."
                alert.informativeText = "\(error)"
                alert.runModal()
            }
            NSApp.terminate(nil)
            return
        }
        let srv = SocketServer(path: path)
        srv.onMessage = { [weak self] msg, conn in self?.receive(msg, from: conn) }
        srv.onClose = { [weak self] conn in self?.connectionClosed(conn) }
        do { try srv.start(); server = srv } catch {
            log.error("Socket server failed: \(String(describing: error), privacy: .public)")
        }
        socketDir = dir
        socketPath = path
        applySSH()
    }

    // MARK: SSH sessions

    var remoteSocketPath: String? { socketDir.map { $0 + "/remote.sock" } }
    /// Socket paths for display, with `~` for the home folder.
    var displaySocket: String { ((socketPath ?? "") as NSString).abbreviatingWithTildeInPath }
    var displayRemoteSocket: String { ((remoteSocketPath ?? "") as NSString).abbreviatingWithTildeInPath }

    /// Opens or closes `remote.sock` to match the setting. It shares the main socket's 0700 folder and lock.
    func applySSH() {
        guard let path = remoteSocketPath else { return }
        if sshEnabled, remoteServer == nil {
            _ = currentRemoteToken()
            let srv = SocketServer(path: path)
            srv.onMessage = { [weak self] msg, conn in self?.receiveRemote(msg, from: conn) }
            srv.onClose = { [weak self] conn in self?.connectionClosed(conn) }
            do { try srv.start(); remoteServer = srv } catch {
                log.error("Remote socket failed: \(String(describing: error), privacy: .public)")
            }
        } else if !sshEnabled, let srv = remoteServer {
            srv.stop()
            remoteServer = nil
            remoteToken = nil
            let r = store.endRemoteSessions()
            replyNull(r.stale)
            r.ended.forEach(scheduleRemoval)
            changed()
        }
        remoteListening = remoteServer != nil
    }

    private func newRemoteToken() -> String? {
        let t = RemoteAuth.newToken()
        return RemoteKeychain.write(t) ? t : nil
    }

    /// Remote hosts keep the old token until you run the install command again.
    func rotateRemoteToken() -> String {
        deleteInstallFile()
        guard let t = newRemoteToken() else { return "The Keychain did not save a new token." }
        remoteToken = t
        remoteTokenPresent = true
        return "New token saved. Run the remote install command again on each host."
    }

    private var installFilePath: String { UninstallPlan.supportFolder(home: NSHomeDirectory()) + "/" + RemoteInstall.envFileName }

    /// Writes the token file that the copied install command reads. It is deleted after 10 minutes.
    func writeInstallFile(_ token: String) throws -> String {
        let path = try RemoteInstall.writeEnvFile(token: token, dir: UninstallPlan.supportFolder(home: NSHomeDirectory()))
        installFileTimer?.cancel()
        installFileExpires = Date().addingTimeInterval(RemoteInstall.envFileLifetime)
        installFileTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteInstall.envFileLifetime))
            if !Task.isCancelled { self?.deleteInstallFile() }
        }
        return path
    }

    /// On expiry, Rotate token, and quit.
    func deleteInstallFile() {
        installFileTimer?.cancel()
        installFileTimer = nil
        installFileExpires = nil
        unlink(installFilePath)
    }

    /// The Keychain token, loaded on demand (the Settings copy button works while SSH sessions are off).
    func currentRemoteToken() -> String? {
        if remoteToken == nil { remoteToken = RemoteKeychain.read() ?? newRemoteToken() }
        remoteTokenPresent = remoteToken != nil
        return remoteToken
    }

    /// One hook message per connection, from an allowed ssh client, with the right token. Nothing from the payload
    /// is recorded before the check passes.
    private func receiveRemote(_ msg: WireMessage, from conn: Connection) {
        guard case .hook(let h) = msg, conn.role == .unknown else {
            log.error("Remote socket: message not allowed; dropping it")
            conn.close()
            return
        }
        // The audit token from accept time, so a peer that exits and leaves its pid to another process never passes.
        let verdict = RemoteAuth.check(peerUid: PeerCheck.peerUid(conn.fd), peerPath: conn.peerToken.flatMap(PeerCheck.path(ofToken:)),
                                       allowedClients: RemoteAuth.defaultClients + sshClients, sent: h.token, expected: remoteToken,
                                       remote: h.remote)
        var reason = verdict == .ok ? nil : verdict.rawValue
        if reason == nil, replies.contains(h.id) { reason = "duplicate request id" }
        guard reason == nil, let pid = conn.peerToken.map(PeerCheck.pid(of:)), let (local, origin) = try? RemoteAuth.localize(h, sshPid: pid) else {
            let why = "rejected: \(reason ?? "bad payload")"
            log.error("Remote hook \(why, privacy: .public)")
            record(nil, "remote", nil, why)
            lastRemoteRejection = (Date(), why)
            conn.close()
            return
        }
        conn.role = .hook
        lastRemoteEvent = Date()
        handleHook(local, from: conn, origin: origin)
    }

    // MARK: Socket messages

    private func receive(_ msg: WireMessage, from conn: Connection) {
        switch (msg, conn.role) {
        case (.hook(let h), .unknown):
            let reason = !RemoteAuth.mainSocketAccepts(h) || !hookPeerAllowed(conn, h) ? "peer check failed"
                : replies.contains(h.id) ? "duplicate request id" : nil
            if let reason {
                log.error("Hook rejected: \(reason, privacy: .public)")
                record(nil, h.payload["hook_event_name"]?.string, h.payload["tool_name"]?.string, "rejected: \(reason)")
                conn.close()
                return
            }
            conn.role = .hook
            handleHook(h, from: conn)
        case (.statusLine(let m), .unknown):
            // Same peer rule as a hook. The bridge never waits, so nothing is sent back.
            conn.role = .hook
            if hookPeerAllowed(conn, claudePid: m.claudePid), showPlanUsage { receivePlanUsage(m.rateLimits) }
            conn.close()
        case (.extHello(let m), .unknown):
            conn.role = .ext
            ext.hello(m, from: conn)
        case (.extTerminals(let m), .ext): ext.terminals(m, from: conn)
        case (.ack(let m), .ext): ext.ack(m)
        case (.unknown, .ext), (.unknown, .hook): break
        default:
            log.error("Message not allowed for this connection role; dropping it")
            conn.close()
        }
    }

    /// The peer must be the bundled buddy-hook, a child (or grandchild) of the claude pid it reports.
    /// OpenCode: a child of the plugin host it reports; the session pid is that host or a TUI of it in the payload's cwd.
    private func hookPeerAllowed(_ conn: Connection, _ h: HookMessage) -> Bool {
        guard h.env.agent == HookEnv.openCode else { return hookPeerAllowed(conn, claudePid: h.env.claudePid) }
        guard let host = h.env.hostPid, let pid = h.env.claudePid, hookPeerAllowed(conn, claudePid: host) else { return false }
        return pid == host || OpenCodeTUI.isTUI(pid, of: host, cwd: h.payload["cwd"]?.string)
    }

    private func hookPeerAllowed(_ conn: Connection, claudePid: Int32?) -> Bool {
        guard let pid = conn.peerPid, let expected = expectedHookPath else { return false }
        // The audit token names the exact process; the pid only when the kernel gave no token.
        let peerPath = conn.peerToken.map(PeerCheck.path(ofToken:)) ?? PeerCheck.path(of: pid)
        return PeerCheck.hookPeerAllowed(peerPath: peerPath, expectedHookPath: expected,
                                         ancestors: Array(ProcInfo.ancestors(of: pid, limit: 3).dropFirst()),
                                         claudePid: claudePid)
    }

    // MARK: Plan usage (status line bridge)

    /// Stores the parsed limits and posts the one 90% reminder per window. The numbers are never logged.
    private func receivePlanUsage(_ limits: JSONValue, now: Date = Date()) {
        guard let u = PlanUsage.parse(json: limits, now: now) else { return }
        planUsage = u
        for r in u.reminders(now: now) where planReminded.insert(r.key).inserted && notifyPlanUsage {
            notifier?.planUsage(r.text, key: r.key)
        }
        planReminded = planReminded.filter { key in u.reminders(now: now).contains { $0.key == key } }
        startReaper()
        changed()
    }

    /// "5h 23% · 7d 41%" while a window is known and the setting is on.
    var planChip: String? { showPlanUsage ? planUsage?.chip : nil }
    var planSpoken: String? { showPlanUsage ? planUsage?.spoken() : nil }

    private func handleHook(_ msg: HookMessage, from conn: Connection, origin: RemoteOrigin? = nil) {
        let sid = msg.payload["session_id"]?.string
        let old = sid.flatMap { store.sessions[$0] }
        let before = old?.state
        let isNew = sid != nil && old == nil
        let change = store.apply(msg, origin: origin)
        replyNull(change.staleRequests)
        if let sid, isNew || msg.payload["hook_event_name"]?.string == "SessionStart" { checkClaudeApp(sid) }
        let held = PendingReplies<Connection>.shouldHold(msg, in: store)
        record(sid, msg.payload["hook_event_name"]?.string, msg.payload["tool_name"]?.string,
               change.sessionId == nil ? "ignored" : held ? "waiting for card" : msg.wantsReply ? "deferred" : "received")
        if held, let sid {
            replies.hold(msg.id, sid: sid, token: conn)
        } else {
            if msg.wantsReply { send(ReplyMessage(id: msg.id, output: .null), to: conn) }
            // The hook waits for this close so the peer check above could still see it.
            conn.close()
        }
        if let sid {
            afterChange(sid, before: before)
            refreshUsage(sid, force: msg.payload["hook_event_name"]?.string == "Stop")
            maybeTip(sid)
            if let s = store.sessions[sid], !s.hidden, showMinis, SoundRules.subagentFinished(before: old, after: s) {
                Sounds.shared.play(.subagentDone, session: s, model: self)
            }
            if let s = store.sessions[sid] { findBee(.project(s.folderName, remote: s.remote != nil)) }
        }
        startReaper()
    }

    /// Marks a session whose claude runs under /Applications/Claude.app (Desktop without the env markers).
    private func checkClaudeApp(_ sid: String) {
        guard let env = store.sessions[sid]?.env, env.agent == nil, let pid = env.claudePid else { return }
        store.setUnderClaudeApp(sid, Self.underClaudeApp(pid))
        if let v = ClaudeVersion.fromExecutable(PeerCheck.path(of: pid)) { claudeVersions.insert(v) } else { claudeVersionUnknown = true }
    }

    /// Adds a "Last events" line. Only names and results: never commands, prompts, or tokens.
    func record(_ sid: String?, _ event: String?, _ tool: String?, _ result: String) {
        let s = sid.flatMap { store.sessions[$0] }
        events.append(DiagEvent(time: Date(), sessionId: sid ?? "-", project: s?.folderName ?? "-", host: s?.remote?.host,
                                event: event ?? "?", tool: tool, result: result))
    }

    /// Only hook events create sessions; this lookup never scans for processes.
    static func underClaudeApp(_ pid: Int32) -> Bool {
        let paths = ProcInfo.ancestors(of: pid).dropFirst().compactMap(PeerCheck.path(of:))
        return TerminalApp.detect(HookEnv(), chainPaths: paths) == .claudeDesktop
    }

    private func connectionClosed(_ conn: Connection) {
        ext.closed(conn)
        for (id, sid) in replies.closed(conn) {
            let tool = store.sessions[sid]?.pending?.toolName
            let before = store.sessions[sid]?.state
            if store.requestClosed(sid: sid, requestId: id) {
                record(sid, "PermissionRequest", tool, "closed by Claude Code")
                afterChange(sid, before: before)
            }
        }
    }

    @discardableResult
    private func send(_ reply: ReplyMessage, to conn: Connection) -> Bool {
        do { return conn.send(try WireMessage.encode(reply)) } catch {
            log.error("Reply encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Releases held hooks whose request no longer matters; the terminal dialog answers them.
    private func replyNull(_ ids: [String]) {
        for (id, conn) in replies.takeStale(ids) { send(ReplyMessage(id: id, output: .null), to: conn) }
    }

    private func afterChange(_ sid: String, before: SessionState?) {
        if let s = store.sessions[sid] {
            if s.state != before || notifier?.isNewRequest(s) == true {
                let posted = notifier?.post(for: s, model: self) ?? false
                // Hidden buddies make no sound of their own; a posted notification still gets its one.
                if !s.hidden, !buddiesHidden || posted, let e = SoundRules.event(for: s.state) { Sounds.shared.play(e, session: s, model: self) }
            }
            if s.pending == nil { notifier?.clear(sessionId: sid) }
            if s.state == .ended { scheduleRemoval(sid) }
        }
        changed()
        director?.cardChanged(sid)
    }

    func changed() {
        director?.sync()
        sleepAssertion.set(KeepAwake.shouldHold(sessions: store.sessions.values, enabled: keepAwake))
    }

    // MARK: Reaper (runs only while there are sessions or plan limits)

    private func startReaper() {
        guard reaper == nil, !store.isEmpty || planUsage != nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reap() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)  // keeps running while a menu is open
        reaper = t
    }

    private func reap() {
        if var u = planUsage, u.dropExpired() {
            planUsage = u.isEmpty ? nil : u
            changed()
        }
        guard !store.isEmpty || planUsage != nil else { reaper?.invalidate(); reaper = nil; return }
        escalate(now: Date())
        away.check(model: self)
        // On a copy: an unchanged store is not written, so no view updates every 5 s.
        var copy = store
        let result = copy.reap(isAlive: ProcInfo.isAlive)
        guard result.changed else { return }
        store = copy
        replyNull(result.stale)
        guard !result.ended.isEmpty else { return }
        result.ended.forEach(scheduleRemoval)
        changed()
    }

    private func scheduleRemoval(_ sid: String) {
        guard removals.insert(sid).inserted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            self.removals.remove(sid)
            if self.store.removeIfEnded(sid) {
                self.usage[sid] = nil
                self.usageAt[sid] = nil
                self.sendStatus[sid] = nil
                self.tipLimiter.forget(sid)
                await self.usageWorker.forget(sid)
                self.changed()
            }
        }
    }

    // MARK: Answers (never automatic: every call comes from a user click)

    /// Answers only the request the card showed (`requestId`), never whatever is pending now.
    func answer(_ sid: String, requestId: String, output: JSONValue) {
        let tool = store.sessions[sid]?.pending?.toolName
        let decision = replies.answer(sid: sid, requestId: requestId, store: &store)
        if decision == .stale {
            store.setNote(sid, "That request is no longer open, so Buddy sent nothing. It was answered in the terminal or replaced.")
            record(sid, "PermissionRequest", tool, "stale: sent nothing")
            return
        }
        if case .send(let conn) = decision, send(ReplyMessage(id: requestId, output: output), to: conn) {
            record(sid, "PermissionRequest", tool, DiagEvent.result(for: output))
        } else {
            store.setNote(sid, "Answered in terminal. Buddy's answer was not delivered.")
            record(sid, "PermissionRequest", tool, "not delivered: hook gone")
        }
        notifier?.clear(sessionId: sid)
        changed()
    }

    /// "Answer in terminal": release the hook with no output; the terminal dialog is already live.
    func deferToTerminal(_ sid: String, requestId: String) {
        let tool = store.sessions[sid]?.pending?.toolName
        let decision = replies.answer(sid: sid, requestId: requestId, store: &store)
        guard decision != .stale else { return }
        if case .send(let conn) = decision { send(ReplyMessage(id: requestId, output: .null), to: conn) }
        record(sid, "PermissionRequest", tool, "deferred to terminal")
        store.setNote(sid, "Answer in \(store.sessions[sid]?.answerPlace ?? "the terminal")")
        notifier?.clear(sessionId: sid)
        changed()
        jump(sid)
    }

    /// A click on a notification or one of its actions. Answers (Deny only) go through `answer`, bound to the request id.
    /// Review… opens the card in front, where the normal 700 ms arming applies.
    func notificationAction(_ id: String, sessionId sid: String, requestId: String?, text: String?) {
        let action = NotificationAction(rawValue: id) ?? .open
        switch NotificationActions.decide(action, requestId: requestId, pendingId: session(sid)?.pending?.id,
                                          enabled: notifyActions, text: text) {
        case .open:
            director?.openBubble(sessionId: sid)
            if action == .open { jump(sid) }
        case .answer(let output):
            answer(sid, requestId: requestId ?? "", output: output)
        case .sendPrompt(let prompt):
            Task {
                if await sendPrompt(prompt, to: sid) == .failed { notifier?.info(sid, project: session(sid)?.displayName, sendStatus[sid] ?? "Not sent.") }
            }
        case .alreadyAnswered:
            notifier?.info(sid, project: session(sid)?.displayName, "Already answered. Buddy sent nothing.")
        }
    }

    func dismissNote(_ sid: String) { store.setNote(sid, nil) }
    func showNote(_ sid: String, _ note: String) { store.setNote(sid, note); changed() }
    func setHidden(_ sid: String, _ hidden: Bool) { store.setHidden(sid, hidden); changed() }

    // MARK: Looks

    static let mix = "mix"

    /// Bases a look may use: the chosen character, or every enabled one under Mix. Falls back to the built-in one.
    var characters: [String] {
        guard let sheet else { return [] }
        if character == Self.mix { return sheet.baseNames }
        return sheet.bases[character] != nil ? [character] : Array(sheet.baseNames.filter { !$0.contains("/") }.prefix(1))
    }

    /// "Claude" for the built-in base, else "Crate (crate)": the base and its skin.
    func characterLabel(_ base: String) -> String {
        let parts = base.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return base == "clawd" ? "Claude" : base.capitalized }
        return "\(parts[1].capitalized) (\(parts[0]))"
    }

    /// The project's look: the user's override for this cwd (`host:cwd` for SSH), else its hash. Cached per key.
    func projectLook(cwd: String) -> Look? {
        if let hit = lookCache[cwd] { return hit }
        guard let sheet else { return nil }
        let chars = characters
        var look = LookPicker.pick(cwd: cwd, sheet: sheet, bases: chars)
        if let o = UserDefaults.standard.lookOverrides[cwd] {
            if character == Self.mix, chars.contains(o.base) { look.base = o.base }
            if sheet.palettes[o.palette] != nil { look.palette = o.palette }
            if o.outfit == nil || sheet.outfits(fitting: look.base).contains(o.outfit ?? "") { look.outfit = o.outfit }
        }
        if let o = look.outfit, !sheet.outfits(fitting: look.base).contains(o) { look.outfit = nil }
        lookCache[cwd] = look
        return look
    }

    /// Sprites, skins, or the character changed: keep each buddy's look where it is still valid.
    /// One character: every buddy switches to it. Mix: a buddy whose character is gone gets a new look.
    func refreshLooks() {
        lookCache.removeAll()
        guard let sheet else { return }
        let kept = LookRefresh.refresh(lookBook.looks, sheet: sheet, bases: characters, mix: character == Self.mix)
        lookBook.keep(Set(kept.keys))
        for (key, l) in kept { lookBook.set(key, l) }
        director?.rebuild()
    }

    /// The palette query or a project name may unlock the Bee (`BeeEgg.unlocks`).
    func findBee(_ t: BeeEgg.Trigger) {
        if !beeUnlocked, BeeEgg.unlocks(t, hidden: beeHidden) { unlockBee() }
    }

    /// Settings → About. Buddies that wear the Bee get another character.
    func hideBee() {
        beeHidden = true
        if beeUnlocked { beeUnlocked = false }
    }

    /// Once: the Bee skin loads, flies across, and a callout says where to pick it.
    private func unlockBee() {
        guard !beeUnlocked else { return }
        beeHidden = false
        beeUnlocked = true
        Task { [weak self] in
            await SkinStore.shared.loading?.value
            self?.director?.beeFound()
        }
    }

    /// The mini's character: the parent's, or the Bee for a `forgebee:` subagent once the Bee is found.
    func miniBase(_ agent: Subagent, parent: String) -> String {
        BeeEgg.miniBase(agentType: agent.type, parent: parent, unlocked: beeUnlocked, enabled: forgeBeeMinis,
                        available: sheet?.bases[BeeEgg.base] != nil)
    }

    /// Enabled skins changed.
    func applySkins(_ skins: [Skin]) {
        sheet = baseSheet?.merged(skins)
        MascotImages.clear()
        refreshLooks()
    }

    /// Mascot keys of sessions with a buddy on screen.
    private var visibleLookKeys: Set<String> {
        Set(store.sessions.values.filter { !$0.hidden && $0.state != .ended }.map(\.mascotKey))
    }

    /// The session's own look, set once when first asked for and unique among visible buddies.
    func look(for s: Session) -> Look? {
        guard let sheet, let preferred = projectLook(cwd: s.lookKey) else { return nil }
        if lookBook.looks[s.mascotKey] == nil { lookBook.keep(Set(store.sessions.values.map(\.mascotKey))) }
        return lookBook.look(for: s.mascotKey, preferred: preferred, seed: s.lookKey, visible: visibleLookKeys, sheet: sheet, bases: characters)
    }

    /// Palettes that other visible buddies wear.
    func palettesInUse(except s: Session) -> Set<String> {
        Set(lookBook.taken(except: s.mascotKey, visible: visibleLookKeys).map(\.palette))
    }

    func charactersInUse(except s: Session) -> Set<String> {
        Set(lookBook.taken(except: s.mascotKey, visible: visibleLookKeys).map(\.base))
    }

    func rerollLook(_ s: Session) {
        guard let sheet, let current = look(for: s) else { return }
        var rng = SystemRandomNumberGenerator()
        let next = LookAssigner.reroll(current: current, taken: lookBook.taken(except: s.mascotKey, visible: visibleLookKeys),
                                       sheet: sheet, bases: characters, using: &rng)
        setLook(s, base: next.base, palette: next.palette, outfit: .some(next.outfit))
    }

    /// Changes this buddy only. When it wears the project look, the change also becomes the project's look.
    func setLook(_ s: Session, base: String? = nil, palette: String? = nil, outfit: String?? = nil) {
        guard let sheet, let current = look(for: s) else { return }
        let b = base ?? current.base
        var o = outfit ?? current.outfit
        if let name = o, !sheet.outfits(fitting: b).contains(name) { o = nil }
        lookBook.set(s.mascotKey, Look(base: b, palette: palette ?? current.palette, outfit: o))
        if current == projectLook(cwd: s.lookKey) {
            var all = UserDefaults.standard.lookOverrides
            let old = all[s.lookKey] ?? current
            all[s.lookKey] = Look(base: b, palette: palette ?? old.palette, outfit: o)
            UserDefaults.standard.lookOverrides = all
            lookCache[s.lookKey] = nil
        }
        director?.rebuild()
    }

    // MARK: Tokens and cost

    /// At most every 5 s while the session works, plus once on Stop. Reads off the main thread.
    func refreshUsage(_ sid: String, force: Bool) {
        guard showUsage, let s = store.sessions[sid], let path = s.transcriptPath else { return }
        let active = s.state == .working || s.state.needsAttention || s.activeSubagents > 0
        guard force || (active && Date().timeIntervalSince(usageAt[sid] ?? .distantPast) >= 5) else { return }
        guard usageBusy.insert(sid).inserted else { if force { usageAgain.insert(sid) }; return }
        usageAt[sid] = Date()
        Task {
            let totals = await usageWorker.update(sid, path: path)
            usageBusy.remove(sid)
            // The session was removed while the transcript was read: its meter must not come back.
            guard store.sessions[sid] != nil else {
                usageAgain.remove(sid)
                await usageWorker.forget(sid)
                return
            }
            // The tag, tooltip, and sprite label read it through the specs.
            if let totals, usage[sid] != totals { usage[sid] = totals; changed() }
            if usageAgain.remove(sid) != nil { refreshUsage(sid, force: true) }
        }
    }

    /// The token sums of these sessions when usage shows and some tokens were counted. Never for SSH: no transcript access.
    private func usageTotals(_ sids: [String]) -> [String: TokenCounts]? {
        guard showUsage else { return nil }
        let known = sids.compactMap { sid in usage[sid].flatMap { store.sessions[sid]?.remote == nil && UsageFormat.total($0) > 0 ? $0 : nil } }
        return known.isEmpty ? nil : UsageFormat.sum(known)
    }

    /// "42.1k tok · $0.31" (tokens only when a model has no price), or nil when off or unknown.
    /// `spoken`: the VoiceOver form, "42.1 thousand tokens, 31 cents".
    func usageText(_ sid: String, spoken: Bool = false) -> String? { usageText([sid], spoken: spoken) }

    /// The sum of several sessions (single buddy mode); "remote" for one SSH session.
    func usageText(_ sids: [String], spoken: Bool = false) -> String? {
        if showUsage, sids.count == 1, store.sessions[sids[0]]?.remote != nil { return "remote" }
        return usageTotals(sids).map { spoken ? UsageFormat.spoken($0, prices: prices) : UsageFormat.line($0, prices: prices) }
    }

    /// The name tag's "$0.31" (or "42k"), when that setting is on.
    func tagUsage(_ sids: [String]) -> String? { UsageFormat.tag(usageTotals(sids), prices: prices, costOnTag: costOnTag) }

    /// A bubble opened: read the transcript now when the session has no totals yet.
    func usageForBubble(_ sid: String) { if usage[sid] == nil { refreshUsage(sid, force: true) } }

    var pricesPath: String { UninstallPlan.supportFolder(home: NSHomeDirectory()) + "/prices.json" }

    /// The user's prices.json, seeded from the bundled one. A bad file falls back to the bundled prices.
    func loadPrices() {
        let bundled = AppServices.bundledResource("prices", ext: "json", devPath: "Resources/prices.json")
        let fallback = bundled.flatMap { try? JSONDecoder().decode(PriceTable.self, from: Data(contentsOf: $0)) }
        #if DEBUG
        if Demo.on { prices = fallback; return }
        #endif
        let fm = FileManager.default
        if let bundled, !fm.fileExists(atPath: pricesPath) {
            do {
                try fm.createDirectory(atPath: (pricesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: bundled, to: URL(fileURLWithPath: pricesPath))
            } catch {
                log.error("prices.json seed failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let data = SafeFile.contents(pricesPath, maxBytes: 256 * 1024), let table = try? JSONDecoder().decode(PriceTable.self, from: data) {
            prices = table
            pricesError = nil
        } else {
            prices = fallback
            pricesError = "prices.json is missing or invalid. Buddy uses the built-in placeholder prices."
        }
    }

    // MARK: Impatience, away digest, tips

    /// One "still waiting" notification per request, at level 2. Runs on the reaper tick.
    private func escalate(now: Date) {
        guard let after = escalateAfter else { return }
        var waiting = Set<String>()
        for s in store.sessions.values {
            guard let since = s.waitingSince else { continue }
            let key = s.pending?.id ?? "\(s.id)@\(since.timeIntervalSince1970)"
            waiting.insert(key)
            guard !s.hidden, Impatience.level(waited: now.timeIntervalSince(since), after: after) == 2,
                  renotified.insert(key).inserted else { continue }
            let posted = notifier?.post(for: s, model: self, stillWaiting: Impatience.minutes(now.timeIntervalSince(since))) ?? false
            if !buddiesHidden || posted { Sounds.shared.play(.reminder, session: s, model: self) }
        }
        // Keys of waits that ended are dropped; a wait that goes on keeps its one reminder.
        renotified.formIntersection(waiting)
    }

    /// Shows the digest on the buddy most in need, when something happened since `since`.
    func showDigest(since: Date, now: Date = Date()) {
        let lines = AwayDigest.build(Array(store.sessions.values), since: since, now: now)
        guard let sid = AwayDigest.focus(lines) else { return }
        lastDigest = (lines, sid)
        director?.showDigest(lines, sessionId: sid)
        Sounds.shared.play(.digest, session: nil, model: self)
    }

    /// From the menu bar or the palette.
    func showLastDigest() {
        guard let d = lastDigest else { return }
        director?.showDigest(d.lines, sessionId: d.sessionId)
    }

    /// A new away period starts.
    func clearLastDigest() { if lastDigest != nil { lastDigest = nil } }

    func openFromDigest(_ line: DigestLine) {
        switch line.kind {
        case .waiting, .finished: director?.openBubble(sessionId: line.sessionId)
        default: director?.openActivity(sessionId: line.sessionId, highlight: nil)
        }
    }

    /// Rare: fun extras on, the session works, the user is not busy with Buddy, at most once an hour per session.
    private func maybeTip(_ sid: String) {
        guard funExtras, let s = store.sessions[sid], s.state == .working, !s.hidden, !buddiesHidden, let tip = s.tip,
              !PaletteController.shared.isOpen, director?.bubbleOpen(sid) == false,
              Double.random(in: 0..<1) < 0.25, tipLimiter.allow(sid, now: Date()) else { return }
        director?.showTip(tip, sessionId: sid)
    }
}

/// Token sums per session, off the main thread.
actor UsageWorker {
    private var meters: [String: UsageMeter] = [:]

    func update(_ sid: String, path: String) -> [String: TokenCounts]? {
        var m = meters[sid] ?? UsageMeter()
        let ok = m.update(transcript: path)
        meters[sid] = m
        return ok ? m.byModel : nil
    }

    func forget(_ sid: String) { meters[sid] = nil }
}

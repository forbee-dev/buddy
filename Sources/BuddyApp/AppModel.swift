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
    private(set) var editorsConnected: [String] = []
    /// Per-session result line for the "Next prompt" box.
    var sendStatus: [String: String] = [:]
    /// Accessibility setting, kept current by `ReduceMotion`.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var mode: MascotMode { didSet { defaults.set(mode.rawValue, forKey: PrefKey.mode); changed() } }
    var arrangement: Arrangement { didSet { defaults.set(arrangement.rawValue, forKey: PrefKey.arrangement); director?.arrangementChanged() } }
    var walking: Bool { didSet { defaults.set(walking, forKey: PrefKey.walking) } }
    var size: BuddySize { didSet { defaults.set(size.rawValue, forKey: PrefKey.size); director?.rebuild() } }
    /// All mascot and bubble panels ordered out; menu and notifications keep working.
    var buddiesHidden: Bool { didSet { defaults.set(buddiesHidden, forKey: PrefKey.buddiesHidden); director?.applyHidden() } }
    var sleepMascot: Bool { didSet { defaults.set(sleepMascot, forKey: PrefKey.sleepMascot); changed() } }
    var notifyPermission: Bool { didSet { defaults.set(notifyPermission, forKey: PrefKey.notifyPermission) } }
    var notifyQuestion: Bool { didSet { defaults.set(notifyQuestion, forKey: PrefKey.notifyQuestion) } }
    var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: PrefKey.notifyDone) } }
    var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: PrefKey.hotkey); Hotkey.shared.apply(hotkey) } }

    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private var lockFD: Int32 = -1
    @ObservationIgnored private var hookConnections: [String: Connection] = [:]
    @ObservationIgnored private var removals: Set<String> = []
    @ObservationIgnored private var reaper: Timer?
    @ObservationIgnored private var lookCache: [String: Look] = [:]
    @ObservationIgnored private lazy var expectedHookPath: String? =
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("buddy-hook").path
    @ObservationIgnored let ext = ExtensionHub()
    @ObservationIgnored var director: MascotDirector?
    @ObservationIgnored var notifier: Notifier?

    private init() {
        let d = UserDefaults.standard
        mode = MascotMode(rawValue: d.string(forKey: PrefKey.mode) ?? "") ?? .perSession
        arrangement = Arrangement(rawValue: d.string(forKey: PrefKey.arrangement) ?? "") ?? .free
        walking = d.bool(PrefKey.walking, default: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        size = BuddySize(rawValue: d.string(forKey: PrefKey.size) ?? "")
            ?? (d.object(forKey: PrefKey.scale) != nil ? .migrate(scale: d.integer(forKey: PrefKey.scale)) : .medium)
        buddiesHidden = d.bool(forKey: PrefKey.buddiesHidden)
        sleepMascot = d.bool(PrefKey.sleepMascot, default: true)
        notifyPermission = d.bool(PrefKey.notifyPermission, default: true)
        notifyQuestion = d.bool(PrefKey.notifyQuestion, default: true)
        notifyDone = d.bool(PrefKey.notifyDone, default: false)
        hotkey = HotkeyChoice(rawValue: d.string(forKey: PrefKey.hotkey) ?? "") ?? .ctrlOptB
    }

    var sessions: [Session] { store.sessions.values.sorted { $0.id < $1.id } }
    var menuSessions: [Session] { SessionOrder.menu(store.sessions.values.filter { $0.state != .ended }) }
    var attentionCount: Int { store.sessions.values.filter { $0.state.needsAttention && !$0.hidden }.count }

    /// Points per sprite pixel for the main screen.
    var pointScale: CGFloat {
        CGFloat(size.pointsPerPixel(backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2)))
    }
    func session(_ id: String) -> Session? { store.sessions[id] }
    var onboarded: Bool {
        get { defaults.bool(forKey: PrefKey.onboarded) }
        set { defaults.set(newValue, forKey: PrefKey.onboarded) }
    }

    /// Newest session with an open card, for the global hotkey.
    var newestPending: Session? { store.sessions.values.filter { $0.pending != nil && !$0.hidden }.max { $0.updated < $1.updated } }

    // MARK: Start

    func start() {
        loadSprites()
        refreshHookStatus()
        ext.onChange = { [weak self] in
            guard let self else { return }
            self.editorsConnected = self.ext.connectedEditors
        }
        startServer()
        director = MascotDirector(model: self)
        director?.sync()
        Hotkey.shared.apply(hotkey)
    }

    private func loadSprites() {
        let candidates = [Bundle.main.url(forResource: "sprites", withExtension: "json"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/design/sprites.json")]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            sheetError = "sprites.json not found in the app bundle."
            log.error("sprites.json missing")
            return
        }
        do { sheet = try SpriteSheet.load(Data(contentsOf: url)) } catch {
            sheetError = "sprites.json is invalid: \(error)"
            log.error("sprites.json invalid: \(String(describing: error), privacy: .public)")
        }
        lookCache.removeAll()
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
            NSApp.terminate(nil)
            return
        }
        let srv = SocketServer(path: path)
        srv.onMessage = { [weak self] msg, conn in self?.receive(msg, from: conn) }
        srv.onClose = { [weak self] conn in self?.connectionClosed(conn) }
        do { try srv.start(); server = srv } catch {
            log.error("Socket server failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Socket messages

    private func receive(_ msg: WireMessage, from conn: Connection) {
        switch (msg, conn.role) {
        case (.hook(let h), .unknown):
            guard hookPeerAllowed(conn, h) else { log.error("Hook peer rejected"); conn.close(); return }
            conn.role = .hook
            handleHook(h, from: conn)
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
    private func hookPeerAllowed(_ conn: Connection, _ h: HookMessage) -> Bool {
        guard let pid = conn.peerPid, let expected = expectedHookPath else { return false }
        return PeerCheck.hookPeerAllowed(peerPath: PeerCheck.path(of: pid), expectedHookPath: expected,
                                         ancestors: Array(ProcInfo.ancestors(of: pid, limit: 3).dropFirst()),
                                         claudePid: h.env.claudePid)
    }

    private func handleHook(_ msg: HookMessage, from conn: Connection) {
        let sid = msg.payload["session_id"]?.string
        let before = sid.flatMap { store.sessions[$0]?.state }
        let isNew = sid.map { store.sessions[$0] == nil } ?? false
        let change = store.apply(msg)
        change.staleRequests.forEach { _ = reply($0, output: .null) }
        if let sid, isNew || msg.payload["hook_event_name"]?.string == "SessionStart" { checkClaudeApp(sid) }
        if msg.wantsReply, let sid, store.sessions[sid]?.pending?.id == msg.id {
            hookConnections[msg.id] = conn
            conn.hookRequestIds.insert(msg.id)
        } else {
            if msg.wantsReply { send(ReplyMessage(id: msg.id, output: .null), to: conn) }
            // The hook waits for this close so the peer check above could still see it (review S1).
            conn.close()
        }
        if let sid { afterChange(sid, before: before) }
        startReaper()
    }

    /// Marks a session whose claude runs under /Applications/Claude.app (Desktop without the env markers).
    private func checkClaudeApp(_ sid: String) {
        guard let pid = store.sessions[sid]?.env.claudePid else { return }
        store.setUnderClaudeApp(sid, Self.underClaudeApp(pid))
    }

    /// Only hook events create sessions; this lookup never scans for processes.
    static func underClaudeApp(_ pid: Int32) -> Bool {
        let paths = ProcInfo.ancestors(of: pid).dropFirst().compactMap(PeerCheck.path(of:))
        return TerminalApp.detect(HookEnv(), chainPaths: paths) == .claudeDesktop
    }

    private func connectionClosed(_ conn: Connection) {
        ext.closed(conn)
        for id in conn.hookRequestIds {
            hookConnections[id] = nil
            if let sid = store.requestClosed(id) { afterChange(sid, before: nil) }
        }
    }

    @discardableResult
    private func send(_ reply: ReplyMessage, to conn: Connection) -> Bool {
        do { return conn.send(try WireMessage.encode(reply)) } catch {
            log.error("Reply encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// True only if the hook connection took the reply.
    private func reply(_ requestId: String, output: JSONValue) -> Bool {
        guard let conn = hookConnections.removeValue(forKey: requestId) else { return false }
        conn.hookRequestIds.remove(requestId)
        return send(ReplyMessage(id: requestId, output: output), to: conn)
    }

    private func afterChange(_ sid: String, before: SessionState?) {
        if let s = store.sessions[sid] {
            if s.state != before { notifier?.post(for: s, model: self) }
            if s.pending == nil { notifier?.clear(sessionId: sid) }
            if s.state == .ended { scheduleRemoval(sid) }
        }
        changed()
        director?.cardChanged(sid)
    }

    func changed() { director?.sync() }

    // MARK: Reaper (runs only while there are sessions)

    private func startReaper() {
        guard reaper == nil, !store.isEmpty else { return }
        reaper = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reap() }
        }
        reaper?.tolerance = 1
    }

    private func reap() {
        guard !store.isEmpty else { reaper?.invalidate(); reaper = nil; return }
        let result = store.reap(isAlive: ProcInfo.isAlive)
        result.stale.forEach { _ = reply($0, output: .null) }
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
            if self.store.removeIfEnded(sid) { self.changed() }
        }
    }

    // MARK: Answers (never automatic: every call comes from a user click)

    /// Answers only the request the card showed (`requestId`), never whatever is pending now (review H1).
    func answer(_ sid: String, requestId: String, output: JSONValue) {
        guard store.sessions[sid]?.pending?.id == requestId, store.resolve(requestId: requestId) else {
            store.setNote(sid, "That request is no longer open, so Buddy sent nothing. It was answered in the terminal or replaced.")
            return
        }
        if !reply(requestId, output: output) {
            store.setNote(sid, "Answered in terminal. Buddy's answer was not delivered.")
        }
        notifier?.clear(sessionId: sid)
        changed()
    }

    /// "Answer in terminal": release the hook with no output; the terminal dialog is already live.
    func deferToTerminal(_ sid: String, requestId: String) {
        guard store.sessions[sid]?.pending?.id == requestId, store.resolve(requestId: requestId) else { return }
        _ = reply(requestId, output: .null)
        store.setNote(sid, "Answer in \(store.sessions[sid]?.answerPlace ?? "the terminal")")
        notifier?.clear(sessionId: sid)
        changed()
        jump(sid)
    }

    func dismissNote(_ sid: String) { store.setNote(sid, nil) }
    func showNote(_ sid: String, _ note: String) { store.setNote(sid, note); changed() }
    func setHidden(_ sid: String, _ hidden: Bool) { store.setHidden(sid, hidden); changed() }

    // MARK: Looks (cached per cwd)

    func look(for s: Session) -> Look? {
        if let hit = lookCache[s.cwd] { return hit }
        guard let sheet else { return nil }
        var look = LookPicker.pick(cwd: s.cwd, sheet: sheet)
        if let o = UserDefaults.standard.lookOverrides[s.cwd] {
            if sheet.palettes[o.palette] != nil { look.palette = o.palette }
            if o.outfit == nil || sheet.outfits[o.outfit ?? ""] != nil { look.outfit = o.outfit }
        }
        lookCache[s.cwd] = look
        return look
    }

    func setLook(cwd: String, palette: String? = nil, outfit: String?? = nil) {
        guard let sheet else { return }
        var all = UserDefaults.standard.lookOverrides
        let base = all[cwd] ?? LookPicker.pick(cwd: cwd, sheet: sheet)
        all[cwd] = Look(base: base.base, palette: palette ?? base.palette, outfit: outfit ?? base.outfit)
        UserDefaults.standard.lookOverrides = all
        lookCache.removeAll()
        director?.rebuild()
    }
}

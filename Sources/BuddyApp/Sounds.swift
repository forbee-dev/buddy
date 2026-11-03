import AppKit
import BuddyCore

/// Settings → Sounds and the player. Sounds add to the buddy, the card, and VoiceOver; they never replace them.
/// No timer: a sound held back by the rate limit plays from one short task.
@MainActor
@Observable
final class Sounds {
    static let shared = Sounds()

    var on: Bool { didSet { d.set(on, forKey: Key.on) } }
    var set: SoundSet { didSet { d.set(set.rawValue, forKey: Key.set) } }
    /// 0...1.
    var volume: Double { didSet { d.set(volume, forKey: Key.volume) } }
    var onlyWhenNotFront: Bool { didSet { d.set(onlyWhenNotFront, forKey: Key.notFront) } }
    var alsoWhenNotificationsOff: Bool { didSet { d.set(alsoWhenNotificationsOff, forKey: Key.notifOff) } }
    /// The notification's own system sound, only for events Buddy does not play itself.
    var bannerSound: Bool { didSet { d.set(bannerSound, forKey: Key.banner) } }
    private var events: [String: Bool] { didSet { d.set(events, forKey: Key.events) } }
    private var system: [String: String] { didSet { d.set(system, forKey: Key.system) } }

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var gate = SoundGate()
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: NSSound] = [:]
    /// The app found above each session's claude process, so the process walk runs once per session.
    @ObservationIgnored private var resolvedApps: [String: String] = [:]

    private enum Key {
        static let on = "sounds.on", set = "sounds.set", volume = "sounds.volume", notFront = "sounds.notFront"
        static let notifOff = "sounds.whenNotificationsOff", banner = "sounds.bannerSound", events = "sounds.events", system = "sounds.system"
    }

    private init() {
        on = d.bool(Key.on, default: true)
        set = SoundSet(rawValue: d.string(forKey: Key.set) ?? "") ?? .chiptune
        volume = SoundRules.volume(saved: d.object(forKey: Key.volume) as? Double)
        onlyWhenNotFront = d.bool(Key.notFront, default: true)
        alsoWhenNotificationsOff = d.bool(Key.notifOff, default: true)
        bannerSound = d.bool(Key.banner, default: false)
        events = d.dictionary(forKey: Key.events) as? [String: Bool] ?? [:]
        system = d.dictionary(forKey: Key.system) as? [String: String] ?? [:]
    }

    func isOn(_ e: SoundEvent) -> Bool { events[e.rawValue] ?? e.defaultOn }
    func setOn(_ e: SoundEvent, _ v: Bool) { events[e.rawValue] = v }
    func systemName(_ e: SoundEvent) -> String { SoundRules.systemName(saved: system[e.rawValue], for: e) }
    func setSystemName(_ e: SoundEvent, _ name: String) { system[e.rawValue] = name }

    /// Buddy plays this event itself (then its notification is silent).
    func plays(_ e: SoundEvent, model: AppModel) -> Bool {
        let notification: Bool? = switch e {
        case .permission: model.notifyPermission
        case .question: model.notifyQuestion
        case .done: model.notifyDone
        default: nil
        }
        return SoundRules.buddyPlays(master: on, set: set, eventOn: isOn(e), notificationOn: notification,
                                     alsoWhenNotificationsOff: alsoWhenNotificationsOff)
    }

    /// `session`: the event's session, for the "not in front" rule; nil for app-wide events.
    func play(_ e: SoundEvent, session: Session?, model: AppModel) {
        guard plays(e, model: model) else { return }
        if let s = session, onlyWhenNotFront,
           SoundRules.frontSuppresses(sessionApps: apps(s), frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                      onlyWhenNotFront: true) { return }
        switch gate.offer(e, now: Date()) {
        case .play(let p): emit(p)
        case .wait(let delay):
            waiting = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(delay))) != nil, let self, let q = self.gate.flush(now: Date()) else { return }
                self.emit(q)
            }
        case .drop: break
        }
    }

    /// The ▶︎ button: plays the chosen sound now, past the rate limit and the rules.
    func preview(_ e: SoundEvent) { emit(e) }

    private func apps(_ s: Session) -> Set<String> {
        let ids = SoundRules.appIds(s.terminal, envBundleId: s.env.bundleId)
        guard ids.isEmpty, s.remote == nil, let pid = s.env.claudePid else { return ids }
        let key = "\(s.id)#\(pid)"
        if let hit = resolvedApps[key] { return [hit] }
        guard let id = Jumper.terminalApp(above: pid)?.bundleIdentifier else { return ids }
        // shortcut: ended sessions are not removed one by one; the cache starts over past 64 entries.
        if resolvedApps.count >= 64 { resolvedApps.removeAll() }
        resolvedApps[key] = id
        return [id]
    }

    private func emit(_ e: SoundEvent) {
        guard let sound = sound(e) else { return }
        sound.stop()
        sound.volume = Float(volume)
        sound.play()
    }

    private func sound(_ e: SoundEvent) -> NSSound? {
        let key: String
        switch set {
        case .none: return nil
        case .system: key = "system:" + systemName(e)
        case .chiptune: key = "buddy:" + e.chiptune
        }
        if let hit = cache[key] { return hit }
        let s: NSSound?
        if set == .system {
            s = NSSound(named: NSSound.Name(systemName(e)))?.copy() as? NSSound
        } else {
            s = AppServices.bundledResource(e.chiptune, ext: "wav", subdirectory: "sounds", devPath: "Resources/sounds/\(e.chiptune).wav")
                .flatMap { NSSound(contentsOf: $0, byReference: true) }
        }
        if s == nil { log.error("Sound missing: \(key, privacy: .public)") }
        cache[key] = s
        return s
    }
}

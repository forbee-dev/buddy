import Foundation

/// The events Buddy can play a sound for, most important first.
public enum SoundEvent: String, CaseIterable, Sendable, Identifiable {
    case permission, question, error, done, reminder, subagentDone, digest, bee

    public var id: String { rawValue }

    /// Rate-limit rank: permission > question > error > done > the others.
    public var priority: Int {
        switch self {
        case .permission: 5
        case .question: 4
        case .error: 3
        case .done: 2
        case .reminder, .subagentDone, .digest, .bee: 1
        }
    }

    public var label: String {
        switch self {
        case .permission: "Permission needed"
        case .question: "Question asked"
        case .error: "Tool failed"
        case .done: "Session done"
        case .reminder: "Still waiting reminder"
        case .subagentDone: "Subagent done"
        case .digest: "While you were away"
        case .bee: "Bee found"
        }
    }

    public var defaultOn: Bool { self != .subagentDone }
    /// The bundled chiptune file, `Resources/sounds/<name>.wav`.
    public var chiptune: String { self == .subagentDone ? "subagent-done" : rawValue }
    public var defaultSystemSound: String {
        switch self {
        case .permission: "Glass"
        case .question: "Ping"
        case .error: "Basso"
        case .done: "Hero"
        case .reminder: "Tink"
        case .subagentDone: "Pop"
        case .digest: "Purr"
        case .bee: "Frog"
        }
    }
}

public enum SoundSet: String, CaseIterable, Sendable, Identifiable {
    case chiptune, system, none
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .chiptune: "Buddy chiptune"
        case .system: "macOS sounds"
        case .none: "None"
        }
    }
    public static let systemNames = ["Glass", "Ping", "Pop", "Tink", "Submarine", "Funk", "Hero", "Purr", "Sosumi", "Bottle", "Frog",
                                     "Morse", "Blow", "Basso"]
}

/// At most one sound per `window`. Inside the window only a more important event than the last one is kept;
/// it plays when the window ends (`flush`). Less or equally important ones are dropped.
public struct SoundGate: Sendable {
    public enum Decision: Equatable, Sendable { case play(SoundEvent), wait(TimeInterval), drop }
    public static let window: TimeInterval = 1.5
    private var lastAt: Date?
    private var lastPriority = 0
    public private(set) var queued: SoundEvent?

    public init() {}

    /// A clock that moved back counts as outside the window. Outside it, a queued event whose flush did not run yet
    /// is never lost: the more important of it and `e` plays.
    public mutating func offer(_ e: SoundEvent, now: Date) -> Decision {
        guard let last = lastAt, now >= last, now.timeIntervalSince(last) < Self.window else {
            let pick = queued.map { $0.priority > e.priority ? $0 : e } ?? e
            mark(pick, now)
            return .play(pick)
        }
        guard e.priority > max(lastPriority, queued?.priority ?? 0) else { return .drop }
        let first = queued == nil
        queued = e
        // One wake-up per window: a later, more important event only replaces the queued one.
        return first ? .wait(Self.window - now.timeIntervalSince(last)) : .drop
    }

    /// The window ended: the queued event plays now, and a new window starts.
    public mutating func flush(now: Date) -> SoundEvent? {
        guard let e = queued else { return nil }
        mark(e, now)
        return e
    }

    private mutating func mark(_ e: SoundEvent, _ now: Date) {
        lastAt = now
        lastPriority = e.priority
        queued = nil
    }
}

public enum SoundRules {
    /// Bundle ids of the app a session runs in: its own (when the hook saw it) plus the known ones for its kind.
    public static func appIds(_ terminal: TerminalApp, envBundleId: String?) -> Set<String> {
        var ids: Set<String> = envBundleId.map { [$0] } ?? []
        switch terminal {
        case .vscode: ids.formUnion(["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"])
        case .cursor: ids.insert("com.todesktop.230313mzl4w4u92")
        case .iterm: ids.insert("com.googlecode.iterm2")
        case .terminal: ids.insert("com.apple.Terminal")
        case .claudeDesktop: ids.insert(TerminalApp.desktopBundleId)
        case .other: break
        }
        return ids
    }

    /// No sound while you already look at the session's app (when that setting is on).
    public static func frontSuppresses(sessionApps: Set<String>, frontmost: String?, onlyWhenNotFront: Bool) -> Bool {
        guard onlyWhenNotFront, let frontmost else { return false }
        return sessionApps.contains(frontmost)
    }

    /// Buddy plays this event's sound itself. `notificationOn`: the event's notification setting; nil when the event has none.
    public static func buddyPlays(master: Bool, set: SoundSet, eventOn: Bool, notificationOn: Bool?, alsoWhenNotificationsOff: Bool) -> Bool {
        master && set != .none && eventOn && (notificationOn != false || alsoWhenNotificationsOff)
    }

    /// The notification's own sound: never when Buddy plays one (one sound source), else only with "Notification banner sound".
    public static func notificationHasSound(buddyPlays: Bool, bannerSound: Bool) -> Bool { !buddyPlays && bannerSound }

    /// The saved macOS sound for an event, or its default when none is saved or the name is not a known one.
    public static func systemName(saved: String?, for e: SoundEvent) -> String {
        saved.flatMap { SoundSet.systemNames.contains($0) ? $0 : nil } ?? e.defaultSystemSound
    }

    /// The saved volume clamped to 0...1; 0.6 when none is saved or it is not a finite number.
    public static func volume(saved: Double?) -> Double {
        guard let v = saved, v.isFinite else { return 0.6 }
        return min(max(v, 0), 1)
    }

    /// A subagent of the session finished with this event. `before` is nil for a session that did not exist under this id
    /// (new, or moved here by /clear or resume): its done subagents are old news.
    public static func subagentFinished(before: Session?, after: Session?) -> Bool {
        guard let before, let after else { return false }
        return !doneSubagents(after).isSubset(of: doneSubagents(before))
    }

    static func doneSubagents(_ s: Session) -> Set<String> { Set(s.subagents.values.filter { $0.state == .done }.map(\.id)) }

    /// The event a session state change sounds for.
    public static func event(for state: SessionState) -> SoundEvent? {
        switch state {
        case .needsPermission: .permission
        case .asking: .question
        case .error: .error
        case .done: .done
        default: nil
        }
    }
}

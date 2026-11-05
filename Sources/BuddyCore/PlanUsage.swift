import Foundation

/// The claude.ai plan limits from the status line's `rate_limits` (Pro, Max, and Ultra logins only).
/// One value for the whole app: the limits belong to the account, not to a session.
public struct PlanUsage: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var usedPercentage: Double
        public var resetsAt: Date
        public init(usedPercentage: Double, resetsAt: Date) { self.usedPercentage = usedPercentage; self.resetsAt = resetsAt }
    }
    public struct Spend: Sendable, Equatable {
        public var usedPercentage: Double
        public var usedUSD: Double?
        public var limitUSD: Double?
        public var period: String?
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var spend: Spend?
    public var updatedAt: Date

    public static let warnAt = 80.0, errorAt = 95.0, remindAt = 90.0

    public init(fiveHour: Window? = nil, sevenDay: Window? = nil, spend: Spend? = nil, updatedAt: Date = Date()) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.spend = spend; self.updatedAt = updatedAt
    }

    /// The `rate_limits` object. A window with a bad percentage, or a reset time in the past, is dropped.
    /// nil when no window is left: the status line JSON is a file-like input, not a trusted source.
    public static func parse(json: JSONValue, now: Date = Date()) -> PlanUsage? {
        func percent(_ v: JSONValue?) -> Double? {
            guard case .number(let n)? = v, n.isFinite else { return nil }
            return min(max(n, 0), 100)
        }
        func window(_ v: JSONValue?) -> Window? {
            guard let p = percent(v?["used_percentage"]), case .number(let t)? = v?["resets_at"], t.isFinite, t < 1e12 else { return nil }
            let at = Date(timeIntervalSince1970: t)
            return at > now ? Window(usedPercentage: p, resetsAt: at) : nil
        }
        func usd(_ v: JSONValue?) -> Double? {
            guard case .number(let n)? = v, n.isFinite, n >= 0 else { return nil }
            return n
        }
        var u = PlanUsage(fiveHour: window(json["five_hour"]), sevenDay: window(json["seven_day"]), updatedAt: now)
        if let s = json["spend_limit"], let p = percent(s["used_percentage"]) {
            u.spend = Spend(usedPercentage: p, usedUSD: usd(s["used_usd"]), limitUSD: usd(s["limit_usd"]),
                            period: s["period"]?.string.map { Activity.clip($0, 20) })
        }
        return u.isEmpty ? nil : u
    }

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil && spend == nil }

    /// Drops windows whose reset time passed. True when something changed.
    public mutating func dropExpired(now: Date = Date()) -> Bool {
        let before = self
        if let w = fiveHour, w.resetsAt <= now { fiveHour = nil }
        if let w = sevenDay, w.resetsAt <= now { sevenDay = nil }
        return self != before
    }

    /// "5h 23% · 7d 41%", or nil without a window.
    public var chip: String? {
        let parts = [fiveHour.map { "5h \(Int($0.usedPercentage.rounded()))%" }, sevenDay.map { "7d \(Int($0.usedPercentage.rounded()))%" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The highest window share: the chip's color follows it.
    public var maxPercentage: Double { max(fiveHour?.usedPercentage ?? 0, sevenDay?.usedPercentage ?? 0) }

    /// "5-hour limit 23 percent used, resets in 2 h 10 min; 7-day limit 41 percent used, resets in 3 d 2 h".
    public func spoken(now: Date = Date()) -> String? {
        let parts = [fiveHour.map { Self.spoken("5-hour", $0, now: now) }, sevenDay.map { Self.spoken("7-day", $0, now: now) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func spoken(_ name: String, _ w: Window, now: Date) -> String {
        "\(name) limit \(Int(w.usedPercentage.rounded())) percent used, resets in \(Self.resetsIn(w.resetsAt, now: now))"
    }

    /// "5h 23% · resets in 2 h 10 min" per window, one line each, for the menu.
    public func lines(now: Date = Date()) -> [String] {
        [fiveHour.map { ("5h", $0) }, sevenDay.map { ("7d", $0) }].compactMap { $0 }
            .map { "\($0.0) \(Int($0.1.usedPercentage.rounded()))% · resets in \(Self.resetsIn($0.1.resetsAt, now: now))" }
    }

    /// "3 d 2 h", "2 h 10 min", or "5 min".
    public static func resetsIn(_ at: Date, now: Date) -> String {
        let s = max(0, Int(at.timeIntervalSince(now)))
        if s >= 86400 { return "\(s / 86400) d \(s % 86400 / 3600) h" }
        if s >= 3600 { return "\(s / 3600) h \(String(format: "%02d", s % 3600 / 60)) min" }
        return "\(max(1, s / 60)) min"
    }

    /// Windows at or over `remindAt`: a key that is new for each reset, and the notification body.
    public func reminders(now: Date = Date()) -> [(key: String, text: String)] {
        [fiveHour.map { ("5-hour", $0) }, sevenDay.map { ("7-day", $0) }].compactMap { $0 }
            .filter { $0.1.usedPercentage >= Self.remindAt }
            .map { name, w in
                ("\(name)@\(Int(w.resetsAt.timeIntervalSince1970))",
                 "Plan usage: \(name) limit at \(Int(w.usedPercentage.rounded()))%. Resets in \(Self.resetsIn(w.resetsAt, now: now)).")
            }
    }
}

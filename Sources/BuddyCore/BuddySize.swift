/// Mascot size: points per sprite pixel.
public enum BuddySize: String, CaseIterable, Sendable, Identifiable {
    case tiny, small, medium, large, huge

    public var id: String { rawValue }

    public var factor: Double {
        switch self {
        case .tiny: 1
        case .small: 1.5
        case .medium: 2
        case .large: 3
        case .huge: 4
        }
    }

    public var label: String {
        switch self {
        case .tiny: "Tiny 1×"
        case .small: "Small 1.5×"
        case .medium: "Medium 2×"
        case .large: "Large 3×"
        case .huge: "Huge 4×"
        }
    }

    /// Points per sprite pixel on a screen with `backingScale`. Each sprite pixel must cover a whole number
    /// of device pixels to stay crisp: 1.5× is exact on Retina (3 px) and rounds up to 2× on 1× screens.
    public func pointsPerPixel(backingScale: Double) -> Double {
        let device = factor * max(backingScale, 1)
        return device == device.rounded() ? factor : factor.rounded(.up)
    }

    /// A subagent mini: half the buddy, rounded up to whole device pixels, never bigger than the buddy.
    /// Retina: 2× → 1, Tiny 1× → 0.5. A 1× screen: Tiny minis keep the buddy's scale.
    public func miniPointsPerPixel(backingScale: Double) -> Double {
        let b = max(backingScale, 1)
        let full = pointsPerPixel(backingScale: b)
        return min(full, (full / 2 * b).rounded(.up) / b)
    }

    /// Name tag font: grows a little with the mascot, never below 9 pt.
    public var tagFontSize: Double { min(13, max(9, 9 + factor)) }

    /// Gap between grouped mascots: 8 pt at the default 2×.
    public var groupSpacing: Double { 4 * factor }

    /// Old 2–5 integer scale setting → nearest size.
    public static func migrate(scale: Int) -> BuddySize {
        switch scale {
        case ...1: .tiny
        case 2: .medium
        case 3: .large
        default: .huge
        }
    }
}

extension SessionState {
    /// Menu order: needs attention first, then failures, finished, busy, quiet.
    public var menuRank: Int {
        switch self {
        case .needsPermission, .asking: 0
        case .error: 1
        case .done: 2
        case .working: 3
        case .starting, .idle: 4
        case .ended: 5
        }
    }
}

public enum SessionOrder {
    public static func menu(_ sessions: [Session]) -> [Session] {
        sessions.sorted {
            ($0.state.menuRank, $0.projectName.lowercased(), $0.id) < ($1.state.menuRank, $1.projectName.lowercased(), $1.id)
        }
    }
}

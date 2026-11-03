import Foundation
import CoreGraphics

/// Name-tag math for free mode. A buddy takes the width of its sprite or of its tag, whichever is wider.
public enum TagLayout {
    /// Horizontal padding inside a tag, both sides together.
    public static let padding: CGFloat = 12
    /// Space kept between two buddies' footprints.
    public static let gap: CGFloat = 6
    /// A tag cut shorter than this stacks instead (one row up).
    public static let minTruncated: CGFloat = 40

    public static func tagWidth(text: CGFloat, max cap: CGFloat) -> CGFloat { min(cap, (text + padding).rounded(.up)) }

    public static func footprint(sprite: CGFloat, tag: CGFloat) -> CGFloat { max(sprite, tag) }

    /// Center distance at which two footprints keep `gap` between them.
    public static func minDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 + gap }

    public struct Tag: Sendable, Equatable {
        public var id: String
        public var rect: CGRect
        public var priority: Int
        public init(id: String, rect: CGRect, priority: Int) { self.id = id; self.rect = rect; self.priority = priority }
    }

    public enum Fit: Sendable, Equatable {
        /// Cut to this width (ellipsis), same place.
        case truncate(CGFloat)
        /// Moved up one tag height, full width.
        case stack
    }

    /// Fixes for tags that still overlap (dragged or pinned buddies). The higher priority keeps its tag; ties go to the lower id.
    /// shortcut: one stacked row only; a third tag in the same spot can still overlap a stacked one.
    public static func resolve(_ tags: [Tag]) -> [String: Fit] {
        var placed: [CGRect] = []
        var out: [String: Fit] = [:]
        for t in tags.sorted(by: { ($0.priority, $1.id) > ($1.priority, $0.id) }) {
            let r = t.rect
            let room = placed.filter { $0.minY < r.maxY && r.minY < $0.maxY }
                .map { 2 * (abs($0.midX - r.midX) - $0.width / 2 - gap) }.min() ?? .infinity
            guard room < r.width else { placed.append(r); continue }
            if room >= minTruncated {
                out[t.id] = .truncate(room.rounded(.down))
                placed.append(CGRect(x: r.midX - room / 2, y: r.minY, width: room, height: r.height))
            } else {
                out[t.id] = .stack
                placed.append(r.offsetBy(dx: 0, dy: r.height + 2))
            }
        }
        return out
    }
}

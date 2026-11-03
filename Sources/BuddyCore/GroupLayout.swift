import Foundation
import CoreGraphics

/// Slot math for grouped mascots. Slot 0 sits at the anchor (the group's bottom-right corner);
/// later slots grow left (row) or up (stack), so existing mascots stay put when one joins.
/// A full line wraps into a second line to the left (stack) or above (row).
public struct GroupLayout: Equatable, Sendable {
    public var origins: [CGPoint]
    public var size: CGSize
    /// The requested anchor, clamped so the whole group fits inside the bounds.
    public var anchor: CGPoint

    public static let margin: CGFloat = 16

    public static func defaultAnchor(bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin)
    }

    public static func layout(count: Int, item: CGSize, spacing: CGFloat, vertical: Bool,
                              anchor: CGPoint, bounds: CGRect) -> GroupLayout {
        let n = max(0, count)
        let along = vertical ? item.height : item.width
        let room = vertical ? bounds.height : bounds.width
        let perLine = max(1, Int(((room + spacing) / (along + spacing)).rounded(.down)))
        let lines = max(1, (n + perLine - 1) / perLine)
        let inLine = max(1, min(n, perLine))
        func extent(_ k: Int, _ len: CGFloat) -> CGFloat { CGFloat(k) * len + CGFloat(k - 1) * spacing }
        let size = n == 0 ? CGSize.zero : vertical
            ? CGSize(width: extent(lines, item.width), height: extent(inLine, item.height))
            : CGSize(width: extent(inLine, item.width), height: extent(lines, item.height))
        let loX = bounds.minX + size.width
        let a = CGPoint(x: min(max(anchor.x, loX), max(bounds.maxX, loX)),
                        y: min(max(anchor.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
        let origins = (0..<n).map { i -> CGPoint in
            let line = CGFloat(i / perLine), pos = CGFloat(i % perLine)
            return vertical
                ? CGPoint(x: a.x - item.width - line * (item.width + spacing), y: a.y + pos * (item.height + spacing))
                : CGPoint(x: a.x - item.width - pos * (item.width + spacing), y: a.y + line * (item.height + spacing))
        }
        return GroupLayout(origins: origins, size: size, anchor: a)
    }
}

/// Where a bubble opens relative to its mascot in a group.
public enum BubblePlacement: Sendable {
    case left, right, above, below

    /// Opens away from the nearest screen edge, on the axis the group does not run along.
    public static func choose(sprite: CGRect, screen: CGRect, vertical: Bool) -> BubblePlacement {
        if vertical { return sprite.midX - screen.minX >= screen.maxX - sprite.midX ? .left : .right }
        return sprite.midY - screen.minY >= screen.maxY - sprite.midY ? .below : .above
    }
}

import CoreGraphics
import Testing
@testable import BuddyCore

@Suite struct GroupLayoutTests {
    let screen = CGRect(x: 0, y: 40, width: 1440, height: 800)
    let item = CGSize(width: 120, height: 100)

    func item(for size: BuddySize) -> CGSize {
        let sprite = 32 * size.factor
        return CGSize(width: max(sprite, 100 + 10 * size.factor), height: sprite + size.tagFontSize + 8 + 4)
    }

    func frames(_ l: GroupLayout, _ item: CGSize) -> [CGRect] { l.origins.map { CGRect(origin: $0, size: item) } }

    @Test func verticalSlots() {
        let l = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 1000, y: 100), bounds: screen)
        #expect(l.origins == [CGPoint(x: 880, y: 100), CGPoint(x: 880, y: 208), CGPoint(x: 880, y: 316)])
        #expect(l.size == CGSize(width: 120, height: 316))
    }

    @Test func horizontalSlots() {
        let l = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: false, anchor: CGPoint(x: 1000, y: 100), bounds: screen)
        #expect(l.origins == [CGPoint(x: 880, y: 100), CGPoint(x: 752, y: 100), CGPoint(x: 624, y: 100)])
        #expect(l.size == CGSize(width: 376, height: 100))
    }

    @Test(arguments: [BuddySize.tiny, .medium, .huge], [true, false])
    func spacingAtSizes(size: BuddySize, vertical: Bool) {
        let it = item(for: size)
        let gap = CGFloat(size.groupSpacing)
        let l = GroupLayout.layout(count: 3, item: it, spacing: gap, vertical: vertical, anchor: CGPoint(x: 1000, y: 100), bounds: screen)
        let f = frames(l, it)
        for (a, b) in zip(f, f.dropFirst()) {
            #expect(!a.intersects(b))
            #expect(vertical ? b.minY - a.maxY == gap : a.minX - b.maxX == gap)
        }
    }

    @Test func spacingIsEightAtDefaultSize() {
        #expect(BuddySize.tiny.groupSpacing == 4 && BuddySize.medium.groupSpacing == 8 && BuddySize.huge.groupSpacing == 16)
    }

    @Test func clampsIntoVisibleFrame() {
        let l = GroupLayout.layout(count: 2, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 5000, y: 5000), bounds: screen)
        #expect(l.anchor == CGPoint(x: 1440, y: 840 - 208))
        let low = GroupLayout.layout(count: 2, item: item, spacing: 8, vertical: false, anchor: CGPoint(x: -50, y: -50), bounds: screen)
        #expect(low.anchor == CGPoint(x: 248, y: 40))
        for f in frames(l, item) + frames(low, item) { #expect(screen.contains(f)) }
    }

    @Test func wrapsWhenTooLong() {
        let small = CGRect(x: 0, y: 0, width: 1000, height: 250)
        let l = GroupLayout.layout(count: 5, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 1000, y: 0), bounds: small)
        // 2 per column fit in 250 pt: 3 columns.
        #expect(l.size == CGSize(width: 376, height: 208))
        #expect(l.origins[2] == CGPoint(x: 752, y: 0))
        #expect(l.origins[4] == CGPoint(x: 624, y: 0))
        let row = GroupLayout.layout(count: 5, item: item, spacing: 8, vertical: false, anchor: CGPoint(x: 300, y: 0),
                                     bounds: CGRect(x: 0, y: 0, width: 300, height: 600))
        #expect(row.size == CGSize(width: 248, height: 316))
        #expect(row.origins[2] == CGPoint(x: 180, y: 108))
        for f in frames(l, item) + frames(row, item) { #expect(small.union(CGRect(x: 0, y: 0, width: 1000, height: 600)).contains(f)) }
    }

    @Test func orderIsByIndexAndStable() {
        let three = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 1000, y: 100), bounds: screen)
        let four = GroupLayout.layout(count: 4, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 1000, y: 100), bounds: screen)
        #expect(Array(four.origins.prefix(3)) == three.origins)
    }

    @Test func dragKeepsOffsets() {
        let a = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 800, y: 100), bounds: screen)
        let b = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 700, y: 150), bounds: screen)
        for (p, q) in zip(a.origins, b.origins) { #expect(q == CGPoint(x: p.x - 100, y: p.y + 50)) }
        let far = GroupLayout.layout(count: 3, item: item, spacing: 8, vertical: true, anchor: CGPoint(x: 9000, y: 100), bounds: screen)
        #expect(far.anchor.x == screen.maxX)
    }

    @Test func defaultAnchorIsBottomRight() {
        #expect(GroupLayout.defaultAnchor(bounds: screen) == CGPoint(x: 1424, y: 56))
    }

    @Test func bubbleOpensAwayFromNearestEdge() {
        let right = CGRect(x: 1300, y: 100, width: 64, height: 64)
        let left = CGRect(x: 20, y: 100, width: 64, height: 64)
        #expect(BubblePlacement.choose(sprite: right, screen: screen, vertical: true) == .left)
        #expect(BubblePlacement.choose(sprite: left, screen: screen, vertical: true) == .right)
        #expect(BubblePlacement.choose(sprite: right, screen: screen, vertical: false) == .above)
        let top = CGRect(x: 700, y: 760, width: 64, height: 64)
        #expect(BubblePlacement.choose(sprite: top, screen: screen, vertical: false) == .below)
    }
}

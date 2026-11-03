import Testing
@testable import BuddyCore

@Suite struct ClickActionTests {
    @Test func single() { #expect(ClickAction.decide(clickCount: 1, isDrag: false, kind: .buddy) == .openBubble) }
    @Test func double() { #expect(ClickAction.decide(clickCount: 2, isDrag: false, kind: .buddy) == .jump) }
    @Test func drag() { #expect(ClickAction.decide(clickCount: 1, isDrag: true, kind: .buddy) == .none) }
    @Test func sleeping() { #expect(ClickAction.decide(clickCount: 2, isDrag: false, kind: .sleeping) == .none) }
    @Test func miniDouble() { #expect(ClickAction.decide(clickCount: 2, isDrag: false, kind: .mini) == .jumpToParent) }
    @Test func miniSingle() { #expect(ClickAction.decide(clickCount: 1, isDrag: false, kind: .mini) == .openBubble) }
}

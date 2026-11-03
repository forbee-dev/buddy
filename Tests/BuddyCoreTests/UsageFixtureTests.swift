import Foundation
import Testing
@testable import BuddyCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct UsageFixtureTests {
    /// The test's own prices, so an edit of the bundled prices.json does not break these tests.
    let prices = PriceTable(note: nil, models: ["claude-opus-5-5": .init(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)])

    /// A real-format assistant line (values made up): the nested `output_tokens_details` must not break decoding.
    @Test func realFormatLineYieldsTotals() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Tests/Fixtures/usage-real-line.jsonl"))
        var m = UsageMeter()
        for line in data.split(separator: UInt8(ascii: "\n")) { m.count(Data(line)) }
        #expect(m.byModel["claude-opus-5-5"] == TokenCounts(input: 2, output: 258, cacheWrite: 165_293, cacheRead: 0))
        #expect(UsageFormat.line(m.byModel, prices: prices) == "165.6k tok · $1.04")
        #expect(UsageFormat.short(m.byModel, prices: prices) == "$1.04")
        #expect(UsageFormat.short(m.byModel, prices: nil) == "166k")
    }

    @Test func bundledPricesDecode() throws {
        let table = try JSONDecoder().decode(PriceTable.self, from: Data(contentsOf: repo.appendingPathComponent("Resources/prices.json")))
        #expect(!table.models.isEmpty)
    }

    @Test func shortTagForm() {
        let t = { (n: Int) in UsageFormat.short(["m": TokenCounts(input: n)], prices: nil) }
        #expect(t(950) == "950")
        #expect(t(42_100) == "42k")
        #expect(t(3_240_000) == "3.2M")
        let p = PriceTable(note: nil, models: ["m": .init(input: 1, output: 0, cacheWrite: 0, cacheRead: 0)])
        #expect(UsageFormat.short(["m": TokenCounts(input: 310_000)], prices: p) == "$0.31")
        // A model without a price: tokens, never a partial cost.
        #expect(UsageFormat.short(["m": TokenCounts(input: 1), "other": TokenCounts(input: 42_999)], prices: p) == "43k")
    }

    /// The tag rounds like the tooltip: 42,999 is "43k" next to "43.0k tok".
    @Test func shortAndTokensRoundAlike() {
        let t = { (n: Int) in (UsageFormat.short(["m": TokenCounts(input: n)], prices: nil), UsageFormat.tokens(n)) }
        #expect(t(999) == ("999", "999 tok"))
        #expect(t(1000) == ("1k", "1.0k tok"))
        #expect(t(42_999) == ("43k", "43.0k tok"))
        #expect(t(999_499) == ("999k", "999.5k tok"))
        #expect(t(999_999) == ("1.0M", "1.0M tok"))
        #expect(t(1_000_000) == ("1.0M", "1.0M tok"))
    }

    @Test func totalAndSum() {
        let a = ["m": TokenCounts(input: 1, output: 2), "n": TokenCounts(cacheRead: 3)]
        let b = ["m": TokenCounts(input: 10, cacheWrite: 5)]
        #expect(UsageFormat.total(a) == 6)
        #expect(UsageFormat.sum([a, b]) == ["m": TokenCounts(input: 11, output: 2, cacheWrite: 5), "n": TokenCounts(cacheRead: 3)])
        #expect(UsageFormat.total(["m": TokenCounts(input: .max), "n": TokenCounts(input: 1)]) == .max)
        #expect(UsageFormat.sum([]).isEmpty)
    }

    @Test func tagNeedsTheSettingAndTokens() {
        let u = ["claude-opus-5-5": TokenCounts(input: 62_000)]
        #expect(UsageFormat.tag(u, prices: prices, costOnTag: true) == "$0.31")
        #expect(UsageFormat.tag(u, prices: nil, costOnTag: true) == "62k")
        #expect(UsageFormat.tag(u, prices: prices, costOnTag: false) == nil)
        #expect(UsageFormat.tag(nil, prices: prices, costOnTag: true) == nil)
        #expect(UsageFormat.tag(["m": TokenCounts()], prices: prices, costOnTag: true) == nil)
    }

    @Test func spokenForm() {
        let u = ["claude-opus-5-5": TokenCounts(input: 42_100, output: 0)]
        #expect(UsageFormat.spoken(u, prices: nil) == "42.1 thousand tokens")
        #expect(UsageFormat.spoken(["claude-opus-5-5": TokenCounts(input: 62_000)], prices: prices) == "62 thousand tokens, 31 cents")
        #expect(UsageFormat.spoken(["claude-opus-5-5": TokenCounts(input: 200)], prices: prices) == "200 tokens, 0 cents")
        #expect(UsageFormat.spoken(["claude-opus-5-5": TokenCounts(input: 1)], prices: nil) == "1 token")
        #expect(UsageFormat.spoken(["claude-opus-5-5": TokenCounts(input: 3_240_000)], prices: prices) == "3.2 million tokens, 16.20 dollars")
        #expect(!UsageFormat.spoken(u, prices: prices).contains("tok ·"))
    }
}

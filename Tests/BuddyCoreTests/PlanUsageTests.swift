import Foundation
import Testing
@testable import BuddyCore

@Suite struct PlanUsageTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func parsesAllWindows() throws {
        let j = json(#"{"five_hour":{"used_percentage":23.5,"resets_at":1007800},"seven_day":{"used_percentage":41.2,"resets_at":1300000},"spend_limit":{"used_percentage":62.8,"used_usd":314.12,"limit_usd":500,"period":"monthly"}}"#)
        let u = try #require(PlanUsage.parse(json: j, now: now))
        #expect(u.fiveHour == PlanUsage.Window(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: 1_007_800)))
        #expect(u.sevenDay?.usedPercentage == 41.2)
        #expect(u.spend?.usedUSD == 314.12 && u.spend?.limitUSD == 500 && u.spend?.period == "monthly")
        #expect(u.chip == "5h 24% · 7d 41%")
        #expect(u.spoken(now: now) == "5-hour limit 24 percent used, resets in 2 h 10 min; 7-day limit 41 percent used, resets in 3 d 11 h")
        #expect(u.lines(now: now) == ["5h 24% · resets in 2 h 10 min", "7d 41% · resets in 3 d 11 h"])
        #expect(u.reminders(now: now).isEmpty)
    }

    @Test func clampsAndDropsBadWindows() {
        // Over 100, negative, not a number, expired, and non-finite: kept clamped or dropped.
        let j = json(#"{"five_hour":{"used_percentage":140,"resets_at":1007800},"seven_day":{"used_percentage":50,"resets_at":999999}}"#)
        let u = PlanUsage.parse(json: j, now: now)
        #expect(u?.fiveHour?.usedPercentage == 100)
        #expect(u?.sevenDay == nil)
        #expect(PlanUsage.parse(json: json(#"{"five_hour":{"used_percentage":-5,"resets_at":1007800}}"#), now: now)?.fiveHour?.usedPercentage == 0)
        #expect(PlanUsage.parse(json: json(#"{"five_hour":{"used_percentage":"23","resets_at":1007800}}"#), now: now) == nil)
        #expect(PlanUsage.parse(json: json(#"{"five_hour":{"used_percentage":23}}"#), now: now) == nil)
        #expect(PlanUsage.parse(json: json(#"{"five_hour":{"used_percentage":23,"resets_at":1e300}}"#), now: now) == nil)
        #expect(PlanUsage.parse(json: json(#"{"other":1}"#), now: now) == nil)
        #expect(PlanUsage.parse(json: .string("x"), now: now) == nil)
    }

    @Test func expiredWindowsDropOnTheTimer() {
        var u = PlanUsage(fiveHour: .init(usedPercentage: 10, resetsAt: now.addingTimeInterval(60)),
                          sevenDay: .init(usedPercentage: 20, resetsAt: now.addingTimeInterval(600)), updatedAt: now)
        let same = u.dropExpired(now: now)
        #expect(!same)
        let first = u.dropExpired(now: now.addingTimeInterval(61))
        #expect(first && u.fiveHour == nil && u.sevenDay != nil)
        let second = u.dropExpired(now: now.addingTimeInterval(601))
        #expect(second && u.isEmpty && u.chip == nil)
    }

    @Test func remindersOncePerWindowAndReset() {
        let u = PlanUsage(fiveHour: .init(usedPercentage: 92, resetsAt: now.addingTimeInterval(3900)),
                          sevenDay: .init(usedPercentage: 89.9, resetsAt: now.addingTimeInterval(86400)), updatedAt: now)
        let r = u.reminders(now: now)
        #expect(r.map(\.key) == ["5-hour@\(1_000_000 + 3900)"])
        #expect(r.first?.text == "Plan usage: 5-hour limit at 92%. Resets in 1 h 05 min.")
        #expect(u.maxPercentage == 92)
        #expect(PlanUsage.resetsIn(now.addingTimeInterval(30), now: now) == "1 min")
    }
}

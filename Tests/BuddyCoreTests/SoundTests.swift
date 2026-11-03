import Foundation
import Testing
@testable import BuddyCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct SoundTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func priorityOrder() {
        let order: [SoundEvent] = [.permission, .question, .error, .done]
        #expect(zip(order, order.dropFirst()).allSatisfy { $0.priority > $1.priority })
        for e in [SoundEvent.reminder, .subagentDone, .digest, .bee] { #expect(e.priority < SoundEvent.done.priority) }
    }

    @Test func rateLimitOneSoundPerWindow() {
        var g = SoundGate()
        #expect(g.offer(.done, now: t0) == .play(.done))
        // Less or equally important inside the window: dropped.
        #expect(g.offer(.done, now: t0.addingTimeInterval(0.5)) == .drop)
        #expect(g.offer(.subagentDone, now: t0.addingTimeInterval(0.6)) == .drop)
        #expect(g.queued == nil)
        // After the window: plays at once.
        #expect(g.offer(.subagentDone, now: t0.addingTimeInterval(1.5)) == .play(.subagentDone))
    }

    @Test func mostImportantWins() {
        var g = SoundGate()
        #expect(g.offer(.done, now: t0) == .play(.done))
        // More important: waits for the end of the window (one wake-up), and a later, still more important one replaces it.
        #expect(g.offer(.error, now: t0.addingTimeInterval(0.5)) == .wait(1.0))
        #expect(g.offer(.question, now: t0.addingTimeInterval(0.7)) == .drop)
        #expect(g.offer(.error, now: t0.addingTimeInterval(0.8)) == .drop)
        #expect(g.offer(.permission, now: t0.addingTimeInterval(0.9)) == .drop)
        #expect(g.queued == .permission)
        #expect(g.flush(now: t0.addingTimeInterval(1.5)) == .permission)
        #expect(g.flush(now: t0.addingTimeInterval(1.6)) == nil)
        // The flushed sound starts a new window.
        #expect(g.offer(.question, now: t0.addingTimeInterval(2.0)) == .drop)
        #expect(g.offer(.done, now: t0.addingTimeInterval(3.0)) == .play(.done))
    }

    /// The window ended before the flush ran: the queued permission is never dropped for a less important event.
    @Test func queuedEventSurvivesALateFlush() {
        var g = SoundGate()
        #expect(g.offer(.done, now: t0) == .play(.done))
        #expect(g.offer(.permission, now: t0.addingTimeInterval(0.5)) == .wait(1.0))
        #expect(g.offer(.subagentDone, now: t0.addingTimeInterval(1.6)) == .play(.permission))
        #expect(g.queued == nil)
        #expect(g.flush(now: t0.addingTimeInterval(1.7)) == nil)
        // A more important new event wins over the queued one.
        var h = SoundGate()
        _ = h.offer(.done, now: t0)
        _ = h.offer(.error, now: t0.addingTimeInterval(0.5))
        #expect(h.offer(.permission, now: t0.addingTimeInterval(2)) == .play(.permission))
    }

    /// A clock set back counts as outside the window: the sound plays instead of waiting for a window that never ends.
    @Test func clockMovedBackPlays() {
        var g = SoundGate()
        #expect(g.offer(.done, now: t0) == .play(.done))
        #expect(g.offer(.done, now: t0.addingTimeInterval(-3600)) == .play(.done))
        #expect(g.offer(.error, now: t0.addingTimeInterval(-3599)) == .wait(0.5))
    }

    @Test func systemNameFallbackAndVolumeClamp() {
        #expect(SoundRules.systemName(saved: "Funk", for: .done) == "Funk")
        #expect(SoundRules.systemName(saved: nil, for: .done) == "Hero")
        #expect(SoundRules.systemName(saved: "../../evil", for: .permission) == "Glass")
        #expect(SoundRules.systemName(saved: "", for: .bee) == "Frog")
        #expect(SoundRules.volume(saved: nil) == 0.6)
        #expect(SoundRules.volume(saved: 0.25) == 0.25)
        #expect(SoundRules.volume(saved: -1) == 0 && SoundRules.volume(saved: 7) == 1)
        #expect(SoundRules.volume(saved: .nan) == 0.6 && SoundRules.volume(saved: .infinity) == 0.6)
    }

    /// /clear and resume move a session with its done subagents to a new id: no "subagent done" sound for them.
    @Test func subagentFinishedOnlyForANewDoneOne() {
        var s = SessionStore()
        _ = s.apply(hook("SessionStart"))
        _ = s.apply(hook("SubagentStart", extra: ["agent_id": "a1", "agent_type": "general"]))
        let running = s.sessions["s1"]
        _ = s.apply(hook("SubagentStop", extra: ["agent_id": "a1"]))
        let done = s.sessions["s1"]
        #expect(SoundRules.subagentFinished(before: running, after: done))
        #expect(!SoundRules.subagentFinished(before: done, after: done))
        // Rekey: same claude pid, new session id. The new id has no "before".
        _ = s.apply(hook("SessionStart", session: "s2"))
        let moved = s.sessions["s2"]
        #expect(moved?.subagents["a1"]?.state == .done)
        #expect(!SoundRules.subagentFinished(before: s.sessions["nope"], after: moved))
        #expect(!SoundRules.subagentFinished(before: nil, after: nil))
    }

    @Test func frontmostAppSuppresses() {
        let iterm = SoundRules.appIds(.iterm, envBundleId: nil)
        #expect(SoundRules.frontSuppresses(sessionApps: iterm, frontmost: "com.googlecode.iterm2", onlyWhenNotFront: true))
        #expect(!SoundRules.frontSuppresses(sessionApps: iterm, frontmost: "com.googlecode.iterm2", onlyWhenNotFront: false))
        #expect(!SoundRules.frontSuppresses(sessionApps: iterm, frontmost: "com.apple.Safari", onlyWhenNotFront: true))
        #expect(!SoundRules.frontSuppresses(sessionApps: iterm, frontmost: nil, onlyWhenNotFront: true))
        #expect(!SoundRules.frontSuppresses(sessionApps: [], frontmost: "com.apple.Terminal", onlyWhenNotFront: true))
        #expect(SoundRules.appIds(.vscode, envBundleId: nil).contains("com.microsoft.VSCodeInsiders"))
        #expect(SoundRules.appIds(.claudeDesktop, envBundleId: nil) == [TerminalApp.desktopBundleId])
        #expect(SoundRules.appIds(.other("WezTerm"), envBundleId: "com.github.wez.wezterm") == ["com.github.wez.wezterm"])
        #expect(SoundRules.appIds(.other("WezTerm"), envBundleId: nil).isEmpty)
    }

    @Test func buddyPlaysRules() {
        func plays(master: Bool = true, set: SoundSet = .chiptune, on: Bool = true, notif: Bool? = true, alsoOff: Bool = true) -> Bool {
            SoundRules.buddyPlays(master: master, set: set, eventOn: on, notificationOn: notif, alsoWhenNotificationsOff: alsoOff)
        }
        #expect(plays())
        #expect(plays(set: .system))
        #expect(!plays(master: false))
        #expect(!plays(set: .none))
        #expect(!plays(on: false))
        #expect(plays(notif: false))
        #expect(!plays(notif: false, alsoOff: false))
        #expect(plays(notif: nil, alsoOff: false))
        #expect(!SoundEvent.subagentDone.defaultOn && SoundEvent.permission.defaultOn)
    }

    /// One sound source: Buddy's own sound makes the notification silent.
    @Test func notificationSoundIsNilWhenBuddyPlays() {
        #expect(!SoundRules.notificationHasSound(buddyPlays: true, bannerSound: true))
        #expect(!SoundRules.notificationHasSound(buddyPlays: true, bannerSound: false))
        #expect(!SoundRules.notificationHasSound(buddyPlays: false, bannerSound: false))
        #expect(SoundRules.notificationHasSound(buddyPlays: false, bannerSound: true))
        #expect(SoundRules.event(for: .needsPermission) == .permission && SoundRules.event(for: .asking) == .question)
        #expect(SoundRules.event(for: .error) == .error && SoundRules.event(for: .done) == .done && SoundRules.event(for: .working) == nil)
    }

    /// Every chiptune file exists and has a valid 16-bit mono PCM header, at most 0.4 s.
    @Test func chiptuneWavHeaders() throws {
        for e in SoundEvent.allCases {
            let d = try Data(contentsOf: repo.appendingPathComponent("Resources/sounds/\(e.chiptune).wav"))
            func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
            func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
            func tag(_ o: Int) -> String { String(decoding: d[o..<o + 4], as: UTF8.self) }
            #expect(d.count > 44, "\(e)")
            #expect(tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && tag(36) == "data", "\(e)")
            #expect(u32(4) == d.count - 8 && u32(40) == d.count - 44, "\(e)")
            #expect(u16(20) == 1 && u16(22) == 1 && u16(34) == 16 && u16(32) == 2, "\(e)")
            let rate = u32(24)
            #expect(rate > 0 && u32(28) == rate * 2, "\(e)")
            #expect(Double(u32(40)) / 2 / Double(max(rate, 1)) <= 0.4, "\(e)")
        }
    }
}

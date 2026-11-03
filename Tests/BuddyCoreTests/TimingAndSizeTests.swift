import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct TimingAndSizeTests {
    @Test func tickPolicy() { // P1
        #expect(TickPolicy.interval(mascots: 0, moving: false, fps: 8, paused: false) == nil)
        #expect(TickPolicy.interval(mascots: 0, moving: true, fps: 8, paused: false) == nil)
        #expect(TickPolicy.interval(mascots: 2, moving: false, fps: 8, paused: true) == nil)
        #expect(TickPolicy.interval(mascots: 2, moving: false, fps: 8, paused: false) == 1.0 / 8)
        #expect(TickPolicy.interval(mascots: 2, moving: true, fps: 8, paused: false) == 1.0 / 30)
    }

    @Test func sizeMath() { // Phase 3
        #expect(BuddySize.small.pointsPerPixel(backingScale: 2) == 1.5)  // 3 device px per sprite px
        #expect(BuddySize.small.pointsPerPixel(backingScale: 1) == 2)    // rounded on 1× screens
        #expect(BuddySize.tiny.pointsPerPixel(backingScale: 1) == 1)
        #expect(BuddySize.huge.pointsPerPixel(backingScale: 2) == 4)
        for size in BuddySize.allCases {
            let device = size.pointsPerPixel(backingScale: 2) * 2
            #expect(device == device.rounded())
            #expect(size.tagFontSize >= 9)
        }
        #expect(BuddySize.migrate(scale: 3) == .large && BuddySize.migrate(scale: 5) == .huge)
    }

    @Test func menuOrderAttentionFirst() { // Phase 3
        var s = SessionStore()
        let states: [(String, String, [String: JSONValue])] = [
            ("a", "Stop", [:]), ("b", "UserPromptSubmit", [:]), ("c", "PermissionRequest", ["tool_name": "Bash"]),
            ("d", "SessionStart", [:]), ("e", "PostToolUseFailure", ["tool_name": "Bash"]),
        ]
        for (i, st) in states.enumerated() {
            _ = s.apply(hook(st.1, session: st.0, pid: Int32(200 + i), extra: st.2.merging(["cwd": .string("/p/\(st.0)")]) { $1 }))
        }
        #expect(SessionOrder.menu(Array(s.sessions.values)).map(\.id) == ["c", "e", "a", "b", "d"])
    }

    @Test func silhouetteOutline() {
        let rgba: [UInt8] = (0..<16).flatMap { i -> [UInt8] in
            let x = i % 4, y = i / 4
            return (1...3).contains(x) && (1...3).contains(y) ? [9, 9, 9, 255] : [0, 0, 0, 0]
        }
        let frame = RenderedFrame(width: 4, height: 4, rgba: rgba, missing: [])
        let full = Silhouette.mask(frame, outlineOnly: false)
        #expect(full.width == 5 && full.height == 5 && full.on.filter { $0 }.count == 9)
        #expect(Silhouette.mask(frame, outlineOnly: true).on.filter { $0 }.count == 8)
    }
}

@Suite struct IdleTickTests {
    @Test func sleepingAloneNeedsNoTimer() {
        #expect(TickPolicy.interval(mascots: 1, moving: false, fps: 8, paused: false, idle: true) == nil)
        #expect(TickPolicy.interval(mascots: 1, moving: false, fps: 8, paused: false, idle: false) == 1.0 / 8)
        // Something moves: the timer runs, idle or not.
        #expect(TickPolicy.interval(mascots: 1, moving: true, fps: 8, paused: false, idle: true) == 1.0 / 30)
    }
}

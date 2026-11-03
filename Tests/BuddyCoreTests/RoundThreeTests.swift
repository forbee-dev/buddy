import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct StoreReleaseTests {
    @Test func rekeyReleasesPending() { // C1
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", session: "old", id: "r", pid: 7, extra: ["tool_name": "Bash"]))
        let c = s.apply(hook("SessionStart", session: "new", pid: 7, extra: ["source": "clear"]))
        #expect(c.staleRequests == ["r"])
        #expect(s.sessions["new"]?.pending == nil)
    }

    @Test func reapReleasesPending() { // C1
        var s = SessionStore()
        _ = s.apply(hook("PermissionRequest", id: "r", pid: 7, extra: ["tool_name": "Bash"]))
        let r = s.reap { _ in false }
        #expect(r.ended == ["s1"] && r.stale == ["r"])
    }

    @Test func parallelBashMatchesToolUseId() { // C3
        var s = SessionStore()
        _ = s.apply(toolHook("PermissionRequest", id: "A", useId: "use-a"))
        let replaced = s.apply(toolHook("PermissionRequest", id: "B", useId: "use-b"))
        #expect(replaced.staleRequests == ["A"])
        let otherTool = s.apply(toolHook("PostToolUse", useId: "use-a"))
        #expect(otherTool.staleRequests.isEmpty)
        #expect(s.sessions["s1"]?.pending?.id == "B")
        let denied = s.apply(toolHook("PermissionDenied", useId: "use-a"))
        #expect(denied.staleRequests.isEmpty && s.sessions["s1"]?.pending?.id == "B")
        let own = s.apply(toolHook("PostToolUseFailure", useId: "use-b"))
        #expect(own.staleRequests == ["B"])
        // No tool_use_id on either side: fall back to the tool name.
        _ = s.apply(hook("PermissionRequest", id: "C", extra: ["tool_name": "Bash"]))
        let byName = s.apply(hook("PostToolUse", extra: ["tool_name": "Bash"]))
        #expect(byName.staleRequests == ["C"])
    }

    @Test func endedSessionIgnoresAllButSessionStart() { // C4
        var s = SessionStore()
        _ = s.apply(hook("SessionEnd", extra: ["reason": "logout"]))
        #expect(s.sessions["s1"]?.state == .ended)
        _ = s.apply(hook("Stop"))
        #expect(s.sessions["s1"]?.state == .ended)
        _ = s.apply(hook("SessionStart"))
        #expect(s.sessions["s1"]?.state == .starting)
        let revived = s.removeIfEnded("s1")
        #expect(!revived)
        _ = s.apply(hook("SessionEnd", extra: ["reason": "logout"]))
        let removed = s.removeIfEnded("s1")
        #expect(removed && s.sessions["s1"] == nil)
    }

    @Test func sessionStartFromOtherPidOnlyIfOldIsDead() { // Low: env takeover
        var s = SessionStore()
        _ = s.apply(hook("SessionStart", pid: 10))
        _ = s.apply(hook("SessionStart", pid: 11), isAlive: { _ in true })
        #expect(s.sessions["s1"]?.env.claudePid == 10)
        _ = s.apply(hook("SessionStart", pid: 11), isAlive: { $0 != 10 })
        #expect(s.sessions["s1"]?.env.claudePid == 11)
    }
}

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

@Suite struct HardeningTests {
    @Test func installerOnlyMatchesQuotedForm() { // Low: isOurs
        let path = "/A/Buddy.app/Contents/MacOS/buddy-hook"
        #expect(HookInstaller.isOurs(HookInstaller.command(for: path), hookPath: path))
        #expect(!HookInstaller.isOurs(path, hookPath: path))
        #expect(!HookInstaller.isOurs(path + " --evil", hookPath: path))
    }

    @Test func inboxFolderMustNotBeWritableByOthers() throws { // Low
        let dir = PeerCheck.resolved(NSTemporaryDirectory()) + "/bgw-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sock = dir + "/a.sock"
        let fd = try UnixSocket.listen(sock)
        defer { close(fd) }
        chmod(dir, 0o777)
        #expect(throws: SocketError.self) { try InboxClient.checkSocketFile(sock) }
        chmod(dir, 0o1777)
        try InboxClient.checkSocketFile(sock)
        chmod(dir, 0o700)
        try InboxClient.checkSocketFile(sock)
    }

    @Test func descendsUsesAncestors() {
        #expect(ProcInfo.descends(getpid(), from: getpid()))
        #expect(ProcInfo.descends(getpid(), from: getppid()))
        #expect(!ProcInfo.descends(getppid(), from: getpid()))
        #expect(ProcInfo.info(of: getpid())?.ppid == getppid())
        #expect(ProcInfo.info(of: 999_999) == nil)
    }
}

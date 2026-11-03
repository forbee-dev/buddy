import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct ProjectNameTests {
    @Test func projectNamesAreRevealedAndClipped() {
        var store = SessionStore()
        var msg = hook("SessionStart", session: "l1")
        msg.payload = .object(["session_id": "l1", "hook_event_name": "SessionStart", "cwd": .string("/tmp/evil\u{202E}txt.exe" + String(repeating: "x", count: 80))])
        _ = store.apply(msg, isAlive: { _ in true })
        let name = store.sessions["l1"]?.projectName ?? ""
        #expect(name.hasPrefix("evil\\u{202E}txt.exe") && !name.contains("\u{202E}"))
        #expect(name.count == RemoteInfo.maxLength + 1 && name.hasSuffix("…"))

        let origin = RemoteOrigin(host: "devbox", user: "u", sshPid: 900, claudePid: 1)
        var remote = hook("SessionStart", session: "r1", pid: nil)
        remote.payload = .object(["session_id": "r1", "hook_event_name": "SessionStart", "cwd": .string("/home/u/a\u{200B}pi")])
        _ = store.apply(remote, origin: origin, isAlive: { _ in true })
        #expect(store.sessions["r1"]?.projectName == "devbox:a\\u{200B}pi")
    }
}

@Suite struct PeerTokenTests {
    @Test func tokenNamesThisProcess() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let token = try #require(PeerCheck.peerToken(fds[0]))
        #expect(PeerCheck.pid(of: token) == getpid())
        #expect(PeerCheck.path(ofToken: token) == PeerCheck.path(of: getpid()))
        // A token whose pidversion is off names no live process.
        var stale = token
        stale.val.7 &+= 1
        #expect(PeerCheck.path(ofToken: stale) == nil)
    }

    @Test func savedClientsKeepOnlySSHBinaries() {
        #expect(RemoteAuth.savedClients(["/opt/homebrew/bin/ssh", "/bin/sh", "ssh", "/tmp/ssh/evil", "/usr/local/bin/ssh"])
                == ["/opt/homebrew/bin/ssh", "/usr/local/bin/ssh"])
    }
}

@Suite struct TextFieldKeyTests {
    /// Review L1: ⌘⌫ in the palette search (or any text field) edits text, never denies the open card.
    @Test func commandDeleteStaysInATextField() {
        #expect(TextFieldKeys.keepInField(keyCode: TextFieldKeys.delete, command: true, textFocused: true))
        #expect(!TextFieldKeys.keepInField(keyCode: TextFieldKeys.delete, command: true, textFocused: false))
        #expect(!TextFieldKeys.keepInField(keyCode: TextFieldKeys.delete, command: false, textFocused: true))
        #expect(!TextFieldKeys.keepInField(keyCode: 36, command: true, textFocused: true))
    }
}

@Suite struct SafeFileTests {
    @Test func symlinkedFolderResolvesButSymlinkedFileIsRefused() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("buddy-safe-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/real/f.json", contents: Data("{}".utf8))
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        try fm.createSymbolicLink(atPath: root + "/real/l.json", withDestinationPath: root + "/real/f.json")
        #expect(SafeFile.contents(root + "/link/f.json", maxBytes: 10) == Data("{}".utf8))
        #expect(SafeFile.contents(root + "/real/l.json", maxBytes: 10) == nil)
        #expect(SafeFile.contents(root + "/real/f.json", maxBytes: 10, uid: getuid() + 1) == nil)
        #expect(SafeFile.contents(root + "/real/f.json", maxBytes: 10, uid: nil) != nil)
        #expect(SafeFile.contents(root + "/real/..", maxBytes: 10) == nil)
    }
}

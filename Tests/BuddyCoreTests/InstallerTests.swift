import Foundation
import Testing
@testable import BuddyCore

@Suite struct InstallerTests {
    let path = "/Applications/Buddy.app/Contents/MacOS/buddy-hook"


    @Test func emptyFileGetsAllEvents() throws {
        let out = try obj(HookInstaller.install(settings: nil, hookPath: path))
        let hooks = try #require(out["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookInstaller.specs.map(\.event)))
        let perm = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(perm.first?["timeout"] as? Int == 3600)
        let pre = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] as? String == "AskUserQuestion|Agent|Task")
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop.first?["timeout"] as? Int == 5)
    }

    @Test func preservesUserKeysAndHooks() throws {
        let user = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"Foo":[{"hooks":[{"type":"command","command":"x"}]}]}}"#
        let out = try obj(HookInstaller.install(settings: Data(user.utf8), hookPath: path))
        #expect(out["model"] as? String == "opus")
        let hooks = try #require(out["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect(hooks["Foo"] != nil)
    }

    @Test func idempotent() throws {
        let first = try #require(try HookInstaller.install(settings: Data(#"{"a":1}"#.utf8), hookPath: path))
        #expect(try HookInstaller.install(settings: first, hookPath: path) == nil)
    }

    @Test func uninstallRemovesOnlyOurs() throws {
        let user = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"x":true}"#
        let installed = try #require(try HookInstaller.install(settings: Data(user.utf8), hookPath: path))
        let removed = try obj(HookInstaller.uninstall(settings: installed, hookPath: path))
        #expect(NSDictionary(dictionary: removed).isEqual(to: try obj(Data(user.utf8))))
        #expect(try HookInstaller.uninstall(settings: Data(user.utf8), hookPath: path) == nil)
    }

    @Test func invalidJSONRefused() throws {
        #expect(throws: HookInstallerError.self) { try HookInstaller.install(settings: Data("{nope".utf8), hookPath: path) }
        #expect(throws: HookInstallerError.notAnObject) { try HookInstaller.install(settings: Data("[1]".utf8), hookPath: path) }
    }

    @Test func fileApplyWritesBackupAndRefusesInvalid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: url)
        let result = try HookInstaller.apply(install: true, settingsURL: url, hookPath: path)
        guard case .written(let backup?) = result else { Issue.record("no backup"); return }
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == #"{"model":"opus"}"#)
        #expect(try HookInstaller.apply(install: true, settingsURL: url, hookPath: path) == .unchanged)
        #expect(HookInstaller.isInstalled(settingsURL: url, hookPath: path))

        try Data("{broken".utf8).write(to: url)
        #expect(throws: HookInstallerError.self) { try HookInstaller.apply(install: true, settingsURL: url, hookPath: path) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{broken")
    }
}

@Suite struct InstallerHardeningTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-inst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func symlinkedSettingsStaysALink() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: target)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try HookInstaller.apply(install: true, settingsURL: link, hookPath: "/x/Contents/MacOS/buddy-hook")
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try obj(Data(contentsOf: target))["hooks"] != nil)
    }

    @Test func missingClaudeFolderIsCreated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".claude/settings.json")
        let r = try HookInstaller.apply(install: true, settingsURL: url, hookPath: "/x/Contents/MacOS/buddy-hook")
        #expect(r == .written(backup: nil))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func mixedGroupUninstallKeepsTheUserHandler() throws {
        let cmd = HookInstaller.command(for: "/x/Contents/MacOS/buddy-hook")
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"], ["type": "command", "command": cmd]]]]]]
        let data = try JSONSerialization.data(withJSONObject: settings)
        let out = try obj(HookInstaller.uninstall(settings: data, hookPath: "/x/Contents/MacOS/buddy-hook"))
        let stop = try #require((out["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let handlers = try #require(stop.first?["hooks"] as? [[String: Any]])
        #expect(stop.count == 1 && handlers.count == 1)
        #expect(handlers.first?["command"] as? String == "say done")
    }

    @Test func pathAlwaysQuoted() throws { // L3
        let path = "/Users/o'neil/Apps/Buddy.app/Contents/MacOS/buddy-hook"
        #expect(HookInstaller.command(for: path) == #"'/Users/o'\''neil/Apps/Buddy.app/Contents/MacOS/buddy-hook'"#)
        #expect(HookInstaller.unquoted(HookInstaller.command(for: path)) == path)
        let out = try obj(HookInstaller.install(settings: nil, hookPath: path))
        let stop = (out["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == HookInstaller.command(for: path))
    }

    @Test func movedAppStillUninstallsAndReinstallsCleanly() throws { // L3
        let old = try #require(try HookInstaller.install(settings: nil, hookPath: "/Applications/Buddy.app/Contents/MacOS/buddy-hook"))
        let moved = "/Users/me/Desktop/Buddy.app/Contents/MacOS/buddy-hook"
        let removed = try obj(HookInstaller.uninstall(settings: old, hookPath: moved))
        #expect((removed["hooks"] as? [String: Any])?.isEmpty == true)
        let re = try obj(HookInstaller.install(settings: old, hookPath: moved))
        let stop = try #require((re["hooks"] as? [String: Any])?["Stop"] as? [Any])
        #expect(stop.count == 1)
    }

    @Test func wrongShapeRefused() { // L3
        #expect(throws: HookInstallerError.unexpectedShape("hooks")) {
            try HookInstaller.install(settings: Data(#"{"hooks":[1]}"#.utf8), hookPath: "/a/Contents/MacOS/buddy-hook")
        }
        #expect(throws: HookInstallerError.unexpectedShape("hooks.Stop")) {
            try HookInstaller.install(settings: Data(#"{"hooks":{"Stop":"x"}}"#.utf8), hookPath: "/a/Contents/MacOS/buddy-hook")
        }
    }

    @Test func backupsPrivateAndPruned() throws { // L4
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-bk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        for i in 0..<8 {
            try Data(#"{"n":\#(i)}"#.utf8).write(to: url)
            let r = try HookInstaller.apply(install: true, settingsURL: url, hookPath: "/x/Contents/MacOS/buddy-hook",
                                            now: Date(timeIntervalSince1970: Double(i)))
            guard case .written(let b?) = r else { Issue.record("no backup"); return }
            let mode = try FileManager.default.attributesOfItem(atPath: b)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("buddy-backup") }
        #expect(backups.count == HookInstaller.backupsKept)
    }
}

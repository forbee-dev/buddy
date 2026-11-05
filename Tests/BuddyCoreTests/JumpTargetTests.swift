import Testing
import Foundation
@testable import BuddyCore

struct JumpTargetTests {
    private func w(_ folders: [String], _ file: String? = nil) -> JumpTarget.Window { .init(folders: folders, workspaceFile: file) }

    @Test func workspaceFileIsTheCliTarget() {
        let p = JumpTarget.pick(owner: w(["/a", "/b"], "/ws/x.code-workspace"), all: [], cwd: "/b/src")
        #expect(p.folder == "/b" && p.workspaceFile == "/ws/x.code-workspace" && p.cliTarget == "/ws/x.code-workspace")
    }

    @Test func multiRootWithoutFileHasNoCliTarget() {
        let p = JumpTarget.pick(owner: nil, all: [w(["/a", "/b"])], cwd: "/b/src")
        #expect(p.isOpen && p.workspaceFile == nil && p.cliTarget == nil)
    }

    @Test func singleFolderIsTheCliTarget() {
        #expect(JumpTarget.pick(owner: w(["/a"]), all: [], cwd: "/a/x").cliTarget == "/a")
    }

    @Test func workspaceFileValidated() {
        #expect(JumpTarget.validWorkspaceFile("/ws/x.code-workspace") == "/ws/x.code-workspace")
        #expect(JumpTarget.validWorkspaceFile("ws/x.code-workspace") == nil)
        #expect(JumpTarget.validWorkspaceFile("/ws/x.json") == nil)
        #expect(JumpTarget.validWorkspaceFile("/ws/\0.code-workspace") == nil)
        #expect(JumpTarget.validWorkspaceFile("/" + String(repeating: "a", count: 1024) + ".code-workspace") == nil)
        #expect(JumpTarget.validWorkspaceFile(nil) == nil)
    }

    @Test func workspaceFileDecodes() throws {
        let h = #"{"kind":"ext-hello","editor":"cursor","appPid":5,"version":"0.1.5","terminals":[],"workspaceFile":"/ws/x.code-workspace"}"#
        guard case .extHello(let m) = try WireMessage.decode(Data(h.utf8)) else { Issue.record("not hello"); return }
        #expect(m.workspaceFile == "/ws/x.code-workspace")
        let t = #"{"kind":"ext-terminals","terminals":[]}"#
        guard case .extTerminals(let m2) = try WireMessage.decode(Data(t.utf8)) else { Issue.record("not terminals"); return }
        #expect(m2.workspaceFile == nil)
    }

    @Test func ownerClientWins() {
        let p = JumpTarget.pick(owner: w(["/a/app"]), all: [w(["/a/app"]), w(["/b"])], cwd: "/b/x")
        #expect(p.folder == "/a/app" && p.isOpen)
    }

    @Test func ownerPrefersFolderHoldingCwd() {
        let p = JumpTarget.pick(owner: w(["/w/one", "/w/two"]), all: [], cwd: "/w/two/src")
        #expect(p.folder == "/w/two")
    }

    @Test func prefixMatchAcrossClients() {
        let p = JumpTarget.pick(owner: nil, all: [w(["/p/one"]), w(["/p/two"])], cwd: "/p/two/sub/dir")
        #expect(p.folder == "/p/two" && p.isOpen)
    }

    @Test func longestPrefixWins() {
        let p = JumpTarget.pick(owner: nil, all: [w(["/p"]), w(["/p/mono/pkg"]), w(["/p/mono"])], cwd: "/p/mono/pkg/src")
        #expect(p.folder == "/p/mono/pkg")
    }

    @Test func prefixIsPathComponentAware() {
        let p = JumpTarget.pick(owner: nil, all: [w(["/p/app"])], cwd: "/p/app2/x")
        #expect(p.folder == "/p/app2/x" && !p.isOpen)
    }

    @Test func cwdFallback() {
        #expect(JumpTarget.pick(owner: w([]), all: [], cwd: "/x/y") == .init(folder: "/x/y", isOpen: false, workspaceFile: nil, cliTarget: "/x/y"))
    }

    @Test func foldersValidated() {
        let long = "/" + String(repeating: "a", count: 1024)
        let many = (0..<30).map { "/f\($0)" }
        #expect(JumpTarget.validFolders(["rel", "/ok", "../x", long]) == ["/ok"])
        #expect(JumpTarget.validFolders(many).count == 20)
        #expect(JumpTarget.validFolders(nil) == [])
    }

    @Test func cliArgsAreAnArrayNotAShell() {
        let evil = "/tmp/a b; rm -rf ~ $(x)"
        #expect(JumpTarget.cliArgs(folder: evil) == [evil])
        #expect(JumpTarget.cliArgs(folder: "relative") == nil)
        #expect(JumpTarget.cliArgs(folder: "-n") == nil)
    }

    @Test func oldExtensionHelloDecodes() throws {
        let h = #"{"kind":"ext-hello","editor":"cursor","appPid":5,"version":"0.1.1","terminals":[]}"#
        guard case .extHello(let m) = try WireMessage.decode(Data(h.utf8)) else { Issue.record("not hello"); return }
        #expect(m.workspaceFolders == nil)
        let n = #"{"kind":"ext-hello","editor":"cursor","appPid":5,"version":"0.1.2","terminals":[],"workspaceFolders":["/a"]}"#
        guard case .extHello(let m2) = try WireMessage.decode(Data(n.utf8)) else { Issue.record("not hello"); return }
        #expect(m2.workspaceFolders == ["/a"])
    }
}

@Suite struct SafeTTYTests {
    /// Only ASCII letters and digits reach the AppleScript: quotes and spaces cannot end the string.
    @Test func injectionIsStripped() {
        #expect(JumpTarget.safeTTY("ttys003\" then do shell script \"x") == "/dev/ttys003thendoshellscriptx")
        #expect(JumpTarget.safeTTY("ttys003") == "/dev/ttys003")
    }

    @Test func emptyAndOddInput() {
        // "/dev/" matches no tty, so the script does nothing.
        #expect(JumpTarget.safeTTY("") == "/dev/")
        #expect(JumpTarget.safeTTY("/dev/ttys004") == "/dev/devttys004")
        #expect(JumpTarget.safeTTY("../../etc/passwd") == "/dev/etcpasswd")
        #expect(JumpTarget.safeTTY("ttys\u{0}0\n5é") == "/dev/ttys05")
        #expect(JumpTarget.safeTTY("ｔｔｙ１") == "/dev/")
    }
}

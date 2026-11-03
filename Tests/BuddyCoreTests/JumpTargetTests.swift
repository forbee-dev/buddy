import Testing
import Foundation
@testable import BuddyCore

struct JumpTargetTests {
    @Test func ownerClientWins() {
        let p = JumpTarget.pick(ownerFolders: ["/a/app"], allFolders: ["/a/app", "/b"], cwd: "/b/x")
        #expect(p == .init(folder: "/a/app", isOpen: true))
    }

    @Test func ownerPrefersFolderHoldingCwd() {
        let p = JumpTarget.pick(ownerFolders: ["/w/one", "/w/two"], allFolders: [], cwd: "/w/two/src")
        #expect(p.folder == "/w/two")
    }

    @Test func prefixMatchAcrossClients() {
        let p = JumpTarget.pick(ownerFolders: nil, allFolders: ["/p/one", "/p/two"], cwd: "/p/two/sub/dir")
        #expect(p == .init(folder: "/p/two", isOpen: true))
    }

    @Test func longestPrefixWins() {
        let p = JumpTarget.pick(ownerFolders: nil, allFolders: ["/p", "/p/mono/pkg", "/p/mono"], cwd: "/p/mono/pkg/src")
        #expect(p.folder == "/p/mono/pkg")
    }

    @Test func prefixIsPathComponentAware() {
        let p = JumpTarget.pick(ownerFolders: nil, allFolders: ["/p/app"], cwd: "/p/app2/x")
        #expect(p == .init(folder: "/p/app2/x", isOpen: false))
    }

    @Test func cwdFallback() {
        #expect(JumpTarget.pick(ownerFolders: [], allFolders: [], cwd: "/x/y") == .init(folder: "/x/y", isOpen: false))
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

import Foundation
import Testing
@testable import BuddyCore

@Suite struct DesktopTests {
    @Test func detection() {
        #expect(TerminalApp.detect(HookEnv(entrypoint: "claude-desktop")) == .claudeDesktop)
        #expect(TerminalApp.detect(HookEnv(bundleId: "com.anthropic.claudefordesktop")) == .claudeDesktop)
        let chain = ["/Applications/Claude.app/Contents/Helpers/disclaimer", "/Applications/Claude.app/Contents/MacOS/Claude"]
        #expect(TerminalApp.detect(HookEnv(termProgram: nil), chainPaths: chain) == .claudeDesktop)
        // Desktop markers win over an inherited terminal env.
        #expect(TerminalApp.detect(HookEnv(termProgram: "iTerm.app", entrypoint: "claude-desktop")) == .claudeDesktop)
        #expect(TerminalApp.detect(HookEnv(termProgram: "iTerm.app", entrypoint: "cli")) == .iterm)
        #expect(TerminalApp.claudeDesktop.displayName == "Claude Desktop")
    }

    @Test func entrypointSanitized() throws {
        #expect(HookEnv.sanitizeEntrypoint("Claude-Desktop\n$(rm -rf)") == "claude-desktoprm-rf")
        #expect(HookEnv.sanitizeEntrypoint(String(repeating: "a", count: 99)).count == 32)
        let env = HookEnv(claudePid: 5, entrypoint: "claude-desktop")
        let decoded = try JSONDecoder().decode(HookEnv.self, from: JSONEncoder().encode(env))
        #expect(decoded.entrypoint == "claude-desktop")
    }

    @Test func sessionFromDesktop() {
        var s = SessionStore()
        var m = hook("SessionStart", pid: 300)
        m.env.tty = nil
        m.env.entrypoint = "claude-desktop"
        _ = s.apply(m)
        #expect(s.sessions["s1"]?.terminal == .claudeDesktop)
        #expect(s.sessions["s1"]?.answerPlace == "Claude Desktop")
        _ = s.apply(hook("SessionStart", session: "s2", pid: 301))
        s.setUnderClaudeApp("s2", true)
        #expect(s.sessions["s2"]?.terminal == .claudeDesktop)
        #expect(s.sessions["s1"].map { $0.terminal != .iterm } == true)
    }

    @Test func guardRulesForDesktop() {
        // No tty: tpgid is not claude's group. Desktop skips that check but needs Claude.app above it.
        let noTTY = ProcInfo.Status(pgid: 40, tpgid: -1, stopped: false)
        #expect(PromptGuard.refusal(state: .done, status: noTTY, desktop: true, underClaudeApp: true) == nil)
        #expect(PromptGuard.refusal(state: .done, status: noTTY, desktop: true, underClaudeApp: false) != nil)
        #expect(PromptGuard.refusal(state: .done, status: noTTY) != nil)  // a terminal session with no foreground
        #expect(PromptGuard.refusal(state: .working, status: noTTY, desktop: true, underClaudeApp: true) != nil)
        #expect(PromptGuard.refusal(state: .idle, status: nil, desktop: true, underClaudeApp: true) != nil)
        let stopped = ProcInfo.Status(pgid: 40, tpgid: -1, stopped: true)
        #expect(PromptGuard.refusal(state: .idle, status: stopped, desktop: true, underClaudeApp: true) != nil)
    }

    @Test func hookPeerAcceptsDesktopChain() {
        // buddy-hook < Desktop's bundled claude < disclaimer < Claude: claude is the parent; no claude path is hardcoded.
        let hookPath = "/bin/ls"
        let real = PeerCheck.resolved(hookPath)
        let desktopClaude: Int32 = 900, disclaimer: Int32 = 899
        #expect(PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [desktopClaude, disclaimer],
                                          claudePid: desktopClaude))
        // Through a shell wrapper: buddy-hook < sh < claude.
        #expect(PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [901, desktopClaude],
                                          claudePid: desktopClaude))
        // The Claude app itself is not the claude pid.
        #expect(!PeerCheck.hookPeerAllowed(peerPath: real, expectedHookPath: hookPath, ancestors: [desktopClaude, disclaimer],
                                           claudePid: disclaimer - 1))
    }
}

@Suite struct TerminalAskpassTests {
    @Test func askpassNamesTheEditor() {
        #expect(TerminalApp.detect(HookEnv(askpassMain: "/Applications/Cursor.app/Contents/Resources/app/extensions/git/dist/askpass-main.js")) == .cursor)
        #expect(TerminalApp.detect(HookEnv(askpassMain: "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/git/dist/askpass-main.js"))
                == .vscode)
        #expect(TerminalApp.detect(HookEnv(askpassMain: "/Users/me/Apps/Code.app/Contents/Resources/app/extensions/git/dist/askpass-main.js"))
                == .vscode)
        #expect(TerminalApp.detect(HookEnv(termProgram: "WezTerm", askpassMain: "/opt/other/askpass.js")) == .other("WezTerm"))
    }

    /// The bundle id the hook saw wins over the askpass path and TERM_PROGRAM.
    @Test func bundleIdWins() {
        let cursorAskpass = "/Applications/Cursor.app/Contents/Resources/app/extensions/git/dist/askpass-main.js"
        #expect(TerminalApp.detect(HookEnv(termProgram: "vscode", bundleId: "com.microsoft.VSCode", askpassMain: cursorAskpass)) == .vscode)
        #expect(TerminalApp.detect(HookEnv(termProgram: "vscode", bundleId: "com.googlecode.iterm2", askpassMain: cursorAskpass)) == .iterm)
        #expect(TerminalApp.detect(HookEnv(termProgram: "vscode", askpassMain: cursorAskpass)) == .cursor)
    }
}

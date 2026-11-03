import Foundation
import Darwin
import Testing
@testable import BuddyCore

@Suite struct PaletteOrderTests {
    private func store() -> SessionStore {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 0)
        func at(_ sec: Double) -> Date { t0.addingTimeInterval(sec) }
        _ = s.apply(hook("Stop", session: "done1", pid: 1), now: at(1))
        _ = s.apply(hook("UserPromptSubmit", session: "work", pid: 2), now: at(2))
        _ = s.apply(hook("PermissionRequest", session: "perm", id: "p", pid: 3, extra: ["tool_name": "Bash",
            "tool_input": json(#"{"command":"swift test\nopen x","description":"Run"}"#)]), now: at(5))
        _ = s.apply(hook("PermissionRequest", session: "ask", id: "q", pid: 4, extra: ["tool_name": "AskUserQuestion",
            "tool_input": json(#"{"questions":[{"question":"Pick a library?\nmore","options":[]}]}"#)]), now: at(3))
        _ = s.apply(hook("SessionStart", session: "idle", pid: 5), now: at(9))
        _ = s.apply(hook("Notification", session: "idle", pid: 5, extra: ["notification_type": "idle_prompt"]), now: at(9))
        _ = s.apply(hook("SessionEnd", session: "gone", pid: 6, extra: ["reason": "other"]), now: at(9))
        return s
    }

    @Test func waitingFirstThenDoneWorkingIdle() {
        let rows = PaletteOrder.sorted(Array(store().sessions.values))
        #expect(rows.map(\.id) == ["ask", "perm", "done1", "work", "idle"])  // the longest wait first; ended left out
    }

    @Test func filterByProjectOrState() {
        var s = store()
        _ = s.apply(hook("Stop", session: "web", pid: 7, extra: ["cwd": "/Users/me/web-app"]))
        let rows = PaletteOrder.sorted(Array(s.sessions.values))
        #expect(PaletteOrder.filter(rows, query: "WEB").map(\.id) == ["web"])
        #expect(PaletteOrder.filter(rows, query: "needs permission").map(\.id) == ["perm"])
        #expect(PaletteOrder.filter(rows, query: "done web").map(\.id) == ["web"])
        #expect(PaletteOrder.filter(rows, query: "  ").count == rows.count)
    }

    @Test func nextWaitingWrapsAndSkipsSelf() {
        let rows = PaletteOrder.sorted(Array(store().sessions.values))
        #expect(PaletteOrder.nextWaiting(after: "ask", in: rows)?.id == "perm")
        #expect(PaletteOrder.nextWaiting(after: "perm", in: rows)?.id == "ask")
        #expect(PaletteOrder.nextWaiting(after: "work", in: rows)?.id == "ask")
        #expect(PaletteOrder.nextWaiting(after: nil, in: rows)?.id == "ask")
        let one = rows.filter { $0.id != "ask" }
        #expect(PaletteOrder.nextWaiting(after: "perm", in: one) == nil)
    }

    @Test func summaryShowsFirstLine() {
        let s = store().sessions
        #expect(PaletteOrder.summary(s["perm"]!) == "Bash: swift test")
        #expect(PaletteOrder.summary(s["ask"]!) == "Pick a library?")
        #expect(PaletteOrder.summary(s["done1"]!) == nil)
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

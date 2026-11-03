import Foundation
import Testing
@testable import BuddyCore

@Suite struct CardTests {
    static let input = json(#"""
    {"questions":[
     {"question":"Pick a color","header":"Color","multiSelect":false,"options":[
       {"label":"Red","preview":"```\nred()\n```"},{"label":"Blue","description":"Calm","preview":"  \n"}]},
     {"question":"Pick fruits","multiSelect":true,"options":[{"label":"Pear"},{"label":"Plum"}]},
     {"question":"Ship it?","header":"Ship","options":[{"label":"Yes"},{"label":"No"}]}]}
    """#)

    // MARK: Preview parsing

    @Test func previewParsed() {
        let qs = AskQuestion.parse(Self.input)
        #expect(qs[0].options[0].preview == "```\nred()\n```")
        #expect(qs[0].options[1].preview == nil)  // blank preview counts as none
        #expect(qs[0].options[1].description == "Calm")
        #expect(qs[0].hasPreview && !qs[1].hasPreview)
    }

    // MARK: Step state machine

    @Test func stepsAndReview() {
        var f = QuestionFlow(AskQuestion.parse(Self.input))
        #expect(f.hasReview && f.progress == "1 of 3" && !f.showsSubmit)
        f.back()
        #expect(f.step == 0)
        #expect(!f.canAdvance)  // nothing picked yet
        f.pick(1)
        #expect(f.step == 0 && f.canAdvance)  // a pick never moves on by itself
        f.next()
        #expect(f.step == 1)
        f.pick(0)
        f.pick(1)
        #expect(f.step == 1)
        #expect(f.answer(1) == "Pear, Plum")
        f.next()
        f.pick(0)
        #expect(f.isLastQuestion)
        f.next()
        #expect(f.isReview && f.showsSubmit && f.progress == "Review")
        f.next()
        #expect(f.isReview)  // clamps at review
        f.go(to: 0)
        #expect(f.step == 0)
        #expect(f.complete)
        #expect(f.answers == ["Pick a color": "Blue", "Pick fruits": "Pear, Plum", "Ship it?": "Yes"])
    }

    @Test func singleQuestionHasNoReview() {
        var f = QuestionFlow([AskQuestion(question: "Q", header: nil, options: [.init(label: "A")], multiSelect: false)])
        #expect(!f.hasReview && f.showsSubmit)
        f.pick(0)
        f.next()
        #expect(f.step == 0 && !f.isReview && f.complete)
    }

    @Test func otherRules() {
        var f = QuestionFlow(AskQuestion.parse(Self.input))
        f.pick(0)
        f.pick(2)  // Other on single choice replaces the pick
        #expect(f.otherOn.contains(0) && f.picks[0] == [])
        #expect(!f.answered(0))
        f.others[0] = "  Green "
        #expect(f.answer(0) == "Green")
        f.pick(1)  // a real option turns Other off
        #expect(f.answer(0) == "Blue")
        f.go(to: 1)
        f.pick(0)
        f.pick(2)  // multi: Other adds
        f.others[1] = "Fig"
        #expect(f.answer(1) == "Pear, Fig")
        f.pick(2)
        #expect(f.answer(1) == "Pear")
        let before = f
        f.pick(9)
        f.pick(-1)
        #expect(f == before)  // rows that do not exist change nothing
    }

    @Test func completeNeedsUniqueTexts() {
        let q = AskQuestion(question: "Same", header: nil, options: [.init(label: "A")], multiSelect: false)
        var f = QuestionFlow([q, q])
        f.pick(0); f.next(); f.pick(0)
        #expect(f.answered(0) && f.answered(1) && !f.uniqueTexts && !f.complete)
        #expect(!QuestionFlow().complete)
    }

    // MARK: Keyboard mapping

    @Test func digitBounds() {
        #expect(QuestionKeys.row(forDigit: 1, rows: 3) == 0)
        #expect(QuestionKeys.row(forDigit: 3, rows: 3) == 2)
        #expect(QuestionKeys.row(forDigit: 4, rows: 3) == nil)
        #expect(QuestionKeys.row(forDigit: 0, rows: 3) == nil)
        #expect(QuestionKeys.row(forDigit: 9, rows: 12) == 8)
        #expect(QuestionKeys.row(forDigit: 10, rows: 12) == nil)
    }

    @Test func keyActions() {
        var f = QuestionFlow(AskQuestion.parse(Self.input))
        #expect(QuestionKeys.action(.digit(3), flow: f, textFocused: false) == .pick(2))  // Other row
        #expect(QuestionKeys.action(.digit(4), flow: f, textFocused: false) == .ignore)
        #expect(QuestionKeys.action(.digit(1), flow: f, textFocused: true) == .ignore)
        #expect(QuestionKeys.action(.left, flow: f, textFocused: true) == .ignore)
        #expect(QuestionKeys.action(.space, flow: f, textFocused: true) == .ignore)
        #expect(QuestionKeys.action(.returnKey, flow: f, textFocused: true) == .primary)
        #expect(QuestionKeys.action(.right, flow: f, textFocused: false) == .next)
        #expect(QuestionKeys.action(.left, flow: f, textFocused: false) == .back)
        #expect(QuestionKeys.action(.space, flow: f, textFocused: false) == .ignore)  // no row focused yet
        f.moveCursor(1)
        #expect(QuestionKeys.action(.space, flow: f, textFocused: false) == .pick(0))
        // A focused button or other control keeps Space; arrows still change the question.
        #expect(QuestionKeys.action(.space, flow: f, textFocused: false, controlFocused: true) == .ignore)
        #expect(QuestionKeys.action(.right, flow: f, textFocused: false, controlFocused: true) == .next)
        f.moveCursor(10)
        #expect(f.cursor[0] == 2)
        f.go(to: 3)
        #expect(QuestionKeys.action(.digit(1), flow: f, textFocused: false) == .ignore)  // review step
    }

    // MARK: Transcript tail

    static func line(_ type: String, _ content: String) -> String {
        let c = JSONValue.string(content).encoded()
        return #"{"type":"\#(type)","message":{"content":\#(c)}}"#
    }
    static func textLine(_ text: String) -> String {
        let c = JSONValue.string(text).encoded()
        return #"{"type":"assistant","message":{"content":[{"type":"text","text":\#(c)}]}}"#
    }
    static let toolUse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{}}]}}"#
    static let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#

    /// A fresh resolved temp folder used as "home".
    static func home() throws -> String {
        let dir = PeerCheck.resolved(NSTemporaryDirectory()) + "/buddy-tt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/.claude", withIntermediateDirectories: true)
        return dir
    }

    static func write(_ lines: [String], to path: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func mixedLines() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.claude/s.jsonl"
        try Self.write([Self.line("user", "do it"), Self.textLine("First \u{202E}part."), "not json {",
                        Self.toolResult, Self.toolUse, #"{"type":"progress"}"#], to: path)
        #expect(TranscriptTail.lastAssistantText(path: path, home: home) == "First \\u{202E}part.")
    }

    @Test func stopsAtUserPromptAndNoAssistant() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.claude/s.jsonl"
        try Self.write([Self.textLine("Old turn"), Self.line("user", "new prompt"), Self.toolUse], to: path)
        #expect(TranscriptTail.lastAssistantText(path: path, home: home) == nil)
        try Self.write([Self.line("user", "hi"), Self.toolResult], to: path)
        #expect(TranscriptTail.lastAssistantText(path: path, home: home) == nil)
    }

    @Test func truncatedFirstLineDropped() throws {
        let data = Data((Self.textLine("partial") + "\n" + Self.toolUse + "\n").utf8)
        #expect(TranscriptTail.lastAssistantText(inTail: data, truncatedStart: false) == "partial")
        #expect(TranscriptTail.lastAssistantText(inTail: data, truncatedStart: true) == nil)
        // A real file over 64 KB: only the tail is read, and the cut first line is skipped.
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.claude/big.jsonl"
        try Self.write([Self.textLine(String(repeating: "x", count: 70_000)), Self.textLine("tail text")], to: path)
        #expect(TranscriptTail.lastAssistantText(path: path, home: home) == "tail text")
        try Self.write([Self.textLine("head"), Self.textLine(String(repeating: "y", count: 70_000)), Self.toolUse], to: path)
        #expect(TranscriptTail.lastAssistantText(path: path, home: home) == nil)
    }

    @Test func capAt300() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.claude/s.jsonl"
        try Self.write([Self.textLine(String(repeating: "a", count: 500))], to: path)
        let text = try #require(TranscriptTail.lastAssistantText(path: path, home: home))
        #expect(text.count == 301 && text.hasSuffix("…"))
    }

    @Test func pathChecks() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let real = home + "/.claude/s.jsonl"
        try Self.write([Self.textLine("hello")], to: real)
        #expect(TranscriptTail.lastAssistantText(path: real, home: home) == "hello")
        let link = home + "/.claude/link.jsonl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(TranscriptTail.lastAssistantText(path: link, home: home) == nil)
        let outside = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let away = outside + "/.claude/s.jsonl"
        try Self.write([Self.textLine("hello")], to: away)
        #expect(TranscriptTail.lastAssistantText(path: away, home: home) == nil)
        #expect(TranscriptTail.lastAssistantText(path: home + "/../" + (outside as NSString).lastPathComponent + "/.claude/s.jsonl", home: home) == nil)
        #expect(!TranscriptTail.validPath("relative/s.jsonl", home: home))
        #expect(!TranscriptTail.validPath(home + "/.claude/s.json", home: home))
        // A symlinked folder that points outside home.
        try FileManager.default.createSymbolicLink(atPath: home + "/out", withDestinationPath: outside + "/.claude")
        #expect(TranscriptTail.lastAssistantText(path: home + "/out/s.jsonl", home: home) == nil)
        try FileManager.default.createDirectory(atPath: home + "/dir.jsonl", withIntermediateDirectories: true)
        #expect(TranscriptTail.lastAssistantText(path: home + "/dir.jsonl", home: home) == nil)
        #expect(TranscriptTail.lastAssistantText(path: real, home: home, uid: getuid() + 1) == nil)  // other owner
    }

    @Test func riskAccents() {
        #expect(PermissionDisplay.risk(tool: "Read", input: json(#"{"file_path":"/x"}"#)) == .readOnly)
        #expect(PermissionDisplay.risk(tool: "Bash", input: json(#"{"command":"ls"}"#)) == .writes)
        #expect(PermissionDisplay.risk(tool: "Bash", input: json(#"{"command":"ls","dangerouslyDisableSandbox":true}"#)) == .sandboxOff)
        #expect(PermissionDisplay.risk(tool: "mcp__x__y", input: .null) == .writes)
    }

    @Test func transcriptPathKept() throws {
        let p = try HookPayload.decode(Data(#"{"session_id":"s","hook_event_name":"Stop","transcript_path":"/Users/x/.claude/p/s.jsonl"}"#.utf8))
        #expect(p["transcript_path"]?.string == "/Users/x/.claude/p/s.jsonl")
        var store = SessionStore()
        _ = store.apply(hook("Stop", extra: ["transcript_path": "/Users/x/t.jsonl"]))
        #expect(store.sessions["s1"]?.transcriptPath == "/Users/x/t.jsonl")
    }
}

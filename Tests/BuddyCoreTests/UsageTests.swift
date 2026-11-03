import Foundation
import Testing
@testable import BuddyCore

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A class, so each test's temp folder goes away in `deinit`.
@Suite final class UsageTests {
    private let home: String = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-usage-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d + "/proj/sess/subagents", withIntermediateDirectories: true)
        return d
    }()

    deinit { try? FileManager.default.removeItem(atPath: home) }

    private func line(_ id: String, model: String = "claude-opus-5-5", input: Int = 10, output: Int = 100, write: Int = 1000, read: Int = 0) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read)}}}"# + "\n"
    }

    private func append(_ path: String, _ text: String) throws {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    @Test func incrementalDedupedWithSubagents() throws {
        let main = home + "/proj/sess.jsonl"
        try append(main, #"{"type":"user","message":{"content":"SECRET"}}"# + "\n" + line("m1") + line("m1"))
        var m = UsageMeter()
        do { let ok = m.update(transcript: main, home: home); #expect(ok) }
        #expect(m.byModel["claude-opus-5-5"] == TokenCounts(input: 10, output: 100, cacheWrite: 1000, cacheRead: 0))
        // A partial line waits for its newline; a repeated id adds only its growth.
        let next = line("m2", read: 500)
        try append(main, line("m1", output: 140) + String(next.prefix(30)))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1150)
        try append(main, String(next.dropFirst(30)))
        try append(home + "/proj/sess/subagents/agent-a1.jsonl", line("s1", model: "claude-haiku-5-5", input: 1, output: 2, write: 3, read: 4) + line("m2", read: 500))
        try append(home + "/proj/sess/subagents/other.jsonl", line("x9"))
        _ = m.update(transcript: main, home: home)
        #expect(m.byModel["claude-opus-5-5"]?.total == 1150 + 1610)
        #expect(m.byModel["claude-haiku-5-5"]?.total == 10)
        // Nothing new: nothing changes.
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1150 + 1610 + 10)
        // A rewritten file counts from zero again.
        try Data((line("n1")).utf8).write(to: URL(fileURLWithPath: main))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1110 + 10 + 1610)
    }

    @Test func costAndFormat() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/prices.json"))
        let prices = try JSONDecoder().decode(PriceTable.self, from: data)
        #expect(prices.note?.contains("anthropic.com/pricing") == true)
        for m in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] { #expect(prices.models[m] != nil) }
        let table = PriceTable(note: nil, models: ["m": .init(input: 1, output: 10, cacheWrite: 2, cacheRead: 0.5)])
        let usage = ["m": TokenCounts(input: 10_000, output: 20_000, cacheWrite: 10_000, cacheRead: 2_100)]
        #expect(UsageFormat.line(usage, prices: table) == "42.1k tok · $0.23")
        #expect(UsageFormat.line(usage.merging(["new-model": TokenCounts(input: 5)]) { $1 }, prices: table) == "42.1k tok")
        #expect(UsageFormat.line(usage, prices: nil) == "42.1k tok")
        #expect(UsageFormat.tokens(999) == "999 tok")
        #expect(UsageFormat.tokens(999_960) == "1.0M tok")
        #expect(UsageFormat.tokens(3_240_000) == "3.2M tok")
    }

    @Test func hugeOrNegativeCountsAreClampedAndNeverTrap() throws {
        let main = home + "/proj/big.jsonl"
        let huge = #"{"type":"assistant","message":{"id":"h1","model":"m","usage":{"input_tokens":9223372036854775807,"output_tokens":-5,"cache_creation_input_tokens":9000000000000000000,"cache_read_input_tokens":9000000000000000000}}}"#
        try append(main, huge + "\n" + huge.replacingOccurrences(of: "h1", with: "h2") + "\n")
        var m = UsageMeter()
        _ = m.update(transcript: main, home: home)
        let max = TokenCounts.maxField
        #expect(m.byModel["m"] == TokenCounts(input: 2 * max, output: 0, cacheWrite: 2 * max, cacheRead: 2 * max))
        #expect(TokenCounts.add(.max, 1) == .max)
        #expect(TokenCounts(input: .max, output: .max).total == .max)
        #expect(UsageFormat.line(["a": TokenCounts(input: .max), "b": TokenCounts(input: .max)], prices: nil).hasSuffix("M tok"))
    }

    @Test func giantLineIsSkippedNotKept() throws {
        let main = home + "/proj/giant.jsonl"
        try append(main, line("m1"))
        // A line over 8 MB, written in two parts: the reader skips it to its newline, also across updates.
        let giant = #"{"type":"assistant","x":""# + String(repeating: "a", count: 9 << 20)
        try append(main, String(giant.prefix(5 << 20)))
        var m = UsageMeter()
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 1110)
        try append(main, String(giant.dropFirst(5 << 20)) + #"","usage":{"input_tokens":7}}"# + "\n" + line("m2"))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 2220)
        try append(main, line("m3"))
        _ = m.update(transcript: main, home: home)
        #expect(m.tokens == 3330)
    }

    @Test func pricesOutsideTheRangeAreRejected() {
        func decode(_ v: String) -> PriceTable? {
            try? JSONDecoder().decode(PriceTable.self, from: Data(#"{"models":{"m":{"input":\#(v),"output":1,"cacheWrite":1,"cacheRead":1}}}"#.utf8))
        }
        #expect(decode("0") != nil && decode("1000") != nil && decode("3.5") != nil)
        for bad in ["-0.01", "1000.01", "1e308", "1e400"] { #expect(decode(bad) == nil, "\(bad)") }
    }

    @Test func unsafePathsAreNotRead() throws {
        let real = home + "/proj/real.jsonl"
        try append(real, line("m1"))
        let link = home + "/proj/link.jsonl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        var m = UsageMeter()
        do { let ok = m.update(transcript: link, home: home); #expect(!ok) }
        do { let ok = m.update(transcript: home + "/proj/../proj/real.jsonl", home: home); #expect(!ok) }
        do { let ok = m.update(transcript: real, home: home + "/elsewhere"); #expect(!ok) }
        do { let ok = m.update(transcript: real, home: home, uid: getuid() + 1); #expect(!ok) }
        let txt = home + "/proj/real.txt"
        try append(txt, line("m1"))
        do { let ok = m.update(transcript: txt, home: home); #expect(!ok) }
        #expect(m.tokens == 0)
        do { let ok = m.update(transcript: home + "/proj/missing.jsonl", home: home); #expect(!ok) }
    }
}

/// A class, so each test's temp folder goes away in `deinit`.
@Suite final class UsageReplaceTests {
    let home: String = {
        let d = PeerCheck.resolved(NSTemporaryDirectory()) + "/buddy-usage-r-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d + "/p", withIntermediateDirectories: true)
        return d
    }()

    deinit { try? FileManager.default.removeItem(atPath: home) }

    func line(_ id: String, type: String = "assistant", model: String = "m", out: Int = 10) -> String {
        #"{"type":"\#(type)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"# + "\n"
    }

    /// Writes a new file under the same name (atomic rename: a new inode).
    func replace(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }

    @Test func replacedTranscriptIsNotDoubleCounted() throws {
        let path = home + "/p/s.jsonl"
        try replace(path, line("a") + line("b"))
        var m = UsageMeter()
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 22)
        // Same size, new inode: counted from zero, not skipped and not added to the old sum.
        try replace(path, line("c", out: 20) + line("d", out: 20))
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 42)
        // Larger, new inode, the same lines plus one more: still no double count.
        try replace(path, line("c", out: 20) + line("d", out: 20) + line("e"))
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 53)
    }

    @Test func syntheticAndNonAssistantLinesAreIgnored() throws {
        let path = home + "/p/t.jsonl"
        try replace(path, line("a", model: "<synthetic>") + line("b", type: "user") + line("c"))
        var m = UsageMeter()
        _ = m.update(transcript: path, home: home)
        #expect(m.tokens == 11)
        #expect(m.byModel.keys.sorted() == ["m"])
    }
}

import Foundation
import Darwin

public struct TokenCounts: Sendable, Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public var total: Int { fields.reduce(0, Self.add) }
    var fields: [Int] { [input, output, cacheWrite, cacheRead] }
    init(_ f: [Int]) { self.init(input: f[0], output: f[1], cacheWrite: f[2], cacheRead: f[3]) }

    /// One field of one transcript line: 0 to 10^12. The transcript is a file, not a trusted source.
    public static let maxField = 1_000_000_000_000
    static func clamp(_ v: Int?) -> Int { min(max(v ?? 0, 0), maxField) }
    /// Sums stop at Int.max instead of trapping.
    static func add(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : r
    }
}

/// Token sums of one session (main transcript plus `subagents/agent-*.jsonl`), read incrementally (E4).
/// Only assistant lines count, once per `message.id`. The text of a line is never kept.
public struct UsageMeter: Sendable {
    public private(set) var byModel: [String: TokenCounts] = [:]
    private var offsets: [String: Int64] = [:]
    /// The inode each offset belongs to: a replaced file starts again from 0.
    private var inodes: [String: UInt64] = [:]
    /// Home and path pairs that passed `TranscriptTail.validPath`.
    private var valid: Set<String> = []
    /// Files whose read stopped inside a line longer than `maxLine`: the rest of that line is skipped.
    private var skipping: Set<String> = []
    /// Recent message ids only: the lines of one response come together.
    private var seen: [String: TokenCounts] = [:]
    private var seenOrder: [String] = []
    static let seenKept = 64
    static let chunk = 1 << 20
    /// Longer lines are skipped, so one giant line cannot hold memory.
    static let maxLine = 8 << 20
    private static let decoder = JSONDecoder()
    public init() {}

    public var tokens: Int { byModel.values.reduce(0) { TokenCounts.add($0, $1.total) } }

    /// Reads the new bytes of every file. False when the main transcript cannot be read.
    public mutating func update(transcript: String, home: String = NSHomeDirectory(), uid: uid_t = getuid()) -> Bool {
        let files = [transcript] + Self.subagentFiles(transcript, home: home)
        var readAny = false
        for path in files {
            let key = home + "\u{0}" + path
            if !valid.contains(key) {
                guard TranscriptTail.validPath(path, home: home) else { continue }
                valid.insert(key)
            }
            guard let (fd, size) = SafeFile.open(path, uid: uid) else { continue }
            defer { close(fd) }
            if path == transcript { readAny = true }
            var st = stat()
            let inode = fstat(fd, &st) == 0 ? UInt64(st.st_ino) : 0
            if size < offsets[path, default: 0] || inodes[path].map({ $0 != inode }) == true {
                // Rewritten, rotated, or replaced: count the whole session again, so nothing counts twice.
                self = UsageMeter()
                return update(transcript: transcript, home: home, uid: uid)
            }
            inodes[path] = inode
            guard size > offsets[path, default: 0] else { continue }
            read(fd, size: size, path: path)
        }
        return readAny
    }

    /// Full lines only: a partial last line is read again next time. Only new bytes are searched for a newline,
    /// so a long line costs O(n), not O(n²).
    private mutating func read(_ fd: Int32, size: Int64, path: String) {
        let newline = UInt8(ascii: "\n")
        var offset = offsets[path, default: 0]
        var pos = offset
        var carry = Data()
        var skip = skipping.contains(path)
        while pos < size {
            guard let data = SafeFile.read(fd, from: pos, count: Int(min(Int64(Self.chunk), size - pos))), !data.isEmpty else { break }
            pos += Int64(data.count)
            guard let last = data.lastIndex(of: newline) else {
                if !skip { carry.append(data) }
                if carry.count > Self.maxLine { carry = Data(); skip = true }
                if skip { offset = pos }
                continue
            }
            var from = data.startIndex
            if skip, let first = data.firstIndex(of: newline) {
                from = first + 1
                skip = false
            }
            if from < last { carry.append(data[from..<last]) }
            for line in carry.split(separator: newline) { count(Data(line)) }
            carry = Data(data[(last + 1)...])
            offset = pos - Int64(carry.count)
        }
        offsets[path] = offset
        if skip { skipping.insert(path) } else { skipping.remove(path) }
    }

    private struct Line: Decodable {
        struct Usage: Decodable {
            var input_tokens: Int?, output_tokens: Int?, cache_creation_input_tokens: Int?, cache_read_input_tokens: Int?
        }
        struct Message: Decodable { var id: String?; var model: String?; var usage: Usage? }
        var type: String?
        var message: Message?
    }

    /// One response is written as several lines that repeat its usage: count each `message.id` once,
    /// and only the growth when a later line reports more.
    mutating func count(_ line: Data) {
        guard line.range(of: Data(#""usage""#.utf8)) != nil,
              let l = try? Self.decoder.decode(Line.self, from: line), l.type == "assistant",
              let id = l.message?.id, let u = l.message?.usage else { return }
        let model = l.message?.model ?? "unknown"
        guard !model.hasPrefix("<") else { return }
        let new = TokenCounts(input: TokenCounts.clamp(u.input_tokens), output: TokenCounts.clamp(u.output_tokens),
                              cacheWrite: TokenCounts.clamp(u.cache_creation_input_tokens), cacheRead: TokenCounts.clamp(u.cache_read_input_tokens))
        let old = seen[id] ?? TokenCounts()
        let add = TokenCounts(zip(new.fields, old.fields).map { max(0, $0 - $1) })
        if seen[id] == nil {
            seenOrder.append(id)
            if seenOrder.count > Self.seenKept { seen[seenOrder.removeFirst()] = nil }
        }
        seen[id] = TokenCounts(zip(new.fields, old.fields).map { max($0, $1) })
        byModel[model] = TokenCounts(zip(byModel[model, default: TokenCounts()].fields, add.fields).map(TokenCounts.add))
    }

    /// `<transcript without .jsonl>/subagents/agent-*.jsonl`, sorted.
    static func subagentFiles(_ transcript: String, home: String) -> [String] {
        guard transcript.hasSuffix(".jsonl") else { return [] }
        let dir = String(transcript.dropLast(6)) + "/subagents"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }.sorted().map { dir + "/" + $0 }
    }
}

/// USD per million tokens, per model id. Read from the user's editable `prices.json`.
public struct PriceTable: Decodable, Sendable {
    public struct Price: Decodable, Sendable {
        public var input, output, cacheWrite, cacheRead: Double
        enum CodingKeys: String, CodingKey { case input, output, cacheWrite, cacheRead }
    }
    public var note: String?
    public var models: [String: Price]

    /// nil when a model with tokens has no price: then Buddy shows tokens only.
    public func cost(_ byModel: [String: TokenCounts]) -> Double? {
        var sum = 0.0
        for (model, t) in byModel where t.total > 0 {
            guard let p = models[model] else { return nil }
            sum += (Double(t.input) * p.input + Double(t.output) * p.output
                    + Double(t.cacheWrite) * p.cacheWrite + Double(t.cacheRead) * p.cacheRead) / 1_000_000
        }
        return sum
    }
}

extension PriceTable.Price {
    /// A price that is not finite or not 0 to 1000 USD per million tokens rejects the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func usd(_ k: CodingKeys) throws -> Double {
            let v = try c.decode(Double.self, forKey: k)
            guard v.isFinite, (0...1000).contains(v) else {
                throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "price must be 0 to 1000")
            }
            return v
        }
        self.init(input: try usd(.input), output: try usd(.output), cacheWrite: try usd(.cacheWrite), cacheRead: try usd(.cacheRead))
    }
}

public enum UsageFormat {
    /// "950 tok", "42.1k tok", "3.2M tok".
    public static func tokens(_ n: Int) -> String {
        if n < 1000 { return "\(n) tok" }
        let k = (Double(n) / 100).rounded() / 10
        if k < 1000 { return String(format: "%.1fk tok", k) }
        return String(format: "%.1fM tok", (Double(n) / 100_000).rounded() / 10)
    }

    /// "42.1k tok · $0.31", or tokens only when the price table misses a model.
    public static func line(_ byModel: [String: TokenCounts], prices: PriceTable?) -> String {
        let t = tokens(byModel.values.reduce(0) { TokenCounts.add($0, $1.total) })
        guard let cost = prices?.cost(byModel) else { return t }
        return t + String(format: " · $%.2f", cost)
    }
}

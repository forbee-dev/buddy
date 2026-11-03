import Foundation
import Darwin

/// Reads what Claude said last from the session transcript (`transcript_path`), for the card context line.
/// The path comes from a hook payload, so it is checked before any read. Never log the text.
public enum TranscriptTail {
    public static let maxBytes = 64 * 1024
    public static let maxChars = 300

    /// Absolute, `.jsonl`, under `home`, no `.`/`..` parts, and it still resolves under `home`.
    public static func validPath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"), !base.isEmpty, path.hasPrefix(base + "/") else { return false }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return PeerCheck.resolved(path).hasPrefix(PeerCheck.resolved(base) + "/")
    }

    /// Last assistant text in the current turn, revealed and capped, or nil on any failure.
    public static func lastAssistantText(path: String, home: String = NSHomeDirectory(), uid: uid_t = getuid()) -> String? {
        guard validPath(path, home: home), let (data, cut) = readTail(path, uid: uid) else { return nil }
        return lastAssistantText(inTail: data, truncatedStart: cut)
    }

    /// O_NOFOLLOW rejects a symlink; fstat on the open fd checks the file that is really read.
    static func readTail(_ path: String, uid: uid_t) -> (Data, Bool)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid else { return nil }
        let start = max(0, Int64(st.st_size) - Int64(maxBytes))
        let want = Int(Int64(st.st_size) - start)
        var buf = [UInt8](repeating: 0, count: want)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(start)) }
        guard n >= 0 else { return nil }
        return (Data(buf.prefix(n)), start > 0)
    }

    /// Walks lines backwards. Stops at the user's own prompt, so text from an older turn is not shown.
    static func lastAssistantText(inTail data: Data, truncatedStart: Bool) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncatedStart, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let v = try? decoder.decode(JSONValue.self, from: Data(line)) else { continue }
            let content = v["message"]?["content"]
            switch v["type"]?.string {
            case "assistant":
                let text = texts(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return cap(text) }
            case "user":
                if !texts(content).isEmpty { return nil }
            default:
                continue
            }
        }
        return nil
    }

    /// A string content, or the joined `text` blocks (tool_use and tool_result blocks have none).
    private static func texts(_ content: JSONValue?) -> String {
        if let s = content?.string { return s }
        return (content?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }

    private static func cap(_ s: String) -> String {
        DisplayText.reveal(s.count > maxChars ? String(s.prefix(maxChars)) + "…" : s)
    }
}

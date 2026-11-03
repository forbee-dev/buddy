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

    static func readTail(_ path: String, uid: uid_t) -> (Data, Bool)? {
        guard let (fd, size) = SafeFile.open(path, uid: uid) else { return nil }
        defer { close(fd) }
        let start = max(0, size - Int64(maxBytes))
        guard let data = SafeFile.read(fd, from: start, count: Int(size - start)) else { return nil }
        return (data, start > 0)
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

/// Opens files Buddy did not write (transcripts, skins, prices) without following links.
public enum SafeFile {
    /// The folder is resolved first (`realpath`), then opened with O_NOFOLLOW_ANY: no part of the path may be a symlink at
    /// open time, so a folder swapped after the check is refused too. fstat on the open fd checks the file that is really
    /// read: regular, and owned by `uid` (nil: any owner, for signed app bundle resources).
    public static func open(_ path: String, uid: uid_t? = getuid()) -> (fd: Int32, size: Int64)? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", let dir = realpath((path as NSString).deletingLastPathComponent, nil) else { return nil }
        let resolved = String(cString: dir) + "/" + name
        free(dir)
        // O_NOFOLLOW_ANY also covers the last part; with O_NOFOLLOW added, open fails with EINVAL.
        let fd = Darwin.open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, uid.map({ st.st_uid == $0 }) ?? true else { close(fd); return nil }
        return (fd, Int64(st.st_size))
    }

    public static func read(_ fd: Int32, from offset: Int64, count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: max(0, count))
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        return n >= 0 ? Data(buf.prefix(n)) : nil
    }

    /// The whole file when it is at most `maxBytes`; nil when it is missing, unsafe, or too big.
    public static func contents(_ path: String, maxBytes: Int, uid: uid_t? = getuid()) -> Data? {
        guard let (fd, size) = open(path, uid: uid) else { return nil }
        defer { close(fd) }
        return size <= Int64(maxBytes) ? read(fd, from: 0, count: Int(size)) : nil
    }
}

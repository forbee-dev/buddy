import Foundation
import Darwin

/// Claude Code session inbox socket (docs/hooks-facts.md section 4). The model sees the text as a peer message.
public enum InboxClient {
    public static func lines(token: String?, text: String) throws -> Data {
        var out = Data()
        if let token { out.append(try WireMessage.encode(["type": "auth", "token": token])) }
        let msg: JSONValue = .object(["type": "user", "message": .object(["role": "user", "content": .string(text)])])
        out.append(try WireMessage.encode(msg))
        return out
    }

    /// Only `/tmp/cc-socks/<claudePid>.sock` is accepted, as `/private/tmp/...`.
    public static func validatedSocket(_ path: String?, claudePid: Int32?) -> String? {
        guard var p = path, let pid = claudePid else { return nil }
        if p.hasPrefix("/tmp/") { p = "/private" + p }
        return p == "/private/tmp/cc-socks/\(pid).sock" ? p : nil
    }

    /// The socket and its folder must be real (not symlinks) and owned by this user.
    /// The folder must not be group/other-writable unless it has the sticky bit.
    public static func checkSocketFile(_ path: String) throws {
        func owned(_ p: String, type: mode_t) throws -> stat {
            var st = stat()
            guard lstat(p, &st) == 0 else { throw SocketError(call: "lstat", code: errno) }
            guard st.st_mode & S_IFMT == type, st.st_uid == getuid() else { throw SocketError(call: "owner/type", code: EPERM) }
            return st
        }
        let dir = try owned((path as NSString).deletingLastPathComponent, type: S_IFDIR)
        guard dir.st_mode & 0o022 == 0 || dir.st_mode & S_ISVTX != 0 else { throw SocketError(call: "folder mode", code: EPERM) }
        _ = try owned(path, type: S_IFSOCK)
    }

    public static func send(socketPath: String, token: String?, text: String) throws {
        try checkSocketFile(socketPath)
        let fd = try UnixSocket.connect(socketPath)
        defer { close(fd) }
        UnixSocket.setSendTimeout(fd, seconds: 2)
        try UnixSocket.writeAll(fd, lines(token: token, text: text))
    }
}

import Foundation
import Darwin

/// `remote` of a remote hook message. Display only: never used for routing or trust.
public struct RemoteInfo: Codable, Sendable, Equatable {
    public var host: String
    public var user: String
    public init(host: String, user: String) { self.host = host; self.user = user }

    public static let maxLength = 64

    /// One line, hidden characters made visible, at most 64 characters plus "…".
    public static func display(_ s: String) -> String {
        let flat = DisplayText.reveal(s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " "))
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? "?" : HookPayload.trim(flat, maxLength)
    }
}

/// Where a remote session comes from. `sshPid` is the local ssh client (the socket peer). `claudePid` is a pid on the
/// REMOTE host: it only tells sessions on one connection apart and is never used for a local process lookup.
public struct RemoteOrigin: Sendable, Equatable {
    public var host: String
    public var user: String
    public var sshPid: Int32
    public var claudePid: Int32?
    public init(host: String, user: String, sshPid: Int32, claudePid: Int32?) {
        self.host = host; self.user = user; self.sshPid = sshPid; self.claudePid = claudePid
    }
}

/// Checks for `remote.sock`. The peer is the local ssh client, so the local ancestry checks cannot apply:
/// same uid, an allowed ssh binary, and the shared token instead.
public enum RemoteAuth {
    public static let keychainService = "com.tiagosantos.buddy"
    public static let keychainAccount = "remote-token"
    public static let defaultClients = ["/usr/bin/ssh"]

    public enum Verdict: String, Sendable, Equatable {
        case ok
        case otherUser = "other user"
        case notSSH = "peer is not an allowed ssh client"
        case notConfigured = "no token on this Mac"
        case noToken = "no token sent"
        case badToken = "token mismatch"
        case noRemote = "no remote field"
    }

    /// Saved extra ssh clients: only absolute paths of binaries named `ssh` (the defaults can be edited by hand).
    public static func savedClients(_ paths: [String]) -> [String] {
        paths.filter { $0.hasPrefix("/") && ($0 as NSString).lastPathComponent == "ssh" }
    }

    /// `peerPath` is already resolved (`PeerCheck.path(of:)`); `allowedClients` are resolved here.
    public static func check(peerUid: uid_t?, peerPath: String?, allowedClients: [String], sent: String?, expected: String?,
                             remote: RemoteInfo?, uid: uid_t = getuid(),
                             equals: (String, String) -> Bool = constantTimeEquals) -> Verdict {
        guard let peerUid, peerUid == uid else { return .otherUser }
        guard let peerPath, allowedClients.map(PeerCheck.resolved).contains(peerPath) else { return .notSSH }
        guard let expected, !expected.isEmpty else { return .notConfigured }
        guard let sent, !sent.isEmpty else { return .noToken }
        guard equals(sent, expected) else { return .badToken }
        return remote == nil ? .noRemote : .ok
    }

    /// Time depends only on the length of `expected`, never on where the first difference is.
    public static func constantTimeEquals(_ sent: String, _ expected: String) -> Bool {
        let a = Array(sent.utf8), b = Array(expected.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<b.count { diff |= (i < a.count ? a[i] : 0) ^ b[i] }
        return diff == 0
    }

    /// 256 random bits as 64 lowercase hex characters. `SystemRandomNumberGenerator` is a CSPRNG on Apple platforms.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    public static func isValidToken(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The main socket takes local hooks only.
    public static func mainSocketAccepts(_ h: HookMessage) -> Bool { h.remote == nil && h.token == nil }

    /// What the store sees of a remote message: no token; the payload slimmed again (the remote side is untrusted) and
    /// without `transcript_path` (a remote file); an env without pid, tty, or socket, so no local process lookup uses it.
    public static func localize(_ h: HookMessage, sshPid: Int32) throws -> (HookMessage, RemoteOrigin) {
        var m = h
        m.token = nil
        m.env = HookEnv(attended: h.env.attended)
        var p = try HookPayload.decode(Data(h.payload.encoded().utf8)).object ?? [:]
        p["transcript_path"] = nil
        m.payload = .object(p)
        let r = h.remote ?? RemoteInfo(host: "?", user: "?")
        return (m, RemoteOrigin(host: RemoteInfo.display(r.host), user: RemoteInfo.display(r.user), sshPid: sshPid, claudePid: h.env.claudePid))
    }
}

/// The install command and the ssh_config lines that Settings → SSH copies.
public enum RemoteInstall {
    /// An ssh host alias or user@host: ASCII letters, digits, `.`, `_`, `-`. No part may start with `-` (ssh would read an option).
    public static func validHost(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard s.count <= 253, (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.first != "-" && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    public static let envFileName = "remote-install.env"
    /// The app deletes the env file this long after it wrote it (and on Rotate token and on quit).
    public static let envFileLifetime: TimeInterval = 600

    /// `cat '<env file>' '<script>' | ssh <host> 'bash -s'`. The token goes over stdin only: never in the
    /// command, the clipboard, shell history, or a process list. nil for an invalid host.
    public static func command(host: String, envFile: String, script: String) -> String? {
        guard validHost(host) else { return nil }
        return "cat \(HookInstaller.command(for: envFile)) \(HookInstaller.command(for: script)) | ssh \(host) 'bash -s'"
    }

    /// Writes `BUDDY_TOKEN=<token>` to `<dir>/remote-install.env` and returns the path. `dir` gets the socket folder
    /// checks (a real 0700 directory of this user). An old file is unlinked first; the new one is O_EXCL, O_NOFOLLOW, 0600.
    public static func writeEnvFile(token: String, dir: String) throws -> String {
        guard RemoteAuth.isValidToken(token) else { throw SocketError(call: "token", code: EINVAL) }
        try UnixSocket.prepareDirectory(dir)
        let path = dir + "/" + envFileName
        if unlink(path) != 0 && errno != ENOENT { throw SocketError(call: "unlink", code: errno) }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SocketError(call: "open", code: errno) }
        defer { close(fd) }
        do { try UnixSocket.writeAll(fd, Data("BUDDY_TOKEN=\(token)\n".utf8)) } catch {
            unlink(path)
            throw error
        }
        return path
    }

    /// Lines for the LOCAL ~/.ssh/config. ssh_config takes a double-quoted argument with spaces (checked with `ssh -G`).
    public static func sshConfig(host: String, remoteHome: String, localSocket: String) -> String {
        let alias = host.split(separator: "@").last.map(String.init) ?? host
        return "Host \(alias)\n  RemoteForward \(remoteHome)/.buddy/buddy.sock \"\(localSocket)\""
    }
}

/// Jump for a remote session goes to the local terminal that runs the ssh client.
public enum RemoteJump {
    /// `ancestors`: the ssh pid first, then its parents. The shell is the first parent that an editor extension reports
    /// as a terminal, else the ssh client's parent. `claudePid` holds the ssh pid: Jump walks up from it to the app.
    public static func env(ancestors: [Int32], tty: String?, bundleId: String?, extShells: Set<Int32>) -> HookEnv? {
        guard let ssh = ancestors.first else { return nil }
        let parents = ancestors.dropFirst()
        return HookEnv(claudePid: ssh, shellPid: parents.first(where: extShells.contains) ?? parents.first, tty: tty, bundleId: bundleId)
    }
}

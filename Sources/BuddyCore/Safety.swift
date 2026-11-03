import Foundation
import Darwin

/// Text from the model or hook payloads, made safe to show.
public enum DisplayText {
    static func isHidden(_ v: UInt32) -> Bool {
        switch v {
        case 0x00...0x08, 0x0B...0x1F, 0x7F...0x9F: return true
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFEFF, 0xFFA0: return true
        case 0xFE00...0xFE0F, 0xE0000...0xE007F: return true
        default: return false
        }
    }

    /// Hidden characters become visible `\u{XXXX}` text: bidi controls, zero-width characters, C0/C1 controls, variation
    /// selectors, tag characters, and blank fillers (Hangul fillers, soft hyphen, and the like). Tab and newline stay.
    public static func reveal(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if isHidden(u.value) { out += String(format: "\\u{%04X}", u.value) } else { out.unicodeScalars.append(u) }
        }
        return out
    }
}

public enum PermissionDisplay {
    /// Every tool_input key except `description`; `command` first. Strings are shown raw, then revealed.
    public static func detail(_ input: JSONValue) -> String {
        guard let obj = input.object else { return DisplayText.reveal(input.encoded(pretty: true)) }
        let keys = obj.keys.filter { $0 != "description" }.sorted { a, b in a == "command" ? true : b == "command" ? false : a < b }
        let parts = keys.map { k -> String in
            let v = obj[k].map { $0.string ?? $0.encoded(pretty: true) } ?? ""
            return keys == ["command"] ? v : "\(k):\n\(v)"
        }
        return DisplayText.reveal(parts.joined(separator: "\n\n"))
    }

    public enum Risk: Sendable { case sandboxOff, writes, readOnly }

    /// Card accent. Unknown tools (MCP and others) count as `writes`: Buddy cannot tell what they do.
    public static func risk(tool: String, input: JSONValue) -> Risk {
        if sandboxDisabled(input) { return .sandboxOff }
        return ["Read", "Glob", "Grep", "LS", "NotebookRead", "WebSearch", "WebFetch", "TodoWrite"].contains(tool) ? .readOnly : .writes
    }

    public static func sandboxDisabled(_ input: JSONValue) -> Bool { input["dangerouslyDisableSandbox"]?.bool == true }

    public static func stats(_ text: String) -> (lines: Int, chars: Int) {
        (text.split(separator: "\n", omittingEmptySubsequences: false).count, text.count)
    }
}

/// Checks before Buddy sends a next prompt.
public enum PromptGuard {
    public static let maxBytes = 32 * 1024

    /// Keeps tab and newline (CR and CRLF become LF), drops other C0, DEL, and C1 controls, caps at 32 KB of UTF-8.
    /// No ESC survives, so the text cannot end the extension's bracketed paste early.
    public static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").unicodeScalars {
            let v = u.value
            if (v < 0x20 && v != 0x09 && v != 0x0A) || (0x7F...0x9F).contains(v) { continue }
            let n = String(u).utf8.count
            if bytes + n > maxBytes { break }
            bytes += n
            out.append(u)
        }
        return String(out)
    }

    /// SSH sessions: Buddy cannot see whether claude is in the foreground of the remote terminal (docs/SSH.md).
    public static let remoteRefusal = "Answer in the terminal. Buddy cannot send prompts to SSH sessions."

    /// The part of `refusal` that needs no process lookup (safe to call from a view body).
    public static func stateRefusal(_ state: SessionState) -> String? {
        state == .done || state == .idle || state == .starting ? nil
            : "Claude is busy or waiting for an answer. Send the prompt when it is done."
    }

    /// nil = safe to send. Otherwise a reason to show the user.
    /// Claude Desktop sessions have no tty: instead of the foreground check, claude must still run under Claude.app.
    public static func refusal(state: SessionState, status: ProcInfo.Status?, desktop: Bool = false,
                               underClaudeApp: Bool = false, remote: Bool = false) -> String? {
        if remote { return remoteRefusal }
        if let r = stateRefusal(state) { return r }
        guard let st = status else { return "The Claude process is gone." }
        if st.stopped { return "Claude is suspended (Ctrl-Z)." }
        if desktop {
            return underClaudeApp ? nil : "This session no longer runs under Claude Desktop."
        }
        guard st.pgid == st.tpgid else { return "Claude is not in the foreground of its terminal, so the text could run in the shell." }
        return nil
    }
}

/// Socket peer checks.
public enum PeerCheck {
    public static func peerPid(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    public static func peerUid(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    public static func resolved(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    public static func path(of pid: pid_t) -> String? { pathFrom { proc_pidpath(pid, $0, $1) } }

    private static func pathFrom(_ fill: (UnsafeMutableRawPointer, UInt32) -> Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { b in b.baseAddress.map { fill($0, UInt32(b.count)) } ?? 0 }
        guard n > 0 else { return nil }
        return resolved(String(decoding: buf.prefix(Int(n)), as: UTF8.self))
    }

    /// The peer's audit token at connect time. It names one process (pid plus pidversion), so a reused pid never matches.
    public static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0, len == MemoryLayout<audit_token_t>.size else { return nil }
        return token
    }

    /// `audit_token_to_pid` (libbsm reads the same slot).
    public static func pid(of token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

    /// The executable of the exact process in `token`, resolved. nil when that process is gone, also when its pid now
    /// belongs to another process: the kernel compares the pidversion (`proc_pidpath_audittoken`).
    public static func path(ofToken token: audit_token_t) -> String? {
        var t = token
        return pathFrom { proc_pidpath_audittoken(&t, $0, $1) }
    }

    /// A hook peer must be the bundled buddy-hook, started by the claude process it names (parent or grandparent).
    public static func hookPeerAllowed(peerPath: String?, expectedHookPath: String, ancestors: [Int32], claudePid: Int32?) -> Bool {
        guard let peerPath, let claudePid, peerPath == resolved(expectedHookPath) else { return false }
        return ancestors.prefix(2).contains(claudePid)  // parent or grandparent only
    }
}

/// Which listener buddy-hook may send a payload to.
public enum HookTrust {
    public static let releaseNames = ["Buddy"]
    public static let debugNames = ["Buddy", "BuddyApp"]

    /// Our own user, running one of `names` from the hook's own folder. `peerPath` is resolved; `selfPath` is the hook's.
    public static func serverAllowed(peerUid: uid_t?, ownUid: uid_t, peerPath: String?, selfPath: String?, names: [String]) -> Bool {
        guard peerUid == ownUid, let peerPath, let selfPath else { return false }
        let dir = (selfPath as NSString).deletingLastPathComponent
        return names.map { PeerCheck.resolved(dir + "/" + $0) }.contains(peerPath)
    }
}

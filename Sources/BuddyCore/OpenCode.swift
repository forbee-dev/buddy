import Foundation

/// Finds the terminal process of an OpenCode session. OpenCode 2 runs plugins in a background service
/// (`opencode serve --service`) that has no tty; the TUI in the terminal is the process to jump to.
public enum OpenCodeTUI {
    public struct Candidate: Sendable, Equatable {
        public var pid: Int32
        public var ppid: Int32?
        public var tty: String?
        public var cwd: String?
        public init(pid: Int32, ppid: Int32?, tty: String?, cwd: String?) { self.pid = pid; self.ppid = ppid; self.tty = tty; self.cwd = cwd }
    }

    /// `host` runs the plugin. With a tty it is the TUI itself (OpenCode without the service). Else the one process
    /// that runs the same binary from a terminal in `cwd`; nil when there is none or more than one.
    public static func find(host: Int32, cwd: String?) -> Int32? {
        guard let info = ProcInfo.info(of: host) else { return nil }
        if info.tty != nil { return host }
        guard let cwd, let exe = PeerCheck.path(of: host) else { return nil }
        let candidates = ProcInfo.allPids().filter { $0 != host && PeerCheck.path(of: $0) == exe }.compactMap { pid -> Candidate? in
            guard let i = ProcInfo.info(of: pid) else { return nil }
            return Candidate(pid: pid, ppid: i.ppid, tty: i.tty, cwd: ProcInfo.cwd(of: pid))
        }
        return pick(candidates, cwd: PeerCheck.resolved(cwd))
    }

    /// Only these events search for the TUI (a scan of all processes) and can move a session to another pid.
    /// A new turn or a card is when the user is at a terminal; other events keep the routing the session has.
    public static let routingEvents: Set<String> = ["SessionStart", "UserPromptSubmit", "PermissionRequest"]

    /// The app's check of a reported TUI: `host` has no tty, and `pid` runs the same binary from a terminal in `cwd`.
    public static func isTUI(_ pid: Int32, of host: Int32, cwd: String?) -> Bool {
        guard let cwd, ProcInfo.tty(of: host) == nil, ProcInfo.tty(of: pid) != nil,
              let exe = PeerCheck.path(of: host), PeerCheck.path(of: pid) == exe else { return false }
        return ProcInfo.cwd(of: pid) == PeerCheck.resolved(cwd)
    }

    static func pick(_ all: [Candidate], cwd: String) -> Int32? {
        let hits = all.filter { $0.tty != nil && $0.cwd == cwd }
        let pids = Set(hits.map(\.pid))
        // Helper processes of one TUI run the same binary: only the top one counts.
        let tops = hits.filter { !pids.contains($0.ppid ?? -1) }
        return tops.count == 1 ? tops[0].pid : nil
    }
}

public enum OpenCodeInstallError: Error, Equatable, CustomStringConvertible {
    case notOurs(String)
    case badTemplate

    public var description: String {
        switch self {
        case .notOurs(let p): "\(p) exists and was not written by Buddy. Buddy did not change it."
        case .badTemplate: "The bundled OpenCode plugin is missing or damaged. Reinstall Buddy."
        }
    }
}

/// Writes and removes Buddy's OpenCode plugin. Only a file that starts with `marker` is Buddy's.
public enum OpenCodeInstaller {
    public static let marker = "// buddy:opencode-plugin"
    public static let fileName = "buddy.js"
    static let placeholder = "\"__BUDDY_HOOK_PATH__\""

    /// `$OPENCODE_CONFIG_DIR/plugins`, else `$XDG_CONFIG_HOME/opencode/plugins`, else `~/.config/opencode/plugins`.
    public static func pluginURL(env: [String: String], home: String) -> URL {
        let config = env["OPENCODE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ((env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config") + "/opencode")
        return URL(fileURLWithPath: config).appendingPathComponent("plugins").appendingPathComponent(fileName)
    }

    /// The template with the hook path as a JSON string literal; nil when the template is not Buddy's plugin.
    public static func render(template: String, hookPath: String) -> String? {
        guard template.hasPrefix(marker), template.contains(placeholder),
              let data = try? JSONSerialization.data(withJSONObject: hookPath, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return template.replacingOccurrences(of: placeholder, with: literal)
    }

    static func isOurs(_ data: Data) -> Bool { data.starts(with: Data(marker.utf8)) }

    public enum Status: Sendable, Equatable {
        case missing, current
        /// Buddy's file from another version or app path.
        case outdated
        /// Another file has Buddy's file name.
        case foreign
    }

    public static func status(url: URL, template: String?, hookPath: String) -> Status {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        guard isOurs(data) else { return .foreign }
        let want = template.flatMap { render(template: $0, hookPath: hookPath) }
        return want.map { Data($0.utf8) } == data ? .current : .outdated
    }

    /// Atomic write; refuses to replace a file that is not Buddy's.
    public static func install(url: URL, template: String?, hookPath: String) throws -> InstallResult {
        guard let text = template.flatMap({ render(template: $0, hookPath: hookPath) }) else { throw OpenCodeInstallError.badTemplate }
        let new = Data(text.utf8)
        if let old = FileManager.default.contents(atPath: url.path) {
            guard isOurs(old) else { throw OpenCodeInstallError.notOurs(url.path) }
            if old == new { return .unchanged }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: url, options: [.atomic])
        return .written(backup: nil)
    }

    /// Removes the file only when it is Buddy's.
    public static func remove(url: URL) throws -> InstallResult {
        guard let data = FileManager.default.contents(atPath: url.path), isOurs(data) else { return .unchanged }
        try FileManager.default.removeItem(at: url)
        return .written(backup: nil)
    }
}

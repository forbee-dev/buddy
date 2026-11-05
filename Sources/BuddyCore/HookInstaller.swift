import Foundation
import os

public enum HookInstallerError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case notAnObject
    case unexpectedShape(String)

    public var description: String {
        switch self {
        case .invalidJSON(let m): "settings.json is not valid JSON (\(m)). Buddy did not change it."
        case .notAnObject: "settings.json is not a JSON object. Buddy did not change it."
        case .unexpectedShape(let k): "settings.json has an unexpected value at \(k). Buddy did not change it."
        }
    }
}

public enum InstallResult: Equatable, Sendable {
    case unchanged
    case written(backup: String?)
}

/// Merges Buddy's hook entries into Claude Code settings. Buddy entries are the handlers whose command is the buddy-hook path.
public enum HookInstaller {
    struct Spec { let event: String; let matcher: String?; let timeout: Int }

    static let specs: [Spec] = [
        Spec(event: "SessionStart", matcher: nil, timeout: 5),
        Spec(event: "SessionEnd", matcher: nil, timeout: 5),
        Spec(event: "UserPromptSubmit", matcher: nil, timeout: 5),
        Spec(event: "Stop", matcher: nil, timeout: 5),
        // Runs instead of Stop when the turn ends with an API error.
        Spec(event: "StopFailure", matcher: nil, timeout: 5),
        Spec(event: "Notification", matcher: nil, timeout: 5),
        // The only blocking hook: it answers permissions and AskUserQuestion.
        Spec(event: "PermissionRequest", matcher: nil, timeout: 3600),
        // Agent/Task: the call's description names the subagent that starts next.
        Spec(event: "PreToolUse", matcher: "AskUserQuestion|Agent|Task", timeout: 5),
        Spec(event: "PostToolUse", matcher: nil, timeout: 5),
        Spec(event: "PostToolUseFailure", matcher: nil, timeout: 5),
        Spec(event: "PermissionDenied", matcher: nil, timeout: 5),
        Spec(event: "SubagentStart", matcher: nil, timeout: 5),
        Spec(event: "SubagentStop", matcher: nil, timeout: 5),
        Spec(event: "PreCompact", matcher: nil, timeout: 5),
        Spec(event: "PostCompact", matcher: nil, timeout: 5),
    ]

    public static var eventCount: Int { specs.count }

    static let hookSuffix = "/Contents/MacOS/buddy-hook"
    public static let backupsKept = 5

    /// Always single-quoted for the shell; `'` becomes `'\''`.
    public static func command(for hookPath: String) -> String {
        "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Inverse of `command(for:)` for a fully single-quoted string; otherwise the input unchanged.
    static func unquoted(_ cmd: String) -> String {
        guard cmd.count >= 2, cmd.hasPrefix("'"), cmd.hasSuffix("'") else { return cmd }
        return String(cmd.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Buddy's handler: exactly the quoted form Buddy writes, for this path or any
    /// `.../Contents/MacOS/buddy-hook` (an older or moved Buddy.app).
    static func isOurs(_ cmd: String, hookPath: String) -> Bool {
        let path = unquoted(cmd)
        guard command(for: path) == cmd else { return false }
        return path == hookPath || path.hasSuffix(hookSuffix)
    }

    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) else { return [:] }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch {
            throw HookInstallerError.invalidJSON(error.localizedDescription)
        }
        guard let dict = obj as? [String: Any] else { throw HookInstallerError.notAnObject }
        return dict
    }

    static func serialize(_ dict: [String: Any]) throws -> Data {
        var d = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    /// Returns new file contents, or nil when nothing changes.
    public static func install(settings: Data?, hookPath: String) throws -> Data? {
        let original = try parse(settings)
        var dict = original
        var hooks = removingOurs(try hooksObject(original), hookPath: hookPath)
        let cmd = command(for: hookPath)
        for spec in specs {
            guard hooks[spec.event] == nil || hooks[spec.event] is [Any] else { throw HookInstallerError.unexpectedShape("hooks.\(spec.event)") }
            var groups = hooks[spec.event] as? [Any] ?? []
            var group: [String: Any] = ["hooks": [["type": "command", "command": cmd, "timeout": spec.timeout]]]
            if let m = spec.matcher { group["matcher"] = m }
            groups.append(group)
            hooks[spec.event] = groups
        }
        dict["hooks"] = hooks
        return NSDictionary(dictionary: dict).isEqual(to: original) ? nil : try serialize(dict)
    }

    public static func uninstall(settings: Data?, hookPath: String) throws -> Data? {
        let original = try parse(settings)
        guard original["hooks"] != nil else { return nil }
        let hooks = try hooksObject(original)
        var dict = original
        dict["hooks"] = removingOurs(hooks, hookPath: hookPath)
        return NSDictionary(dictionary: dict).isEqual(to: original) ? nil : try serialize(dict)
    }

    /// Refuses a `hooks` value that is not an object instead of replacing it.
    static func hooksObject(_ dict: [String: Any]) throws -> [String: Any] {
        guard let value = dict["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw HookInstallerError.unexpectedShape("hooks") }
        return hooks
    }

    /// Drops Buddy handlers; drops a group or event only if Buddy emptied it.
    static func removingOurs(_ hooks: [String: Any], hookPath: String) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { g in
                guard var group = g as? [String: Any], let handlers = group["hooks"] as? [Any] else { return g }
                let left = handlers.filter { h in
                    guard let cmd = (h as? [String: Any])?["command"] as? String else { return true }
                    return !isOurs(cmd, hookPath: hookPath)
                }
                if left.count == handlers.count { return g }
                if left.isEmpty { return nil }
                group["hooks"] = left
                return group
            }
            if kept.isEmpty && !groups.isEmpty { out[event] = nil } else { out[event] = kept }
        }
        return out
    }

    /// Reads, backs up, and writes `settingsURL`. Follows a symlinked settings file instead of replacing it.
    public static func apply(install: Bool, settingsURL: URL, hookPath: String, now: Date = Date()) throws -> InstallResult {
        let url = settingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let new = install ? try self.install(settings: existing, hookPath: hookPath)
                          : try uninstall(settings: existing, hookPath: hookPath)
        guard let new else { return .unchanged }
        var backup: String?
        if let existing {
            backup = try writeBackup(existing, settingsPath: url.path, now: now)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try new.write(to: url, options: [.atomic])
        return .written(backup: backup)
    }

    private static let log = Logger(subsystem: "com.tiagosantos.buddy", category: "installer")

    /// Backup with mode 0600; keeps only the newest `backupsKept`. A failed prune never blocks the install.
    static func writeBackup(_ data: Data, settingsPath: String, now: Date) throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = settingsPath + ".buddy-backup-" + f.string(from: now)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SocketError(call: "create backup", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let prefix = (settingsPath as NSString).lastPathComponent + ".buddy-backup-"
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(prefix) }.sorted()) ?? []
        for old in all.dropLast(backupsKept) where (try? FileManager.default.removeItem(atPath: dir + "/" + old)) == nil {
            log.error("Old settings backup not removed: \(old, privacy: .public)")
        }
        return path
    }

    public enum Status: Sendable, Equatable {
        case missing
        /// Buddy hooks exist but differ from what Install writes now (new events, or a moved app).
        case outdated
        case current
        /// settings.json is not JSON or has a shape Install refuses to change; Install would fail.
        case invalid
    }

    public static func status(settings: Data?, hookPath: String) -> Status {
        let dict: [String: Any], hooks: [String: Any], new: Data?
        do {
            dict = try parse(settings)
            hooks = try hooksObject(dict)
            new = try install(settings: settings, hookPath: hookPath)
        } catch {
            return .invalid
        }
        guard dict["hooks"] != nil else { return .missing }
        if new == nil { return .current }
        return NSDictionary(dictionary: removingOurs(hooks, hookPath: hookPath)).isEqual(to: hooks) ? .missing : .outdated
    }

    public static func status(settingsURL: URL, hookPath: String) -> Status {
        status(settings: try? Data(contentsOf: settingsURL.resolvingSymlinksInPath()), hookPath: hookPath)
    }

    /// Events that have no handler with exactly this hook's command.
    public static func missingEvents(settings: Data?, hookPath: String) -> [String] {
        let hooks = (try? hooksObject(parse(settings))) ?? [:]
        let cmd = command(for: hookPath)
        return specs.map(\.event).filter { event in
            !(hooks[event] as? [Any] ?? []).contains { g in
                ((g as? [String: Any])?["hooks"] as? [Any] ?? []).contains { ($0 as? [String: Any])?["command"] as? String == cmd }
            }
        }
    }

    public static func isInstalled(settingsURL: URL, hookPath: String) -> Bool {
        status(settingsURL: settingsURL, hookPath: hookPath) == .current
    }
}

import Foundation

/// Keeps the newest `capacity` elements.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var items: [Element] = []
    public init(capacity: Int) { self.capacity = capacity }

    public mutating func append(_ e: Element) {
        items.append(e)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }
}

/// One line of "Last events". Never holds commands, prompts, or tokens; the session id is cut to 8 chars.
public struct DiagEvent: Sendable, Equatable {
    public var time: Date
    public var session: String
    /// The folder name; `host` is set for an SSH session. The report replaces both with aliases.
    public var project: String
    public var host: String?
    public var event: String
    public var tool: String?
    public var result: String

    public init(time: Date, sessionId: String, project: String, host: String? = nil, event: String, tool: String?, result: String) {
        self.time = time
        session = String(sessionId.prefix(8))
        self.project = project
        self.host = host
        self.event = Activity.clip(event, 40)
        self.tool = tool.map { Activity.clip($0, 64) }
        self.result = result
    }

    /// Result text for a PermissionRequest reply.
    public static func result(for output: JSONValue) -> String {
        guard let d = output["hookSpecificOutput"]?["decision"] else { return "deferred" }
        if d["behavior"]?.string == "deny" { return "replied deny" }
        if d["updatedPermissions"] != nil { return "replied always allow" }
        if d["updatedInput"] != nil { return "replied answers" }
        return "replied allow"
    }
}

public struct DiagRow: Sendable, Equatable {
    public enum Level: String, Sendable { case ok = "OK", warn = "WARN", bad = "FAIL" }
    public var level: Level
    public var title: String
    public var detail: String
    public var fix: String?
    public init(_ level: Level, _ title: String, _ detail: String, fix: String? = nil) {
        self.level = level; self.title = title; self.detail = detail; self.fix = fix
    }
}

/// Settings that stop Claude Code from running Buddy's hooks. Read only; missing files are fine.
public enum HookBlockers {
    public struct File: Sendable {
        public var name: String
        public var data: Data?
        public var managed: Bool
        public init(name: String, data: Data?, managed: Bool) { self.name = name; self.data = data; self.managed = managed }
    }

    /// `blockers`: what turns the hooks off. `unreadable`: files that exist but are not a JSON object.
    public static func check(_ files: [File]) -> (blockers: [String], unreadable: [String]) {
        var blockers: [String] = [], unreadable: [String] = []
        for f in files {
            guard let data = f.data else { continue }
            guard let dict = try? HookInstaller.parse(data) else { unreadable.append(f.name); continue }
            if dict["disableAllHooks"] as? Bool == true { blockers.append("disableAllHooks in \(f.name)") }
            // Claude Code reads allowManagedHooksOnly from managed settings only.
            if f.managed, dict["allowManagedHooksOnly"] as? Bool == true { blockers.append("allowManagedHooksOnly in \(f.name)") }
        }
        return (blockers, unreadable)
    }
}

public enum ClaudeVersion {
    /// Native installs run `.../claude/versions/<version>`. Other installs (npm runs node) give nil.
    public static func fromExecutable(_ path: String?) -> String? {
        guard let parts = path?.split(separator: "/"), parts.count >= 2, parts[parts.count - 2] == "versions",
              let v = parts.last, v.count <= 32, v.first?.isNumber == true,
              v.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0.isLetter) }) else { return nil }
        return String(v)
    }
}

public enum DiagnosticsReport {
    public static func format(rows: [DiagRow], events: [DiagEvent], generated: Date, home: String,
                              timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        var out = ["Buddy diagnostics report", "Generated: \(f.string(from: generated))", ""]
        for r in rows {
            out.append("[\(r.level.rawValue)] \(r.title): \(r.detail)")
            if let fix = r.fix, r.level != .ok { out.append("       Fix: \(fix)") }
        }
        out += ["", "Last events (oldest first, max 50):"]
        if events.isEmpty { out.append("  (none)") }
        f.dateFormat = "HH:mm:ss"
        // Project and host names stay out of a report meant for a public issue: each gets an alias for this report.
        var projects: [String: String] = [:], hosts: [String: String] = [:]
        func alias(_ name: String, _ prefix: String, _ table: inout [String: String]) -> String {
            if let a = table[name] { return a }
            let a = "\(prefix)-\(table.count + 1)"
            table[name] = a
            return a
        }
        for e in events {
            var project = e.project == "-" ? "-" : alias(e.project, "project", &projects)
            if let h = e.host { project = alias(h, "ssh", &hosts) + ":" + project }
            out.append("  " + [f.string(from: e.time), e.session, project, e.event, e.tool ?? "-", e.result].joined(separator: "  "))
        }
        return redact(out.joined(separator: "\n") + "\n", home: home)
    }

    /// Home paths (any letter case: APFS ignores it) become `~`; UUIDs (session ids) keep their first 8 chars.
    public static func redact(_ s: String, home: String) -> String {
        var out = s
        if !home.isEmpty, home != "/" {
            // A trailing period ends a sentence, so "/Users/me." is redacted; "/Users/me.old" is another folder.
            let homeRe = NSRegularExpression.escapedPattern(for: home) + "(?=$|\\.(?![A-Za-z0-9_-])|[^A-Za-z0-9._-])"
            out = replace(out, homeRe, "~", options: .caseInsensitive)
        }
        return replace(out, "\\b([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b", "$1…")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

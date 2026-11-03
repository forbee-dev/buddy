import Foundation

/// "It looks like you're…" tips for the current tool call. Static text only: a tip never quotes the command or path.
public enum Tips {
    struct Rule {
        var tools: Set<String>
        /// Lowercased substrings of the Bash command or the file path; one match is enough.
        var any: [String]
        var text: String
    }

    static let edits: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let rules: [Rule] = [
        Rule(tools: ["Bash"], any: ["npm test", "npm run test", "yarn test", "pnpm test", "swift test", "pytest", "go test", "cargo test", "jest", "vitest", "rspec"],
             text: "It looks like you're running tests. Want me to cheer?"),
        Rule(tools: edits, any: [".sql", "migrations/", "migrate/"], text: "It looks like you're writing a migration. Back up first?"),
        Rule(tools: ["Bash"], any: ["rm -rf"], text: "It looks like you're deleting things. I hope you meant it."),
        Rule(tools: ["Bash"], any: ["git push"], text: "It looks like you're shipping. Fingers crossed!"),
        Rule(tools: ["Bash"], any: ["git rebase"], text: "It looks like you're rebasing. Deep breaths."),
        Rule(tools: ["Bash"], any: ["git commit"], text: "It looks like you're committing. Shall I hum a little tune?"),
        Rule(tools: ["Bash"], any: ["npm install", "npm i ", "yarn add", "pnpm add", "pip install", "brew install", "cargo add", "swift package add"],
             text: "It looks like you're adding a dependency. I'll guard the lockfile."),
        Rule(tools: ["Bash"], any: ["docker ", "podman "], text: "It looks like you're shipping containers. I'll hold the whale."),
        Rule(tools: ["Bash"], any: ["swift build", "npm run build", "cargo build", "xcodebuild", "make", "gradle", "tsc"],
             text: "It looks like you're building. Snack break?"),
        Rule(tools: ["Bash"], any: ["curl ", "wget "], text: "It looks like you're calling the internet. Say hi for me."),
        Rule(tools: edits, any: ["dockerfile"], text: "It looks like you're writing a Dockerfile. Layers, like an onion."),
        Rule(tools: edits, any: [".github/workflows", ".gitlab-ci", ".circleci"], text: "It looks like you're editing CI. May the pipeline be green."),
        Rule(tools: edits, any: ["package.json", "package.swift", "cargo.toml", "pyproject.toml"], text: "It looks like you're changing dependencies. Careful with those versions!"),
        Rule(tools: edits, any: ["test", "spec"], text: "It looks like you're writing tests. I'm proud of you."),
        Rule(tools: edits, any: [".css", ".scss", ".less"], text: "It looks like you're styling. Center that div!"),
        Rule(tools: edits, any: [".md", ".mdx", ".rst"], text: "It looks like you're writing docs. Future you says thanks."),
        Rule(tools: ["Grep", "Glob"], any: [""], text: "It looks like you're searching. I'll check under the couch."),
        Rule(tools: ["WebFetch", "WebSearch"], any: [""], text: "It looks like you're researching. Bring back snacks."),
    ]

    /// The first rule for this tool whose pattern is in the command (Bash) or the file path (edits).
    public static func match(tool: String?, input: JSONValue?) -> String? {
        guard let tool else { return nil }
        let hay = (tool == "Bash" ? input?["command"]?.string : input?["file_path"]?.string)?.lowercased() ?? ""
        return rules.first { $0.tools.contains(tool) && $0.any.contains { $0.isEmpty || hay.contains($0) } }?.text
    }
}

/// At most one tip per session per `interval`.
public struct TipLimiter: Sendable {
    public static let interval: TimeInterval = 3600
    private var shown: [String: Date] = [:]
    public init() {}

    /// True (and remembered) when `sid` had no tip in the last hour.
    public mutating func allow(_ sid: String, now: Date) -> Bool {
        if let last = shown[sid], now.timeIntervalSince(last) < Self.interval { return false }
        shown[sid] = now
        return true
    }

    /// The session is gone: drop its entry, so the map does not grow without end.
    public mutating func forget(_ sid: String) { shown[sid] = nil }
    var count: Int { shown.count }
}

/// Two buddies that finish close in time and space high-five.
public enum HighFive {
    public static let window: TimeInterval = 3
    public static let distance: Double = 300

    public struct Finish: Sendable {
        public var key: String
        public var at: Date
        /// Center x in points.
        public var x: Double
        /// Index in a grouped arrangement; nil in free mode.
        public var slot: Int?
        public init(key: String, at: Date, x: Double, slot: Int?) { self.key = key; self.at = at; self.x = x; self.slot = slot }
    }

    /// The closest buddy that finished at most 3 s before `new`, within 300 pt or in the next group slot.
    public static func partner(for new: Finish, among recent: [Finish]) -> Finish? {
        recent.filter { f in
            guard f.key != new.key, abs(new.at.timeIntervalSince(f.at)) <= window else { return false }
            if let a = f.slot, let b = new.slot { return abs(a - b) == 1 }
            return abs(f.x - new.x) <= distance
        }.min { abs($0.x - new.x) < abs($1.x - new.x) }
    }
}

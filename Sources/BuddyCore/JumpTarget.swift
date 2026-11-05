import Foundation

/// Chooses which editor window folder a Jump must raise, and how to ask the editor CLI for it.
public enum JumpTarget {
    public struct Pick: Equatable, Sendable {
        public var folder: String
        /// True when an extension reported the folder as open, so the CLI cannot create a new window.
        public var isOpen: Bool
        /// Saved workspace file of the window that holds `folder`, for the title match.
        public var workspaceFile: String?
        /// What the editor CLI may open. Nil when only a new window could result (multi-root without a saved file).
        public var cliTarget: String?
    }

    /// One editor window as its extension reports it.
    public struct Window: Equatable, Sendable {
        public var folders: [String]
        public var workspaceFile: String?
        public init(folders: [String], workspaceFile: String?) { self.folders = folders; self.workspaceFile = workspaceFile }
    }

    public static let maxFolders = 20
    public static let maxFolderLength = 1024

    /// Keeps absolute paths only, at most 20, each at most 1024 chars.
    public static func validFolders(_ raw: [String]?) -> [String] {
        Array((raw ?? []).filter { $0.hasPrefix("/") && $0.count <= maxFolderLength && !$0.contains("\0") }.prefix(maxFolders))
    }

    /// Keeps an absolute `.code-workspace` path of at most 1024 chars.
    public static func validWorkspaceFile(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.count <= maxFolderLength, !raw.contains("\0"), raw.hasSuffix(".code-workspace") else { return nil }
        return raw
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        let f = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return f == "/" || path == f || path.hasPrefix(f + "/")
    }

    static func longestPrefix(of cwd: String, in folders: [String]) -> String? {
        folders.filter { contains($0, cwd) }.max { $0.count < $1.count }
    }

    /// Owner client folder, else the longest known folder holding the cwd, else the cwd.
    public static func pick(owner: Window?, all: [Window], cwd: String) -> Pick {
        func make(_ f: String, _ w: Window) -> Pick {
            Pick(folder: f, isOpen: true, workspaceFile: w.workspaceFile,
                 cliTarget: w.workspaceFile ?? (w.folders.count > 1 ? nil : f))
        }
        if let o = owner, let f = longestPrefix(of: cwd, in: o.folders) ?? o.folders.first { return make(f, o) }
        let hits = all.compactMap { w in longestPrefix(of: cwd, in: w.folders).map { ($0, w) } }
        if let (f, w) = hits.max(by: { $0.0.count < $1.0.count }) { return make(f, w) }
        return Pick(folder: cwd, isOpen: false, workspaceFile: nil, cliTarget: cwd)
    }

    /// Plain folder argument: the editor focuses the window that has it open. Never a shell string.
    public static func cliArgs(folder: String) -> [String]? {
        folder.hasPrefix("/") && !folder.contains("\0") ? [folder] : nil
    }

    /// Only ASCII letters and digits reach the AppleScript, so a tty name cannot inject script. Empty input gives "/dev/", which matches no tty.
    public static func safeTTY(_ tty: String) -> String { "/dev/" + tty.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    public static func cliCandidates(for app: TerminalApp) -> [String] {
        switch app {
        case .cursor:
            ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor", "/usr/local/bin/cursor", "/opt/homebrew/bin/cursor"]
        case .vscode:
            ["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", "/usr/local/bin/code", "/opt/homebrew/bin/code"]
        default: []
        }
    }
}

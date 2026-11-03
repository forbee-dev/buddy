import Foundation

/// Chooses which editor window folder a Jump must raise, and how to ask the editor CLI for it.
public enum JumpTarget {
    public struct Pick: Equatable, Sendable {
        public var folder: String
        /// True when an extension reported the folder as open, so the CLI cannot create a new window.
        public var isOpen: Bool
    }

    public static let maxFolders = 20
    public static let maxFolderLength = 1024

    /// Keeps absolute paths only, at most 20, each at most 1024 chars.
    public static func validFolders(_ raw: [String]?) -> [String] {
        Array((raw ?? []).filter { $0.hasPrefix("/") && $0.count <= maxFolderLength && !$0.contains("\0") }.prefix(maxFolders))
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        let f = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return f == "/" || path == f || path.hasPrefix(f + "/")
    }

    static func longestPrefix(of cwd: String, in folders: [String]) -> String? {
        folders.filter { contains($0, cwd) }.max { $0.count < $1.count }
    }

    /// Owner client folder, else the longest known folder holding the cwd, else the cwd.
    public static func pick(ownerFolders: [String]?, allFolders: [String], cwd: String) -> Pick {
        if let owner = ownerFolders, let f = longestPrefix(of: cwd, in: owner) ?? owner.first { return Pick(folder: f, isOpen: true) }
        if let f = longestPrefix(of: cwd, in: allFolders) { return Pick(folder: f, isOpen: true) }
        return Pick(folder: cwd, isOpen: false)
    }

    /// Plain folder argument: the editor focuses the window that has it open. Never a shell string.
    public static func cliArgs(folder: String) -> [String]? {
        folder.hasPrefix("/") && !folder.contains("\0") ? [folder] : nil
    }

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

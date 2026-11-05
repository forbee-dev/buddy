public enum TerminalApp: Sendable, Equatable {
    case vscode, cursor, iterm, terminal, claudeDesktop, other(String)

    public static let desktopBundleId = "com.anthropic.claudefordesktop"
    public static let desktopAppPath = "/Applications/Claude.app/"

    /// `chainPaths`: executable paths of claude's ancestors, when the caller looked them up.
    public static func detect(_ env: HookEnv, chainPaths: [String] = []) -> TerminalApp {
        if env.entrypoint == "claude-desktop" || env.bundleId == desktopBundleId
            || chainPaths.contains(where: { $0.hasPrefix(desktopAppPath) }) { return .claudeDesktop }
        switch env.bundleId {
        case "com.todesktop.230313mzl4w4u92": return .cursor
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders": return .vscode
        case "com.googlecode.iterm2": return .iterm
        case "com.apple.Terminal": return .terminal
        default: break
        }
        if let ask = env.askpassMain {
            if ask.contains("/Cursor.app/") { return .cursor }
            if ask.contains("/Visual Studio Code") || ask.contains("/Code.app/") { return .vscode }
        }
        switch env.termProgram {
        case "iTerm.app": return .iterm
        case "Apple_Terminal": return .terminal
        case "vscode": return .vscode
        case "WarpTerminal": return .other("Warp")
        case "ghostty": return .other("Ghostty")
        case let other?: return .other(other)
        case nil: return .other("terminal")
        }
    }

    public var isEditor: Bool { self == .vscode || self == .cursor }

    public var displayName: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .iterm: "iTerm2"
        case .terminal: "Terminal"
        case .claudeDesktop: "Claude Desktop"
        case .other(let s): s
        }
    }
}

import Foundation

public enum UninstallStep: Equatable, Sendable {
    case removeHooks
    /// The `settings.json.buddy-backup-*` files next to settings.json: they can hold API keys.
    case removeSettingsBackups(dir: String)
    /// `cli` nil: no `code` or `cursor` command was found.
    case uninstallExtension(editor: String, cli: String?)
    case unregisterLoginItem
    /// Only when the user leaves "Also delete the SSH token" on.
    case removeRemoteToken
    case removeSupportFolder(path: String)
    /// Never deletes the bundle: Finder shows it and the user drags it to the Trash.
    case quitAndReveal(appPath: String)

    public var title: String {
        switch self {
        case .removeHooks: "Remove Buddy's hooks from ~/.claude/settings.json (with a backup)"
        case .removeSettingsBackups: "Delete Buddy's settings.json backups from ~/.claude (they can hold API keys)"
        case .uninstallExtension(let editor, _): "Uninstall the companion extension from \(editor)"
        case .unregisterLoginItem: "Turn off Start at login"
        case .removeRemoteToken: "Delete the SSH token (\"Buddy SSH token\") from the login Keychain"
        case .removeSupportFolder: "Remove ~/Library/Application Support/Buddy"
        case .quitAndReveal: "Quit, and show Buddy.app in Finder so you can drag it to the Trash"
        }
    }
}

public enum UninstallPlan {
    public static let extensionId = "tiagosantos-local.buddy-companion"

    public static func supportFolder(home: String) -> String { home + "/Library/Application Support/Buddy" }

    /// The steps in order, with one extension step per editor command found.
    public static func steps(editors: [(name: String, cli: String)], home: String, appPath: String) -> [UninstallStep] {
        let ext = editors.isEmpty ? [UninstallStep.uninstallExtension(editor: "VS Code / Cursor", cli: nil)]
            : editors.map { UninstallStep.uninstallExtension(editor: $0.name, cli: $0.cli) }
        return [.removeHooks, .removeSettingsBackups(dir: home + "/.claude")] + ext + [.unregisterLoginItem, .removeRemoteToken, .removeSupportFolder(path: supportFolder(home: home)),
                                      .quitAndReveal(appPath: appPath)]
    }

    /// A backup file name as `HookInstaller.writeBackup` makes it.
    public static func isSettingsBackup(_ name: String) -> Bool { name.hasPrefix("settings.json.buddy-backup-") }

    /// True when `<cli> --list-extensions` output names the companion (ids are case-insensitive).
    public static func listsExtension(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == extensionId }
    }
}

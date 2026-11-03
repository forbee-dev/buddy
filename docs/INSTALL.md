# Install Buddy

## What Buddy tracks

Buddy tracks Claude Code sessions in terminals (iTerm2, Terminal, others), in IDE terminals (VS Code, Cursor), and in Claude Desktop local Code sessions.
It does not track cloud or VM sessions, or plain Claude chats.

Needs macOS 14 or later and Claude Code 2.1.224 or later. Tested on Claude Code 2.1.317 and Claude Desktop 4.4212.0 (Claude Code 2.1.309).

## Team install (from the DMG)

1. Download `Buddy-<version>.dmg`. Open it and drag **Buddy** to **Applications**.
2. Open Buddy from Applications. The app is not notarized, so macOS blocks it the first time.
   - Go to **System Settings → Privacy & Security**. Scroll down. Click **Open Anyway** next to the Buddy message.
   - On recent macOS, right-click → Open no longer skips this check.
   - Alternative in Terminal: `xattr -dr com.apple.quarantine /Applications/Buddy.app`
3. In the welcome window, grant the permissions (see below).
4. Click **Install hooks**.
5. If you use VS Code or Cursor, click **Install in VS Code** or **Install in Cursor**. Then reload the editor window.

Each ad-hoc or self-signed update is a new app identity for macOS. macOS may ask for Accessibility again after an update. Remove the old Buddy entry in System Settings → Privacy & Security → Accessibility and allow the new one.

## Build from source

You need only the Swift Command Line Tools. Xcode is not necessary.

```sh
./scripts/build-app.sh            # writes build/Buddy.app
open build/Buddy.app
```

- The script runs `swift build -c release` and assembles `build/Buddy.app`.
- `Contents/MacOS`: `Buddy` and `buddy-hook`.
- `Contents/Resources`: `sprites.json` (from `design/`), `AppIcon.icns`, and the newest `vscode-ext/buddy-companion-*.vsix` if there is one.
- `scripts/make-icon.swift` makes `Resources/AppIcon.icns` from the sprites when `design/sprites.json` changes.

### Local dev install

```sh
./scripts/install-local.sh
```

The script builds with `build-app.sh` and quits a running Buddy. It moves an old `/Applications/Buddy.app` to `~/.Trash` with a timestamp. Then it copies the new app with `ditto` and checks it with `codesign --verify --deep`. It unregisters `build/Buddy.app` from LaunchServices, registers `/Applications/Buddy.app`, and opens it. Use this instead of opening `build/Buddy.app`, so macOS does not keep two copies registered.

### Local signing certificate (once)

An ad-hoc signature makes macOS reset the Accessibility permission on every rebuild. To keep it:

1. Open Keychain Access. Select Keychain Access → Certificate Assistant → Create a Certificate.
2. Name: `Buddy Dev`. Identity Type: Self Signed Root. Certificate Type: Code Signing. Click Create.
3. Run `./scripts/build-app.sh` again. It finds `Buddy Dev` by itself.

### Tests

The tests use swift-testing (the Command Line Tools have no XCTest). Load the Testing macro plugin explicitly:

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

## First run and permissions

The welcome window opens on the first launch. You can open it again from the menu (**Welcome…**).

| Permission | Why |
|---|---|
| Notifications | Alerts when a session needs you or finishes. |
| Accessibility | Jump raises the editor window that has the project open. Without it, Jump needs the companion extension 0.1.2 for exact window focus. |
| Automation | Jump selects the iTerm2 or Terminal tab of the session. macOS asks once per app. |

You can see and request them later in Settings → Permissions.

### Notifications don't work

Notifications are optional. If **Request** shows "macOS refused":

1. Sign the app with a local certificate (see Local signing certificate above). Then run `./scripts/build-app.sh` again.
2. Or open System Settings → Notifications and turn Buddy on. Settings has an **Open Notification Settings** button.
3. After a denial, macOS does not ask again. **Request** then opens Notification Settings.

If Buddy runs from outside an Applications folder, the window first offers **Move to Applications**. The hooks point at the app's path, so move the app before you install them.

## Claude Code hooks

**Install hooks** (welcome window, or Settings → Hooks & Extension) adds Buddy's entries to `~/.claude/settings.json`:

- It writes a backup first: `settings.json.buddy-backup-<timestamp>`, mode 0600. It keeps the newest 5.
- It keeps all your other keys and hooks. A second install changes nothing.
- It refuses to write when the file is not valid JSON, or when `hooks` (or one of its events) has an unexpected type.
- The file is written back with sorted keys, so key order can change.
- Only new Claude sessions use the hooks.

Events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Notification`, `PermissionRequest` (timeout 3600 s, the only one that waits), `PreToolUse` (matcher `AskUserQuestion`), `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` (timeout 5 s each).

The command is the single-quoted absolute path of `Buddy.app/Contents/MacOS/buddy-hook`. Buddy recognizes its entries by that quoted form and the `/Contents/MacOS/buddy-hook` suffix. If you move the app, click Install again: the old entries are replaced.

**Uninstall hooks** removes only Buddy's entries.

If Buddy is not running, the hook exits at once with no output. Claude then works as if Buddy is not there.

## VS Code / Cursor extension

The companion extension lets Buddy type your next prompt into the right editor terminal, and focus that terminal on Jump.
- Jump needs the companion extension 0.1.2 or Accessibility for exact window focus. With two editor windows open, the extension tells Buddy which folder each window has.
- Settings → Hooks & Extension shows **Install in VS Code** and **Install in Cursor** for each editor command it finds (`code`, `cursor` in `/usr/local/bin`, `/opt/homebrew/bin`, or inside the app bundles).
- Buddy runs `<cli> --install-extension <bundled .vsix> --force` only when you click. It shows the result.
- Without the extension, Buddy sends the next prompt through the session's inbox socket, as a peer message.

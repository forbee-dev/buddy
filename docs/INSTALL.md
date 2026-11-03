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
(cd vscode-ext && npm ci && npm run package)   # builds the .vsix first
./scripts/build-app.sh            # writes build/Buddy.app
open build/Buddy.app
```

- The script runs `swift build -c release` and assembles `build/Buddy.app`.
- `Contents/MacOS`: `Buddy` and `buddy-hook`.
- `Contents/Resources`: `sprites.json` (from `design/`), `prices.json`, `skins/crate.json`, the `remote/` scripts, `AppIcon.icns`, and the newest `vscode-ext/buddy-companion-*.vsix` if there is one.
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

Events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Notification`, `PermissionRequest` (timeout 3600 s, the only one that waits), `PreToolUse` (matcher `AskUserQuestion|Agent|Task`), `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `SubagentStart`, `SubagentStop` (timeout 5 s each).

**After you update Buddy, click Install hooks again.** A new version can use new events (for example `SubagentStart` and `SubagentStop` for subagent minis). When your installed hooks lack them, the menu and Settings show "New hook events available: click Install hooks". Install adds only what is missing; your other hooks stay.

The command is the single-quoted absolute path of `Buddy.app/Contents/MacOS/buddy-hook`. Buddy recognizes its entries by that quoted form and the `/Contents/MacOS/buddy-hook` suffix. If you move the app, click Install again: the old entries are replaced.

**Uninstall hooks** removes only Buddy's entries.

If Buddy is not running, the hook exits at once with no output. Claude then works as if Buddy is not there.

## VS Code / Cursor extension

The companion extension lets Buddy type your next prompt into the right editor terminal, and focus that terminal on Jump.
- Jump needs the companion extension 0.1.2 or Accessibility for exact window focus. With two editor windows open, the extension tells Buddy which folder each window has.
- Settings → Hooks & Extension shows **Install in VS Code** and **Install in Cursor** for each editor command it finds (`code`, `cursor` in `/usr/local/bin`, `/opt/homebrew/bin`, or inside the app bundles).
- Buddy runs `<cli> --install-extension <bundled .vsix> --force` only when you click. It shows the result.
- Without the extension, Buddy sends the next prompt through the session's inbox socket, as a peer message.
- A next prompt can have more than one line. Extension 0.1.3 or later pastes it as one multi-line prompt. Older versions join the lines with spaces. Install the extension again after you update Buddy.

## Notifications and shortcuts

- Permission alerts have **Deny** and **Review…**. Review… opens the card, where you click Allow. No notification can allow a request.
- Question alerts have **Answer…**, which opens the card. "Claude finished" alerts have **Reply…**, which sends your next prompt through the same route and checks as the card.
- Deny and Reply… need an unlocked Mac. Alerts show the tool and the project, never the command.
- Deny answers only the request that the alert shows. If that request is already answered or replaced, Buddy sends nothing and posts "Already answered".
- To turn the actions off: Settings → Notifications → **Allow answering from notifications**.
- ⌃⌥B opens the newest waiting card. ⌃⌥Space opens the command palette: a list of sessions, waiting ones first. Change both in Settings → General. If you give one the other's key, the two swap.

## Fun, impatience, and away

Settings → General:
- **Get impatient after** (Off, 1, 3, 5, 10 min; default 3): a buddy that waits on you longer hops every 20 s and shows "waiting 3m" on its tag. At twice the time it grows to 1.25× and taps the screen, and Buddy sends one "Still waiting" notification (if that notification type is on). Answering clears it. With Reduce Motion, only the timer shows. Focus and Do Not Disturb hold the reminder as macOS decides.
- **While you were away** (Off, 5, 10, 30 min; default 5): after the screens sleep, the user session switches, or no input for that long, one buddy walks to the bottom center with a list of what happened. Click a line to open that card or Activity list. It takes keyboard focus when it opens. Esc or × closes it. It closes itself after 60 s, but never while it has focus, VoiceOver reads it, or the pointer is over it. Menu and palette: **Show last digest**. Nothing happened: no list.
- **Fun extras** (default on): two buddies that finish within 3 s high-five, all buddies party when every session is done, and now and then (at most once an hour per session) a working buddy shows a short tip. Tips never show the command. Reduce Motion turns off the high-five and the party.
- **Character**: Claude, a character from an enabled skin, or **Mix** (each session gets one of all enabled characters).

## Tokens and cost

Buddy adds up the tokens in each session's transcript and its subagent transcripts. It reads only new bytes, at most every 5 s while the session works, and once when it stops. It shows "42.1k tok · $0.31" in the Activity tab, the menu, and the command palette. Turn it off in Settings → General → **Show tokens and cost**.

The prices are in `~/Library/Application Support/Buddy/prices.json` (USD per million tokens, per model id). Buddy copies its placeholder table there on first start. **Edit prices…** opens it; restart Buddy after a change. A model that is not in the table shows tokens only. Check the prices for your plan at anthropic.com/pricing.

## Skins

Put skin files in `~/Library/Application Support/Buddy/skins/` (Settings → Skins → **Open skins folder**). Buddy loads them at once when the folder changes. Settings → Skins lists each skin with a switch, or the reason it was not loaded. The bundled example **Crate** is off until you switch it on. Format: [SKINS.md](SKINS.md).

## SSH sessions

Claude Code on another host can show up as a buddy too (opt-in: Settings → SSH). The host needs python3 3.8+. Setup, limits, and troubleshooting: [SSH.md](SSH.md). Script tests: `python3 scripts/remote/test_hook.py` (temp HOME only).

## Diagnostics

Settings → Diagnostics shows a green, orange, or red dot and a fix for each check: hooks, hooks turned off by `disableAllHooks` or `allowManagedHooksOnly`, the socket, connected extensions, permissions, the app signature, and the Claude Code versions seen. It also shows the last 50 hook events.

**Copy diagnostics report** puts the same data on the clipboard as plain text. Home paths become `~`, session ids keep their first 8 characters, and project and host names become aliases. The report never has prompts, commands, or tokens. Add it to a bug report.

## Uninstall

Menu bar icon → **Uninstall Buddy…**. A window lists the steps. Nothing changes until you click **Uninstall**. Each step then shows its result:

1. Remove Buddy's hooks from `~/.claude/settings.json`. Buddy writes a backup first, as for Uninstall hooks.
2. Uninstall the companion extension (`tiagosantos-local.buddy-companion`) from VS Code and Cursor with their `--uninstall-extension` command, if it is installed. Reload the editor windows after.
3. Turn off Start at login.
4. Remove `~/Library/Application Support/Buddy`.
5. **Quit and Show in Finder** quits Buddy and selects Buddy.app in Finder. Drag it to the Trash. Buddy never deletes the app bundle itself.

Buddy's settings (`com.tiagosantos.buddy` in UserDefaults) stay. To remove them too: `defaults delete com.tiagosantos.buddy`.

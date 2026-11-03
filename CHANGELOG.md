# Changelog

All notable changes to Buddy are in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-11-03

### Added
- Command palette (⌃⌥Space): sessions sorted by attention, inline cards, keyboard answers.
- Settings → Diagnostics with status rows, the last 50 hook events, and a redacted report to copy.
- Deny, Review…, Answer… and Reply… on notifications (Settings → Notifications to turn off).
- Menu → Uninstall Buddy… (hooks, extension, login item, data folder; reveals the app).
- Impatience: a buddy that waits longer than the set time (default 3 min) hops and shows a timer; at twice the time it grows and sends one reminder.
- "While you were away" digest: after a break, one buddy lists what finished, what waits, and failed subagents. Each line opens its card. It takes keyboard focus and never closes while focused, read by VoiceOver or under the pointer; Menu and palette have Show last digest.
- Fun extras (Settings → General): high-fives, a party when every session is done, and rare tips (20 s, announced to VoiceOver).
- Community skins from `~/Library/Application Support/Buddy/skins/`, with Settings → Skins and strict checks. See docs/SKINS.md.
- Skins can add whole characters; bundled example 'Crate', a pocket-console robot.
- Character → Mix gives each session a character from all enabled skins.
- Tokens and cost per session ("42.1k tok · $0.31") in Activity, the menu, and the palette, from an editable prices.json.
- Opt-in SSH sessions (remote Claude Code via ssh -R socket forwarding).

### Changed
- Double-click a buddy to jump to its terminal; Unpin moved to the right-click menu.
- Question card: Tab and Shift-Tab move keyboard focus. ←/→, Next or Return change the question. Picking an option never moves on by itself. Space picks only when no control has focus.
- Accessibility: Increase Contrast support, risk shown as text, 24 pt minimum click targets.
- Idle with only the sleeping buddy is 0.0% CPU (the sleep loop is a Core Animation animation). Hook overhead is about 4.5 ms per event.
- Next prompts keep newlines; extension 0.1.3 sends them as a bracketed paste.
- A subagent with a running background shell stays open after its SubagentStop, and resumes on a second SubagentStart.

### Fixed
- Jump: a newer Jump cancels an older one that is still running.
- A subagent killed with TaskStop stayed "running"; it now shows "stopped".
- A subagent was marked done too early when it had left the task list but its shell still ran.
- In free mode, name tags of buddies close together overlapped. Spacing now uses the wider of sprite and tag; a tag that still overlaps is cut (full name in a tooltip) or stacked.

### Security
- Notifications can no longer allow a request. Permission alerts offer Deny and Review…; Review… opens the armed card.
- The SSH install command no longer holds the token. It pipes a 0600 file that Buddy deletes after 10 minutes, on Rotate token, and on quit.
- The diagnostics report replaces project and host names with aliases and redacts home paths in any letter case.
- ⌘⌫ in a text field edits the text and no longer denies the open card.
- Token counts are clamped and a transcript line over 8 MB is skipped; prices outside 0 to 1000 are rejected.
- Skins cannot reuse another skin's legend char or color key, or a built-in color key; labels are revealed and clipped; folder reloads run off the main thread.
- Project names are revealed and clipped; remote peer checks use the connect-time audit token.
- The SSH token's Keychain item trusts only Buddy; the remote hook refuses a socket in a folder that others can write.
- Remote installs write settings through a random temp file; Uninstall can delete the SSH token, times out editor commands, and asks before it removes the data folder when hook removal failed.
- CI actions are pinned by commit SHA; file reads resolve the folder, then open with O_NOFOLLOW_ANY, so a folder swapped for a symlink after the check is refused.

## [0.2.0] - 2026-11-03

### Added
- Menu bar icon with a count dot, and a dropdown: Hide/Show buddies, buddy list, Settings, Welcome, Quit.
- Support for local Code sessions in Claude Desktop (next prompt through the inbox socket).
- Size setting: Tiny, Small, Medium, Large, Huge, with a live preview.
- Arrangement setting: Free, Stacked or Row. Grouped buddies keep a fixed order and drag as one group.
- Question card redesign: one question at a time, numbered options, keyboard keys, inline Other, review step.
- Permission and done cards in the same visual style, with a code block, copy button and risk accents.
- Unique look per session, assigned once and different among visible buddies.
- Subagent and background shell tracking: mini buddies, a shell chip and an Activity tab. Click **Install hooks** again after the update.
- `scripts/install-local.sh` for local installs (old app goes to the Trash).
- DMG packaging with `scripts/make-dmg.sh`.

### Changed
- Signing picks the self-signed "Buddy Dev" identity, so Accessibility grants survive rebuilds.
- Notification permission shows the real error, a manual path and an Open Notification Settings button.

### Fixed
- Jump: a newer Jump cancels an older one that is still running.
- Security review findings from the first release.
- Jump raised the most recent Cursor window instead of the window of the session.
- Work inside subagents changed the state of the main buddy.

## [0.1.0] - 2026-11-03

### Added
- First release: one pixel mascot on the desktop for each Claude Code session.
- `buddy-hook` CLI and a Unix socket (mode 0600). The hook fails open.
- Permission and question answers from the card through the PermissionRequest hook.
- Next prompt through the VS Code and Cursor companion extension, or the Claude Code inbox socket.
- Sprites as JSON: palettes, outfits and an effects layer.

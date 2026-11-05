# Changelog

All notable changes to Buddy are in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Notification banners only show while the buddies are hidden, the screen is asleep or you are away, because the buddy already tells you. Settings → Notifications → **Also while the buddies are on screen** brings them back.

## [1.0.0] - 2026-11-05

### Added
- Settings → General → **Show plan usage**: a "5h 23% · 7d 41%" chip with the claude.ai 5-hour and 7-day limits in the bubble, the tooltip, the menu and the palette, through a status line bridge that keeps your own status line command working, plus one notification when a window passes 90%. Off by default.
- Universal binary: Buddy runs native on Apple silicon and Intel Macs.
- `StopFailure` hook: a turn that ends with a rate limit or another API error shows the error state and the reason on the card. Click **Install hooks** again after the update.
- `PreCompact` and `PostCompact` hooks: the card and the palette show "Compacting…" while Claude Code compacts the context. Click **Install hooks** again after the update.
- Settings → General → **Keep the Mac awake while a session works**: stops idle sleep while a visible local session starts or works. Off by default.
- A session named with `claude --name` or `/rename` shows that name on the tag, the cards, the menu, the palette and the digest.
- Next prompts reach Claude Code builds that use the per-user inbox folder (`/tmp/cc-socks-<uid>`).
- Settings → About links to Releases, Issues and Discussions, and **Check for updates…** opens the releases page in the browser.
- Jump shows a message when the session runs inside tmux or screen and the terminal cannot be raised.
- Homebrew cask: `livecheck` finds new releases; the caveat explains the self-signed signature.
- Docs: a troubleshooting table in INSTALL.md, how to verify the DMG hash, the signing facts, and a Limits section in the README.

### Changed
- Warp and Ghostty show by name in the menu and the cards.
- Settings → Hooks & Extension: **Install hooks** is disabled until Buddy runs from Applications. A translocated or Downloads path dies with the next launch.
- A second copy of Buddy brings the running one to the front, or shows an alert, instead of exiting without a word.
- Settings → Permissions: Accessibility shows "Not granted" after the first prompt, and **Request** opens the Accessibility pane.
- Companion extension: reconnects within 5 s while Buddy is not running yet, and refuses to type when `claude` is not the foreground process of the shell.
- Build: `build-app.sh` fails when the companion extension is not built. CI has a `package` job that runs the build and DMG scripts.
- Uninstall Buddy… also deletes the `settings.json.buddy-backup-*` files in `~/.claude`. The remote uninstall does the same.

### Fixed
- A compact (`/compact`, auto-compact) keeps the session state. Before, the buddy jumped back to "starting".
- A second call of the same tool no longer closes the open permission card. The card waits for its own call.
- A resume onto an ended session id leaves one buddy, not a live one next to an idle one.
- A late permission notification after the terminal already answered no longer sets the buddy to "needs permission".
- Subagents that start after their Agent call returned get the right label.
- The buddies stay inside the screen when a display connects, disconnects or changes resolution.
- Esc leaves the next-prompt field and keeps the typed text. Before, it closed the card and dropped it.
- Buddies keep walking and sessions keep reaping while a menu is open.
- Settings → General: a stale "impatient" or "away" value snaps to a picker choice, so the picker is never blank.
- The hook socket is closed only after its read source is cancelled, and a closed card frees its view.

### Security
- Settings backups that can hold API keys are removed on uninstall (app and remote).
- The DMG carries its own code signing identifier.

## [0.5.1] - 2026-11-05

### Changed
- The done card opens on the done view, not on Activity, when the session ran subagents.
- A done buddy shows a green check badge. Before, it showed a red count.
- The Crate and Bee hold a green check when they are done.
- A buddy throws a short confetti burst out of its frame when Claude finishes. Reduce Motion turns it off.

## [0.5.0] - 2026-11-05

### Changed
- A done buddy stays done until your next prompt. Before, it went idle about 60 s after Claude finished.
- The done card opens by itself when a session finishes a turn. It takes no keyboard focus. It closes after 8 seconds if you do not touch it.
- The done sprite plays once and holds its last frame while the session stays done.

## [0.4.0] - 2026-11-04

### Added
- Sounds for permissions, questions, done, errors and more (Settings → Sounds; original chiptune set or macOS sounds).
- A hidden Bee character (easter egg).
- Settings → General → Show cost on the buddy's name tag (off by default): "project · $0.31".
- ForgeBee subagents fly as bee minis once the Bee is found (Settings → General → Fun extras).

### Changed
- Homebrew: the `forbee-dev/tap` cask is published. Run `brew trust forbee-dev/tap` once before `brew install --cask forbee-dev/tap/buddy`.
- After "Hide Bee again", only `buzz` in the palette finds the Bee again. SSH projects never unlock it.
- The Bee callout stays at least 20 s, waits while you point at it, and Esc closes it.
- Buddies that stand still use no timer, and idle walks start from a delayed task. Three idle sessions use about 0% CPU.
- With "Play sounds" off, the sound set, volume, and "Only when…" options are disabled.
- Companion extension 0.1.4: replies to the app go out in request order, a rejected hello closes the socket, and the ext-hello version comes from package.json.
- Remote uninstall now prunes old settings backups, like install.
- Build: build-app.sh bundles every skin JSON and rebuilds the icon when make-icon.swift changes; make-icon.swift fails on an unresolved legend slot. CI also runs the sound file check.

### Fixed
- Tokens and cost now show in every bubble header and the buddy tooltip, and update at once when a bubble opens.
- No "subagent done" sound after /clear or resume, and no replayed "Claude finished" alert when Claude Code closes a permission hook.
- A queued permission sound is never dropped when the 1.5 s window ends. A clock set back no longer mutes sounds.
- An invalid or unexpected ~/.claude/settings.json shows as such in Settings and Diagnostics, not as "installed".
- A failed prune of old settings backups no longer stops Install hooks.
- The name tag rounds tokens like the tooltip (42,999 → "43k").
- Hiding buddies or a sleeping screen stops the Bee flight.
- Single buddy mode shows the tokens and cost of all visible sessions.
- Sounds: fixed a click on short notes (question, subagent done).

### Accessibility
- VoiceOver reads usage as "42.1 thousand tokens, 31 cents". The marked Activity row is "selected". Option rows have stronger borders and marks. Rules that were only tooltips are now visible text.
- No subagent sound when minis are off, and no state sound while buddies are hidden unless a notification was posted.

### Security
- Tool names are clipped at 200 characters (app and remote hook). An extra ssh client counts only when its real binary is named `ssh`. Editor names in the log are clipped.

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

[Unreleased]: https://github.com/forbee-dev/buddy/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/forbee-dev/buddy/compare/v0.5.1...v1.0.0
[0.5.1]: https://github.com/forbee-dev/buddy/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/forbee-dev/buddy/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/forbee-dev/buddy/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/forbee-dev/buddy/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/forbee-dev/buddy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/forbee-dev/buddy/releases/tag/v0.1.0

<p align="center">
  <img src="docs/assets/hero.gif" alt="Three Claude buddies and one Crate robot cycling through working, question, permission and done, with subagent minis and a shell chip" width="760">
</p>

<h1 align="center">Buddy</h1>

<p align="center">
  A tiny pixel mascot on your desktop for every Claude Code session.<br>
  It tells you when a session needs you, and lets you answer from the mascot.
</p>

<p align="center">
  <a href="https://github.com/forbee-dev/buddy/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/forbee-dev/buddy/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange?logo=swift">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Works with Claude Code" src="https://img.shields.io/badge/works%20with-Claude%20Code-d97757">
</p>

## Why I built this

I run about four Claude Code sessions at once, across different projects. I kept missing the one that was waiting for a permission or an answer. It sat there for ten minutes while I looked at something else.

Then I saw another dev with a little mascot that stayed on screen all day. It reminded me of Clippy. I thought: what if every session had one, and the mascot could ask me things the way Clippy did?

So Buddy is a small, friendly Clippy for Claude Code. It is a personal tool. I use it every day. I put it here in case you want it too.

## What it does

Buddy is a native macOS app (Swift 6, SwiftUI and AppKit). It puts one mascot on your desktop for each running Claude Code session. It works with:

- any terminal
- the terminals in VS Code and Cursor
- local Code sessions in Claude Desktop

Each mascot shows what its session is doing:

| State | What you see |
| --- | --- |
| Working | A laptop with scrolling code |
| Question | A "?" bubble and a little hop |
| Permission | A worried face and a yellow shield |
| Done | A big grin, confetti and a green check |
| Error | Dizzy eyes and a small fire |
| Sleeping | Zzz, when nothing runs |
| Session ended | A wave goodbye, then it walks off |

Idle mascots wander along the bottom of your screen. You can drag one and it stays where you drop it.

Every session gets its own look. Buddy hashes the project path, so the same project always gets the same mascot, and no two visible buddies match. There are 10 palettes and 16 outfits. You can re-roll the look or pick one from the right-click menu. A name tag under each mascot shows the project.

<p align="center">
  <img src="docs/assets/outfits.png" alt="All 16 outfits" width="640">
</p>

### The cards

Click a mascot and a bubble card opens. Double-click a mascot (or its name tag) to jump to its terminal; on a subagent mini it jumps to the parent session. There are three kinds.

- **Permission card.** It shows the full tool input. It warns you when the sandbox is off. It makes hidden Unicode visible. Buttons: Allow, Deny (with an optional reason), Always allow (only the options Claude itself suggests), and Answer in terminal.
- **Question card.** One question at a time, with numbered options. Press `1` to `9` to pick one. Picking never moves on by itself: use Next, `↩` or `←` / `→`. Options can carry a preview, such as a code snippet. Single choice uses radio buttons, multiple choice uses checkboxes, and Other takes free text. A review step comes last.
- **Done card.** It shows Claude's last message and a "Next prompt" box. Send types the prompt into the session. Jump takes you to the right place.

Jump focuses the right terminal tab or editor window. For Claude Desktop, Jump brings the app to the front. Claude Desktop has no per-session link, so that is as close as it gets.

### Screenshots

| | | |
| :---: | :---: | :---: |
| <img src="docs/assets/screens/question-preview.png" alt="Question card with a preview, inside the command palette" width="260"> | <img src="docs/assets/screens/permission-card.png" alt="Permission card with the sandbox-off warning" width="260"> | <img src="docs/assets/screens/activity.png" alt="Activity tab with subagents and shells" width="260"> |
| A question with a preview | A permission, sandbox off | Activity: subagents and shells |
| <img src="docs/assets/screens/palette.png" alt="Command palette listing sessions" width="260"> | <img src="docs/assets/screens/done-card.png" alt="Done card with a next prompt box" width="260"> | <img src="docs/assets/screens/crate-states.png" alt="All Crate states" width="260"> |
| The command palette | The done card | Crate, all states |

### What else is in there

- **Subagent minis, shells and Activity.** A running subagent shows as a half-size copy of its buddy, next to it (at most 4, then `+N`). A `>_ N` chip counts background shells. Click one to open **Activity**: every subagent and shell with its state, time and result. A subagent's permission request uses the normal card, named "(subagent)".
- **Command palette.** `⌃⌥Space` lists your sessions, waiting ones first. Answer a card inline and use the keyboard for all of it.
- **Notification actions.** Deny, Review…, Answer… and Reply… work from the macOS notification. A notification never allows a request: Review… opens the card, where you see the full request and click Allow. Deny and Reply… need an unlocked Mac. Alerts never show the command.
- **Impatience.** A buddy that waits longer than you set (default 3 min) hops and shows a timer. At twice that time it grows and sends one reminder.
- **While you were away.** After a break, one buddy lists what finished, what waits and which subagents failed. Each line opens its card. The list takes keyboard focus, and it stays open while it has focus, VoiceOver reads it or the pointer is over it. The menu and the palette have **Show last digest**.
- **Fun extras.** High-fives, a party when every session is done, and a rare tip. Each one has a switch.
- **Skins, Crate and Mix.** A skin adds palettes, outfits or whole characters. Crate is a pocket-console robot, bundled and off by default. Settings → General → Character → **Mix** gives each session a character from all enabled skins. Write your own: [docs/SKINS.md](docs/SKINS.md).
- **Tokens and cost.** Each session shows "42.1k tok · $0.31" in Activity, the menu and the palette. The prices are a placeholder table in `prices.json` that you can edit. They are not official numbers. Check anthropic.com/pricing for your plan.
- **SSH sessions (opt-in).** Show Claude Code sessions that run on another host, through `ssh -R`. Setup and limits: [docs/SSH.md](docs/SSH.md).
- **Diagnostics.** Settings → Diagnostics shows status rows, the last 50 hook events, and a redacted report you can copy into an issue.
- **Uninstall.** Menu → **Uninstall Buddy…** lists each step and changes nothing until you click. It removes hooks, the extension, the login item and the data folder.

## How it works

```mermaid
flowchart LR
    A[Claude Code session] -->|hook event| B[buddy-hook CLI]
    B -->|Unix socket| C[Buddy.app]
    C --> D[Mascot and bubble card]
    D -->|your answer| C
    C -->|permission or question answer| B
    B -->|hook reply| A
    C -->|next prompt| E[VS Code or Cursor extension]
    C -->|next prompt| F[Claude Code inbox socket]
    E -->|types into the exact terminal| A
    F --> A
    G[Claude Code on an SSH host] -->|buddy-hook-remote, ssh -R| C
    C --> H[Minis and Activity for subagents and shells]
```

Claude Code runs a small CLI, `buddy-hook`, for each hook event. The CLI sends the event to Buddy over a Unix socket. Buddy shows a card. When you answer a permission or a question, the answer goes back through the hook.

The terminal prompt stays live the whole time. The first answer wins, whether you give it in the terminal or on the card.

The next prompt takes one of two routes. The companion VS Code and Cursor extension types it into the exact terminal, so it is real user input. Or Buddy writes to Claude Code's local inbox socket. Claude Desktop uses only the inbox.

SSH sessions come in through a second, opt-in socket and use the same cards. Subagents and background shells show as minis next to their buddy.

More detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install

You need macOS 14 or later.

**From a release (easiest).** Download `Buddy-<version>.dmg` from the [Releases](https://github.com/forbee-dev/buddy/releases) page. Drag Buddy to Applications.

Buddy is not notarized yet. The first time you open it, macOS will block it. Go to System Settings, then Privacy & Security, and click **Open Anyway**.

**With Homebrew (after the first release).**

```sh
brew install --cask forbee-dev/tap/buddy
```

See [docs/HOMEBREW.md](docs/HOMEBREW.md). The not-notarized note below applies too.

**From source.**

```sh
git clone https://github.com/forbee-dev/buddy.git
cd buddy
(cd vscode-ext && npm ci && npm run package)   # builds the .vsix that Buddy bundles
./scripts/build-app.sh   # builds build/Buddy.app
./scripts/make-dmg.sh    # optional: builds build/Buddy-<version>.dmg
```

On first launch, Buddy walks you through setup:

1. Permissions
2. Move to Applications
3. Install hooks
4. Install the VS Code / Cursor extension (the `.vsix` is bundled)
5. Start at login

Install hooks adds Buddy's hooks to `~/.claude/settings.json`. It makes a backup first. One click removes them again.

Full steps and troubleshooting: [docs/INSTALL.md](docs/INSTALL.md).

## Using it

- **Menu bar.** The icon is an outline. It fills with a count dot when a session needs you, even while the buddies are hidden. The dropdown has Hide/Show buddies, a list of buddies (the ones that need you come first, each with thumbnail, project, state dot and app name), Settings, Welcome, Uninstall Buddy… and Quit.
- **Arrangement.** Settings → General: Free (default), Stacked or Row. In Stacked and Row the buddies keep a fixed order with a gap, and dragging one moves the whole group. Not used in single-buddy mode.
- **Pinning.** Drag a mascot to pin it. Right-click → Unpin to release it.
- **Right-click menu.** Re-roll look, palette, outfit, Move to left/right edge, Jump and Hide.
- **Modes.** One mascot per session (the default), or a single buddy with a badge and a session picker.
- **Subagents and shells.** Settings → General can turn off minis and the shell chip. After an update, click **Install hooks** again.
- **Size.** Tiny 1x, Small 1.5x, Medium 2x (default), Large 3x, Huge 4x. Settings has a live preview.
- **Settings tabs.** General, Size, Notifications, Hooks & Extension, SSH, Permissions, Skins, Diagnostics, About. Notifications are set per event type.

| Shortcut | Action |
| --- | --- |
| `⌘↩` | Allow / Submit |
| `⌘⌫` | Deny |
| `⌘T` | Answer in terminal / Claude Desktop |
| `1` to `9` | Pick option N on a question card |
| `←` / `→` | Previous / next question |
| `⇥` / `⇧⇥` | Move focus in the question card (they do not change the question) |
| `Space` | Pick the option, only when no control has focus |
| `↩` | Next question, or open the selected row in the palette |
| `Esc` | Close the bubble or palette |
| `⌘B` | Hide / Show buddies |
| `⌘,` | Settings |
| `⌘Q` | Quit |
| `⌃⌥B` | Global: open the newest waiting card |
| `⌃⌥Space` | Global: open the command palette |

In the palette: `↑` `↓` select, `↩` or `⌘↩` open the card (`⌘↩` again allows), `⌘J` jump, `⇥` next waiting.

Both global shortcuts are configurable in Settings → General. If you give one the other's key, the two swap.

Accessibility: Buddy respects Reduce Motion (no walking, still frames) and Reduce Transparency, and it supports Increase Contrast. Risk shows as text ("Changes files"), and click targets are at least 24 pt. It posts VoiceOver announcements, tips included. Its panels are hidden from screenshots and screen sharing.

When no sessions run, Buddy uses about 0% CPU. With only the sleeping buddy, idle is 0.0% CPU, because the sleep loop is a Core Animation animation. The hook adds about 4.5 ms per event.

## What it can't do (yet)

- **Cloud and VM sessions.** Claude Code cloud sessions and plain Claude Desktop chats can't be tracked. No hooks reach your Mac from them.
- **Notarization.** The app is not notarized yet. That is why you need Open Anyway on first launch.
- **The inbox socket.** It is an internal Claude Code mechanism. It could change in a future version and break the next-prompt route for Claude Desktop.
- **Peer messages.** A next prompt sent through the inbox reaches Claude as a peer message, not as something you typed.
- **Next prompt over SSH.** It is off. Buddy can't tell if claude is in the foreground on a remote host, so a prompt could run as a shell command. Answer in the terminal.
- **Remote tokens and cost.** Not shown for SSH sessions. Buddy can't read the remote transcript.
- **Cost numbers.** They come from an editable price table, so treat them as a rough guide.

## Security and privacy

- Buddy never approves anything for you. Every click is yours.
- Clicks are bound to the exact request on the card. Buttons are disarmed for a moment when a card changes, so a late click can't hit the wrong request.
- It fails open. If Buddy is not running, Claude Code behaves as if Buddy was never there.
- Nothing leaves your Mac. No network, no telemetry. Prompts, commands and tokens are not logged.
- Hooks go into `~/.claude/settings.json` with a backup, and one click removes them.

More in [docs/SECURITY.md](docs/SECURITY.md).

## Make your own buddy

The sprites are plain JSON. `design/sprites.json` holds 32x32 character grids, palettes, outfit layers and an effects layer. `design/gen-sprites.js` generates it.

Open `design/preview.html` in a browser to see every state and every outfit. Add `?character=crate` to see the Crate skin. For a whole new character or a palette pack, see [docs/SKINS.md](docs/SKINS.md). To add an outfit, add a layer to the generator, run it, and check the preview. Outfit contributions are very welcome.

`docs/assets/make-hero.js` renders the GIF and the outfit grid above from the same data. It needs Node and `ffmpeg`.

## Project layout

```
Sources/BuddyCore    logic you can unit test
Sources/BuddyApp     the macOS app
Sources/buddy-hook   the CLI that each hook runs
Tests/               tests
vscode-ext/          companion extension for VS Code and Cursor (TypeScript)
design/              sprites, skins (Crate), generator, preview
scripts/             build and DMG scripts
docs/                install, SSH, skins, releasing, security, architecture, protocol notes
```

## Contributing

Issues and pull requests are welcome. Small ones are best. For a big change, open an issue first so we can talk about it.

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Before you send a PR, build with `./scripts/build-app.sh` and run the tests. Details are in [docs/INSTALL.md](docs/INSTALL.md). Release steps are in [docs/RELEASING.md](docs/RELEASING.md).

I built Buddy with Claude Code itself. Different agents did the hooks research, the sprite design, the Swift app, the extension and the security review. I read and tested the result. Bugs are still possible.

## Credits and disclaimer

Buddy is an unofficial fan project. It is not affiliated with, endorsed by, or sponsored by Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC. The mascot is a fan-made pixel tribute.

## License

[MIT](LICENSE) © 2026 Tiago Santos

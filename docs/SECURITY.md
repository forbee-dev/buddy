# Security

## Trust model

- Buddy is a local, single-user tool. The security boundary is the macOS user account.
- Other users on the Mac must not be able to read Buddy's data or send it messages. Processes of the same user are trusted as much as the user's shell.
- Buddy never approves anything by itself. Every answer comes from a click (or a keyboard shortcut) in a card.
- If Buddy fails, Claude Code works as normal. The hook fails open: it exits 0 with no output.

## Socket

- Path: `~/Library/Application Support/Buddy/buddy.sock`. The folder must be a real directory (not a symlink) owned by the user, and its mode becomes 0700. The socket is 0600.
- One instance only: the app holds an `flock` on `buddy.lock` in the same folder.
- The app accepts at most 64 connections, and only from the same user (`getpeereid`). A client that sends nothing gets 5 s.
- Newline-delimited JSON, max 1 MB per line. Bad JSON or a longer line drops the connection.

## Peer checks

- **Hook → app**: `buddy-hook` checks the listener before it sends. The peer uid must match, and the peer process (`LOCAL_PEERPID`, `proc_pidpath`) must be the `Buddy` binary next to the hook. Release builds ignore `BUDDY_SOCKET`.
- **App → hook**: the first message decides the role of a connection. A hook connection carries one hook message only. The peer must be the bundled `buddy-hook`, and its parent or grandparent must be the claude pid that the message names.
- **Routing fields** (claude pid, shell pid, tty, inbox socket, token) come from `SessionStart` only. A later `SessionStart` from another claude pid can take over only when the old process is dead.
- **Inbox socket**: only `/tmp/cc-socks/<claude pid>.sock`. Before each send, Buddy checks with `lstat` that it is a real socket owned by the user, in a folder that others cannot write (or that has the sticky bit).
- **Extension**: only terminals whose shell runs under the extension's own editor process count.

## Answers and prompts

- A card answers only the request it shows (bound by request id). If that request was answered in the terminal or replaced, Buddy sends nothing and says so.
- Allow, Always allow, and Submit stay disabled for 700 ms after a card appears, changes, or moves. A card that opens by itself never takes keyboard focus.
- The permission card shows every `tool_input` field. Bidi, zero-width, and control characters show as `\u{…}`. `dangerouslyDisableSandbox` gets a red badge. The model-written `description` is labeled "Claude says:".
- A next prompt is sent only when the session is done, idle, or starting. Claude must be alive, not stopped, and the foreground process group of its tty. For Claude Desktop, claude must instead still run under Claude.app.
- Control characters are removed from a next prompt (tab stays), newlines become spaces, and the text is cut at 32 KB.
- Buddy never types keystrokes into a terminal. The next prompt goes through the companion extension or the session inbox socket.
- Unattended sessions (`claude -p`) are never held: Buddy defers them at once.

## What is logged

- Logging uses `os.Logger`, subsystem `com.tiagosantos.buddy`.
- Logged: errors (socket, install, AppleScript error numbers), extension connect events, and unresolved sprite keys.
- Never logged: prompts, commands, tool input, assistant messages, or the messaging token.
- The messaging token stays in memory only. It is never written to disk.
- `buddy-hook` sends only the payload fields the app uses. `tool_response` and `prompt` are never sent.
- Mascot and bubble panels are excluded from screenshots and screen sharing (`sharingType = .none`).

## Reporting a vulnerability

Please report it privately through GitHub's private vulnerability reporting ("Security" tab → "Report a vulnerability") on this repository. Do not open a public issue. <!-- placeholder: confirm the repository URL and enable private advisories -->

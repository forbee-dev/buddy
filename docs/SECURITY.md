# Security

## Supported versions

Only the latest release gets fixes.

## Trust model

- Buddy is a local, single-user tool. The security boundary is the macOS user account.
- Other users on the Mac must not be able to read Buddy's data or send it messages. Processes of the same user are trusted as much as the user's shell.
- Buddy never approves anything by itself. Every answer comes from a click (or a keyboard shortcut) in a card. The one other answer is Deny on a notification. Nothing outside a card can allow.
- If Buddy fails, Claude Code works as normal. The hook fails open: it exits 0 with no output.
- SSH sessions (opt-in) add one more sender: a remote host that has the shared token. See [SSH sessions](#ssh-sessions-remotesock).

## Socket

- Path: `~/Library/Application Support/Buddy/buddy.sock`. The folder must be a real directory (not a symlink) owned by the user, and its mode becomes 0700. The socket is 0600.
- One instance only: the app holds an `flock` on `buddy.lock` in the same folder.
- The app accepts at most 64 connections, and only from the same user (`getpeereid`). A client that sends nothing gets 5 s.
- Newline-delimited JSON, max 1 MB per line. Bad JSON or a longer line drops the connection.

## Peer checks

- **Hook → app**: `buddy-hook` checks the listener before it sends. The peer uid must match, and the peer process (`LOCAL_PEERPID`, `proc_pidpath`) must be the `Buddy` binary next to the hook. Release builds ignore `BUDDY_SOCKET`.
- **App → hook**: the first message decides the role of a connection. A hook connection carries one hook message only. The peer must be the bundled `buddy-hook`, and its parent or grandparent must be the claude pid that the message names.
- **Status line bridge** (`buddy-hook statusline`, opt-in): the hook forwards only the `rate_limits` object of the status line JSON (never the model, cwd, cost, or transcript path), with the same peer rule as a hook; the user's previous status line command runs unchanged, with the same stdin, from `/bin/sh -c`. The app never logs the numbers, and the diagnostics report leaves them out.
- **OpenCode hook**: the parent or grandparent of the peer must be the plugin host that the message names (`hostPid`). The session pid must be that host, or a TUI of it: the host has no tty, and the TUI has a tty, runs the same binary, and has the payload's cwd as its current folder.
- **Routing fields** (claude pid, shell pid, tty, inbox socket, token) come from `SessionStart` only. A later `SessionStart` from another claude pid can take over only when the old process is dead. A message never changes a session of the other agent (Claude Code or OpenCode). OpenCode routing moves only to a pid of the same plugin host, or when the old pid is dead.
- **Inbox socket**: only `/tmp/cc-socks/<claude pid>.sock`. Before each send, Buddy checks with `lstat` that it is a real socket owned by the user, in a folder that others cannot write (or that has the sticky bit).
- **Extension**: only terminals whose shell runs under the extension's own editor process count.

## SSH sessions (`remote.sock`)

Off by default. Details and setup: [SSH.md](SSH.md).

- **Separate socket.** `remote.sock` sits next to `buddy.sock` (same 0700 folder, same `flock`, mode 0600). It exists only while Settings → SSH → Allow SSH sessions is on. The main socket refuses any hook message that carries `remote` or `token`.
- **Peer.** The peer of a remote connection is the local `ssh` client, not the hook, so the ancestry check cannot apply. Instead: the peer uid must be the user's, and the peer's `realpath` must be `/usr/bin/ssh` or a path the user added (only binaries named `ssh`; a saved entry with another name is dropped at launch). Buddy takes the peer's audit token (`LOCAL_PEERTOKEN`) at accept and reads the path with `proc_pidpath_audittoken`. The kernel checks the pidversion, so a client that exits and leaves its pid to another process never passes.
- **Token.** A 256-bit random token, in the login Keychain (generic password, service `com.tiagosantos.buddy`, account `remote-token`) and on the host in `~/.config/buddy/token` (0600; the hook refuses a file that group or others can read). Every message carries it. Buddy compares it in constant time and drops it from the message right after the check. It is never in UserDefaults, logs, or the diagnostics report.
- **Keychain item.** On every write (first use and Rotate token) Buddy deletes the item and adds it again with an access list that trusts only Buddy. Other apps must ask you. An update would keep an older access list. The data protection keychain is not used: it needs a keychain-access-groups entitlement, which ad-hoc and self-signed builds cannot have (`errSecMissingEntitlement`).
- **Install command.** The copied command is `cat '<env file>' '<install.sh>' | ssh <host> 'bash -s'`. It holds two paths, never the token. The token goes to `remote-install.env` (one line, `BUDDY_TOKEN=<token>`) in the 0700 Buddy folder: a new file (`O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600). Buddy deletes it 10 minutes after it writes it, on Rotate token, on quit, and at launch. The token travels on stdin inside the SSH connection: not in shell history, the clipboard, or a process list. `install.sh` still takes the token as an argument for old instructions; that form is discouraged.
- **Remote hook socket.** `buddy-hook-remote` uses `~/.buddy/buddy.sock` only when it is a socket in a folder of the user that group and others cannot write, or a socket of the user in a folder with the sticky bit. On Linux the listener must also run as the user (`SO_PEERCRED`); other systems skip that check.
- **No HMAC.** The hook sends the token itself, not an HMAC of the message. An HMAC would add nothing here: the only parties that can see the token in transit (the user, root on the host, root on the Mac) can also read the token file, and the socket checks above keep other users from posing as the forward.
- **Untrusted content.** The app slims each remote payload again with the local allowlist and drops `transcript_path`. The stored env keeps only `attended`: no pid, tty, or socket from the host is ever used for a local process lookup. Liveness and Jump use the local `ssh` pid. `remote.host` and `remote.user` are display only (hidden characters revealed, max 64 characters).
- **Isolation.** Remote events never change a local session, and events from one ssh connection never change a session of another. Remote sessions take at most 8 of the 32 session slots. A request id that is already open is refused.
- **Next prompt** is off for SSH sessions: Buddy cannot check that claude is in the foreground on the host.
- **Residual risk.** Anyone who can write to the host's `~/.buddy/buddy.sock` and read the token (for example root on the host) can show cards and receive your answers to them. Answers still need your click.

## Answers and prompts

- A card answers only the request it shows (bound by request id). If that request was answered in the terminal or replaced, Buddy sends nothing and says so.
- Allow, Always allow, and Submit stay disabled for 700 ms after a card appears, changes, or moves. A card that opens by itself never takes keyboard focus.
- **Notification actions.** A permission notification has **Deny** (destructive, needs an unlocked Mac) and **Review…** (opens that session's card in front; the 700 ms arming applies). It has no Allow: Allow needs the card, where the full request shows. A click on the notification also opens the card. Deny answers only the request id the notification names; a stale one sends nothing. A subagent's label shows as "Claude says: …", with hidden characters revealed, at most 40 characters. Alerts never show the command. **Reply…** on a done notification sends a next prompt. It needs an unlocked Mac and the normal prompt checks.
- **Text fields keep ⌘⌫.** While a text field has focus (the palette search, a deny reason, a next prompt), ⌘⌫ deletes text. It never reaches the card's Deny shortcut.
- The permission card shows every `tool_input` field. Invisible and direction-changing characters (bidi, zero-width, control, variation selectors, tag characters, fillers) become `\u{XXXX}`. Tab and newline stay. `dangerouslyDisableSandbox` gets a red badge. The model-written `description` is labeled "Claude says:".
- A next prompt is sent only when the session is done, idle, or starting. Claude must be alive, not stopped, and the foreground process group of its tty. For Claude Desktop, claude must instead still run under Claude.app.
- A next prompt keeps newlines and tabs; other C0 controls, DEL, ESC and C1 controls are removed (so the text cannot end the extension's bracketed paste early), and the text is cut at 32 KB.
- Buddy never types keystrokes into a terminal. The next prompt goes through the companion extension or the session inbox socket.
- Unattended sessions (`claude -p`) are never held: Buddy defers them at once.
- The away digest takes keyboard focus when you come back. Esc closes it. It cannot answer a request.

## OpenCode service password

OpenCode's background service writes its local URL and password to `service.json`. The plugin needs them only to send a question answer, because the plugin API has no form reply. The plugin reads the file only when its `pid` is the plugin's own process. It uses the URL only when it is `http` on a loopback address (`127.0.0.1`, `localhost`, `[::1]`). The password goes only in the `Authorization` header of that one request. The plugin never sends the password to Buddy and never logs it or the URL. A failed reply logs only the HTTP status.

## What is logged

- Logging uses `os.Logger`, subsystem `com.tiagosantos.buddy`.
- Logged: errors (socket, install, osascript exit status), extension connect events, and unresolved sprite keys.
- Never logged: prompts, commands, tool input, assistant messages, or the messaging token.
- The messaging token stays in memory only. It is never written to disk.
- The SSH token is never logged. Diagnostics show only whether it is present.
- The diagnostics report replaces each project name with an alias (`project-1`) and each SSH host with one (`ssh-1:project-2`), new for each report. Home paths become `~` in any letter case. Session ids keep 8 characters. Text from an extension or a remote host is revealed and clipped.
- The Copy button of a card's tool input marks the clipboard item `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, so clipboard managers skip it.
- `buddy-hook` sends only the payload fields the app uses. `tool_response` and `prompt` are never sent.
- Mascot and bubble panels are excluded from screenshots and screen sharing (`sharingType = .none`).

## Files Buddy reads

- Transcripts, `prices.json`, and skins: Buddy resolves the folder with `realpath`, then opens the file with `O_NOFOLLOW_ANY`, so a symlink anywhere in the path at open time is refused. `fstat` on the open file checks that it is a regular file of the user. Skins inside the signed app bundle skip the owner check.
- Token counts per line are clamped to 0 to 10^12, and sums stop at the largest integer. A transcript line over 8 MB is skipped.
- `prices.json` is refused when a price is not finite or not 0 to 1000; Buddy then uses the bundled prices.
- Skins are read and checked off the main thread, 300 ms after the last change in the folder. A skin cannot use a built-in color key, or a legend char or color key of a skin before it in the list. Outfit labels are revealed and cut at 40 characters.

## Dependencies

- CI actions are pinned by commit SHA.
- Accepted: the npm advisory for `minimatch` in the extension's dev dependencies. Only the packaging tool (`@vscode/vsce`) uses it, and it is not in the `.vsix`.

## Reporting a vulnerability

Report privately via GitHub Security Advisories: https://github.com/forbee-dev/buddy/security/advisories/new

Do not open a public issue.

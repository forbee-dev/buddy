# Buddy wire protocol

Version 1. Source of truth for `buddy-hook`, the Buddy app, and the VS Code/Cursor extension.

## Transport

- Unix domain stream socket: `~/Library/Application Support/Buddy/buddy.sock`.
- The directory has mode 0700. The socket has mode 0600. Only the same user can connect.
- The env var `BUDDY_SOCKET` overrides the path in **debug builds only** (tests, extension development with a debug app). Release builds ignore it.
- The app is the only server. One instance runs at a time: it holds an `flock` on `buddy.lock` in the same folder. Clients connect. If connect fails, the app is not running.
- The app accepts at most 64 connections, and only from the same user (`getpeereid`).
- Framing: newline-delimited JSON. One JSON object per line, UTF-8, terminated by `\n`.
- Max line: 1 MB (1,048,576 bytes, without the newline). The app drops the connection on a longer line or on bad JSON.
- Every message has a string field `kind`. Unknown kinds are ignored. Unknown fields are ignored.
- Optional fields can be missing or `null`. Treat both the same.

## hook → app

`buddy-hook` connects first; if Buddy is not running it exits at once, before it reads stdin. Then it checks the listener: the peer uid must be its own, and the peer process (`LOCAL_PEERPID` → `proc_pidpath`) must be the `Buddy` binary in the same folder as `buddy-hook`. On a mismatch, it sends nothing and exits 0.

`payload` holds only the fields the app uses: `session_id`, `hook_event_name`, `cwd`, `permission_mode`, `source`, `reason`, `tool_name`, `tool_use_id`, `notification_type`, `transcript_path`, `last_assistant_message` (max 16,000 chars), `error` and `error_details` (max 4,000 chars each), `session_title` (max 200 chars; only when the user named the session with `--name` or `/rename`), `trigger` (PreCompact: `manual` or `auto`; `custom_instructions` never), `agent_id` and `agent_type` (max 100 chars each; present only inside a subagent). For `PermissionRequest` it also holds `tool_input` (whole, never trimmed) and `permission_suggestions`.

Other events keep only these parts of the big fields:

| Field | Kept | Used for |
|---|---|---|
| `tool_input` | `description`, `subagent_type`, `command`, `task_id`, `file_path`, `url` (strings, max 200 chars each), `run_in_background` (bool) | subagent label, shell label, TaskStop, tips; `command`, `file_path`, and `url` also tell a `PostToolUse` of another call of the same tool from the one a `PermissionRequest` card waits for |
| `tool_response` | `agentId`, `backgroundTaskId`, `task_type` (strings, max 200 chars) | link a subagent to its Agent call; shell id; TaskStop of a subagent or a shell |
| `background_tasks` | `id`, `type`, `status` of each entry (max 50 entries) | a shell that left the list has finished |
| `prompt` | never sent. For a `<task-notification>` prompt the hook sends only its `<task-id>` as `task_id` (ASCII letters, digits, `-`, `_`, max 64 chars) and its `<status>` as `task_status` (ASCII letters and digits, max 20 chars) | a background task ended, and how |

Everything else in `tool_input`, `tool_response`, and `prompt` (Agent prompts, command output, subagent results) never leaves the hook.

### Subagents and background shells

Events: `SubagentStart` and `SubagentStop` (non-blocking), plus `PreToolUse` with the matcher `AskUserQuestion|Agent|Task`. Every event fired inside a subagent carries `agent_id`. The app routes such events to that subagent only; they never change the main session state. The one exception is attention: a subagent's `PermissionRequest` shows the normal card, and the buddy shows "needs permission" until it is answered.

- Subagent: created on `SubagentStart`. Its label is the `description` of the oldest `PreToolUse` `Agent` call in the same session that has no subagent yet (FIFO). `PostToolUse` `Agent` with `tool_response.agentId` fixes a wrong pairing. When that `PostToolUse` comes before the `SubagentStart` (a background agent), the call waits and that `SubagentStart` takes it by `agentId`. Failed on `PostToolUseFailure` for its `Agent` call. `last_assistant_message` of `SubagentStop` is trimmed to 300 chars.
- Done on `SubagentStop`, except while a shell it started is still running: then it stays running. A `SubagentStop` with an `agent_id` that never started is ignored. A second `SubagentStart` with the same `agent_id` resumes the same row (running again, no duplicate).
- Stopped (killed): `PostToolUse` `TaskStop` whose `tool_input.task_id` is the `agent_id` and `tool_response.task_type` is `local_agent`, or a `<task-notification>` with `task_status` `killed`. A killed subagent gets no `SubagentStop`. `task_status` `completed` marks it done and `failed` marks it failed, unless it still owns a running shell.
- Subagent permission: it has no `tool_use_id`, so a later `PostToolUse`, `PostToolUseFailure`, or `PermissionDenied` clears the card only when its `agent_id` and `tool_name` match. Answers bind to the request id, as for the main session.
- Shell: created on `PostToolUse` `Bash` with `tool_input.run_in_background: true`; the id is `tool_response.backgroundTaskId`. Its owner is the event's `agent_id` (a shell started inside a subagent); the Activity list shows it with that subagent. Finished when the newest `background_tasks` of any `Stop` or `SubagentStop` of the session no longer has that id, or on a `<task-notification>` `UserPromptSubmit` whose `task_id` names it. Stopped on `PostToolUse` `TaskStop` with `tool_input.task_id` (`task_type` not `local_agent`), or a notification with `task_status` `killed`. A `Stop` without `background_tasks` changes nothing.
- A main `Stop` also marks a subagent done when its id left `background_tasks` and it owns no listed shell (a safety net for a lost `SubagentStop`).
- `Notification` events never change subagents. Only `PermissionRequest` with `agent_id` gives a subagent attention.
- `SessionEnd` ends all running subagents and shells. Per session the app keeps 20 subagents and 10 shells. Ended entries expire after 10 minutes; past the cap the oldest ended entries go first.

```json
{"kind":"hook","id":"<uuid>","wantsReply":true,"payload":{...hook stdin JSON, unchanged...},"env":{"claudePid":123,"shellPid":122,"tty":"ttys004","termProgram":"vscode","bundleId":"com.todesktop.230313mzl4w4u92","askpassMain":"...","itermSessionId":null,"termSessionId":null,"messagingSocket":"/tmp/cc-socks/123.sock","messagingToken":"...","attended":"1"}}
```

| env field | Source |
|---|---|
| `claudePid` | `CLAUDE_PID` (fallback: the hook's parent pid) |
| `shellPid` | parent pid of `claudePid` (the shell that started claude) |
| `tty` | controlling tty of `claudePid`, e.g. `ttys004` |
| `termProgram` | `TERM_PROGRAM` |
| `bundleId` | `__CFBundleIdentifier` |
| `askpassMain` | `VSCODE_GIT_ASKPASS_MAIN` |
| `itermSessionId` | `ITERM_SESSION_ID` |
| `termSessionId` | `TERM_SESSION_ID` |
| `messagingSocket` | `CLAUDE_CODE_MESSAGING_SOCKET` |
| `messagingToken` | `CLAUDE_CODE_MESSAGING_TOKEN` (secret: the app keeps it in memory only) |
| `attended` | `CLAUDE_CODE_SESSION_ATTENDED` (`"1"` interactive, `"0"` headless) |
| `entrypoint` | `CLAUDE_CODE_ENTRYPOINT`, sanitized to `[a-z0-9-_.]`, max 32 chars (`cli`, `sdk-cli`, `claude-desktop`) |
| `agent` | `"opencode"` when `BUDDY_AGENT=opencode` (the OpenCode plugin); absent for Claude Code |
| `hostPid` | OpenCode only: `CLAUDE_PID`, the process that runs the plugin. `claudePid` is then the TUI that `buddy-hook` finds for `SessionStart`, `UserPromptSubmit` and `PermissionRequest`, else `hostPid` with no terminal fields |

Connection roles: the first message on a connection decides its role. A **hook** connection carries exactly one `hook` message (then only the reply). The app accepts it only when the peer process is the bundled `buddy-hook` and its parent or grandparent is `env.claudePid`. Otherwise the app closes the connection, and the hook exits 0 with no output.

Routing fields (`claudePid`, `shellPid`, `tty`, `messagingSocket`, `messagingToken`, ...) are taken from `SessionStart`, or from the first event of a session the app has not seen. Later events that report a different `claudePid` for the same `session_id` are ignored. `messagingSocket` is used only if it is `/tmp/cc-socks/<claudePid>.sock` or `/tmp/cc-socks-<uid>/<claudePid>.sock` (the app's own uid).

OpenCode sessions accept only OpenCode events, and Claude Code sessions only Claude Code events. An OpenCode event takes the routing fields when its `claudePid` is the same, the old pid is dead, or the old pid is its `hostPid`. Other events from the same `hostPid` keep the routing. After the session ends, only `SessionStart`, `UserPromptSubmit` and `PermissionRequest` bring it back. A session on a pid with no tty ends after 30 minutes without events.

Non-blocking events (`wantsReply: false`): after it writes the line, the hook half-closes its side and waits (max 1 s) until the app closes the connection. The app closes it after it has handled the message. So the hook process is still alive when the app checks it.

A connection that sends no first message within 5 s is closed.

`wantsReply` is `true` only for `PermissionRequest` events (this includes `tool_name: "AskUserQuestion"`). All other events are fire-and-forget: the hook writes the line, closes, and exits 0.

If `wantsReply` is `true`, the app answers on the same connection with exactly one line:

```json
{"kind":"reply","id":"<same id>","output":{...hook JSON output...}}
{"kind":"reply","id":"<same id>","output":null}
```

- `output` object: `buddy-hook` prints it to stdout and exits 0. Claude Code applies it.
- `output: null`, an empty line, a closed socket, or a different `id`: `buddy-hook` prints nothing and exits 0. The terminal dialog stays in charge ("defer").
- The app may hold the connection open for a long time (the user decides). The Claude Code hook `timeout` (3600 s) bounds the wait.
- The app replies `null` at once for hidden or unattended sessions (`attended: "0"`). It never holds them.

`buddy-hook` fails open: if the socket is missing, refuses, or any error happens, it exits 0 with no output. It never exits 2.

### Status line bridge (`buddy-hook statusline`)

Settings → General → **Show plan usage** sets `statusLine` in `~/.claude/settings.json` to `{"type":"command","command":"'<hookPath>' statusline"}`. The user's previous `statusLine` object (or `null`) goes to `~/Library/Application Support/Buddy/statusline-previous.json` (0600); turning the setting off, Uninstall hooks, or Uninstall Buddy puts it back. Claude Code runs the command with the status line JSON on stdin after each assistant message. The hook reads stdin (max 256 KB), sends one line with only the `rate_limits` object, and does not wait for an answer (100 ms for the app's close at most). Then it runs the previous command with `/bin/sh -c`, the same stdin bytes, and passes its stdout and exit code through. Without a previous command it prints nothing and exits 0.

```json
{"kind":"statusline","claudePid":123,"rateLimits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
```

The app applies the hook peer rule, parses the windows (0 to 100, a reset time in the future; a bad window is dropped), and sends nothing back. `rate_limits` exists only for claude.ai Pro, Max and Ultra logins in terminal sessions.

## remote hook → app (`remote.sock`)

Opt-in (Settings → SSH). Setup and trust model: [SSH.md](SSH.md), [SECURITY.md](SECURITY.md).

- Socket: `~/Library/Application Support/Buddy/remote.sock`, same folder, lock, modes, framing, line limit, 64-connection cap, and 5 s first-message timeout as `buddy.sock`. It exists only while the setting is on.
- On the host, `buddy-hook-remote` (python3 3.8+, stdlib only) connects to `$BUDDY_REMOTE_SOCK` or `~/.buddy/buddy.sock` (an `ssh -R` forward to `remote.sock`) with a 0.5 s timeout, then reads stdin (max 1 MB).
- Only one message kind: `hook`. Anything else, or a second message, closes the connection.
- The app accepts the message only when the peer uid is the user's, the peer process `realpath` is an allowed ssh client, `token` matches (constant-time compare), and `remote` is present. Otherwise it closes the connection and Diagnostics shows "rejected: <reason>".

```json
{"kind":"hook","id":"<uuid>","wantsReply":false,"payload":{...slimmed...},"env":{"claudePid":4242,"ssh":true,"sshTty":true,"entrypoint":"cli","attended":"1"},"remote":{"host":"devbox","user":"you"},"token":"<64 hex>"}
```

| Field | Meaning |
|---|---|
| `payload` | Slimmed by the hook with the same allowlist as `buddy-hook` (the table above). The app slims it again and drops `transcript_path`. Keep `slim()` in `scripts/remote/buddy-hook-remote` in sync with `HookPayload`; `RemoteHookParityTests` compares them. The hook counts lengths in code points, Swift in characters. |
| `env.claudePid` | `CLAUDE_PID` on the host (fallback: the hook's parent pid). A REMOTE pid: it only tells sessions on one connection apart (`clear`/`resume` rekeying). |
| `env.ssh`, `env.sshTty` | `SSH_CONNECTION` and `SSH_TTY` present. Informational; v1 does not use them. |
| `env.entrypoint`, `env.attended` | As for the local hook (max 32 chars). The app keeps only `attended`. |
| `remote.host`, `remote.user` | Short host name and user on the host. Display only (`host:project` tag), never routing. Hidden characters revealed, max 64 chars. |
| `token` | The shared secret from `~/.config/buddy/token`. Dropped after the check. |

- Blocking events and replies work as on the main socket: `wantsReply` is `true` for `PermissionRequest`, the app answers with one `reply` line on the same connection, and the hook prints `output` (3600 s wait).
- The hook fails open: on any error (no socket, no token, a token file readable by group or others, oversize stdin, bad JSON) it exits 0 with no output. It never exits 2.
- Remote sessions: the tag shows `host:project`; looks key on `host:cwd`; liveness follows the local `ssh` pid; Jump raises the terminal above that pid; next prompt is refused; no transcript (tokens show "remote").

## extension → app

The extension keeps one long-lived connection. The first line must be `ext-hello`; it makes the connection an **extension** connection. An extension connection can send only `ext-terminals` and `ack` after that. A `hook` message on it closes the connection. The first line:

```json
{"kind":"ext-hello","editor":"vscode","appPid":4567,"version":"0.1.3","terminals":[{"shellPid":122,"name":"zsh"}],"workspaceFolders":["/Users/me/proj"]}
```

- `editor`: `"vscode"` or `"cursor"`.
- `appPid`: the editor main pid or the extension host pid.
- `terminals[].shellPid`: `Terminal.processId` (the shell pid). The app matches it against `env.shellPid` from hook events.
- `workspaceFolders` (optional, since 0.1.2): absolute fsPaths of `vscode.workspace.workspaceFolders`. Max 20 entries, each at most 1024 chars. The app drops non-absolute or oversize entries. Older extensions omit it; the app then has no folder for that window. Jump uses the folders to raise the right editor window.
- The app keeps only terminals whose shell runs under the same editor app process as the extension (process ancestry). Other entries are ignored.
- Pending `send` acks fail with `error: "disconnected"` when the extension connection closes.

When terminals open or close, send the full current list:

```json
{"kind":"ext-terminals","terminals":[{"shellPid":122,"name":"zsh"},{"shellPid":130,"name":"bash"}],"workspaceFolders":["/Users/me/proj"]}
```

Send it also when the workspace folders change (`onDidChangeWorkspaceFolders`). If `workspaceFolders` is missing, the app keeps the last list.

## app → extension

```json
{"kind":"send","reqId":"<uuid>","shellPid":122,"text":"run the tests","submit":true}
{"kind":"focus","reqId":"<uuid>","shellPid":122}
```

- `send`: put `text` into the terminal whose shell pid is `shellPid`. `submit: true` means press Enter after the text.
  - Before it sends, the app checks: the session is `done`, `idle`, or `starting`; claude is alive; claude is the foreground process group of its tty; claude is not stopped. If a check fails, the app sends nothing.
  - `text` can contain newlines (`\n`) and tabs. It never contains other C0 controls, DEL, or C1 controls (U+0080 to U+009F). CR and CRLF become `\n`. It is at most 32 KB of UTF-8.
  - Extension 0.1.3 and later: the extension cleans `text` again with the same rule. Then it sends a bracketed paste, `terminal.sendText("\x1b[200~" + text + "\x1b[201~", false)`. If `submit` is true, it then presses Enter with a separate `terminal.sendText("", true)`. Claude Code's TUI takes the paste as one multi-line prompt. A plain `sendText` with newlines would submit each line. VS Code turns each `\n` into `\r` before it writes to the pty, as in a real paste. The text has no ESC, so it cannot end the paste early.
  - Extension 0.1.2 and older turn newlines into spaces and type the text.
- `focus`: reveal and focus that terminal (`terminal.show(false)`). The VS Code API cannot raise the OS window. The app raises the window first (Accessibility, or the editor CLI with the folder path), then sends `focus`.

## extension → app: acks

Answer every `send` and `focus` with one ack:

```json
{"kind":"ack","reqId":"<same reqId>","ok":true}
{"kind":"ack","reqId":"<same reqId>","ok":false,"error":"no-terminal"}
```

`error` values: `no-terminal` (no terminal with that `shellPid`), or a short free-text reason. The app waits 3 s for a `send` ack, then shows a failure.

## Reconnect

The app can restart. The extension retries the connection (for example every 5 s) and sends `ext-hello` again after each connect.

## Security

- Never log `messagingToken`, prompts, commands, or tool input.
- The socket is local only and owned by the user (0600 in a 0700 directory).
- Never log the SSH token. The main socket refuses messages with `remote` or `token`.

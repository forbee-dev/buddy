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

`payload` holds only the fields the app uses: `session_id`, `hook_event_name`, `cwd`, `permission_mode`, `source`, `reason`, `tool_name`, `tool_use_id`, `notification_type`, `transcript_path`, `last_assistant_message` (max 16,000 chars), `error` (max 4,000 chars), `agent_id` and `agent_type` (max 100 chars each; present only inside a subagent). For `PermissionRequest` it also holds `tool_input` (whole, never trimmed) and `permission_suggestions`.

Other events keep only these parts of the big fields:

| Field | Kept | Used for |
|---|---|---|
| `tool_input` | `description`, `subagent_type`, `command`, `task_id` (strings, max 200 chars each), `run_in_background` (bool) | subagent label, shell label, TaskStop |
| `tool_response` | `agentId`, `backgroundTaskId` (strings, max 200 chars) | link a subagent to its Agent call; shell id |
| `background_tasks` | `id`, `type`, `status` of each entry (max 50 entries) | a shell that left the list has finished |
| `prompt` | never sent. For a `<task-notification>` prompt the hook sends only its `<task-id>` as `task_id` (ASCII letters, digits, `-`, `_`, max 64 chars) | a background task ended |

Everything else in `tool_input`, `tool_response`, and `prompt` (Agent prompts, command output, subagent results) never leaves the hook.

### Subagents and background shells

Events: `SubagentStart` and `SubagentStop` (non-blocking), plus `PreToolUse` with the matcher `AskUserQuestion|Agent|Task`. Every event fired inside a subagent carries `agent_id`. The app routes such events to that subagent only; they never change the main session state. The one exception is attention: a subagent's `PermissionRequest` shows the normal card, and the buddy shows "needs permission" until it is answered.

- Subagent: created on `SubagentStart`. Its label is the `description` of the oldest `PreToolUse` `Agent` call in the same session that has no subagent yet (FIFO). `PostToolUse` `Agent` with `tool_response.agentId` fixes a wrong pairing. Done on `SubagentStop`, failed on `PostToolUseFailure` for its `Agent` call. `last_assistant_message` of `SubagentStop` is trimmed to 300 chars.
- Subagent permission: it has no `tool_use_id`, so a later `PostToolUse`, `PostToolUseFailure`, or `PermissionDenied` clears the card only when its `agent_id` and `tool_name` match. Answers bind to the request id, as for the main session.
- Shell: created on `PostToolUse` `Bash` with `tool_input.run_in_background: true`; the id is `tool_response.backgroundTaskId`. Finished when a later main `Stop` has a `background_tasks` array without that id, or on a `<task-notification>` `UserPromptSubmit` whose `task_id` names it. Stopped on `PostToolUse` `TaskStop` with `tool_input.task_id`. A `Stop` without `background_tasks` changes nothing.
- The same main `Stop` rule marks a subagent done when its id left `background_tasks` (a safety net for a lost `SubagentStop`).
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

Connection roles: the first message on a connection decides its role. A **hook** connection carries exactly one `hook` message (then only the reply). The app accepts it only when the peer process is the bundled `buddy-hook` and its parent or grandparent is `env.claudePid`. Otherwise the app closes the connection, and the hook exits 0 with no output.

Routing fields (`claudePid`, `shellPid`, `tty`, `messagingSocket`, `messagingToken`, ...) are taken from `SessionStart`, or from the first event of a session the app has not seen. Later events that report a different `claudePid` for the same `session_id` are ignored. `messagingSocket` is used only if it is `/tmp/cc-socks/<claudePid>.sock`.

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

## extension → app

The extension keeps one long-lived connection. The first line must be `ext-hello`; it makes the connection an **extension** connection. An extension connection can send only `ext-terminals` and `ack` after that. A `hook` message on it closes the connection. The first line:

```json
{"kind":"ext-hello","editor":"vscode","appPid":4567,"version":"0.1.2","terminals":[{"shellPid":122,"name":"zsh"}],"workspaceFolders":["/Users/me/proj"]}
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

- `send`: type `text` into the terminal whose shell pid is `shellPid` (`terminal.sendText(text, submit)`). `submit: true` means press Enter after the text.
  - Before it sends, the app checks: the session is `done`, `idle`, or `starting`; claude is alive; claude is the foreground process group of its tty; claude is not stopped. If a check fails, the app sends nothing.
  - `text` never contains C0 control characters (tab is allowed) or newlines (they become spaces). It is at most 32 KB of UTF-8.
- `focus`: reveal and focus that terminal (`terminal.show(false)`), The VS Code API cannot raise the OS window. The app raises the window first (Accessibility, or the editor CLI with the folder path), then sends `focus`.

## extension → app

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

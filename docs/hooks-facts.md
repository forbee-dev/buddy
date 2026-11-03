# Claude Code hooks: facts for Buddy

Date: 2026-11-03. Claude Code 2.1.317 on macOS.
Labels: **TESTED** = we ran it. **DOCS** = official docs only. **UNTESTED** = not run, docs say.
Docs: https://code.claude.com/docs/en/hooks.md and https://code.claude.com/docs/en/cross-session-messaging.md
Test files (scratch, not part of the app): a temporary scratch folder (`w0/`)
Headless tests used `claude -p`. Interactive tests used `expect` to drive a real pty. No tokens are copied here.

## 1. Session lifecycle

Verdict: **YES**.

Common input fields (stdin JSON, all events). TESTED:
`session_id`, `transcript_path`, `cwd`, `hook_event_name`, `agent_type` (when `--agent` or a default agent is set), `prompt_id` (not on SessionStart), `permission_mode` (not on SessionEnd), `effort.level` (some events), `scratchpad_dir` (some builds).
`transcript_path` can lag the current turn. Use `last_assistant_message` on Stop.

Per event. TESTED unless noted:

| Event | Extra fields | Example value |
|---|---|---|
| SessionStart | `source` (`startup`/`resume`/`clear`/`compact`/`fork`), `model` | `"source":"startup"` |
| UserPromptSubmit | `prompt` | `"prompt":"Run the bash command: echo hi"` |
| Stop | `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` | `"stop_hook_active":false` |
| SubagentStop (DOCS) | `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message` | |
| Notification (DOCS, plus real payload seen) | `message`, optional `title`, `notification_type` | see below |
| SessionEnd | `reason` | `"reason":"other"` (seen in `-p`) |

SessionEnd `reason` values (DOCS): `clear`, `resume`, `logout`, `prompt_input_exit`, `other`.
SessionEnd has only a 1.5 s budget by default (DOCS). Keep the hook fast. Send the socket message and exit.

Real Notification payload (TESTED, interactive):
```json
{"session_id":"...","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}
```
`notification_type` values (DOCS): `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, plus quota and plugin types.
Notification hooks cannot block. Output is ignored.
`permission_prompt` fires about 6 s after the dialog appears (DOCS). We saw 6 s (TESTED: dialog at 12:15:17, Notification at 12:15:23).

Output contract: exit 0 and no output is fine for all of these events. Exit 0 stdout on SessionStart/UserPromptSubmit is added to Claude context (DOCS).

How to tell the three states:

| State | Signal | Speed |
|---|---|---|
| Needs permission | `PermissionRequest` event (best), or Notification `permission_prompt` | PermissionRequest is instant. Notification is about 6 s late. |
| Needs an answer to a question | `PreToolUse` with matcher `AskUserQuestion` (DOCS), or Notification `elicitation_dialog` for MCP asks | instant |
| Finished turn | `Stop` (has `last_assistant_message`) | instant, TESTED |
| Idle, waiting after done | Notification `idle_prompt` (DOCS). Delay not confirmed. UNTESTED. | late |
| Working | `UserPromptSubmit` then `PreToolUse`/`PostToolUse` events | TESTED |

Minimal config to track everything:
```json
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"buddy-hook"}]}],
"SessionEnd":[{"hooks":[{"type":"command","command":"buddy-hook"}]}],
"UserPromptSubmit":[{"hooks":[{"type":"command","command":"buddy-hook"}]}],
"Stop":[{"hooks":[{"type":"command","command":"buddy-hook"}]}],
"SubagentStop":[{"hooks":[{"type":"command","command":"buddy-hook"}]}],
"Notification":[{"hooks":[{"type":"command","command":"buddy-hook"}]}]}}
```
Evidence: TESTED order in one headless run: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd.
Gotcha: `UserPromptSubmit` has a 30 s default timeout, not 600 s (DOCS).
Gotcha: `claude -p` fires the same hooks as the interactive app. Buddy will see `-p` and subagent sessions too. Use `CLAUDE_CODE_ENTRYPOINT` (`cli` = interactive, `sdk-cli` = headless, TESTED) and `CLAUDE_CODE_SESSION_ATTENDED` (`1` interactive, `0` headless, TESTED) to filter.

## 2. PermissionRequest hook (block, then allow or deny)

Verdict: **YES**.

Input (TESTED, real payload):
```json
{"session_id":"...","cwd":"...","permission_mode":"default","hook_event_name":"PermissionRequest",
 "tool_name":"Bash","tool_input":{"command":"touch /private/tmp/claude-501/buddy_probe_file","description":"Create an empty probe file"},
 "permission_suggestions":[{"type":"addDirectories","directories":["/private/tmp/claude-501"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
```
No `tool_use_id` on this event (DOCS). MCP tools add `mcp_server` (DOCS).

Output (stdout JSON, exit 0):
```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"User said no","interrupt":false}}}
```
Allow also accepts `updatedInput` and `updatedPermissions` (use `permission_suggestions` entries to do "always allow"). Deny also accepts `interrupt: true` (stops Claude). DOCS.
- Allow: TESTED. The command ran.
- Deny with message: TESTED. Claude quoted `BUDDY_DENY_MSG user said no because reasons` back. The message reaches the model.
- Hook slept 8 s then answered: TESTED, works. The hook can block.

Timeout:
- Default for `command` hooks: 600 s (10 min). DOCS.
- Max configurable: the docs state no upper cap. Config `"timeout": 900` was accepted (TESTED, load only). A real wait over 600 s is UNTESTED.
- Set `"timeout"` in seconds on the handler: `{"type":"command","command":"buddy-hook","timeout":3600}`.
- Exit 2 is NOT honored for PermissionRequest. Always deny with JSON. (DOCS)

Exit 0 with no output:
- Interactive session: the normal terminal permission dialog stays. The flow is unchanged. DOCS. The dialog does show (TESTED: with a hook that returned nothing after a 15 s sleep, the dialog appeared).
- Headless `-p`: no prompt is possible, so the tool is DENIED. TESTED: "needs approval" error.

Is the terminal dialog shown while the hook waits?
- **YES, at the same time. TESTED (interactive pty).** Hook started at 12:15:17 and slept 15 s. The "Do you want to proceed?" dialog was on screen before the hook finished. A Notification `permission_prompt` fired at 12:15:23, while the hook still slept.
- DOCS say: for `--permission-prompt-tool` and `canUseTool` "whichever decides first applies". We did not test whether a late hook answer closes a dialog the user already answered. UNTESTED. Assume the first answer wins.
- Impact: the user can answer in the terminal OR in Buddy. Buddy must tolerate the hook being killed or ignored after the terminal answer.

## 3. PreToolUse on `AskUserQuestion`

Verdict: **PARTIAL**. DOCS say YES. We could not TEST it: `AskUserQuestion` is not available in `claude -p` ("isn't available in this session, non-interactive"). No TTY test done. UNTESTED.

Config:
```json
{"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"buddy-hook","timeout":3600}]}]}}
```
Input (DOCS): common fields plus `tool_name:"AskUserQuestion"`, `tool_input.questions[]` (each: `question`, `header`, `options[{label,description}]`, `multiSelect`), `tool_use_id`.

Output (DOCS, quoted shape). Must return `allow` AND `updatedInput`. `allow` alone is not enough:
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",
 "updatedInput":{"questions":[{"question":"Which framework?","header":"Framework",
   "options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],
  "answers":{"Which framework?":"React"}}}}
```
- Copy the original `questions` array back. Add `answers` keyed by the exact question text. Value is the chosen label (string). For multiSelect the format is UNTESTED. Check with a real run.
- This skips the terminal UI (DOCS).
- Fallback if it fails: `permissionDecision:"deny"` with `permissionDecisionReason` that contains the answer, e.g. "The user already answered via Buddy: React. Do not ask again." Claude reads the reason. This works for any PreToolUse (deny path TESTED for PermissionRequest only). It costs one extra model turn.
- Also exists: `Notification` `elicitation_dialog` is for MCP elicitation, not AskUserQuestion.
- Docs also say `ExitPlanMode` uses the same `updatedInput` + `allow` pattern.

## 4. Send a NEW prompt into a running interactive session

Verdict: **YES** via the session inbox socket. TESTED.

### Option A: cross-session messaging inbox socket (recommended)
Docs: https://code.claude.com/docs/en/cross-session-messaging.md. Needs Claude Code 2.1.224+ (we have 2.1.317). On by default.
- Claude Code binds a Unix socket per session: `/tmp/cc-socks/<claude_pid>.sock` (TESTED, files exist).
- Hooks get env `CLAUDE_CODE_MESSAGING_SOCKET` (path), `CLAUDE_CODE_MESSAGING_TOKEN` (per-session secret) and `CLAUDE_PID`. Set before SessionStart runs. TESTED.
- Protocol: JSON lines. Optional first line `{"type":"auth","token":"<token>"}` (optional on macOS). Then:
```json
{"type":"user","message":{"role":"user","content":"Reply with only the word PINEAPPLE"}}
```
- TESTED: interactive session idle after a turn. A separate Python process (not a child of claude) sent the line without auth. Claude started a NEW turn at once. The terminal showed: `Another Claude session sent a message: Reply with only the word PINEAPPLE` plus a preamble that says it came from a peer, not the user. The socket gave no reply bytes (no ack). I did not read the model's final answer text, but the turn started.
- When busy: the message is read between tool calls (DOCS). When idle: it starts a new turn (DOCS, TESTED).
- Plan: SessionStart hook sends `{session_id, socket, token, claude_pid, tty, ...}` to Buddy. Buddy stores them. Buddy writes to the socket later. Buddy must delete the entry on SessionEnd or when the socket file vanishes.
- Pros: no terminal automation, works in any terminal, VS Code and Cursor, no focus needed, user can still type, never leaves the machine.
- Cons:
  - Model sees a peer framing, not a plain user prompt. The text is wrapped. The model "treats it as a teammate's request".
  - The message can NOT approve a permission prompt, change config, or run `/commands` (DOCS).
  - The setting `crossSessionInbound` can be `hold` or `refuse` (DOCS). Receiver is `hold` if it runs in bypassPermissions and the sender is not "also bypassing". Then the user sees an approval dialog (5 min expiry). A non-child sender asserts no class. If the session has bypass on, expect hold. UNTESTED.
  - Not available if `--bare` (no socket) (DOCS). The VS Code extension cannot show the hold dialog (DOCS). Terminals inside VS Code/Cursor are normal CLI sessions and work.
  - Sandboxed Bash cannot reach it unless `sandbox.network.allowUnixSockets` (irrelevant for Buddy: the app is outside).
  - Docs call this feature for sessions of one user. The "post from a script or hook" use is documented in "The session's inbox socket" section. The raw wire format is documented only through the `socat` line and our test.
  - Rate limits: rapid bursts refused, max 50 queued, about 1M chars.
  - The token is a secret. Keep it in memory or a 0600 file. Do not log it.

### Option B: Stop hook `decision: block` with `reason`
TESTED headless. A Stop hook returned `{"decision":"block","reason":"BUDDY_NEXT_PROMPT: now reply with exactly the word PINEAPPLE"}`. Claude continued and answered `PINEAPPLE`. Second Stop call had `stop_hook_active: true`.
- Pros: official, documented, plain model input as "feedback".
- Cons: the turn does not end while the hook waits. The hook must block for minutes. Behavior of the terminal while a Stop hook waits (does the user see a "running Stop hooks" status, can they type?) is UNTESTED. Docs say hooks run with a status line; the UserPromptSubmit pty run showed "running UserPromptSubmit hooks… 0/4" in the footer. Expect a similar line. The 600 s default timeout applies. Check `stop_hook_active` to avoid loops. The session never reads as "finished" while the hook holds it.
- Use only as a backup for "one more instruction right after the turn".

### Option C: other
- `claude --resume <id> -p "..."` (headless): creates a second process on the same transcript. It does not inject into the running UI. Risky: two writers. Not recommended.
- Remote Control (`--remote-control`) and Channels (https://code.claude.com/docs/en/channels.md): need a claude.ai login or an extra flag/plugin on each session. Not usable for "any terminal" without user setup. DOCS only. UNTESTED.
- Keystroke injection (AppleScript, `TIOCSTI`, expect): fragile, needs per-terminal code and accessibility rights. Not recommended.

## 5. Identify the terminal from a hook process

Verdict: **YES**, with limits. TESTED in Cursor integrated terminal (`TERM_PROGRAM=vscode`).

The hook has **no tty**: `tty` prints "not a tty" (TESTED). stdin is a pipe.

Env vars that reach the hook (TESTED, names only):
- Claude: `CLAUDE_PID` (**the claude process id**), `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_ENTRYPOINT` (`cli`/`sdk-cli`), `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_EFFORT`, `CLAUDECODE=1`. `CLAUDE_ENV_FILE` only in SessionStart.
- Terminal: `TERM_PROGRAM=vscode`, `TERM_PROGRAM_VERSION`, `TERM=xterm-256color`, `COLORTERM`, `__CFBundleIdentifier=com.todesktop.230313mzl4w4u92` (this is **Cursor**), `VSCODE_INJECTION`, `VSCODE_GIT_IPC_HANDLE`, `VSCODE_GIT_ASKPASS_MAIN` (path contains `/Applications/Cursor.app/...`, or `Code.app` for VS Code), `VSCODE_GIT_ASKPASS_NODE`.
- Not set in Cursor: `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `TMUX`, `CURSOR_*`. In iTerm2 or Terminal.app, expect `ITERM_SESSION_ID` / `TERM_SESSION_ID` (UNTESTED, standard behavior).
- VS Code vs Cursor: `TERM_PROGRAM` is `vscode` for both. Tell them apart with `__CFBundleIdentifier` or the `.app` name in `VSCODE_GIT_ASKPASS_MAIN`.
- Hooks inherit the full parent env. This is why these vars appear (DOCS: "Hooks inherit the parent environment").

Parent chain (TESTED, interactive claude inside Cursor, from the hook):
```
hook /bin/bash   ppid -> claude   (tty ??)   <- CLAUDE_PID points here
claude           ttys062                      <- controlling tty of the session
/bin/zsh         ttys0xx                      <- the shell
Cursor Helper: terminal pty-host
Cursor.app
```
- The hook's direct parent IS the `claude` pid (equals `CLAUDE_PID`). TESTED.
- `ps -o tty= -p $CLAUDE_PID` gives the tty (e.g. `ttys062`). TESTED. The hook's own tty is `??`.
- The shell pid is the next parent of claude with comm `zsh`/`bash`/`fish`. TESTED (claude -> `/bin/zsh`). Use `ps -o ppid= -p <claude_pid>`.
- Walk up until the comm is the terminal app or pty-host. For Cursor the chain ends at `Cursor.app/Contents/MacOS/Cursor`. For other terminals the walk ends at e.g. `iTerm2`, `Terminal`, `login`.
- Note: when claude runs inside another claude (a Bash tool), the chain has more `claude` entries. Take the first one (`CLAUDE_PID`).
- Use for Buddy: send `{claude_pid, tty, shell_pid, term_program, bundle_id, cwd}` on SessionStart. To focus a terminal later: match tty (iTerm2/Terminal via AppleScript), or activate the app by bundle id (VS Code/Cursor cannot focus a specific terminal tab from outside; UNTESTED).

## 6. Hook config

Verdict: **YES**.

Locations (DOCS): `~/.claude/settings.json` (user), `.claude/settings.json` (project), `.claude/settings.local.json`, managed settings, plugin `hooks/hooks.json`, skill frontmatter.
Shape: event -> list of matcher groups -> list of handlers:
```json
{"hooks":{"PermissionRequest":[{"matcher":"Bash|Edit|Write","hooks":[{"type":"command","command":"/usr/local/bin/buddy-hook","timeout":3600}]}]}}
```
- Handler `type`: `command`, `http`, `mcp_tool`, `prompt`, `agent`. `command` also takes `args` (exec form, no shell), `async`, `shell`, `if`, `statusMessage`, `onFailure`.
- Matcher (DOCS): `"*"`, `""` or omitted = all. Only letters, digits, `_ - , |` and spaces = exact name or a `|`/`,` list. Any other char = JavaScript regex, unanchored. Use `^Edit$` to anchor. MCP tool names: `mcp__server__tool`; `mcp__server__.*` for a server.
- Matcher target per event: tool events = tool name; SessionStart = source; SessionEnd = reason; Notification = notification_type; SubagentStop = agent type. UserPromptSubmit and Stop have no matcher (ignored).
- Multiple hooks for one event run in parallel (DOCS). Buddy hooks run next to the user's own hooks. No change needed to existing hooks.
- `claude --settings <file-or-json>`: **TESTED, YES.** It loads extra settings including hooks. It adds to the user settings, it does not replace them. Real hooks of the user ran too (we saw "cc-plugin-sec-default" hooks in the pty). Use `--settings` for tests. `--bare` skips hooks.
- Default `timeout` (DOCS): 600 s for command hooks. 30 s for UserPromptSubmit. 10 s for MessageDisplay. SessionEnd 1.5 s total.
- Exit codes (DOCS): 0 = success, parse stdout JSON. 2 = block (PreToolUse blocks tool; Stop prevents stopping; PermissionRequest ignores it). Other = non-blocking error.
- Settings reload: hooks are read at session start. UNTESTED whether a running session picks up changes.
- A hook that is slow slows Claude. Keep non-blocking events at under 1 s. Use `"async": true` for fire-and-forget events (DOCS lists `async`; UNTESTED here).

## Impact on Buddy design

Permissions
- Use `PermissionRequest`. It blocks up to 600 s by default. Raise `timeout` for longer. Return allow or deny with `message`.
- The terminal dialog shows at the same time. The user may answer there. Buddy must expect the hook to be killed. Remove the card in Buddy when `PostToolUse`/`PermissionDenied` or the next event arrives.
- If Buddy is not running: `buddy-hook` must exit 0 with no output at once. Then the terminal dialog works as usual.
- Never exit 2 on PermissionRequest.
- Also send `permission_suggestions` to the app so it can offer "always allow".

Questions
- Use `PreToolUse` with matcher `AskUserQuestion`. Return `allow` + `updatedInput` (original `questions` + `answers`). This is DOCS-only: do a quick manual interactive test before building. Fallback: `deny` with the answer in `permissionDecisionReason`.
- Unlike PermissionRequest, the terminal dialog is probably NOT shown while this hook waits (PreToolUse runs before the tool). UNTESTED. If true, the user cannot answer in the terminal while Buddy waits. Add a "skip, ask in terminal" button that exits 0 with no output.

Next prompt
- Use the inbox socket. Save `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` from the SessionStart hook. Write one JSON line `{"type":"user","message":{"role":"user","content":"..."}}`. TESTED: it starts a new turn on an idle session in an interactive terminal.
- The model sees a peer-message wrapper. This is fine for "next task" prompts. It cannot grant permissions.
- Risk: sessions in bypassPermissions mode may hold the message behind an approval dialog. Check `permission_mode` in payloads and warn in Buddy.
- Backup: Stop hook `block` + `reason`. Use only if the socket is missing.

Terminal identification
- Take `CLAUDE_PID` from env. It is the claude process. Read its tty with `ps -o tty=`. Walk its parents for the shell and the terminal app.
- Use `TERM_PROGRAM`, `__CFBundleIdentifier`, `VSCODE_GIT_ASKPASS_MAIN` to name the app (iTerm2, Terminal, VS Code, Cursor). Use `ITERM_SESSION_ID` / `TERM_SESSION_ID` when present.
- Session key = `session_id`. Re-key on `SessionStart` with `source: resume|clear|compact` (the `session_id` can change on clear). UNTESTED for clear.
- Filter noise: ignore `CLAUDE_CODE_SESSION_ATTENDED=0` sessions or show them as "background" mascots.
- Reaper: if `kill -0 $CLAUDE_PID` fails, remove the mascot. SessionEnd can be missed on a crash or kill.

Open items to test by hand in a real terminal
1. AskUserQuestion hook with `answers` (and multiSelect format).
2. Terminal behavior while a Stop hook or PreToolUse hook waits (can the user type?).
3. A PermissionRequest wait longer than 600 s with a larger `timeout`.
4. Late hook answer after the user answered in the terminal.
5. Socket message into a session in bypassPermissions mode.
6. `idle_prompt` timing.

## W2 hand tests

Date: 2026-11-03. Claude Code 2.1.317, `--model haiku`, real pty driven by `expect`, extra hooks via `claude --settings <scratch>`.
Scratch: a temporary scratch folder (`w2/`) (`hook.py`, `t*.exp`, `pty-*.log`, `log.txt`).

### H1. PreToolUse `AskUserQuestion` with `allow` + `updatedInput.answers`
Verdict: **YES, TESTED.** Claude received the answers. The terminal printed `User answered Claude's questions: · Pick a color → Blue · Pick fruits → Pear, Plum`, and the model replied with them.
- Single select: value = the option label string. `{"Pick a color":"Blue"}`.
- multiSelect: value = labels joined with `", "` in ONE string. `{"Pick fruits":"Pear, Plum"}`. TESTED. (Arrays not tested.)
- Free text ("Other"): use the typed text as the string value (same field; the terminal "Type something" option writes there). Not tested by hook.
- Keys = the exact `question` text. Copy `questions` back unchanged.
- PostToolUse for `AskUserQuestion` has `tool_response.answers` with the same map. When the user answers in the terminal, `tool_input` also has `"annotations":{}`.

### H2. Terminal UI while the PreToolUse hook waits
Verdict: **NO question UI.** TESTED: during a 20 s PreToolUse sleep the terminal shows only the spinner ("Computing…"). The user cannot answer in the terminal.
- After PreToolUse exits 0 with no output, Claude fires **`PermissionRequest` with `tool_name:"AskUserQuestion"`** (same `tool_input.questions`), then shows the terminal question UI.

### H3. `PermissionRequest` for `AskUserQuestion`, and late replies
- `PermissionRequest` reply `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"questions":[...],"answers":{...}}}}}` answers the question. TESTED (terminal shows "Allowed by PermissionRequest hook").
- While this hook waits, the terminal question UI IS shown. TESTED. The user can answer in either place.
- Terminal answer first, hook replies 8 s later: **the terminal answer wins.** PostToolUse fired at once with the terminal answer (`Red`). The hook process was NOT killed. Its late reply (`Blue`) had no effect and no error was shown. TESTED.
- Same in `--permission-mode bypassPermissions`: PreToolUse fires, then `PermissionRequest` for `AskUserQuestion` still fires and its answer is used. TESTED.

### Decision for Buddy (W2)
- Answer questions through **`PermissionRequest` where `tool_name == "AskUserQuestion"`**, not through PreToolUse. Reason: the terminal UI stays live, so the first answer wins and "Answer in terminal" needs no reply.
- PreToolUse(`AskUserQuestion`) is installed as a non-blocking signal only (instant "asking" state). It never replies.
- A pending card is cleared on PostToolUse (same tool), on the next UserPromptSubmit/Stop, or when the hook connection closes. Buddy must also reply `null` (defer) to the still-waiting hook so it exits. Since the late reply is ignored, this is safe.
- Fallback (deny + reason) is not needed.

### H4. Failure signal
- `PostToolUseFailure` exists in 2.1.317. TESTED (`claude -p`, failing `ls`). Fields: common fields plus `tool_name`, `tool_input`, `tool_use_id`, `error` (string, e.g. `"Exit code 1\nls: ...: No such file or directory"`), `is_interrupt` (bool), `duration_ms`.
- A failed tool fires `PostToolUseFailure`, NOT `PostToolUse`. Buddy installs both, so a pending card for a failed tool still clears. Buddy shows the `error` animation for it.

### H5. Late PermissionRequest replies on a Bash permission (security review M4)
Scratch `w2/t5.exp`, `t9.exp`, `settings-m4.json`. The hook replied late with `allow` + `updatedPermissions: [{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch:*"}],"behavior":"allow","destination":"localSettings"}]`.
- Terminal **"No"** (option 4) while the hook waits: Claude shows "Interrupted · What should Claude do instead?" and **kills the waiting hook process**. The hook never replied. The command did not run. No rule was saved. TESTED.
- Terminal **"Yes"** (option 1) while the hook waits: the tool runs at once (PostToolUse 7 s after the request). The hook's allow + rule arrived 13 s later and was **ignored**. **No rule was saved** (no `.claude/settings.local.json`). TESTED (`t9.exp`, press timed to the dialog).
- Hook answers first (no terminal answer): `allow` + `updatedPermissions` with `destination: localSettings` **does save** the rule to `<cwd>/.claude/settings.local.json` (`{"permissions":{"allow":["Bash(touch:*)"]}}`). TESTED (an earlier run where the key press missed the dialog). So "Always allow" in Buddy persists rules. That is why Buddy shows it only for Claude's own `permission_suggestions`.
- `PermissionDenied` exists in 2.1.317 (event name is in the binary; its output can set `retry`). It did **not** fire for a user "No" in the terminal. It is probably for auto-mode classifier denials (UNTESTED). Buddy installs it (non-blocking) and clears the card on it.
- Foreground check (for review H2): interactive claude shows `pgid == tpgid` and `stat` `S+`/`Ss+` (TESTED: `ps -o pid,pgid,tpgid,stat` at Stop).

## Subagents and background shells

Date: 2026-11-03. Claude Code 2.1.317. Headless tests (`claude -p`) with a logging hook on all events.
Labels: **TESTED** / **DOCS** / **UNTESTED** as above. Not tested: interactive TTY, failed subagents, killed subagents.
Test note: the user config sets a default agent, so main-session events showed `agent_type:"forgebee:orchestrator"`. Without a default agent the field is absent on main events (DOCS).

### Q1. Events for subagents

Verdict: `SubagentStart` and `SubagentStop` exist. TESTED. Other related events exist (DOCS): `TaskCreated`, `TaskCompleted` (agent teams and TaskCreate tasks, not Agent/Bash tasks), `PostToolBatch`. We registered `TaskCreated` and `TaskCompleted`. They did not fire in any test. Do not use them.

Payloads (TESTED, redacted):
```json
{"hook_event_name":"SubagentStart","session_id":"<parent>","transcript_path":"<parent .jsonl>","cwd":"...","agent_id":"abc530428637b978a","agent_type":"general-purpose"}
{"hook_event_name":"SubagentStop","session_id":"<parent>","transcript_path":"<parent .jsonl>","agent_transcript_path":".../<session_id>/subagents/agent-abc530428637b978a.jsonl","agent_id":"abc530428637b978a","agent_type":"general-purpose","stop_hook_active":false,"permission_mode":"acceptEdits","last_assistant_message":"Content: hello buddy","background_tasks":[],"session_crons":[]}
```
- `SubagentStart` keys: common fields + `agent_id`, `agent_type`. No `tool_use_id`, no description, no `permission_mode`, no prompt.
- `SubagentStop` has `last_assistant_message`, `agent_transcript_path`, `background_tasks`, `session_crons` (both are the PARENT's lists).
- `agent_id` format: `a` + 16 hex (`a6527e11be09810a5`). The DOCS example shows `agent-abc123`. Trust the real format, treat it as an opaque string.
- No success/failure field on `SubagentStop`. A failed or killed subagent: UNTESTED. Docs show nothing for it. Plan for no "failed" signal from hooks.
- Internal agents (prompt suggestions, `/btw`) also fire `SubagentStop`, with `agent_type` equal to the session agent or `""` (DOCS). Ignore a stop with an unknown `agent_id`. UNTESTED.
- Plugin subagents report `agent_type:"plugin:name"` (DOCS).

### Q2. Identity inside a subagent, and mapping to the Agent tool call

Verdict: YES for identity, PARTIAL for the link. TESTED.
- Every event fired inside a subagent (`PreToolUse`, `PostToolUse`, `PostToolBatch`, `PermissionRequest`) carries `agent_id` and `agent_type` (subagent type, e.g. `general-purpose`). `session_id` and `transcript_path` are the PARENT's. There is no `agent_transcript_path` and no parent `tool_use_id` on those events. The subagent's own tool calls have their own `tool_use_id`.
- Subagent tool is named `"Agent"` in `tool_name` (not `Task`). TESTED. Match both `Agent` and `Task` to be safe (older name, UNTESTED).
- `PreToolUse` Agent `tool_input` keys: `description`, `prompt`, `subagent_type`, `run_in_background`, `model`, `effort`. Keys are optional (`run_in_background` was absent when not set in some runs; the key list above is the union seen). `tool_use_id` is on the PreToolUse event.
- Link `agent_id` to the Agent tool call. Two ways:
  1. Exact, but only after the start (foreground: after the end). `PostToolUse` Agent `tool_response.agentId` = `agent_id`, same `tool_use_id` as the PreToolUse. Background: PostToolUse arrives 0.1 s after SubagentStart with `tool_response` `{"isAsync":true,"status":"async_launched","agentId":"...","description":"...","outputFile":"...","canContinueAgent":...}`. So for a background subagent the link is available within 100 ms.
  2. Early: `PreToolUse` Agent is followed at once by `SubagentStart` (0.2 s later in every run). Take the pending Agent call (FIFO, per `session_id`) and give it the new `agent_id`. Parallel Agent calls in one batch could race. Fix the race when `PostToolUse` arrives: it holds the exact `agentId`.
- Foreground `PostToolUse` Agent `tool_response` has `status:"completed"`, `agentId`, `agentType`, `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `toolsUsed`, `content`. Do not copy `prompt` or `content`.

### Q3. Background subagents timeline

Verdict: observable. TESTED (t in seconds, one run):
```
91.9 PreToolUse  Agent (run_in_background)       parent
92.1 SubagentStart a6527e11...                   
92.2 PostToolUse Agent  status=async_launched    parent turn continues
93.7 PreToolUse  Bash  (agent_id=a6527e11...)    inside the subagent
96.4 Stop (parent)  background_tasks=[{id:"a6527e11be09810a5",type:"subagent",status:"running",description:"Run sleep and echo",agent_type:"general-purpose"}]
106.7 PostToolUse Bash (subagent)
108.7 SubagentStop a6527e11...                   parent already stopped
109.1 UserPromptSubmit  prompt="<task-notification>...<task-id>a6527e11be09810a5</task-id>..."   parent wakes
113.1 Stop (parent) background_tasks=[]
```
- The parent `Stop` fires while the subagent still runs. Its `background_tasks` lists the running subagent. The `id` equals `agent_id`.
- Completion is observable: `SubagentStop`. Then the parent gets a synthetic `UserPromptSubmit` whose prompt starts with `<task-notification>` and holds `<task-id>`, `<tool-use-id>`, `<output-file>`, `<status>completed</status>`, `<summary>`. A second parent `Stop` follows. In `-p` mode the process stays alive until then. Interactive behaviour: UNTESTED, expect the same.
- Buddy must NOT turn the parent to "idle/done" on `Stop` when `background_tasks` is not empty. Use `background_tasks` as the truth for "still busy".
- `SubagentStop.background_tasks` still lists the finishing subagent itself as `running` (TESTED). Ignore that entry.

### Q4. Background shells

Verdict: observable, with a pid route. TESTED.
- Start: `PreToolUse` Bash has `tool_input.run_in_background:true`. `PostToolUse` Bash `tool_response` = `{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"by5x4bhvl"}`. The shell id is `tool_response.backgroundTaskId` (9 chars, opaque). The PostToolUse arrives at once (not at the exit).
- While running: parent `Stop` and `SubagentStop` list it. Exact entry (TESTED):
  `{"id":"by5x4bhvl","type":"shell","status":"running","description":"Sleep 6 seconds then print done","command":"sleep 6; echo shdone"}`
  Fields: `id`, `type` (`shell`/`subagent`/`monitor`/`workflow`/`teammate`/`cloud session`/`MCP task`), `status`, `description` (max 1000), `command` (shell only, max 1000), `agent_type` (subagent only), `server`/`tool` (monitor, MCP), `name` (workflow). DOCS and TESTED for shell and subagent. Other `status` values than `running`: UNTESTED (finished tasks leave the array).
- Finish: no dedicated hook event. Signals (all TESTED):
  1. The task id leaves `background_tasks` on the next `Stop` / `SubagentStop`.
  2. A synthetic parent `UserPromptSubmit` with `<task-notification><task-id>by5x4bhvl</task-id><tool-use-id>toolu_...</tool-use-id>...<status>completed</status><summary>Background command "..." completed...`. `<tool-use-id>` is the PreToolUse tool_use_id of the Bash call. Fires also for stop (status text for killed or failed: UNTESTED).
- Tools: there is no `BashOutput`, `KillShell`, or `TaskOutput` in 2.1.317 (the model said none matched). The stop tool is `TaskStop` with `tool_input` `{"task_id":"baz29seig"}`. Its `PostToolUse` `tool_response` = `{"message":"Successfully stopped task: baz29seig (sleep 40; echo never)","task_id":"...","task_type":"local_bash","command":"..."}`. A stopped shell shows in `PostToolUse TaskStop` (hook event), and the later `Stop` has `background_tasks:[]`. The model reads output from the file `<scratch>/<session>/tasks/<id>.output` (path in `<output-file>`), with plain Bash.
- Pid for liveness: YES. TESTED with `CLAUDE_PID` (hook env) and `ps`. Tree at PostToolUse: `claude(CLAUDE_PID) -> /bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-... && eval '<command>' -> sleep 40`. So the shell is a DIRECT CHILD of `CLAUDE_PID`, with the command text in its argv (truncated to 90 chars in our log). Find it by `ppid == CLAUDE_PID` and argv contains the `command`. Match on a new child since the PreToolUse snapshot when the commands repeat. The task id is NOT in argv as far as we logged (UNTESTED for the full argv). A pid check is a nice-to-have. The `background_tasks` list is better: it is exact and needs no `ps`.
- A background shell started INSIDE a subagent is also a child of `CLAUDE_PID` (same process). UNTESTED for pid. Its `PostToolUse` carries `agent_id` (PreToolUse/PostToolUse of Bash in subagent had `agent_id`, TESTED for foreground Bash).

### Q5. PermissionRequest inside a subagent

Verdict: YES, same as top-level. TESTED (`--permission-mode default`, Bash not allowed, subagent ran `touch`):
- Payload keys: `agent_id`, `agent_type`, `cwd`, `effort`, `hook_event_name`, `permission_mode`, `permission_suggestions`, `prompt_id`, `session_id`, `tool_input`, `tool_name`, `transcript_path`. No `tool_use_id` (as for top-level). The pair `agent_id` + `agent_type` is the only attribution.
- Hook answered `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`. The subagent's Bash ran and the file was created. Deny from a subagent hook: UNTESTED (expect it to work as in section 2).
- Order: PreToolUse (subagent) 140.19, PermissionRequest 140.52, PostToolUse 140.72. Notification `permission_prompt` did not fire in `-p`. Whether it carries `agent_id` is UNTESTED.
- Pairing a card with the tool call: `PermissionRequest` has no `tool_use_id`. Use `agent_id` + `tool_name` + `tool_input`, and the preceding `PreToolUse` with the same `agent_id`. At most one pending permission per subagent, so `agent_id` is enough.

### Q6. `agent_type` values

TESTED:
| Event source | `agent_type` |
|---|---|
| Main session, no default agent | field absent (DOCS) |
| Main session with `--agent X` or `agent` setting | `X` (seen: `forgebee:orchestrator`), also on SessionStart |
| Inside a subagent (any hook incl. SubagentStart/Stop) | subagent type: `general-purpose` (also `Explore`, `Plan`, custom `name`, `plugin:name`) |
| Internal agent SubagentStop (DOCS) | session agent name or `""` |
`agent_type` alone cannot tell main from subagent. Use `agent_id`: present only inside a subagent (absent on all main events, TESTED).

### Design impact for Buddy

Register hooks: `PreToolUse`, `PostToolUse`, `PermissionRequest`, `SubagentStart`, `SubagentStop`, `Stop`, `UserPromptSubmit` (already listed in section 1). `PostToolUse` must be unfiltered (matchers `Agent|Task|Bash|TaskStop` are enough for Buddy; `PreToolUse` may use `Agent|Task`).

(a) Subagent rows, state running / needs-permission / done / failed:
- Create: `SubagentStart` (`session_id`, `agent_id`, `agent_type`). Label: the `description` from the latest pending `PreToolUse` Agent in the same session (fill in `agentId` from `PostToolUse` Agent `tool_response.agentId`; use `tool_input.run_in_background` for a bg badge).
- running: after `SubagentStart`. Any event with this `agent_id` also proves it is alive.
- needs-permission: `PermissionRequest` with `agent_id`. Clear on the next `PostToolUse`/`PreToolUse`/`SubagentStop` with the same `agent_id`, or when Buddy answers.
- done: `SubagentStop` (`last_assistant_message` for a short result). Remove when the parent `Stop` shows `background_tasks` without the id and the row is old, or on `SessionEnd`.
- failed: NO hook signal found (UNTESTED). Best effort: parent `PostToolUse Agent` `tool_response.status != "completed"` (foreground), or `PostToolUseFailure` for the Agent call. Show "done" otherwise. Safety net for stuck rows: parent `Stop` whose `background_tasks` lacks the `agent_id` => finished.
- Do not mark the parent mascot idle while `background_tasks` is non-empty.

(b) Background shell rows:
- Create: `PostToolUse` Bash whose `tool_input.run_in_background` is true. Key = `tool_response.backgroundTaskId`. Label = `tool_input.description` (fallback: first 40 chars of `tool_input.command`). Owner = `agent_id` if present, else the parent session.
- running: id in `background_tasks` of the last `Stop`/`SubagentStop` (type `shell`), or no finish signal yet.
- finished: any of: id missing from a later `background_tasks`; synthetic `UserPromptSubmit` starting with `<task-notification>` with `<task-id>` = the id (parse `<status>`); `PostToolUse TaskStop` with `tool_input.task_id` (show "stopped"). Hide the `<task-notification>` prompt from the "last prompt" text on the card.
- Optional liveness: `ps` child of `CLAUDE_PID` matching `command`. Skip in v1.
- Gap: a shell that ends while the parent is mid-turn gives a finish signal only at the next `Stop`, or at the `<task-notification>` prompt (both come within about 1 s of the exit in the tests).

(c) Attribute permission cards: put `agent_id` and `agent_type` from `PermissionRequest` into the card (title "<agent_type> subagent wants to run Bash"). Look up the row by `agent_id`. Answer with the same JSON as for a top-level request.

Test files (scratch, not in the app): `scratchpad/w-sub/` (`log.py`, `ps.py`, `perm.py`, `settings*.json`, `ev1-3.jsonl`).

# Claude Desktop: facts for Buddy

Date: 2026-11-03. Claude Desktop 4.4212.0 (`com.anthropic.claudefordesktop`), bundled Claude Code 2.1.309. Desktop was not running.
Labels: **DOCS** = official docs. **OBSERVED** = seen on this Mac (read-only, structure only). **UNTESTED** = inference or not run yet.
Docs: https://code.claude.com/docs/en/desktop.md, `hooks.md`, `settings.md`, `cloud-environments.md`, `claude-code-on-the-web.md`, `remote-control.md`, `cross-session-messaging.md`.
No conversation content, prompts, tokens or personal data are copied here.

## 0. Three Desktop surfaces (do not mix them)

| Surface | What it is | Hooks? |
|---|---|---|
| Code tab, **Local** | Claude Code on the Mac, inside the app's process tree | Yes (DOCS) |
| Code tab, **Cloud** | Anthropic VM, claude.ai sessions | Yes, but on Anthropic's VM, not on the Mac |
| **Chat** and **Cowork** | Chat app. Cowork = agent mode in a local Linux VM | No Claude Code hooks for chat. Cowork: not a hook surface (see 2 and 3) |

DOCS: "In the Claude Desktop app, Claude Code is the **Code** tab. The app also has chat and Cowork." (desktop.md)

## 1. Local Desktop Code sessions

### 1.1 Process model
- DOCS: Desktop hosts Claude Code through the Agent SDK. hooks.md says: "sessions where it sends permission requests to the Agent SDK's `canUseTool` callback ... is how Claude Desktop and the VS Code extension host Claude Code."
- OBSERVED: Desktop ships a native macOS binary at `~/Library/Application Support/Claude/claude-code/2.1.309/<hash>/claude.app/Contents/MacOS/claude`. Bundle id `com.anthropic.claude-code`, Team ID `Q6L2SF6YDW`. The process name is `claude`.
- UNTESTED: parent chain. Expected: `claude` < (Desktop helper, Electron "Claude Helper" or `Claude`) < `/Applications/Claude.app/Contents/MacOS/Claude`. No shell and no tty in between. The test logs `chain`.
- Consequence: no controlling tty, so Buddy's `tty` field is null. The shell pid is the Desktop helper, not a shell.

### 1.2 Hooks and settings
- DOCS: "Claude Code fires the same hook events wherever it runs: sessions in the terminal, IDE extensions, the Desktop app, and cloud sessions." (hooks.md)
- DOCS: "The desktop app reads the same settings files as the CLI." So user `~/.claude/settings.json` hooks load. Project `.claude/settings.json` and `.claude/settings.local.json` load too (settings.md: terminal, IDE and desktop "all read the same settings files").
- DOCS: Worktree sessions started from Desktop read settings and hooks from the **main checkout root**. Hook `cwd` is the worktree path. `${CLAUDE_PROJECT_DIR}` is the main checkout. (worktrees.md)
- DOCS: Managed settings can switch Desktop hooks off: `disableAllHooks`, `allowManagedHooksOnly`, `strictPluginOnlyCustomization:["hooks"]`. Buddy must tolerate "no events from Desktop" in a managed company setup. Ask IT.
- Gotcha DOCS: Desktop sets some env itself. Claude Code ignores `env` from settings.json when the variable is already set. Not a hook problem, but do not rely on `env` in settings to pass Buddy config.
- UNTESTED: `buddy-hook` in `~/.claude/settings.json` fires for Desktop local sessions. Test step 2 proves it.

### 1.3 PermissionRequest and Desktop's own permission UI
- DOCS: `PermissionRequest` fires "when a tool call needs a permission decision". A hook answer comes first and Desktop UI is skipped: "If you or a PermissionRequest hook answer sooner, Claude Code doesn't run `permission_prompt`." Same text says Desktop uses `canUseTool`.
- DOCS: Notification `permission_prompt` fires about 6 s after the request in Desktop and VS Code sessions. It is not deferred by typing. `CLAUDE_CODE_DISABLE_PERMISSION_PROMPT_NOTIFY_HOOKS=1` turns it off. Before v2.1.233 it did not fire here.
- UNTESTED: whether Desktop shows its dialog while the hook still waits (both visible), and what happens if the user clicks Desktop first (hook is cancelled or ignored). In the CLI the hook wins or the dialog wins, first answer decides. Assume the same for Desktop. The test sends an empty hook output, so Desktop's UI is the only answerer. To test "hook blocks": swap in a hook that sleeps 20 s and answers. Not done here.
- Design rule: Buddy must handle "hook connection closed or timed out" as "someone else answered". Dismiss the Buddy bubble when `PostToolUse` or `PreToolUse` of the next tool or `Stop` arrives for the same session.

### 1.4 Env vars that reach hooks
| Var | Expected in Desktop local | Label |
|---|---|---|
| `CLAUDE_PID` | Yes. Claude Code itself sets it for hook subprocesses. It is the pid of the bundled `claude` | DOCS (env-vars.md) |
| `CLAUDE_CODE_MESSAGING_SOCKET` / `_TOKEN` | Probably yes. Docs: any session with messaging on binds an inbox socket. They name VS Code and Desktop as sessions that cannot show the approval dialog, so they do bind one | DOCS for binding, UNTESTED for Desktop |
| `TERM_PROGRAM` | Unset (no terminal). If Desktop is launched from a terminal it may inherit that terminal's value. Treat as unreliable | UNTESTED |
| `__CFBundleIdentifier` | `com.anthropic.claudefordesktop` if inherited from the Desktop launch (LaunchServices sets it for the app and its children). Treat as the best marker | UNTESTED |
| `CLAUDE_CODE_ENTRYPOINT` | Likely a non-`cli` value (SDK host). Name of the value is unknown. Docs do not list it | UNTESTED |
| `CLAUDE_CODE_SESSION_ATTENDED` | Unknown. Check: Desktop is attended by a person, but not by a tty | UNTESTED |

### 1.5 How Buddy tells Desktop from terminal
Use this order. Stop at the first hit.
1. `env.bundleId == "com.anthropic.claudefordesktop"`. 
2. Walk the pid chain from `claudePid`. If the `claude` binary path contains `/Library/Application Support/Claude/claude-code/` or an ancestor path starts with `/Applications/Claude.app/`, it is Desktop.
3. `CLAUDE_CODE_ENTRYPOINT` is not `cli` and there is no `tty`: SDK host. Then use rule 1 or 2 to pick Desktop, VS Code or Cursor.
The test shows which of these three work. Note the VS Code/Cursor extension also hosts via the SDK, so rule 3 alone cannot separate them.

### 1.6 Jump and "next prompt"
- Jump: activate `com.anthropic.claudefordesktop` (`NSRunningApplication` or `open -b`). UNTESTED. There is no per-session deep link in the docs. Jump brings Desktop forward only. The user picks the session in its sidebar. UNTESTED: whether Desktop has a URL scheme for a session. Do not build on it.
- Next prompt through the inbox socket: DOCS say a Desktop session "can't show the dialog" for held messages and keeps a held message until `dialogExpiry` (5 min default). So a socket message from another process is **held, not delivered**, unless `crossSessionInbound` allows it. The `crossSessionInbound` setting also gates inbound messages (DOCS). Treat inbox-socket delivery as NOT reliable for Desktop. Verdict: UNTESTED, likely held. Check with the test: log whether the socket env var is set, then send a test message by hand later.
- Alternative for "next prompt": none supported. Desktop has no input API. Option: Buddy copies the text to the clipboard, activates Desktop, user pastes. Or macOS Accessibility paste. Both are fragile and need permissions. Mark as optional.

## 2. Cloud and VM sessions

### 2.1 What the folders are (OBSERVED unless noted)
- `claude-code/<ver>/<hash>/claude.app`: macOS native Claude Code for **local** Code tab sessions (1.1).
- `claude-code-vm/<ver>/claude`: an **ELF 64-bit ARM Linux** binary (aarch64, dynamic, glibc). It cannot run on macOS. It runs inside a Linux VM. `claude-code-vm/.sdk-version` holds the version string (2.1.309). `.verified` and `.payload` are integrity files.
- `vm_bundles/claudevm.bundle/`: the VM image (boot parts: `rootfs.img`, `initrd*`, `efivars.fd`, machine id, mac address files). So Desktop runs a local Apple virtualisation VM. `vm-support-probe.json` holds virtualisation support flags.
- `local-agent-mode-sessions/<account-uuid>/<org-uuid>/local_<uuid>.json` plus `local_<uuid>/` folders: **Cowork** (local agent mode) sessions. Cowork runs the Linux `claude` in the local VM, with user folders mounted. It is not the Code tab cloud and it is not Anthropic's cloud. Label: OBSERVED for structure, UNTESTED for the exact name mapping (docs list Cowork but have no page on it).
  - Per-session JSON keys: `sessionId`, `cliSessionId`, `title`, `createdAt`, `lastActivityAt`, `isArchived`, `model`, `cwd`, `userSelectedFolders`, `processName`, `vmProcessName`, `enabledMcpTools`, `remoteMcpServersConfig`, `slashCommands`, `egressAllowedDomains`, `initialMessage`, `systemPrompt` and more (some sessions add `hostLoopMode`, `approvedToolNames`, `mcqAnswers`, `pluginsEnabled`, `skillsEnabled`).
  - Per-session folder: `.claude/`, `outputs/`, `uploads/`, `shim-lib/`, `shim-perm/`, `.audit-key`.
  - Account folder: `.claude.json`, `cowork_settings.json`, `cowork_plugins/`, `debug/<uuid>.txt` (debug logs), `rpm/`, `spaces/`, `scheduled-tasks.json`, `remote-session-spaces.json`.
- `claude-code-sessions/<account>/<org>/scheduled-tasks.json`: only scheduled-task data on this Mac (keys: `scheduledTasks`, `recordedSkips`, ...). No per-session state files for Code tab sessions were found here.
- `git-worktrees.json`: keys `worktrees`, `schemaVersion`, `untrackedDirGc`. Empty list now.
- Never read `initialMessage`, `systemPrompt`, `title` or the debug logs in Buddy. They hold conversation content. Regulated environment.

### 2.2 Where do hooks run?
- Code tab **Cloud** (Anthropic VM): DOCS. Hooks run on Anthropic's VM, from the repo's `.claude/settings.json` (one-repo sessions) and from server-managed settings. User `~/.claude/settings.json` and `settings.local.json` on the Mac are **not read** (settings.md, cloud-environments.md). A VM cannot reach `~/Library/Application Support/Buddy/buddy.sock`. **Not feasible** to use `buddy-hook` + socket.
- **Cowork / local VM**: UNTESTED. The Linux `claude` runs in a VM with its own config dir (`cowork_settings.json`, own `.claude` per session). A Unix socket on the Mac is not visible inside the VM, unless Desktop bridges it (the folders `shim-lib` and `shim-perm` suggest Desktop bridges tool permission calls to the host). Docs say none of the Desktop managed keys apply to Cowork. Assume hooks from `~/.claude/settings.json` do NOT apply. Mark: not feasible by hooks.
- Cloud hooks with a network call (HTTP hook to the Mac) cannot work: Mac has no public endpoint, and cloud egress is limited.

### 2.3 Supported ways to observe state from the Mac
| Option | Works for | Verdict |
|---|---|---|
| Remote Control (`claude --remote-control`, Desktop "Connect new sessions to Remote Control") | **Local** sessions, not cloud. Mirrors a local session to claude.ai | Not a local API. It is for steering from phone. No local event feed. Not useful for Buddy |
| `claude -p "msg" --cloud <session-id>` | Cloud: **send** a message | Send only. No read. No state back. DOCS |
| `claude --teleport` | Cloud to terminal copy | One-way, manual |
| `/tasks` in CLI (lists background sessions) | Cloud list | Interactive UI. No stable output format in docs |
| claude.ai sessions list / cloud sessions API | Cloud | UNTESTED. Docs give no public sessions API for state. Needs claude.ai login cookie or OAuth token. Buddy must not read Desktop tokens. Not acceptable |
| OS notifications (Desktop: "sends an OS notification when a Code session finishes a task and you aren't viewing that session") | Local Code tab | Visible to the user only. macOS gives no API to read other apps' notifications (the notification DB is protected). Not feasible |
| Polling `local_*.json` `lastActivityAt` (Cowork) | Cowork | Inferred only. UNTESTED whether it changes at turn end. It shows "activity", not "done" or "needs input". Weak signal |

### 2.4 Feasible design for cloud / VM
- Cloud: **not feasible** with hooks or files. A weak, optional alternative: a Buddy "cloud" card fed by Desktop's OS notification is not readable. Say "not supported" in the UI.
- Cowork: optional low-confidence signal: watch `local-agent-mode-sessions/*/*/local_*.json` mtime / `lastActivityAt` (FSEvents, read only, never parse content fields). Gives "active / quiet for N seconds". Cannot say "needs input". Build only after the test shows the file changes at turn end. Label UNTESTED.
- If the user needs real state for cloud sessions: file a feature request (`/feedback`) for a local hook or webhook on cloud session events.

## 3. Plain Desktop chats

- DOCS: Claude Code hooks do not apply to the chat surface. Hooks belong to Claude Code sessions only. There is no documented hook, local file or API for "response finished" or "needs input" in chat.
- OBSERVED: `claude_desktop_config.json` exists, top-level keys `coworkUserFilesPath`, `preferences`. It has **no `mcpServers` entry** on this Mac (0 servers).
- MCP server in `claude_desktop_config.json`: DOCS say Desktop loads it for chat and for local Code tab sessions. The server sees only `tools/list`, `tools/call` and notifications for tools Claude decides to call. It gets no "turn finished" event. Partial signal only:
  - A tool call means "Claude is working now". Time since the last call is not "done".
  - A server can offer a tool `report_done` and instructions asking Claude to call it at the end (MCP server `instructions` field). Claude may skip it, and Claude does not call it when it asks you a question. Unreliable. UNTESTED.
  - Desktop shows its own tool approval dialog per tool. The server cannot see it.
- Not feasible: detect "response finished", "needs input" or "streaming" for plain chats without screen scraping (Accessibility API or window title polling). Do not build it. It is fragile and reads conversation text on screen.
- Feasible but weak: show "Claude Desktop is running" (NSWorkspace) and a Jump button. No state.

## 4. Folder facts used (read only)
Listed names and JSON keys only, nothing under `~/Library/Application Support/Claude/` or `~/.claude/` was changed.

## Design impact for Buddy

**Local Desktop Code sessions: build it.**
1. No new hook install. The user hooks in `~/.claude/settings.json` already fire (DOCS). Confirm with the test.
2. Add `source = desktop` in the session model. Detect by `bundleId`, then pid-chain path (1.5). Store the result per session.
3. Do not require `tty` or `shellPid`. Allow null for both.
4. PermissionRequest and AskUserQuestion: keep the same flow. Handle "someone else answered" (Desktop UI wins): close the card when the next hook event for that session arrives or the hook socket closes.
5. Jump: activate `com.anthropic.claudefordesktop`. Show "pick the session in Desktop". No session deep link.
6. Next prompt: hide or disable it for Desktop sessions until a test proves the inbox socket delivers. Offer "copy and jump" as fallback.
7. Filter by `CLAUDE_CODE_ENTRYPOINT` / `ATTENDED` only after the test shows Desktop values. Do not drop Desktop sessions as "headless" by mistake.
8. Managed hook locks (`disableAllHooks`) can silence Desktop. Show "no Desktop events" in settings, not an error.

**Cloud / VM:** not feasible for state. Hooks run on Anthropic's VM. No local API. Say so in the UI. Optional later: weak "activity" indicator for Cowork via file mtime, after the test.

**Plain chats:** not feasible. At most "Desktop running" plus Jump. Do not scrape the screen.

**Next step:** user runs `~/Desktop/buddy-desktop-test/README.md`. Then run `analyze.sh` and update every UNTESTED row in 1.1, 1.3, 1.4, 1.6 and 2.2.

## 5. OBSERVED with a real Desktop session (2026-11-03, Desktop 4.4212.0, bundled Claude Code 2.1.309)

Project-level logging hooks, no hook decisions returned.
- Events: SessionStart > UserPromptSubmit > PreToolUse(Bash) > PostToolUse(Bash) > Stop. Keys as in the CLI plus `agent_type`, `effort`, `prompt_id`, `scratchpad_dir`. Stop has `background_tasks`, `session_crons`, `last_assistant_message`. OBSERVED.
- Env: `CLAUDE_PID` set; `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN` set; `TERM_PROGRAM` null; `TERM` unset; `__CFBundleIdentifier=com.anthropic.claudefordesktop`; `CLAUDE_CODE_ENTRYPOINT=claude-desktop`; `CLAUDE_CODE_SESSION_ATTENDED=1`. OBSERVED.
- Chain: `~/Library/Application Support/Claude/claude-code/2.1.309/<hash>/claude.app/Contents/MacOS/claude` < `/Applications/Claude.app/Contents/Helpers/disclaimer` < `/Applications/Claude.app/Contents/MacOS/Claude`. No tty. OBSERVED.
- With `permission_mode: "default"`: PreToolUse(Write), then PermissionRequest(Write) in the same second. PermissionRequest keys: `agent_type`, `cwd`, `effort`, `hook_event_name`, `permission_mode`, `permission_suggestions`, `prompt_id`, `scratchpad_dir`, `session_id`, `tool_input`, `tool_name`, `transcript_path`. Notification(`permission_prompt`) about 7 s later. After the user approved in Desktop's UI (mode became `acceptEdits`): PostToolUse, then Stop. OBSERVED.
- With `permission_mode: "auto"`, PermissionRequest did not fire. OBSERVED.
- UNTESTED: Desktop honors a hook `allow`/`deny` decision (the logging hook returned no output). UNTESTED: the inbox socket delivers a message to a Desktop session.

How Buddy uses this (W2 phase 4): detect Desktop by `CLAUDE_CODE_ENTRYPOINT == claude-desktop`, the bundle id, or an ancestor under `/Applications/Claude.app/`. Same PermissionRequest flow with "Answer in Claude Desktop". Next prompt only by the inbox socket. Jump activates Claude.app (no per-session link).

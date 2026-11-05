#!/bin/bash
# Installs Buddy's remote hook for Claude Code on THIS host. Run it from your Mac:
#   cat remote-install.env install.sh | ssh <host> 'bash -s'
# Buddy → Settings → SSH → "Copy remote install command" builds that line. See docs/SSH.md.
# remote-install.env is one line, BUDDY_TOKEN=<token>, so the token travels on stdin only.
# The old form `ssh <host> 'bash -s' -- '<token>' < install.sh` still works but is discouraged:
# it puts the token in shell history and in process lists.
# The block between the BUDDY_HOOK_EOF markers is scripts/remote/buddy-hook-remote.
# `python3 scripts/remote/test_hook.py --embed` copies it in again after a change.
set -euo pipefail
umask 077

TOKEN="${BUDDY_TOKEN:-${1:-}}"
case "$TOKEN" in
  "" | *[!0-9a-f]*) echo "buddy: missing or bad token. Copy the command again from Buddy → Settings → SSH." >&2; exit 1 ;;
esac
if [ "${#TOKEN}" -ne 64 ]; then
  echo "buddy: the token must have 64 hex characters." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))'; then
  echo "buddy: this host needs python3 3.8 or later for the hook. Install it, then run the command again." >&2
  exit 1
fi

HOOK="$HOME/.buddy/bin/buddy-hook-remote"
mkdir -p "$HOME/.buddy/bin" "$HOME/.config/buddy" "$HOME/.claude"
chmod 700 "$HOME/.buddy" "$HOME/.buddy/bin" "$HOME/.config/buddy"

tmp="$(mktemp "$HOME/.buddy/bin/.buddy-hook.XXXXXX")"
cat > "$tmp" <<'BUDDY_HOOK_EOF'
#!/usr/bin/env python3
"""Buddy remote hook: sends Claude Code hook events to Buddy on your Mac over an `ssh -R` socket.

Python 3.8+, standard library only. Fails open: on any error it exits 0 with no output (never 2),
so Claude Code runs as if Buddy were not there. See docs/SSH.md.

The payload slimming mirrors Sources/BuddyCore/HookPayload.swift. Keep both in sync (docs/protocol.md).
Lengths count Unicode code points here and grapheme clusters in Swift; the app slims remote payloads again.
"""
import json
import os
import socket
import stat
import sys
import uuid

MAX_IN = 1 << 20
MAX_LINE = 1 << 20
KEYS = ("session_id", "hook_event_name", "cwd", "permission_mode", "source", "reason", "tool_name", "tool_use_id",
        "notification_type", "last_assistant_message", "error", "error_details", "transcript_path", "agent_id", "agent_type",
        "session_title", "trigger")
LIMITS = {"last_assistant_message": 16000, "error": 4000, "error_details": 4000, "agent_id": 100, "agent_type": 100,
          "tool_name": 200, "session_title": 200, "trigger": 20}
INPUT_KEYS = ("description", "subagent_type", "command", "task_id", "file_path", "url")
RESPONSE_KEYS = ("agentId", "backgroundTaskId", "task_type")
INPUT_LIMIT = 200
MAX_TASKS = 50


def trim(s, limit):
    return s[:limit] + "…" if len(s) > limit else s


def strings(obj, keys):
    return {k: trim(obj[k], INPUT_LIMIT) for k in keys if isinstance(obj.get(k), str)}


def tag(name, prompt, limit, extra):
    a = prompt.find("<%s>" % name)
    if a < 0:
        return None
    a += len(name) + 2
    b = prompt.find("</%s>" % name, a)
    if b < 0:
        return None
    v = prompt[a:b]
    ok = 0 < len(v) <= limit and all(c.isascii() and (c.isalnum() or c in extra) for c in v)
    return v if ok else None


def slim(raw):
    """The same allowlist as HookPayload.slim: the prompt and tool output never leave this host."""
    out = {}
    for k in KEYS:
        if isinstance(raw.get(k), str):
            out[k] = trim(raw[k], LIMITS.get(k, len(raw[k])))
    if out.get("hook_event_name") == "PermissionRequest":
        for k in ("tool_input", "permission_suggestions"):
            if raw.get(k) is not None:
                out[k] = raw[k]
        return out
    ti = raw.get("tool_input")
    if isinstance(ti, dict):
        o = strings(ti, INPUT_KEYS)
        if isinstance(ti.get("run_in_background"), bool):
            o["run_in_background"] = ti["run_in_background"]
        if o:
            out["tool_input"] = o
    tr = raw.get("tool_response")
    if isinstance(tr, dict):
        o = strings(tr, RESPONSE_KEYS)
        if o:
            out["tool_response"] = o
    tasks = raw.get("background_tasks")
    if isinstance(tasks, list):
        out["background_tasks"] = [
            {k: trim(t[k], 100) for k in ("id", "type", "status") if isinstance(t.get(k), str)} if isinstance(t, dict) else {}
            for t in tasks[:MAX_TASKS]
        ]
    prompt = raw.get("prompt")
    if out.get("hook_event_name") == "UserPromptSubmit" and isinstance(prompt, str) \
            and prompt.strip().startswith("<task-notification>"):
        task = tag("task-id", prompt, 64, "-_")
        if task:
            out["task_id"] = task
            status = tag("status", prompt, 20, "")
            if status:
                out["task_status"] = status
    return out


def read_token():
    """~/.config/buddy/token: a regular file of this user, not readable by group or others."""
    path = os.path.expanduser("~/.config/buddy/token")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            return None
        return os.read(fd, 256).decode("ascii").strip() or None
    finally:
        os.close(fd)


def gather_env():
    e = os.environ
    try:
        claude_pid = int(e.get("CLAUDE_PID", ""))
    except ValueError:
        claude_pid = os.getppid()
    env = {"claudePid": claude_pid, "ssh": "SSH_CONNECTION" in e, "sshTty": "SSH_TTY" in e}
    for key, name in (("entrypoint", "CLAUDE_CODE_ENTRYPOINT"), ("attended", "CLAUDE_CODE_SESSION_ATTENDED")):
        if e.get(name):
            env[key] = e[name][:32]
    return env


def user_name():
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_name
    except (ImportError, KeyError):
        return os.environ.get("USER", "?")


def socket_ok(path):
    """A socket only this user can have put there: its folder is this user's and not writable by group or others,
    or the folder has the sticky bit and the socket is this user's."""
    uid = os.getuid()
    d = os.stat(os.path.dirname(path) or ".")
    s = os.lstat(path)
    if not stat.S_ISSOCK(s.st_mode):
        return False
    if d.st_mode & stat.S_ISVTX and s.st_uid == uid:
        return True
    return d.st_uid == uid and not d.st_mode & 0o022


def peer_ok(sock):
    """Linux: the listener (sshd for this login) runs as this user. Other systems have no SO_PEERCRED: skipped."""
    if not hasattr(socket, "SO_PEERCRED"):
        return True
    import struct
    _, uid, _ = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    return uid == os.getuid()


def read_line(sock):
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        buf += chunk
        if len(buf) > MAX_LINE + 1:
            return None
    return buf.split(b"\n", 1)[0]


def run():
    token = read_token()
    if not token:
        return
    path = os.environ.get("BUDDY_REMOTE_SOCK") or os.path.expanduser("~/.buddy/buddy.sock")
    if not socket_ok(path):
        return
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        # Connect first: with no forward the hook exits before it reads the payload.
        sock.settimeout(0.5)
        sock.connect(path)
        if not peer_ok(sock):
            return
        data = sys.stdin.buffer.read(MAX_IN + 1)
        if len(data) > MAX_IN:
            return
        raw = json.loads(data.decode("utf-8"))
        if not isinstance(raw, dict):
            return
        payload = slim(raw)
        wants_reply = payload.get("hook_event_name") == "PermissionRequest"
        msg = {"kind": "hook", "id": str(uuid.uuid4()), "wantsReply": wants_reply, "payload": payload,
               "env": gather_env(), "remote": {"host": socket.gethostname().split(".")[0], "user": user_name()},
               "token": token}
        line = (json.dumps(msg, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        if len(line) > MAX_LINE + 1:
            return
        sock.settimeout(5)
        sock.sendall(line)
        if not wants_reply:
            return
        # Claude Code's own hook timeout for PermissionRequest is also 3600 s.
        sock.settimeout(3600)
        reply = read_line(sock)
        if not reply:
            return
        r = json.loads(reply.decode("utf-8"))
        if isinstance(r, dict) and r.get("kind") == "reply" and r.get("id") == msg["id"] and r.get("output") is not None:
            sys.stdout.write(json.dumps(r["output"], ensure_ascii=False, separators=(",", ":")))
            sys.stdout.flush()
    finally:
        sock.close()


if __name__ == "__main__":
    try:
        run()
    except BaseException:  # fail open on everything, including a kill by Ctrl-C
        pass
    os._exit(0)
BUDDY_HOOK_EOF
chmod 700 "$tmp"
mv -f "$tmp" "$HOOK"

# printf is a shell builtin: the token never shows in a process list here.
tmp="$(mktemp "$HOME/.config/buddy/.token.XXXXXX")"
printf '%s\n' "$TOKEN" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$HOME/.config/buddy/token"

# Settings edit: settings-edit.py, embedded below. `test_hook.py --embed` refreshes it.
python3 - install "$HOME/.claude/settings.json" "$HOOK" <<'BUDDY_PY_EOF'
import json, os, sys, tempfile, time

mode, path = sys.argv[1], sys.argv[2]
hook = sys.argv[3] if mode == "install" else None
SUFFIX = "/.buddy/bin/buddy-hook-remote"
# Same events, matchers, and timeouts as the local installer (Sources/BuddyCore/HookInstaller.swift).
SPECS = [("SessionStart", None, 5), ("SessionEnd", None, 5), ("UserPromptSubmit", None, 5), ("Stop", None, 5),
         ("StopFailure", None, 5), ("Notification", None, 5), ("PermissionRequest", None, 3600), ("PreToolUse", "AskUserQuestion|Agent|Task", 5),
         ("PostToolUse", None, 5), ("PostToolUseFailure", None, 5), ("PermissionDenied", None, 5),
         ("SubagentStart", None, 5), ("SubagentStop", None, 5), ("PreCompact", None, 5), ("PostCompact", None, 5)]


def quote(p):
    return "'" + p.replace("'", "'\\''") + "'"


def unquote(c):
    return c[1:-1].replace("'\\''", "'") if len(c) >= 2 and c[0] == "'" and c[-1] == "'" else c


def ours(h):
    c = h.get("command") if isinstance(h, dict) else None
    return isinstance(c, str) and unquote(c).endswith(SUFFIX)


real = os.path.realpath(path)
try:
    with open(real, "rb") as f:
        raw = f.read()
except FileNotFoundError:
    raw = None
try:
    data = json.loads(raw) if raw and raw.strip() else {}
except ValueError as e:
    sys.exit("buddy: %s is not valid JSON (%s). Nothing changed." % (path, e))
if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
    sys.exit("buddy: %s has an unexpected shape. Nothing changed." % path)
if mode == "uninstall" and "hooks" not in data:
    sys.exit(0)

hooks = {}
for event, groups in data.get("hooks", {}).items():
    if not isinstance(groups, list):
        hooks[event] = groups
        continue
    kept = []
    for g in groups:
        handlers = g.get("hooks") if isinstance(g, dict) else None
        if not isinstance(handlers, list):
            kept.append(g)
            continue
        left = [h for h in handlers if not ours(h)]
        if len(left) == len(handlers):
            kept.append(g)
        elif left:
            kept.append(dict(g, hooks=left))
    if kept or not groups:
        hooks[event] = kept
if mode == "install":
    for event, matcher, timeout in SPECS:
        if not isinstance(hooks.get(event, []), list):
            sys.exit("buddy: %s has an unexpected value at hooks.%s. Nothing changed." % (path, event))
        group = {"hooks": [{"type": "command", "command": quote(hook), "timeout": timeout}]}
        if matcher:
            group["matcher"] = matcher
        hooks[event] = hooks.get(event, []) + [group]
new = dict(data, hooks=hooks)
if new == data:
    if mode == "install":
        print("Claude Code settings already have Buddy's hooks.")
    sys.exit(0)

folder = os.path.dirname(real)
backup = None
if raw is not None:
    backup = "%s.buddy-backup-%s" % (real, time.strftime("%Y%m%d-%H%M%S"))
    n = 0
    while os.path.exists(backup + ("-%d" % n if n else "")):
        n += 1
    backup += "-%d" % n if n else ""
    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    prefix = os.path.basename(real) + ".buddy-backup-"
    for old in sorted(x for x in os.listdir(folder) if x.startswith(prefix))[:-5]:
        os.remove(os.path.join(folder, old))
    if mode == "install":
        print("Backup: " + backup)
# A new file with a random name (O_EXCL, 0600) in the same folder, so the replace is atomic.
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.buddy-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(new, indent=2, ensure_ascii=False) + "\n")
    if raw is not None:
        os.chmod(tmp, os.stat(real).st_mode & 0o777)
    os.replace(tmp, real)
except BaseException:
    os.unlink(tmp)
    raise
if mode == "install":
    print("Claude Code settings updated: " + path)
else:
    print("Removed Buddy's hooks from %s. Backup: %s" % (path, backup))
BUDDY_PY_EOF

SOCK="$HOME/.buddy/buddy.sock"
if [ "${#SOCK}" -gt 100 ]; then
  echo "buddy: warning: $SOCK is longer than 100 bytes; Unix socket paths may not fit." >&2
fi
echo
echo "Buddy's remote hook is installed for $(id -un) on $(uname -n)."
echo "Add these lines to ~/.ssh/config on your Mac (use your own host alias):"
echo
echo "Host <your-alias>"
echo "  RemoteForward $SOCK \"%d/Library/Application Support/Buddy/remote.sock\""
echo
echo "On this host, ask an admin to set 'StreamLocalBindUnlink yes' in /etc/ssh/sshd_config,"
echo "or a stale $SOCK blocks the next forward. New Claude sessions use the hook."

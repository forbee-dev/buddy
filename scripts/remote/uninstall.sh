#!/bin/bash
# Removes Buddy's remote hook from THIS host. Run it from your Mac:
#   ssh <host> 'bash -s' < uninstall.sh
# Reverses install.sh: the hook entries in ~/.claude/settings.json (backup first), the hook, and the token.
set -euo pipefail
umask 077

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "buddy: python3 is missing, so $SETTINGS still lists the hook. Remove the entries that end in /.buddy/bin/buddy-hook-remote." >&2
  else
    python3 - "$SETTINGS" <<'BUDDY_PY_EOF'
import json, os, sys, tempfile, time

path = sys.argv[1]
SUFFIX = "/.buddy/bin/buddy-hook-remote"


def ours(h):
    c = h.get("command") if isinstance(h, dict) else None
    if not isinstance(c, str):
        return False
    if len(c) >= 2 and c[0] == "'" and c[-1] == "'":
        c = c[1:-1].replace("'\\''", "'")
    return c.endswith(SUFFIX)


real = os.path.realpath(path)
with open(real, "rb") as f:
    raw = f.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except ValueError as e:
    sys.exit("buddy: %s is not valid JSON (%s). Nothing changed." % (path, e))
if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
    sys.exit("buddy: %s has an unexpected shape. Nothing changed." % path)
if "hooks" not in data:
    sys.exit(0)
hooks = {}
for event, groups in data["hooks"].items():
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
new = dict(data, hooks=hooks)
if new == data:
    sys.exit(0)
backup = "%s.buddy-backup-%s" % (real, time.strftime("%Y%m%d-%H%M%S"))
n = 0
while os.path.exists(backup + ("-%d" % n if n else "")):
    n += 1
backup += "-%d" % n if n else ""
fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(raw)
# A new file with a random name (O_EXCL, 0600) in the same folder, so the replace is atomic.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.buddy-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(new, indent=2, ensure_ascii=False) + "\n")
    os.chmod(tmp, os.stat(real).st_mode & 0o777)
    os.replace(tmp, real)
except BaseException:
    os.unlink(tmp)
    raise
print("Removed Buddy's hooks from %s. Backup: %s" % (path, backup))
BUDDY_PY_EOF
  fi
fi
rm -f "$HOME/.buddy/bin/buddy-hook-remote" "$HOME/.config/buddy/token"
rmdir "$HOME/.buddy/bin" "$HOME/.config/buddy" 2>/dev/null || true
echo "Buddy's remote hook is removed from $(uname -n)."
echo "Also remove the RemoteForward line from ~/.ssh/config on your Mac."
echo "~/.buddy/buddy.sock belongs to sshd: remove it when no ssh session forwards to it."

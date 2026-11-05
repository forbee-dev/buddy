import json, os, sys, tempfile, time

mode, path = sys.argv[1], sys.argv[2]
hook = sys.argv[3] if mode == "install" else None
SUFFIX = "/.buddy/bin/buddy-hook-remote"
# Same events, matchers, and timeouts as the local installer (Sources/BuddyCore/HookInstaller.swift).
SPECS = [("SessionStart", None, 5), ("SessionEnd", None, 5), ("UserPromptSubmit", None, 5), ("Stop", None, 5),
         ("StopFailure", None, 5), ("Notification", None, 5), ("PermissionRequest", None, 3600), ("PreToolUse", "AskUserQuestion|Agent|Task", 5),
         ("PostToolUse", None, 5), ("PostToolUseFailure", None, 5), ("PermissionDenied", None, 5),
         ("SubagentStart", None, 5), ("SubagentStop", None, 5)]


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

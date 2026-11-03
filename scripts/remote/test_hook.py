#!/usr/bin/env python3
"""Tests for buddy-hook-remote, install.sh, and uninstall.sh. Every test uses a temp HOME, never the real one.

    python3 scripts/remote/test_hook.py           run the tests
    python3 scripts/remote/test_hook.py --embed   copy buddy-hook-remote into install.sh
"""
import json
import os
import py_compile
import re
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "buddy-hook-remote")
INSTALL = os.path.join(HERE, "install.sh")
UNINSTALL = os.path.join(HERE, "uninstall.sh")
TOKEN = "ab" * 32
EMBED = re.compile(r"(<<'BUDDY_HOOK_EOF'\n)(.*?)(\nBUDDY_HOOK_EOF\n)", re.S)


def embed():
    with open(HOOK) as f:
        hook = f.read().rstrip("\n")
    with open(INSTALL) as f:
        text = f.read()
    with open(INSTALL, "w") as f:
        f.write(EMBED.sub(lambda m: m.group(1) + hook + m.group(3), text, count=1))


class Server:
    """A fake Buddy: accepts one connection, keeps the line, and answers with `reply(msg)` if given."""

    def __init__(self, path, reply=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(1)
        self.sock.settimeout(0.05)  # set before the thread starts; join() ends the wait
        self.stop = threading.Event()
        self.reply = reply
        self.message = None
        self.connected = False
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
                break
            except socket.timeout:
                if self.stop.is_set():
                    return
        self.connected = True
        with conn:
            buf = b""
            conn.settimeout(3)
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buf += chunk
            self.message = json.loads(buf.split(b"\n")[0])
            if self.reply:
                conn.sendall((json.dumps(self.reply(self.message)) + "\n").encode())

    def join(self):
        # The hook has exited by now, so a connection from it is already queued.
        self.stop.set()
        self.thread.join(5)
        self.sock.close()


class Home(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="buddy-home-")
        self.sock = os.path.join(tempfile.mkdtemp(prefix="bs-", dir="/tmp"), "s.sock")
        self.env = dict(os.environ, HOME=self.home, BUDDY_REMOTE_SOCK=self.sock, CLAUDE_PID="4242",
                        SSH_CONNECTION="10.0.0.1 5000 10.0.0.2 22")
        self.env.pop("SSH_TTY", None)

    def write_token(self, mode=0o600, token=TOKEN):
        d = os.path.join(self.home, ".config", "buddy")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "token")
        with open(p, "w") as f:
            f.write(token + "\n")
        os.chmod(p, mode)

    def hook(self, stdin):
        start = time.monotonic()
        r = subprocess.run([sys.executable, HOOK], input=stdin, env=self.env, capture_output=True, timeout=10)
        return r, time.monotonic() - start


class HookTests(Home):
    def test_compiles(self):
        py_compile.compile(HOOK, cfile=os.path.join(self.home, "hook.pyc"), doraise=True)

    def test_sends_token_and_slim_payload(self):
        self.write_token()
        srv = Server(self.sock)
        payload = {"session_id": "s1", "hook_event_name": "PostToolUse", "cwd": "/home/u/api", "tool_name": "Bash",
                   "prompt": "secret prompt", "tool_input": {"command": "x" * 500, "content": "secret"},
                   "tool_response": {"stdout": "secret", "backgroundTaskId": "b1"}, "transcript_path": "/home/u/t.jsonl"}
        r, _ = self.hook(json.dumps(payload).encode())
        srv.join()
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, b"", b""))
        m = srv.message
        assert m is not None
        self.assertEqual((m["kind"], m["wantsReply"], m["token"]), ("hook", False, TOKEN))
        self.assertEqual(set(m["remote"]), {"host", "user"})
        self.assertEqual((m["env"]["claudePid"], m["env"]["ssh"], m["env"]["sshTty"]), (4242, True, False))
        p = m["payload"]
        self.assertNotIn("prompt", p)
        self.assertEqual(p["tool_input"], {"command": "x" * 200 + "…"})
        self.assertEqual(p["tool_response"], {"backgroundTaskId": "b1"})
        self.assertNotIn("secret", json.dumps(m))

    def test_blocking_reply_is_printed(self):
        self.write_token()
        out = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
        srv = Server(self.sock, reply=lambda m: {"kind": "reply", "id": m["id"], "output": out})
        r, _ = self.hook(json.dumps({"session_id": "s1", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                     "tool_input": {"command": "ls", "extra": "kept whole"}}).encode())
        srv.join()
        m = srv.message
        assert m is not None
        self.assertTrue(m["wantsReply"])
        self.assertEqual(m["payload"]["tool_input"], {"command": "ls", "extra": "kept whole"})
        self.assertEqual((r.returncode, json.loads(r.stdout)), (0, out))

    def test_null_or_wrong_id_reply_prints_nothing(self):
        self.write_token()
        for reply in (lambda m: {"kind": "reply", "id": m["id"], "output": None},
                      lambda m: {"kind": "reply", "id": "other", "output": {"x": 1}}):
            srv = Server(self.sock, reply=reply)
            r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash"}')
            srv.join()
            os.unlink(self.sock)
            self.assertEqual((r.returncode, r.stdout), (0, b""))

    def test_no_server_exits_fast_and_silent(self):
        self.write_token()
        r, took = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, b"", b""))
        self.assertLess(took, 1.0)

    def test_open_token_file_sends_nothing(self):
        for mode in (0o644, 0o640, 0o604):
            self.write_token(mode=mode)
            srv = Server(self.sock)
            r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
            srv.join()
            os.unlink(self.sock)
            self.assertEqual((r.returncode, r.stdout, srv.connected), (0, b"", False), oct(mode))

    def test_missing_token_sends_nothing(self):
        srv = Server(self.sock)
        r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
        srv.join()
        self.assertEqual((r.returncode, r.stdout, srv.connected), (0, b"", False))

    def test_oversize_or_bad_stdin_exits_zero(self):
        self.write_token()
        for stdin in (b'{"a":"' + b"x" * (1 << 20) + b'"}', b"not json", b"[1,2]"):
            srv = Server(self.sock)
            r, _ = self.hook(stdin)
            srv.join()
            os.unlink(self.sock)
            self.assertEqual((r.returncode, r.stdout, srv.message), (0, b"", None))

    def test_socket_in_open_folder_gets_nothing(self):
        self.write_token()
        folder = os.path.dirname(self.sock)
        for mode in (0o770, 0o707):
            srv = Server(self.sock)
            os.chmod(folder, mode)
            r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
            srv.join()
            os.unlink(self.sock)
            os.chmod(folder, 0o700)
            self.assertEqual((r.returncode, r.stdout, srv.connected), (0, b"", False), oct(mode))

    def test_own_socket_in_sticky_folder_is_used(self):
        self.write_token()
        srv = Server(self.sock)
        os.chmod(os.path.dirname(self.sock), 0o1777)
        r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
        srv.join()
        self.assertEqual((r.returncode, srv.connected), (0, True))

    def test_non_socket_path_gets_nothing(self):
        self.write_token()
        with open(self.sock, "w") as f:
            f.write("x")
        r, _ = self.hook(b'{"session_id":"s1","hook_event_name":"Stop"}')
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, b"", b""))

    def test_task_notification_keeps_only_ids(self):
        self.write_token()
        srv = Server(self.sock)
        prompt = "<task-notification>\n<task-id>bd0pozgot</task-id>\n<status>killed</status>\n<summary>secret</summary>"
        self.hook(json.dumps({"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": prompt}).encode())
        srv.join()
        assert srv.message is not None
        p = srv.message["payload"]
        self.assertEqual((p["task_id"], p["task_status"]), ("bd0pozgot", "killed"))
        self.assertNotIn("prompt", p)


class InstallTests(Home):
    def run_script(self, script, *args):
        with open(script, "rb") as f:
            return subprocess.run(["bash", "-s", "--", *args], stdin=f, env=dict(os.environ, HOME=self.home),
                                  capture_output=True, timeout=30)

    def run_with_env_file(self, token=TOKEN):
        """The command Buddy copies: cat '<env file>' '<install.sh>' | ssh <host> 'bash -s'."""
        env_file = os.path.join(self.home, "remote-install.env")
        with open(env_file, "w") as f:
            f.write("BUDDY_TOKEN=%s\n" % token)
        cmd = "cat '%s' '%s' | bash -s" % (env_file, INSTALL)
        return subprocess.run(["bash", "-c", cmd], env=dict(os.environ, HOME=self.home), capture_output=True, timeout=30)

    def settings(self):
        with open(os.path.join(self.home, ".claude", "settings.json")) as f:
            return json.load(f)

    def mode(self, *parts):
        return stat.S_IMODE(os.stat(os.path.join(self.home, *parts)).st_mode)

    def test_syntax(self):
        for s in (INSTALL, UNINSTALL):
            self.assertEqual(subprocess.run(["bash", "-n", s]).returncode, 0, s)

    def test_embedded_hook_matches_file(self):
        with open(HOOK) as f, open(INSTALL) as g:
            found = EMBED.search(g.read())
            assert found is not None
            self.assertEqual(found.group(2), f.read().rstrip("\n"),
                             "run: python3 scripts/remote/test_hook.py --embed")

    def test_install_is_idempotent_and_private(self):
        os.makedirs(os.path.join(self.home, ".claude"))
        user = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}
        with open(os.path.join(self.home, ".claude", "settings.json"), "w") as f:
            json.dump(user, f)
        r = self.run_script(INSTALL, TOKEN)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(TOKEN.encode(), r.stdout + r.stderr)
        self.assertIn(b"RemoteForward", r.stdout)
        first = self.settings()
        self.assertEqual(first["theme"], "dark")
        self.assertEqual(len(first["hooks"]), 12)
        self.assertEqual(first["hooks"]["Stop"][0], user["hooks"]["Stop"][0])
        cmd = first["hooks"]["PermissionRequest"][0]["hooks"][0]
        self.assertEqual((cmd["command"], cmd["timeout"]), ("'%s/.buddy/bin/buddy-hook-remote'" % self.home, 3600))
        self.assertEqual(first["hooks"]["PreToolUse"][0]["matcher"], "AskUserQuestion|Agent|Task")
        self.assertEqual(self.mode(".config", "buddy", "token"), 0o600)
        self.assertEqual(self.mode(".config", "buddy"), 0o700)
        self.assertEqual(self.mode(".buddy"), 0o700)
        self.assertEqual(self.mode(".buddy", "bin", "buddy-hook-remote"), 0o700)
        with open(os.path.join(self.home, ".config", "buddy", "token")) as f:
            self.assertEqual(f.read().strip(), TOKEN)
        backups = [x for x in os.listdir(os.path.join(self.home, ".claude")) if ".buddy-backup-" in x]
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.mode(".claude", backups[0]), 0o600)

        r = self.run_script(INSTALL, TOKEN)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.settings(), first)
        self.assertIn(b"already have", r.stdout)
        self.assertEqual(len([x for x in os.listdir(os.path.join(self.home, ".claude")) if ".buddy-backup-" in x]), 1)

        r = self.run_script(UNINSTALL)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.settings(), user)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".buddy", "bin", "buddy-hook-remote")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "buddy", "token")))

    def test_install_reads_token_from_env_file(self):
        r = self.run_with_env_file()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(TOKEN.encode(), r.stdout + r.stderr)
        with open(os.path.join(self.home, ".config", "buddy", "token")) as f:
            self.assertEqual(f.read().strip(), TOKEN)
        self.assertEqual(self.mode(".config", "buddy", "token"), 0o600)

    def test_bad_token_in_env_file_changes_nothing(self):
        r = self.run_with_env_file(token="zz" * 32)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "buddy", "token")))

    def test_merge_keeps_mode_and_leaves_no_temp_file(self):
        claude = os.path.join(self.home, ".claude")
        os.makedirs(claude)
        p = os.path.join(claude, "settings.json")
        with open(p, "w") as f:
            json.dump({"theme": "dark"}, f)
        os.chmod(p, 0o640)
        for script in (INSTALL, UNINSTALL):
            r = self.run_script(script, TOKEN)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.mode(".claude", "settings.json"), 0o640, script)
            self.assertEqual([x for x in os.listdir(claude) if x.startswith(".settings.buddy-") or x.endswith(".buddy-tmp")], [])

    def test_install_without_settings_file(self):
        r = self.run_script(INSTALL, TOKEN)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.settings()["hooks"]), 12)

    def test_bad_token_or_json_changes_nothing(self):
        for bad in ("", "short", "AB" * 32, "zz" * 32, "ab" * 32 + "; rm -rf ~"):
            r = self.run_script(INSTALL, bad)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "buddy", "token")))
        os.makedirs(os.path.join(self.home, ".claude"), exist_ok=True)
        p = os.path.join(self.home, ".claude", "settings.json")
        with open(p, "w") as f:
            f.write("{not json")
        r = self.run_script(INSTALL, TOKEN)
        self.assertNotEqual(r.returncode, 0)
        with open(p) as f:
            self.assertEqual(f.read(), "{not json")

    def test_installed_hook_reaches_server(self):
        self.assertEqual(self.run_script(INSTALL, TOKEN).returncode, 0)
        srv = Server(self.sock)
        env = dict(os.environ, HOME=self.home, BUDDY_REMOTE_SOCK=self.sock)
        r = subprocess.run([os.path.join(self.home, ".buddy", "bin", "buddy-hook-remote")],
                           input=b'{"session_id":"s1","hook_event_name":"Stop"}', env=env, capture_output=True, timeout=10)
        srv.join()
        assert srv.message is not None
        self.assertEqual((r.returncode, srv.message["token"]), (0, TOKEN))


if __name__ == "__main__":
    if "--embed" in sys.argv:
        embed()
        sys.exit(0)
    unittest.main()

# SSH sessions

Buddy can show Claude Code sessions that run on another host over SSH. The hook runs on the remote host and sends each event back through an OpenSSH Unix socket forward (`ssh -R`). This is off by default.

```
remote host                                   your Mac
claude → buddy-hook-remote → ~/.buddy/buddy.sock ══ ssh -R ══> ~/Library/Application Support/Buddy/remote.sock → Buddy
```

## Requirements

- OpenSSH 6.7 or later on both ends. The server must allow stream forwarding (`AllowStreamLocalForwarding`, default `yes`).
- python3 3.8 or later on the remote host. The hook uses the standard library only. There is no POSIX-sh fallback: the hook must parse and slim JSON, and plain sh cannot do that safely.
- Buddy on the Mac, with its normal hooks installed.

## Setup in 5 steps

1. **Turn it on.** Buddy → Settings → SSH → **Allow SSH sessions**. Buddy creates `remote.sock` (mode 0600, in the 0700 Buddy folder) and a random 256-bit token in your login Keychain (service `com.tiagosantos.buddy`, account `remote-token`).
2. **Install on the host.** Type the host (an ssh alias such as `devbox`, or `user@devbox`) and click **Copy remote install command**. Paste it in Terminal within 10 minutes. It looks like this:

   ```sh
   cat '/Users/you/Library/Application Support/Buddy/remote-install.env' '/Applications/Buddy.app/Contents/Resources/remote/install.sh' | ssh devbox 'bash -s'
   ```

   The command holds no token. Buddy writes the token to `remote-install.env` (one line, `BUDDY_TOKEN=<token>`, mode 0600) and deletes that file after 10 minutes, on **Rotate token**, and when Buddy quits. Settings shows "Install file expires in 10 min". If the file is gone, click the button again.

   `install.sh` runs on the host. It writes `~/.buddy/bin/buddy-hook-remote` (0700), `~/.config/buddy/token` (0600), and adds Buddy's hook entries to the host's `~/.claude/settings.json` (backup first; running it again changes nothing). It prints the ssh_config lines for step 3.
3. **Forward the socket.** Add the printed lines to `~/.ssh/config` on your Mac:

   ```
   Host devbox
     RemoteForward /home/you/.buddy/buddy.sock "/Users/you/Library/Application Support/Buddy/remote.sock"
   ```

   The first path is on the host, the second on your Mac. Use the double quotes: ssh_config takes a double-quoted argument with spaces. `%d` (your local home folder) also works: `"%d/Library/Application Support/Buddy/remote.sock"`. Check the result without a connection: `ssh -G devbox | grep -i remoteforward`.
4. **Let the server replace a stale socket.** On the host, an admin adds this to `/etc/ssh/sshd_config` and reloads sshd:

   ```
   StreamLocalBindUnlink yes
   ```

   Without it, the socket file of a dropped connection stays, and the next `RemoteForward` fails ("remote port forwarding failed for listen path"). The remote socket mode comes from `StreamLocalBindMask` (default `0177`, so the socket is 0600). Keep that default.
5. **Connect and start Claude.** `ssh devbox`, then `claude`. The buddy's tag shows `devbox:project`. Settings → Diagnostics shows "Last remote event: accepted".

To remove it: `ssh devbox 'bash -s' < '/Applications/Buddy.app/Contents/Resources/remote/uninstall.sh'`, then delete the `RemoteForward` line.

## What works

| Feature | SSH session |
|---|---|
| Buddy, states, subagents, background shells, Activity | Yes |
| Permission and AskUserQuestion cards | Yes. The answer goes back on the same connection. |
| Jump | Raises the local terminal that runs `ssh` (for VS Code and Cursor, the terminal of that `ssh` process). |
| Tokens and cost | No. Buddy cannot read the remote transcript. The row shows "remote". |
| Next prompt | No. The card says "Answer in the terminal". |
| Look | Chosen per host and folder, so `devbox:api` and your local `api` can look different. |

Next prompt is off because Buddy types a prompt only when claude is the foreground process of its terminal. On a Mac, Buddy checks that with the process table. On a remote host it cannot: the local `ssh` process is always in the foreground, even when claude is suspended or a shell runs in front of it. A prompt could then run as a shell command on the host. Answer in the terminal.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `remote port forwarding failed for listen path` when you connect | A stale `~/.buddy/buddy.sock` from an old connection. Set `StreamLocalBindUnlink yes` on the server (step 4), or remove the file on the host when no session uses it. |
| No buddy, Diagnostics shows "Last remote event: none yet" | Check the forward on the host: `ls -l ~/.buddy/buddy.sock` must show a socket while you are connected. Check that Settings → SSH is on and Diagnostics shows "Remote socket: Listening". Start a new claude session after the install. |
| Diagnostics: "rejected: token mismatch" or "no token sent" | The host has an old token (you rotated it) or none. Click **Copy remote install command** and run it again. |
| The installer says "missing or bad token" | The install file expired (10 minutes) or you rotated the token. Click **Copy remote install command** again and paste the new command. |
| The hook does nothing, and `~/.buddy` is group- or world-writable | The hook refuses a socket in a folder that others can write. Run `chmod 700 ~/.buddy` on the host. |
| Diagnostics: "rejected: peer is not an allowed ssh client" | Your `ssh` is not `/usr/bin/ssh` (for example Homebrew's). Add its path in Settings → SSH → Allowed ssh clients. |
| The installer says python3 is missing | Install python3 3.8 or later on the host (`apt install python3`, `dnf install python3`), then run the install command again. |
| The hook does nothing and no error shows | That is by design: the hook fails open. Test it on the host: `echo '{"session_id":"t","hook_event_name":"Stop"}' \| ~/.buddy/bin/buddy-hook-remote; echo $?` prints `0`. Check `~/.config/buddy/token`: the hook refuses a token file that group or others can read (`chmod 600`). |
| Socket path errors | Unix socket paths have a limit of about 104 bytes on macOS and 108 on Linux. Keep the remote home path short. |
| Inside tmux or screen | Works. The hook does not depend on `SSH_TTY` or `SSH_CONNECTION`. After a reconnect, sessions that started on the old connection end, and the next event starts a new buddy. |

## Security notes

- **Opt-in, separate socket.** The main socket `buddy.sock` never accepts remote messages: a message with `remote` or `token` is refused there. `remote.sock` exists only while the setting is on.
- **Peer checks.** A connection on `remote.sock` must come from your own uid, and the peer process must be `/usr/bin/ssh` or a path you added (the `realpath` must match; only binaries named `ssh` can be added). Buddy reads the peer's path from its audit token, taken when the connection is accepted, so a reused pid cannot pass.
- **Shared token.** Each message must carry the token. Buddy compares it in constant time. The token lives in the Keychain on the Mac and in `~/.config/buddy/token` (0600) on the host. It is never in UserDefaults, logs, or the diagnostics report. The Keychain item trusts only Buddy: other apps must ask you.
- **Remote socket checks.** The hook sends only to a socket in a folder of yours that group and others cannot write (or a socket of yours in a sticky folder). On Linux, the listener must also run as you (`SO_PEERCRED`).
- **No HMAC.** The hook sends the token, not an HMAC of each message. Anyone who could see the token in transit (you, or root on either end) can also read the token file, so an HMAC would not stop them.
- **Remote data is untrusted.** Buddy slims every remote payload again, drops `transcript_path`, and never uses a remote pid, tty, or socket for a local process lookup. `remote.host` and `remote.user` are for display only (hidden characters shown, max 64 characters). Remote events never change a local session, and remote hosts can hold at most 8 of the 32 session slots.
- **Who can send.** Anyone who can connect to the host's `~/.buddy/buddy.sock` and read the token can show cards on your Mac. Root on the host can do both. Use SSH sessions only with hosts whose admins you trust. Buddy never approves anything by itself: every answer is your click.
- **The install command holds no token.** The token goes over the SSH connection on stdin, from a 0600 file that Buddy deletes after 10 minutes. It is not in your shell history, the clipboard, or a process list. The old form `ssh <host> 'bash -s' -- '<token>' < install.sh` still works, but avoid it: it puts the token in shell history and process lists.
- Menu → **Uninstall Buddy…** can delete the Keychain item ("Also delete the SSH token from the Keychain"). Otherwise delete "Buddy SSH token" in Keychain Access.

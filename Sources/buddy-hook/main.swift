import Foundation
import Darwin
import BuddyCore

// Fail open: any problem -> exit 0 with no output, so Claude Code behaves as if Buddy is not there.
signal(SIGPIPE, SIG_IGN)

#if DEBUG
let debugBuild = true
let appNames = HookTrust.debugNames
/// Tests set `BUDDY_HOOK_WAIT_MS` to tell "the app closed" from "the cap ran out". At least 1: 0 means no timeout.
let closeWaitMs = ProcessInfo.processInfo.environment["BUDDY_HOOK_WAIT_MS"].flatMap(Int.init).map { min(max($0, 1), 60_000) } ?? 1000
#else
let debugBuild = false
let appNames = HookTrust.releaseNames
let closeWaitMs = 1000
#endif

let terminalKeys: Set<String> = ["TERM_PROGRAM", "__CFBundleIdentifier", "VSCODE_GIT_ASKPASS_MAIN", "ITERM_SESSION_ID", "TERM_SESSION_ID"]
let claudeKeys: Set<String> = ["CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_ENTRYPOINT"]

/// Reads only `keys`, not a copy of the whole environment.
func ownEnv(_ keys: Set<String>) -> [String: String] {
    var out: [String: String] = [:]
    for k in keys { if let v = getenv(k) { out[k] = String(cString: v) } }
    return out
}

/// `event` and `cwd`: the payload's. OpenCode runs plugins in a service without a tty; the routing (tty, terminal
/// app) comes from the TUI. Only `OpenCodeTUI.routingEvents` pay for the process scan that finds it.
func gatherEnv(event: String? = nil, cwd: String? = nil) -> HookEnv {
    let own = ownEnv(["CLAUDE_PID", "BUDDY_AGENT"])
    let host = own["CLAUDE_PID"].flatMap { Int32($0) } ?? getppid()
    let openCode = own["BUDDY_AGENT"] == HookEnv.openCode
    var claudePid = host
    var term = ownEnv(terminalKeys)
    if openCode {
        let scan = event.map(OpenCodeTUI.routingEvents.contains) ?? false
        let tui = scan ? OpenCodeTUI.find(host: host, cwd: cwd) : (ProcInfo.tty(of: host) != nil ? host : nil)
        if let tui, tui != host {
            claudePid = tui
            term = ProcInfo.environment(of: tui, keys: terminalKeys) ?? [:]
        } else if tui == nil {
            // The service's environment names the app that started it, not the session's terminal.
            term = [:]
        }
    }
    let claude = openCode ? [:] : ownEnv(claudeKeys)
    let proc = ProcInfo.info(of: claudePid)
    return HookEnv(
        claudePid: claudePid,
        shellPid: proc?.ppid,
        tty: proc?.tty,
        termProgram: term["TERM_PROGRAM"],
        bundleId: term["__CFBundleIdentifier"],
        askpassMain: term["VSCODE_GIT_ASKPASS_MAIN"],
        itermSessionId: term["ITERM_SESSION_ID"],
        termSessionId: term["TERM_SESSION_ID"],
        messagingSocket: claude["CLAUDE_CODE_MESSAGING_SOCKET"],
        messagingToken: claude["CLAUDE_CODE_MESSAGING_TOKEN"],
        attended: claude["CLAUDE_CODE_SESSION_ATTENDED"],
        entrypoint: claude["CLAUDE_CODE_ENTRYPOINT"],
        agent: openCode ? HookEnv.openCode : nil,
        hostPid: openCode ? host : nil)
}

/// Debug builds with `BUDDY_SOCKET` (tests) check the user only.
func trustedServer(_ fd: Int32) -> Bool {
    if debugBuild && ProcessInfo.processInfo.environment["BUDDY_SOCKET"] != nil { return PeerCheck.peerUid(fd) == getuid() }
    return HookTrust.serverAllowed(peerUid: PeerCheck.peerUid(fd), ownUid: getuid(), peerPath: PeerCheck.peerPid(fd).flatMap(PeerCheck.path(of:)),
                                   selfPath: PeerCheck.path(of: getpid()), names: appNames)
}

func run() throws {
    // Connect first: when Buddy is down the hook exits before it reads or parses the payload.
    let fd = try UnixSocket.connect(UnixSocket.defaultPath(allowOverride: debugBuild))
    defer { close(fd) }
    guard trustedServer(fd) else { return }
    let payload = try HookPayload.decode(FileHandle.standardInput.readDataToEndOfFile())
    let wantsReply = payload["hook_event_name"]?.string == "PermissionRequest"
    let msg = HookMessage(id: UUID().uuidString, wantsReply: wantsReply, payload: payload, env: gatherEnv(event: payload["hook_event_name"]?.string, cwd: payload["cwd"]?.string))
    let line = try WireMessage.encode(msg)
    guard line.count <= wireMaxLine else { return }
    UnixSocket.setSendTimeout(fd, seconds: 1)
    try UnixSocket.writeAll(fd, line)
    guard wantsReply else {
        // Stay alive until the app has checked this process and closes; 1 s cap.
        shutdown(fd, SHUT_WR)
        UnixSocket.setReceiveTimeout(fd, milliseconds: closeWaitMs)
        UnixSocket.drainUntilClose(fd)
        return
    }
    // Backstop if the app never answers; Claude Code's own hook timeout is also 3600 s.
    UnixSocket.setReceiveTimeout(fd, seconds: 3600)
    guard let replyLine = try UnixSocket.readLine(fd),
          case .reply(let reply) = try WireMessage.decode(replyLine),
          reply.id == msg.id, reply.output != .null else { return }
    FileHandle.standardOutput.write(Data(reply.output.encoded().utf8))
}

/// `buddy-hook statusline`: sends only `rate_limits` to the app without waiting for an answer, then runs the
/// user's own status line command (saved by the app at install) with the same stdin and passes its output through.
func statusLine() -> Int32 {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    struct Slim: Decodable { var rate_limits: JSONValue? }
    if input.count <= 256 * 1024, let limits = (try? JSONDecoder().decode(Slim.self, from: input))?.rate_limits, limits.object != nil,
       let fd = try? UnixSocket.connect(UnixSocket.defaultPath(allowOverride: debugBuild)) {
        if trustedServer(fd), let line = try? WireMessage.encode(StatusLineMessage(claudePid: gatherEnv().claudePid, rateLimits: limits)) {
            UnixSocket.setSendTimeout(fd, milliseconds: 100)
            try? UnixSocket.writeAll(fd, line)
            // The app checks this process while it is alive; 100 ms is enough for its close, never a full wait.
            shutdown(fd, SHUT_WR)
            UnixSocket.setReceiveTimeout(fd, milliseconds: 100)
            UnixSocket.drainUntilClose(fd)
        }
        close(fd)
    }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    guard let saved = SafeFile.contents(HookInstaller.previousStatusLineURL(home: home).path, maxBytes: 64 * 1024),
          let previous = try? JSONDecoder().decode(JSONValue.self, from: saved),
          previous["type"]?.string == "command", let command = previous["command"]?.string, !command.isEmpty else { return 0 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let stdin = Pipe()
    p.standardInput = stdin
    do { try p.run() } catch { return 0 }
    try? stdin.fileHandleForWriting.write(contentsOf: input)
    try? stdin.fileHandleForWriting.close()
    p.waitUntilExit()
    return p.terminationStatus
}

if CommandLine.arguments.dropFirst().first == "statusline" { exit(statusLine()) }
do { try run() } catch {}
exit(0)

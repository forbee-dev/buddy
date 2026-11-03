import Foundation
import Darwin
import BuddyCore

// Fail open: any problem -> exit 0 with no output, so Claude Code behaves as if Buddy is not there.
signal(SIGPIPE, SIG_IGN)

#if DEBUG
let debugBuild = true
let appNames = ["Buddy", "BuddyApp"]
#else
let debugBuild = false
let appNames = ["Buddy"]
#endif

func gatherEnv() -> HookEnv {
    let e = ProcessInfo.processInfo.environment
    let claudePid = e["CLAUDE_PID"].flatMap { Int32($0) } ?? getppid()
    let proc = ProcInfo.info(of: claudePid)
    return HookEnv(
        claudePid: claudePid,
        shellPid: proc?.ppid,
        tty: proc?.tty,
        termProgram: e["TERM_PROGRAM"],
        bundleId: e["__CFBundleIdentifier"],
        askpassMain: e["VSCODE_GIT_ASKPASS_MAIN"],
        itermSessionId: e["ITERM_SESSION_ID"],
        termSessionId: e["TERM_SESSION_ID"],
        messagingSocket: e["CLAUDE_CODE_MESSAGING_SOCKET"],
        messagingToken: e["CLAUDE_CODE_MESSAGING_TOKEN"],
        attended: e["CLAUDE_CODE_SESSION_ATTENDED"],
        entrypoint: e["CLAUDE_CODE_ENTRYPOINT"])
}

/// The listener must be our own user running the Buddy binary next to this hook (review M1).
/// Debug builds with `BUDDY_SOCKET` (tests) check the user only.
func trustedServer(_ fd: Int32) -> Bool {
    guard PeerCheck.peerUid(fd) == getuid() else { return false }
    if debugBuild && ProcessInfo.processInfo.environment["BUDDY_SOCKET"] != nil { return true }
    guard let me = PeerCheck.path(of: getpid()) else { return false }
    let dir = (me as NSString).deletingLastPathComponent
    return PeerCheck.peerIs(fd, oneOf: appNames.map { dir + "/" + $0 })
}

func run() throws {
    // Connect first: when Buddy is down the hook exits before it reads or parses the payload.
    let fd = try UnixSocket.connect(UnixSocket.defaultPath(allowOverride: debugBuild))
    defer { close(fd) }
    guard trustedServer(fd) else { return }
    let payload = try HookPayload.decode(FileHandle.standardInput.readDataToEndOfFile())
    let wantsReply = payload["hook_event_name"]?.string == "PermissionRequest"
    let msg = HookMessage(id: UUID().uuidString, wantsReply: wantsReply, payload: payload, env: gatherEnv())
    let line = try WireMessage.encode(msg)
    guard line.count <= wireMaxLine else { return }
    UnixSocket.setSendTimeout(fd, seconds: 1)
    try UnixSocket.writeAll(fd, line)
    guard wantsReply else {
        // Stay alive until the app has checked this process and closes (review S1); 1 s cap.
        shutdown(fd, SHUT_WR)
        UnixSocket.setReceiveTimeout(fd, seconds: 1)
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

do { try run() } catch {}
exit(0)

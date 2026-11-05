import Foundation

public enum SessionState: String, Sendable, CaseIterable {
    case starting, working, needsPermission, asking, done, idle, error, ended

    public var needsAttention: Bool { self == .needsPermission || self == .asking }

    public var label: String {
        switch self {
        case .starting: "starting"
        case .working: "working"
        case .needsPermission: "needs permission"
        case .asking: "has a question"
        case .done: "done"
        case .idle: "idle"
        case .error: "tool failed"
        case .ended: "ended"
        }
    }
}

/// A blocked PermissionRequest hook. `id` is the hook message id; the app maps it to the socket connection.
public struct PendingRequest: Sendable, Equatable {
    public enum Kind: Sendable { case permission, question }
    public var id: String
    public var kind: Kind
    public var toolName: String
    /// Matches PostToolUse / PostToolUseFailure / PermissionDenied when present.
    public var toolUseId: String?
    public var toolInput: JSONValue
    public var suggestions: [JSONValue]
    /// Set when a subagent asks. Its requests carry no `tool_use_id`, so matching stays inside this agent.
    public var agentId: String?
    public var arrivedAt = Date()
}

public struct Session: Sendable, Identifiable {
    public var id: String
    /// Survives re-keying (clear/compact/resume) so the mascot stays the same.
    public var mascotKey: String
    public var cwd: String
    /// The main conversation's own state; subagent events never set it.
    public var mainState: SessionState
    /// What the buddy shows: the main state, or attention while a subagent's card waits for the user.
    public var state: SessionState {
        get {
            guard let p = pending, p.agentId != nil else { return mainState }
            return p.kind == .question ? .asking : .needsPermission
        }
        set { mainState = newValue }
    }
    public var env: HookEnv
    public var lastMessage: String?
    public var lastError: String?
    public var pending: PendingRequest?
    public var hidden: Bool
    public var permissionMode: String?
    /// From the hook payload; read only through `TranscriptTail`, which validates it.
    public var transcriptPath: String?
    /// Short status shown on the card, e.g. "Answered in terminal".
    public var note: String?
    public var updated: Date
    public var subagents: [String: Subagent] = [:]
    public var shells: [String: Shell] = [:]
    /// Time of the last main `Stop`, for the "while you were away" digest.
    public var finishedAt: Date?
    /// Playful tip for the newest tool call (`Tips`); never holds command text.
    public var tip: String?
    /// Agent tool calls waiting for their SubagentStart, oldest first.
    var agentCalls: [AgentCall] = []
    var mainPending: PendingRequest? { pending?.agentId == nil ? pending : nil }

    /// When the buddy started to wait on the user. Without a card, the last event time (shortcut: a Notification
    /// gives no start time).
    public var waitingSince: Date? { state.needsAttention ? (pending?.arrivedAt ?? updated) : nil }

    /// The cwd's last part, hidden characters made visible, one line, max 64 characters (it can come from a remote host).
    public var folderName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "claude" : RemoteInfo.display(name)
    }
    public var projectName: String { remote.map { "\($0.host):\(folderName)" } ?? folderName }
    /// Set for a session that runs on another host over SSH.
    public var remote: RemoteOrigin?
    /// Look assignment key: the cwd, plus the host for a remote session.
    public var lookKey: String { remote.map { "\($0.host):\(cwd)" } ?? cwd }
    /// The claude process behind the session: a local pid, or the ssh client plus the remote pid.
    var processKey: String? {
        guard let r = remote else { return env.claudePid.map { "pid-\($0)" } }
        return r.claudePid.map { "ssh-\(r.sshPid)-\($0)" }
    }
    /// Set by the app when claude's parent chain runs under /Applications/Claude.app.
    public var underClaudeApp = false
    public var terminal: TerminalApp { underClaudeApp ? .claudeDesktop : TerminalApp.detect(env) }
    /// Where "Answer in ..." sends the user.
    public var answerPlace: String { terminal == .claudeDesktop ? "Claude Desktop" : "terminal" }
}

public struct StoreChange: Sendable, Equatable {
    public var sessionId: String?
    /// Hook connections that wait for a reply that no longer matters; answer them with `output: null`.
    public var staleRequests: [String] = []
    public init(sessionId: String? = nil, staleRequests: [String] = []) {
        self.sessionId = sessionId; self.staleRequests = staleRequests
    }
}

public struct SessionStore: Sendable {
    public static let maxSessions = 32
    /// Remote hosts may hold only some of the slots, so they cannot crowd out local sessions.
    public static let maxRemoteSessions = 8
    /// Sessions without a claude pid cannot be reaped by pid; they end after this much silence.
    public static let noPidTTL: TimeInterval = 3600
    public private(set) var sessions: [String: Session] = [:]
    public init() {}

    /// `origin` is set for a message from `remote.sock` (`RemoteAuth.localize`); its env has no pids.
    public mutating func apply(_ msg: HookMessage, origin: RemoteOrigin? = nil, now: Date = Date(),
                               isAlive: (Int32) -> Bool = ProcInfo.isAlive) -> StoreChange {
        let p = msg.payload
        guard let sid = p["session_id"]?.string, let event = p["hook_event_name"]?.string else { return StoreChange() }
        var change = StoreChange(sessionId: sid)
        if event == "SessionStart" { rekey(to: sid, env: msg.env, origin: origin, change: &change) }
        if let existing = sessions[sid] {
            // Local events never touch a remote session, remote ones never a local one or another ssh connection's.
            guard existing.remote?.sshPid == origin?.sshPid,
                  accepts(existing, event: event, pid: msg.env.claudePid, isAlive: isAlive) else { return StoreChange() }
        } else if sessions.count >= Self.maxSessions
                    || (origin != nil && sessions.values.filter { $0.remote != nil }.count >= Self.maxRemoteSessions) {
            return StoreChange()
        }
        var s = sessions[sid] ?? newSession(sid, msg, origin: origin, now: now)
        let agent = p["agent_id"]?.string
        if agent == nil {
            if let cwd = p["cwd"]?.string { s.cwd = cwd }
            if let mode = p["permission_mode"]?.string { s.permissionMode = mode }
            if let t = p["transcript_path"]?.string { s.transcriptPath = t }
        }
        if event == "SessionStart" { s.env = Self.routingEnv(msg.env) }
        s.updated = now
        s.trackTools(event: event, p, now: now)
        if let agent { subagentEvent(&s, agent: agent, event: event, msg: msg, change: &change, now: now) }
        else { transition(&s, event: event, msg: msg, change: &change, now: now) }
        s.pruneActivity(now: now)
        sessions[sid] = s
        return change
    }

    /// Routing fields come from SessionStart only. A SessionStart from another claude pid may take over
    /// only when the old pid is unknown, the same, or dead. Ended sessions accept only SessionStart.
    private func accepts(_ s: Session, event: String, pid: Int32?, isAlive: (Int32) -> Bool) -> Bool {
        guard let pid, let old = s.env.claudePid, old != pid else { return event == "SessionStart" || s.state != .ended }
        return event == "SessionStart" && !isAlive(old)
    }

    /// Main-session events only (no `agent_id`).
    private func transition(_ s: inout Session, event: String, msg: HookMessage, change: inout StoreChange, now: Date) {
        let p = msg.payload
        let tool = p["tool_name"]?.string
        switch event {
        case "SessionStart":
            s.state = .starting
        case "UserPromptSubmit":
            if s.mainPending != nil { clearPending(&s, &change, note: nil) }
            s.state = .working; s.lastError = nil
            if let task = p["task_id"]?.string { s.applyTaskNotification(task, status: p["task_status"]?.string, now: now) }
        case "PreToolUse":
            if tool == "AskUserQuestion", s.mainPending == nil { s.state = .asking }
        case "PermissionRequest":
            clearPending(&s, &change, note: nil)
            // Hidden sessions are never held: the app replies null at once.
            guard !s.hidden else { break }
            s.pending = pendingRequest(msg, tool: tool ?? "tool", now: now)
            s.state = tool == "AskUserQuestion" ? .asking : .needsPermission
            s.note = nil
        case "PermissionDenied":
            if matches(s.pending, p) { clearPending(&s, &change, note: "Denied") }
            if s.mainPending == nil { s.state = .working }
        case "PostToolUse", "PostToolUseFailure":
            if matches(s.pending, p) { clearPending(&s, &change, note: "Answered in terminal") }
            if s.mainPending == nil { s.state = event == "PostToolUse" ? .working : .error }
            if event == "PostToolUseFailure" { s.lastError = p["error"]?.string }
        case "Notification":
            applyNotification(&s, type: p["notification_type"]?.string)
        case "Stop":
            if s.mainPending != nil { clearPending(&s, &change, note: nil) }
            s.state = .done
            s.finishedAt = now
            if let m = p["last_assistant_message"]?.string { s.lastMessage = m }
            s.applyBackgroundTasks(p["background_tasks"], main: true, now: now)
            s.agentCalls = []
        case "SessionEnd":
            clearPending(&s, &change, note: nil)
            // clear/resume keep the claude process; a SessionStart with a new id follows.
            let reason = p["reason"]?.string
            s.state = (reason == "clear" || reason == "resume") ? .idle : .ended
            s.endActivity(now: now)
        default:
            break
        }
    }

    /// Events fired inside a subagent. They change its record and its card, never the main state.
    private func subagentEvent(_ s: inout Session, agent: String, event: String, msg: HookMessage,
                               change: inout StoreChange, now: Date) {
        let p = msg.payload
        let tool = p["tool_name"]?.string
        switch event {
        case "SubagentStart":
            if var a = s.subagents[agent] {
                // The same id starts again when the subagent wakes for its own background work (E1).
                a.state = .running
                a.endedAt = nil
                s.subagents[agent] = a
                break
            }
            let call = s.agentCalls.isEmpty ? nil : s.agentCalls.removeFirst()
            s.subagents[agent] = Subagent(id: agent, type: Activity.clip(p["agent_type"]?.string ?? "", 40), call: call, startedAt: now)
        case "SubagentStop":
            // Internal agents stop with ids that never started (Q1, E1).
            guard s.subagents[agent] != nil else { break }
            if s.pending?.agentId == agent { clearPending(&s, &change, note: nil) }
            s.applyBackgroundTasks(p["background_tasks"], main: false, now: now)
            if !s.ownsRunningShell(agent) { s.setSubagent(agent, .done, now: now) }
            if let m = p["last_assistant_message"]?.string { s.subagents[agent]?.lastMessage = Activity.clip(m, 300) }
        case "PermissionRequest":
            clearPending(&s, &change, note: nil)
            guard !s.hidden else { break }
            s.pending = pendingRequest(msg, tool: tool ?? "tool", now: now)
            s.setSubagent(agent, tool == "AskUserQuestion" ? .asking : .needsPermission)
            s.note = nil
        case "PreToolUse":
            if tool == "AskUserQuestion", s.pending?.agentId != agent { s.setSubagent(agent, .asking) }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            if matches(s.pending, p) { clearPending(&s, &change, note: event == "PermissionDenied" ? "Denied" : "Answered in terminal") }
            if s.pending?.agentId != agent { s.setSubagent(agent, .running) }
        default:
            break
        }
    }

    /// Same tool_use_id when both sides have one; the tool name otherwise. Never across agents.
    private func matches(_ pending: PendingRequest?, _ p: JSONValue) -> Bool {
        guard let pending, pending.agentId == p["agent_id"]?.string else { return false }
        if let a = pending.toolUseId, let b = p["tool_use_id"]?.string { return a == b }
        return pending.toolName == p["tool_name"]?.string
    }

    private func newSession(_ sid: String, _ msg: HookMessage, origin: RemoteOrigin?, now: Date) -> Session {
        var s = Session(id: sid, mascotKey: sid, cwd: msg.payload["cwd"]?.string ?? "", mainState: .starting,
                        env: Self.routingEnv(msg.env), hidden: msg.env.attended == "0", updated: now)
        s.remote = origin
        s.mascotKey = s.processKey ?? sid
        return s
    }

    /// Drops an inbox socket that is not `/tmp/cc-socks/<claudePid>.sock`, and its token with it.
    static func routingEnv(_ env: HookEnv) -> HookEnv {
        var e = env
        e.messagingSocket = InboxClient.validatedSocket(env.messagingSocket, claudePid: env.claudePid)
        if e.messagingSocket == nil { e.messagingToken = nil }
        return e
    }

    private func pendingRequest(_ msg: HookMessage, tool: String, now: Date) -> PendingRequest {
        PendingRequest(id: msg.id, kind: tool == "AskUserQuestion" ? .question : .permission, toolName: tool,
                       toolUseId: msg.payload["tool_use_id"]?.string,
                       toolInput: msg.payload["tool_input"] ?? .null,
                       suggestions: msg.payload["permission_suggestions"]?.array ?? [],
                       agentId: msg.payload["agent_id"]?.string, arrivedAt: now)
    }

    private func applyNotification(_ s: inout Session, type: String?) {
        switch type {
        case "permission_prompt": if s.mainPending == nil { s.state = .needsPermission }
        case "elicitation_dialog", "agent_needs_input": if s.mainPending == nil { s.state = .asking }
        // Done stays done until the next prompt: idle_prompt (about 60 s later) used to hide the finish.
        case "idle_prompt": if s.state == .starting { s.state = .idle }
        default: break
        }
    }

    private mutating func rekey(to sid: String, env: HookEnv, origin: RemoteOrigin?, change: inout StoreChange) {
        var probe = Session(id: sid, mascotKey: sid, cwd: "", mainState: .starting, env: env, hidden: false, updated: Date())
        probe.remote = origin
        guard sessions[sid] == nil, let key = probe.processKey,
              let old = sessions.values.first(where: { $0.processKey == key && $0.state != .ended }) else { return }
        var moved = old
        clearPending(&moved, &change, note: nil)
        moved.id = sid
        sessions[old.id] = nil
        sessions[sid] = moved
    }

    private func clearPending(_ s: inout Session, _ change: inout StoreChange, note: String?) {
        guard let pend = s.pending else { return }
        change.staleRequests.append(pend.id)
        s.pending = nil
        s.note = note
        if let a = pend.agentId { s.setSubagent(a, .running) }
        if s.state.needsAttention { s.state = .working }
    }

    /// The hook connection closed (Claude killed the hook or the terminal answered). False if `sid` no longer shows it.
    public mutating func requestClosed(sid: String, requestId: String) -> Bool {
        guard var s = sessions[sid], s.pending?.id == requestId else { return false }
        var c = StoreChange()
        clearPending(&s, &c, note: "Answered in terminal")
        sessions[sid] = s
        return true
    }

    /// Buddy answered the request. Returns false if `sid` no longer shows it.
    public mutating func resolve(sid: String, requestId: String) -> Bool {
        guard var s = sessions[sid], let pend = s.pending, pend.id == requestId else { return false }
        s.pending = nil
        s.note = nil
        if let a = pend.agentId { s.setSubagent(a, .running) } else { s.state = .working }
        sessions[sid] = s
        return true
    }

    /// Marks sessions whose claude process is gone (or, without a pid, silent past the TTL) as ended.
    /// `stale` lists pending requests that were dropped; reply null to them. `changed` is false when nothing changed.
    public mutating func reap(isAlive: (Int32) -> Bool, now: Date = Date()) -> (ended: [String], stale: [String], changed: Bool) {
        var ended: [String] = []
        var change = StoreChange()
        var pruned = false
        for id in Array(sessions.keys) where sessions[id]?.pruneActivity(now: now) == true { pruned = true }
        for (id, s) in sessions where s.state != .ended {
            // A remote session lives as long as the local ssh client that carries it.
            if let pid = s.remote?.sshPid ?? s.env.claudePid {
                guard !isAlive(pid) else { continue }
            } else {
                guard now.timeIntervalSince(s.updated) > Self.noPidTTL else { continue }
            }
            end(id, &change, now: now)
            ended.append(id)
        }
        return (ended, change.staleRequests, pruned || !ended.isEmpty)
    }

    /// SSH sessions turned off: every remote session ends.
    public mutating func endRemoteSessions(now: Date = Date()) -> (ended: [String], stale: [String]) {
        var change = StoreChange()
        let ids = sessions.values.filter { $0.remote != nil && $0.state != .ended }.map(\.id).sorted()
        for id in ids { end(id, &change, now: now) }
        return (ids, change.staleRequests)
    }

    private mutating func end(_ id: String, _ change: inout StoreChange, now: Date) {
        guard var s = sessions[id] else { return }
        clearPending(&s, &change, note: nil)
        s.state = .ended
        s.endActivity(now: now)
        sessions[id] = s
    }

    public var isEmpty: Bool { sessions.isEmpty }
    public mutating func setHidden(_ id: String, _ hidden: Bool) { sessions[id]?.hidden = hidden }
    public mutating func setUnderClaudeApp(_ id: String, _ value: Bool) { sessions[id]?.underClaudeApp = value }
    public mutating func setNote(_ id: String, _ note: String?) { sessions[id]?.note = note }

    /// Removes the session only if it is still ended (a SessionStart may have revived it).
    public mutating func removeIfEnded(_ id: String) -> Bool {
        guard sessions[id]?.state == .ended else { return false }
        sessions[id] = nil
        return true
    }
}

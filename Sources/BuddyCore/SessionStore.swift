import Foundation

public enum SessionState: String, Sendable, CaseIterable {
    case starting, working, needsPermission, asking, done, idle, error, ended

    public var needsAttention: Bool { self == .needsPermission || self == .asking }
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
}

public struct Session: Sendable, Identifiable {
    public var id: String
    /// Survives re-keying (clear/compact/resume) so the mascot stays the same.
    public var mascotKey: String
    public var cwd: String
    public var state: SessionState
    public var env: HookEnv
    public var lastMessage: String?
    public var lastError: String?
    public var pending: PendingRequest?
    public var hidden: Bool
    public var permissionMode: String?
    /// Short status shown on the card, e.g. "Answered in terminal".
    public var note: String?
    public var updated: Date

    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "claude" : name
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
    /// Sessions without a claude pid cannot be reaped by pid; they end after this much silence.
    public static let noPidTTL: TimeInterval = 3600
    public private(set) var sessions: [String: Session] = [:]
    public init() {}

    public mutating func apply(_ msg: HookMessage, now: Date = Date(), isAlive: (Int32) -> Bool = ProcInfo.isAlive) -> StoreChange {
        let p = msg.payload
        guard let sid = p["session_id"]?.string, let event = p["hook_event_name"]?.string else { return StoreChange() }
        var change = StoreChange(sessionId: sid)
        if event == "SessionStart" { rekey(to: sid, env: msg.env, change: &change) }
        if let existing = sessions[sid] {
            guard accepts(existing, event: event, pid: msg.env.claudePid, isAlive: isAlive) else { return StoreChange() }
        } else if sessions.count >= Self.maxSessions {
            return StoreChange()
        }
        var s = sessions[sid] ?? newSession(sid, msg, now: now)
        if let cwd = p["cwd"]?.string { s.cwd = cwd }
        if let mode = p["permission_mode"]?.string { s.permissionMode = mode }
        if event == "SessionStart" { s.env = Self.routingEnv(msg.env) }
        s.updated = now
        transition(&s, event: event, msg: msg, change: &change)
        sessions[sid] = s
        return change
    }

    /// Routing fields come from SessionStart only. A SessionStart from another claude pid may take over
    /// only when the old pid is unknown, the same, or dead. Ended sessions accept only SessionStart.
    private func accepts(_ s: Session, event: String, pid: Int32?, isAlive: (Int32) -> Bool) -> Bool {
        guard let pid, let old = s.env.claudePid, old != pid else { return event == "SessionStart" || s.state != .ended }
        return event == "SessionStart" && !isAlive(old)
    }

    private func transition(_ s: inout Session, event: String, msg: HookMessage, change: inout StoreChange) {
        let p = msg.payload
        let tool = p["tool_name"]?.string
        switch event {
        case "SessionStart":
            s.state = .starting
        case "UserPromptSubmit":
            clearPending(&s, &change, note: nil); s.state = .working; s.lastError = nil
        case "PreToolUse":
            if tool == "AskUserQuestion", s.pending == nil { s.state = .asking }
        case "PermissionRequest":
            clearPending(&s, &change, note: nil)
            // Hidden sessions are never held: the app replies null at once (review M5).
            guard !s.hidden else { break }
            s.pending = pendingRequest(msg, tool: tool ?? "tool")
            s.state = tool == "AskUserQuestion" ? .asking : .needsPermission
            s.note = nil
        case "PermissionDenied":
            if matches(s.pending, p) { clearPending(&s, &change, note: "Denied") }
            if s.pending == nil { s.state = .working }
        case "PostToolUse", "PostToolUseFailure":
            if matches(s.pending, p) { clearPending(&s, &change, note: "Answered in terminal") }
            if s.pending == nil { s.state = event == "PostToolUse" ? .working : .error }
            if event == "PostToolUseFailure" { s.lastError = p["error"]?.string }
        case "Notification":
            applyNotification(&s, type: p["notification_type"]?.string)
        case "Stop":
            clearPending(&s, &change, note: nil)
            s.state = .done
            if let m = p["last_assistant_message"]?.string { s.lastMessage = m }
        case "SessionEnd":
            clearPending(&s, &change, note: nil)
            // clear/resume keep the claude process; a SessionStart with a new id follows.
            let reason = p["reason"]?.string
            s.state = (reason == "clear" || reason == "resume") ? .idle : .ended
        default:
            break
        }
    }

    /// Same tool_use_id when both sides have one; the tool name otherwise.
    private func matches(_ pending: PendingRequest?, _ p: JSONValue) -> Bool {
        guard let pending else { return false }
        if let a = pending.toolUseId, let b = p["tool_use_id"]?.string { return a == b }
        return pending.toolName == p["tool_name"]?.string
    }

    private func newSession(_ sid: String, _ msg: HookMessage, now: Date) -> Session {
        let key = msg.env.claudePid.map { "pid-\($0)" } ?? sid
        return Session(id: sid, mascotKey: key, cwd: msg.payload["cwd"]?.string ?? "", state: .starting,
                       env: Self.routingEnv(msg.env), hidden: msg.env.attended == "0", updated: now)
    }

    /// Drops an inbox socket that is not `/tmp/cc-socks/<claudePid>.sock`, and its token with it.
    static func routingEnv(_ env: HookEnv) -> HookEnv {
        var e = env
        e.messagingSocket = InboxClient.validatedSocket(env.messagingSocket, claudePid: env.claudePid)
        if e.messagingSocket == nil { e.messagingToken = nil }
        return e
    }

    private func pendingRequest(_ msg: HookMessage, tool: String) -> PendingRequest {
        PendingRequest(id: msg.id, kind: tool == "AskUserQuestion" ? .question : .permission, toolName: tool,
                       toolUseId: msg.payload["tool_use_id"]?.string,
                       toolInput: msg.payload["tool_input"] ?? .null,
                       suggestions: msg.payload["permission_suggestions"]?.array ?? [])
    }

    private func applyNotification(_ s: inout Session, type: String?) {
        switch type {
        case "permission_prompt": if s.pending == nil { s.state = .needsPermission }
        case "elicitation_dialog", "agent_needs_input": if s.pending == nil { s.state = .asking }
        case "idle_prompt": if s.state == .done || s.state == .starting { s.state = .idle }
        default: break
        }
    }

    private mutating func rekey(to sid: String, env: HookEnv, change: inout StoreChange) {
        guard sessions[sid] == nil, let pid = env.claudePid,
              let old = sessions.values.first(where: { $0.env.claudePid == pid && $0.state != .ended }) else { return }
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
        if s.state.needsAttention { s.state = .working }
    }

    /// The hook connection closed (Claude killed the hook or the terminal answered).
    public mutating func requestClosed(_ requestId: String) -> String? {
        guard var s = sessions.values.first(where: { $0.pending?.id == requestId }) else { return nil }
        var c = StoreChange()
        clearPending(&s, &c, note: "Answered in terminal")
        sessions[s.id] = s
        return s.id
    }

    /// Buddy answered the request. Returns false if it is no longer pending.
    public mutating func resolve(requestId: String) -> Bool {
        guard var s = sessions.values.first(where: { $0.pending?.id == requestId }) else { return false }
        s.pending = nil
        s.note = nil
        s.state = .working
        sessions[s.id] = s
        return true
    }

    /// Marks sessions whose claude process is gone (or, without a pid, silent past the TTL) as ended.
    /// `stale` lists pending requests that were dropped; reply null to them.
    public mutating func reap(isAlive: (Int32) -> Bool, now: Date = Date()) -> (ended: [String], stale: [String]) {
        var ended: [String] = []
        var change = StoreChange()
        for (id, s) in sessions where s.state != .ended {
            if let pid = s.env.claudePid {
                guard !isAlive(pid) else { continue }
            } else {
                guard now.timeIntervalSince(s.updated) > Self.noPidTTL else { continue }
            }
            var copy = s
            clearPending(&copy, &change, note: nil)
            copy.state = .ended
            sessions[id] = copy
            ended.append(id)
        }
        return (ended, change.staleRequests)
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

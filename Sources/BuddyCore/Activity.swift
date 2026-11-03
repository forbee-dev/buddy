import Foundation

/// The `Agent` tool call a subagent came from (its PreToolUse).
public struct AgentCall: Sendable, Equatable {
    public var toolUseId: String?
    /// The call's `description`, revealed and trimmed. nil: the subagent shows its type.
    public var label: String?
    public var background: Bool
}

public struct Subagent: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        case running, needsPermission, asking, done, failed, stopped
        public var isActive: Bool { self == .running || self == .needsPermission || self == .asking }
    }
    public var id: String
    public var type: String
    public var call: AgentCall?
    public var state: State = .running
    public var startedAt: Date
    public var endedAt: Date?
    /// `last_assistant_message` of SubagentStop, revealed and trimmed.
    public var lastMessage: String?

    public var label: String { call?.label ?? (type.isEmpty ? "subagent" : type) }
    public var background: Bool { call?.background ?? false }
}

public struct Shell: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable { case running, finished, stopped }
    public var id: String
    public var label: String
    public var state: State = .running
    /// `agent_id` of the subagent that started it (E1); nil for the main session.
    public var owner: String?
    public var startedAt: Date
    public var endedAt: Date?
}

public enum Activity {
    public static let maxSubagents = 20
    public static let maxShells = 10
    static let maxCalls = 20
    /// Done, failed, stopped, and finished entries expire after this.
    public static let keepEnded: TimeInterval = 600

    /// Model text for a label: revealed, one line, at most `n` characters.
    public static func clip(_ s: String, _ n: Int) -> String {
        let r = DisplayText.reveal(s.trimmingCharacters(in: .whitespacesAndNewlines))
        return r.count > n ? String(r.prefix(n - 1)) + "…" : r
    }

    /// Drops expired entries, then the oldest ended ones, then the oldest running ones, down to `cap`.
    static func pruned<T>(_ d: [String: T], cap: Int, now: Date, ended: (T) -> Date?, started: (T) -> Date) -> [String: T] {
        var out = d.filter { ended($0.value).map { now.timeIntervalSince($0) < keepEnded } ?? true }
        guard out.count > cap else { return out }
        let order = out.sorted { a, b in
            (ended(a.value) == nil ? 1 : 0, started(a.value), a.key) < (ended(b.value) == nil ? 1 : 0, started(b.value), b.key)
        }
        for (k, _) in order.prefix(out.count - cap) { out[k] = nil }
        return out
    }

    static func isAgentTool(_ name: String?) -> Bool { name == "Agent" || name == "Task" }
}

extension Session {
    public var activeSubagents: Int { subagents.values.filter(\.state.isActive).count }
    public var runningShells: Int { shells.values.filter { $0.state == .running }.count }
    public var hasActivity: Bool { !subagents.isEmpty || !shells.isEmpty }

    /// Card header name for a subagent request.
    public func subagentLabel(_ id: String) -> String { subagents[id]?.label ?? "A subagent" }

    /// Changes a subagent's state only while it still runs; a late event never revives a finished one.
    mutating func setSubagent(_ id: String, _ state: Subagent.State, now: Date? = nil) {
        guard var a = subagents[id], a.state.isActive else { return }
        a.state = state
        if !state.isActive { a.endedAt = now ?? Date() }
        subagents[id] = a
    }

    mutating func endShell(_ id: String, _ state: Shell.State, now: Date) {
        guard shells[id]?.state == .running else { return }
        shells[id]?.state = state
        shells[id]?.endedAt = now
    }

    /// Tool calls that start, stop, or fix up subagents and background shells. Main and subagent events alike.
    mutating func trackTools(event: String, _ p: JSONValue, now: Date) {
        let tool = p["tool_name"]?.string
        let useId = p["tool_use_id"]?.string
        let input = p["tool_input"]
        switch (event, tool) {
        case ("PreToolUse", let t) where Activity.isAgentTool(t):
            let label = input?["description"]?.string.flatMap { $0.isEmpty ? nil : Activity.clip($0, 60) }
            agentCalls.append(AgentCall(toolUseId: useId, label: label, background: input?["run_in_background"]?.bool == true))
            if agentCalls.count > Activity.maxCalls { agentCalls.removeFirst() }
        case ("PostToolUse", let t) where Activity.isAgentTool(t):
            if let aid = p["tool_response"]?["agentId"]?.string { relink(agentId: aid, toolUseId: useId) }
            agentCalls.removeAll { $0.toolUseId != nil && $0.toolUseId == useId }
        case ("PostToolUseFailure", let t) where Activity.isAgentTool(t):
            if let id = subagents.values.first(where: { $0.call?.toolUseId != nil && $0.call?.toolUseId == useId })?.id {
                setSubagent(id, .failed, now: now)
            }
            agentCalls.removeAll { $0.toolUseId != nil && $0.toolUseId == useId }
        case ("PostToolUse", "Bash"):
            guard input?["run_in_background"]?.bool == true, let tid = p["tool_response"]?["backgroundTaskId"]?.string,
                  shells[tid] == nil else { break }
            let text = [input?["description"]?.string, input?["command"]?.string].compactMap { $0 }.first { !$0.isEmpty }
            shells[tid] = Shell(id: tid, label: Activity.clip(text ?? "shell", 60), owner: p["agent_id"]?.string, startedAt: now)
        case ("PostToolUse", "TaskStop"):
            // A killed subagent gets no SubagentStop (E2); `task_type` tells a subagent from a shell.
            guard let tid = input?["task_id"]?.string else { break }
            let type = p["tool_response"]?["task_type"]?.string
            if type != "local_agent" { endShell(tid, .stopped, now: now) }
            if type != "local_bash" { setSubagent(tid, .stopped, now: now) }
        default:
            break
        }
        if event == "PostToolUse" { tip = Tips.match(tool: tool, input: input) }
    }

    /// FIFO gave `agentId` the first open call; PostToolUse knows the exact call. Swap when they differ.
    mutating func relink(agentId: String, toolUseId: String?) {
        guard let toolUseId, var a = subagents[agentId], a.call?.toolUseId != toolUseId else { return }
        if var other = subagents.values.first(where: { $0.call?.toolUseId == toolUseId }) {
            (a.call, other.call) = (other.call, a.call)
            subagents[other.id] = other
        } else if let i = agentCalls.firstIndex(where: { $0.toolUseId == toolUseId }) {
            let old = a.call
            a.call = agentCalls.remove(at: i)
            if let old { agentCalls.insert(old, at: 0) }
        } else {
            return
        }
        subagents[agentId] = a
    }

    /// The newest `background_tasks` of any `Stop` or `SubagentStop` is the truth for shells (E1).
    /// Only a main `Stop` ends subagents, and never one that still owns a listed shell.
    /// A missing list (older Claude Code) proves nothing.
    mutating func applyBackgroundTasks(_ tasks: JSONValue?, main: Bool, now: Date) {
        guard let list = tasks?.array else { return }
        let ids = Set(list.compactMap { $0["id"]?.string })
        for id in shells.keys where !ids.contains(id) { endShell(id, .finished, now: now) }
        guard main else { return }
        for (id, a) in subagents where a.state.isActive && !ids.contains(id) && !ownsRunningShell(id) { setSubagent(id, .done, now: now) }
    }

    /// A subagent with a running shell is not finished, whatever its SubagentStop says (E1).
    func ownsRunningShell(_ agent: String) -> Bool { shells.values.contains { $0.owner == agent && $0.state == .running } }

    /// A `<task-notification>` prompt names a task that ended. `status` is its `<status>` token.
    mutating func applyTaskNotification(_ id: String, status: String?, now: Date) {
        let killed = status == "killed"
        endShell(id, killed ? .stopped : .finished, now: now)
        // "completed" also comes for a subagent that "is waiting on its own background work" (E1).
        guard !ownsRunningShell(id) else { return }
        setSubagent(id, killed ? .stopped : status == "failed" ? .failed : .done, now: now)
    }

    mutating func endActivity(now: Date) {
        for id in subagents.keys { setSubagent(id, .done, now: now) }
        for id in shells.keys { endShell(id, .finished, now: now) }
    }

    /// True when it dropped a row.
    @discardableResult
    mutating func pruneActivity(now: Date) -> Bool {
        let a = Activity.pruned(subagents, cap: Activity.maxSubagents, now: now, ended: \.endedAt, started: \.startedAt)
        let b = Activity.pruned(shells, cap: Activity.maxShells, now: now, ended: \.endedAt, started: \.startedAt)
        guard a.count != subagents.count || b.count != shells.count else { return false }
        subagents = a
        shells = b
        return true
    }
}

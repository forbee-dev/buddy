import Foundation

/// Order, filter, and "next waiting" for the command palette.
public enum PaletteOrder {
    /// Waiting first, then done (and failed), working, idle.
    static func rank(_ s: SessionState) -> Int {
        switch s {
        case .needsPermission, .asking: 0
        case .done, .error: 1
        case .working, .starting: 2
        case .idle: 3
        case .ended: 4
        }
    }

    /// Visible, not ended. Waiting rows: the longest wait first. Other rows: the newest change first.
    public static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.filter { !$0.hidden && $0.state != .ended }.sorted { a, b in
            let ra = rank(a.state), rb = rank(b.state)
            if ra != rb { return ra < rb }
            if ra == 0 {
                let ta = a.waitingSince ?? a.updated, tb = b.waitingSince ?? b.updated
                if ta != tb { return ta < tb }
            } else if a.updated != b.updated {
                return a.updated > b.updated
            }
            return a.id < b.id
        }
    }

    /// Every word of `query` must be in the project name or the state label (case-insensitive).
    public static func filter(_ sessions: [Session], query: String) -> [Session] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { s in
            let hay = "\(s.displayName) \(s.state.label)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// The first waiting row after `id` (wraps around), never `id` itself.
    public static func nextWaiting(after id: String?, in rows: [Session]) -> Session? {
        let start = rows.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
        let order = rows[min(start, rows.count)...] + rows[..<min(start, rows.count)]
        return order.first { $0.state.needsAttention && $0.id != id }
    }

    /// First line of the pending question, or the tool and the first line of its command or file path. Revealed, max 120 chars.
    public static func summary(_ s: Session) -> String? {
        guard let p = s.pending else { return nil }
        let who = p.agentId.map { "\(s.subagentLabel($0)) · " } ?? ""
        func first(_ t: String) -> String? { t.split(separator: "\n").first.map(String.init) }
        if p.kind == .question {
            let q = AskQuestion.parse(p.toolInput).first?.question.split(separator: "\n").first.map(String.init)
            return Activity.clip(who + (q ?? "Question"), 120)
        }
        let input = p.toolInput["command"]?.string ?? p.toolInput["file_path"]?.string ?? ""
        return Activity.clip(who + p.toolName + (first(input).map { ": \($0)" } ?? ""), 120)
    }
}

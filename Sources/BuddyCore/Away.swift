import Foundation

/// How impatient a buddy is that waits on the user.
public enum Impatience {
    /// 0 calm, 1 from `after` seconds, 2 from twice that. nil `after` turns it off.
    public static func level(waited: TimeInterval, after: TimeInterval?) -> Int {
        guard let after, after > 0, waited >= after else { return 0 }
        return waited >= 2 * after ? 2 : 1
    }

    public static func label(waited: TimeInterval) -> String { "waiting \(minutes(waited))m" }

    public static func minutes(_ t: TimeInterval) -> Int { max(0, Int(t)) / 60 }
}

/// One clickable line of the "while you were away" digest.
public struct DigestLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case waiting, finished, subagentsFailed, subagentsDone, shellsFinished }
    public var kind: Kind
    public var text: String
    /// The session to open: its card, or its Activity tab for the count lines.
    public var sessionId: String
    public var at: Date
}

public enum AwayDigest {
    /// What happened since `since`: session lines oldest first, then subagent and shell counts. Empty: nothing happened.
    public static func build(_ sessions: [Session], since: Date, now: Date) -> [DigestLine] {
        let shown = sessions.filter { !$0.hidden && $0.state != .ended }
        var lines: [DigestLine] = []
        for s in shown {
            if let w = s.waitingSince, w >= since {
                lines.append(DigestLine(kind: .waiting, text: "\(s.projectName) waiting \(mins(now.timeIntervalSince(w)))",
                                        sessionId: s.id, at: w))
            } else if s.state == .done, let f = s.finishedAt, f >= since {
                lines.append(DigestLine(kind: .finished, text: "\(s.projectName) finished \(ago(now.timeIntervalSince(f)))",
                                        sessionId: s.id, at: f))
            }
        }
        lines.sort { ($0.at, $0.sessionId) < ($1.at, $1.sessionId) }
        func count(_ kind: DigestLine.Kind, _ noun: String, _ verb: String, _ ended: [(sid: String, at: Date)]) {
            let hits = ended.filter { $0.at >= since }
            guard let last = hits.max(by: { $0.at < $1.at }) else { return }
            lines.append(DigestLine(kind: kind, text: "\(hits.count) \(noun)\(hits.count == 1 ? "" : "s") \(verb)", sessionId: last.sid, at: last.at))
        }
        let agents = shown.flatMap { s in s.subagents.values.map { (sid: s.id, a: $0) } }
        let shells = shown.flatMap { s in s.shells.values.map { (sid: s.id, sh: $0) } }
        count(.subagentsFailed, "subagent", "failed", agents.compactMap { e in e.a.state == .failed ? e.a.endedAt.map { (e.sid, $0) } : nil })
        count(.subagentsDone, "subagent", "finished", agents.compactMap { e in e.a.state == .done ? e.a.endedAt.map { (e.sid, $0) } : nil })
        count(.shellsFinished, "shell", "finished", shells.compactMap { e in e.sh.state == .finished ? e.sh.endedAt.map { (e.sid, $0) } : nil })
        return lines
    }

    /// The session the digest buddy belongs to: the longest wait, else the first line.
    public static func focus(_ lines: [DigestLine]) -> String? {
        (lines.first { $0.kind == .waiting } ?? lines.first)?.sessionId
    }

    static func mins(_ t: TimeInterval) -> String { "\(max(1, Impatience.minutes(t))) min" }
    static func ago(_ t: TimeInterval) -> String { t < 60 ? "just now" : "\(mins(t)) ago" }
}

import Foundation

/// One-question-at-a-time state for the question card. Step `count` is the review step (only when count > 1).
public struct QuestionFlow: Sendable, Equatable {
    public let questions: [AskQuestion]
    public private(set) var step = 0
    public var picks: [Int: Set<String>] = [:]
    public var others: [Int: String] = [:]
    /// Questions where the "Other…" row is selected.
    public var otherOn: Set<Int> = []
    /// Keyboard-focused row per question; `options.count` is the "Other…" row.
    public var cursor: [Int: Int] = [:]

    public init(_ questions: [AskQuestion] = []) { self.questions = questions }

    public var count: Int { questions.count }
    public var hasReview: Bool { count > 1 }
    public var isReview: Bool { hasReview && step == count }
    public var isLastQuestion: Bool { step == count - 1 }
    public var current: AskQuestion? { questions.indices.contains(step) ? questions[step] : nil }
    /// Rows on the current question: the options plus "Other…".
    public var rows: Int { (current?.options.count ?? 0) + 1 }
    /// The last step shows Submit: the review step, or the only question.
    public var showsSubmit: Bool { isReview || count == 1 }

    public mutating func go(to s: Int) { step = min(max(s, 0), hasReview ? count : max(count - 1, 0)) }
    public mutating func next() { go(to: step + 1) }
    public mutating func back() { go(to: step - 1) }

    /// Picks a row on the current question. Returns true when the card should auto-advance:
    /// single choice on a real option, and not on the last question.
    @discardableResult
    public mutating func pick(_ row: Int) -> Bool {
        guard let q = current, row >= 0, row <= q.options.count else { return false }
        cursor[step] = row
        if row == q.options.count {
            // Single choice: Other replaces the selection. Multi: Other adds to it.
            if q.multiSelect {
                if otherOn.contains(step) { otherOn.remove(step) } else { otherOn.insert(step) }
            } else {
                otherOn.insert(step)
                picks[step] = []
            }
            return false
        }
        let label = q.options[row].label
        if q.multiSelect {
            var set = picks[step] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            picks[step] = set
            return false
        }
        picks[step] = [label]
        otherOn.remove(step)
        return !isLastQuestion
    }

    public mutating func moveCursor(_ delta: Int) {
        let now = cursor[step] ?? -1
        cursor[step] = min(max(now + delta, 0), rows - 1)
    }

    public func isPicked(_ i: Int, _ label: String) -> Bool { picks[i]?.contains(label) ?? false }

    /// The answer string sent to Claude: the option label; multiSelect labels joined with ", " (docs/hooks-facts.md W2 H1).
    public func answer(_ i: Int) -> String {
        guard questions.indices.contains(i) else { return "" }
        let q = questions[i]
        let other = otherOn.contains(i) ? (others[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !q.multiSelect && otherOn.contains(i) { return other }
        let chosen = q.options.map(\.label).filter { isPicked(i, $0) }
        return HookOutput.answerText(selected: chosen, other: other)
    }

    public func answered(_ i: Int) -> Bool { !answer(i).isEmpty }

    /// Answers are keyed by question text, so duplicate texts cannot be answered safely.
    public var uniqueTexts: Bool { Set(questions.map(\.question)).count == count }
    public var complete: Bool { count > 0 && uniqueTexts && questions.indices.allSatisfy(answered) }
    /// Next is allowed once the current question has an answer.
    public var canAdvance: Bool { !showsSubmit && (isReview || answered(step)) }

    public var answers: [String: String] {
        Dictionary(questions.indices.map { (questions[$0].question, answer($0)) }, uniquingKeysWith: { a, _ in a })
    }

    public var progress: String { isReview ? "Review" : "\(min(step + 1, count)) of \(count)" }
}

/// Keys the question card handles itself. Command-key shortcuts never reach this.
public enum QuestionKey: Equatable, Sendable {
    case digit(Int), left, right, up, down, tab(shift: Bool), space, returnKey
}

public enum QuestionKeyAction: Equatable, Sendable {
    case pick(Int), back, next, cursor(Int), primary, ignore
}

public enum QuestionKeys {
    /// 1–9 → row index, or nil when the row does not exist.
    public static func row(forDigit d: Int, rows: Int) -> Int? { (1...9).contains(d) && d <= rows ? d - 1 : nil }

    /// While the Other field has focus only Return acts (it confirms the text); every other key types.
    public static func action(_ key: QuestionKey, flow: QuestionFlow, textFocused: Bool) -> QuestionKeyAction {
        if textFocused { return key == .returnKey ? .primary : .ignore }
        switch key {
        case .digit(let d):
            guard !flow.isReview, let r = row(forDigit: d, rows: flow.rows) else { return .ignore }
            return .pick(r)
        case .left, .tab(shift: true): return .back
        case .right, .tab(shift: false): return .next
        case .up: return flow.isReview ? .ignore : .cursor(-1)
        case .down: return flow.isReview ? .ignore : .cursor(1)
        case .space:
            guard !flow.isReview, let c = flow.cursor[flow.step] else { return .ignore }
            return .pick(c)
        case .returnKey: return .primary
        }
    }
}

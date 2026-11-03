import Foundation

public struct AskQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?
    }
    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public static func parse(_ toolInput: JSONValue) -> [AskQuestion] {
        (toolInput["questions"]?.array ?? []).compactMap { q in
            guard let text = q["question"]?.string else { return nil }
            let opts = (q["options"]?.array ?? []).compactMap { o -> Option? in
                guard let label = o["label"]?.string else { return nil }
                return Option(label: label, description: o["description"]?.string)
            }
            return AskQuestion(question: text, header: q["header"]?.string, options: opts,
                               multiSelect: q["multiSelect"]?.bool ?? false)
        }
    }
}

/// Builds PermissionRequest hook outputs. Shapes: docs/hooks-facts.md sections 2 and "W2 hand tests".
public enum HookOutput {
    private static func decision(_ d: [String: JSONValue]) -> JSONValue {
        .object(["hookSpecificOutput": .object(["hookEventName": .string("PermissionRequest"), "decision": .object(d)])])
    }

    public static func allow() -> JSONValue { decision(["behavior": .string("allow")]) }

    public static func allowAlways(_ suggestion: JSONValue) -> JSONValue {
        decision(["behavior": .string("allow"), "updatedPermissions": .array([suggestion])])
    }

    public static func deny(_ message: String) -> JSONValue {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return decision(["behavior": .string("deny"), "message": .string(text.isEmpty ? "The user denied this in Buddy." : text),
                         "interrupt": .bool(false)])
    }

    /// Answers AskUserQuestion: original `questions` copied back plus `answers` keyed by question text.
    public static func answer(toolInput: JSONValue, answers: [String: String]) -> JSONValue {
        var updated = toolInput.object ?? [:]
        updated["answers"] = .object(answers.mapValues { .string($0) })
        return decision(["behavior": .string("allow"), "updatedInput": .object(updated)])
    }

    /// multiSelect answers are one string joined with ", " (TESTED, W2 H1).
    public static func answerText(selected: [String], other: String) -> String {
        let extra = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return (selected + (extra.isEmpty ? [] : [extra])).joined(separator: ", ")
    }

    /// Human label for a permission_suggestions entry.
    public static func suggestionLabel(_ s: JSONValue) -> String {
        switch s["type"]?.string {
        case "addRules":
            let rules = (s["rules"]?.array ?? []).map { r in
                let tool = r["toolName"]?.string ?? "tool"
                return r["ruleContent"]?.string.map { "\(tool)(\($0))" } ?? tool
            }
            return "Always allow " + rules.joined(separator: ", ")
        case "addDirectories":
            let dirs = (s["directories"]?.array ?? []).compactMap(\.string)
            return "Always allow access to " + dirs.joined(separator: ", ")
        case "setMode":
            return "Switch to \(s["mode"]?.string ?? "?") mode"
        default:
            return "Always allow (\(s["type"]?.string ?? "rule"))"
        }
    }
}

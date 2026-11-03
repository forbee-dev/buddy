import Foundation

/// Decodes only the payload fields the app uses (review L6, PF1). PermissionRequest `tool_input` stays whole:
/// the user must see all of it, and AskUserQuestion answers copy it back. Other events keep a few short
/// `tool_input` keys, two `tool_response` ids, and the ids of `background_tasks`. The prompt never leaves the hook.
public enum HookPayload {
    static let limits: [String: Int] = ["last_assistant_message": 16_000, "error": 4_000, "agent_id": 100, "agent_type": 100]
    static let inputLimit = 200
    static let maxTasks = 50

    private struct Slim: Decodable {
        var fields: [String: JSONValue] = [:]

        enum Key: String, CodingKey, CaseIterable {
            case session_id, hook_event_name, cwd, permission_mode, source, reason, tool_name, tool_use_id,
                 notification_type, last_assistant_message, error, transcript_path, agent_id, agent_type
        }
        enum Big: String, CodingKey { case tool_input, permission_suggestions, tool_response, background_tasks, prompt }
        enum InputKey: String, CodingKey { case description, subagent_type, command, task_id, run_in_background }
        enum ResponseKey: String, CodingKey, CaseIterable { case agentId, backgroundTaskId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            for k in Key.allCases {
                guard let s = try? c.decodeIfPresent(String.self, forKey: k) else { continue }
                fields[k.rawValue] = .string(HookPayload.trim(s, HookPayload.limits[k.rawValue] ?? Int.max))
            }
            let big = try decoder.container(keyedBy: Big.self)
            if fields["hook_event_name"] == "PermissionRequest" {
                fields["tool_input"] = try big.decodeIfPresent(JSONValue.self, forKey: .tool_input)
                fields["permission_suggestions"] = try big.decodeIfPresent(JSONValue.self, forKey: .permission_suggestions)
                return
            }
            if let input = try? big.nestedContainer(keyedBy: InputKey.self, forKey: .tool_input) {
                var o = HookPayload.strings(input, [.description, .subagent_type, .command, .task_id])
                if let bg = try? input.decodeIfPresent(Bool.self, forKey: .run_in_background) {
                    o["run_in_background"] = .bool(bg)
                }
                if !o.isEmpty { fields["tool_input"] = .object(o) }
            }
            if let resp = try? big.nestedContainer(keyedBy: ResponseKey.self, forKey: .tool_response) {
                let o = HookPayload.strings(resp, ResponseKey.allCases)
                if !o.isEmpty { fields["tool_response"] = .object(o) }
            }
            if let tasks = try? big.decodeIfPresent([JSONValue].self, forKey: .background_tasks) {
                fields["background_tasks"] = .array(tasks.prefix(HookPayload.maxTasks).map { t in
                    .object(["id": t["id"], "type": t["type"], "status": t["status"]].compactMapValues {
                        $0?.string.map { .string(HookPayload.trim($0, 100)) }
                    })
                })
            }
            if fields["hook_event_name"] == "UserPromptSubmit", let prompt = try? big.decodeIfPresent(String.self, forKey: .prompt),
               let id = HookPayload.taskNotificationId(prompt) {
                fields["task_id"] = .string(id)
            }
        }
    }

    static func trim(_ s: String, _ limit: Int) -> String { s.count > limit ? String(s.prefix(limit)) + "…" : s }

    private static func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ keys: [K]) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        for k in keys {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { o[k.stringValue] = .string(trim(s, inputLimit)) }
        }
        return o
    }

    /// `<task-id>` of a synthetic `<task-notification>` prompt (a background task ended). Only an id-like value.
    static func taskNotificationId(_ prompt: String) -> String? {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>"),
              let a = prompt.range(of: "<task-id>"), let b = prompt.range(of: "</task-id>", range: a.upperBound..<prompt.endIndex) else { return nil }
        let id = String(prompt[a.upperBound..<b.lowerBound])
        let ok = !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        return ok ? id : nil
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        .object(try JSONDecoder().decode(Slim.self, from: data).fields)
    }
}

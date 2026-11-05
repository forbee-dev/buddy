import Foundation

/// Decodes only the payload fields the app uses. PermissionRequest `tool_input` stays whole:
/// the user must see all of it, and AskUserQuestion answers copy it back. Other events keep a few short
/// `tool_input` keys, two `tool_response` ids, and the ids of `background_tasks`. The prompt never leaves the hook.
public enum HookPayload {
    static let limits: [String: Int] = ["last_assistant_message": 16_000, "error": 4_000, "agent_id": 100, "agent_type": 100,
                                         "tool_name": 200, "session_title": 200, "error_details": 4_000, "trigger": 20]
    static let inputLimit = 200
    /// Kept `tool_input` keys that tell two calls of the same tool apart (`SessionStore.matches`).
    static let matchKeys = ["command", "file_path", "url"]
    static let maxTasks = 50

    private struct Slim: Decodable {
        var fields: [String: JSONValue] = [:]

        enum Key: String, CodingKey, CaseIterable {
            case session_id, hook_event_name, cwd, permission_mode, source, reason, tool_name, tool_use_id,
                 notification_type, last_assistant_message, error, error_details, transcript_path, agent_id, agent_type,
                 session_title, trigger
        }
        enum Big: String, CodingKey { case tool_input, permission_suggestions, tool_response, background_tasks, prompt }
        enum InputKey: String, CodingKey { case description, subagent_type, command, task_id, file_path, url, run_in_background }
        enum ResponseKey: String, CodingKey, CaseIterable { case agentId, backgroundTaskId, task_type }

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
                var o = HookPayload.strings(input, [.description, .subagent_type, .command, .task_id, .file_path, .url])
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
                if let status = HookPayload.tag("status", in: prompt, max: 20, extra: []) { fields["task_status"] = .string(status) }
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
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>") else { return nil }
        return tag("task-id", in: prompt, max: 64, extra: ["-", "_"])
    }

    /// The first `<name>…</name>` value, only when it is 1…`max` ASCII letters, digits, or `extra` characters.
    static func tag(_ name: String, in prompt: String, max: Int, extra: Set<Character>) -> String? {
        guard let a = prompt.range(of: "<\(name)>"),
              let b = prompt.range(of: "</\(name)>", range: a.upperBound..<prompt.endIndex) else { return nil }
        let v = String(prompt[a.upperBound..<b.lowerBound])
        let ok = !v.isEmpty && v.count <= max && v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
        return ok ? v : nil
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        .object(try JSONDecoder().decode(Slim.self, from: data).fields)
    }
}

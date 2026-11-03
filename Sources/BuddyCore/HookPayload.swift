import Foundation

/// Decodes only the payload fields the app uses (review L6, PF1). PermissionRequest `tool_input` stays whole:
/// the user must see all of it, and AskUserQuestion answers copy it back. Other events skip it unparsed.
public enum HookPayload {
    static let limits: [String: Int] = ["last_assistant_message": 16_000, "error": 4_000]

    private struct Slim: Decodable {
        var fields: [String: JSONValue] = [:]

        enum Key: String, CodingKey, CaseIterable {
            case session_id, hook_event_name, cwd, permission_mode, source, reason, tool_name, tool_use_id,
                 notification_type, last_assistant_message, error
        }
        enum Big: String, CodingKey { case tool_input, permission_suggestions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            for k in Key.allCases {
                guard let s = try? c.decodeIfPresent(String.self, forKey: k) else { continue }
                let limit = HookPayload.limits[k.rawValue] ?? Int.max
                fields[k.rawValue] = .string(s.count > limit ? String(s.prefix(limit)) + "…" : s)
            }
            guard fields["hook_event_name"] == "PermissionRequest" else { return }
            let big = try decoder.container(keyedBy: Big.self)
            fields["tool_input"] = try big.decodeIfPresent(JSONValue.self, forKey: .tool_input)
            fields["permission_suggestions"] = try big.decodeIfPresent(JSONValue.self, forKey: .permission_suggestions)
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        .object(try JSONDecoder().decode(Slim.self, from: data).fields)
    }
}

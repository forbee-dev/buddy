import Foundation
import Testing
@testable import BuddyCore

func hook(_ event: String, session: String = "s1", id: String = UUID().uuidString, pid: Int32? = 100,
          extra: [String: JSONValue] = [:]) -> HookMessage {
    var p: [String: JSONValue] = ["session_id": .string(session), "hook_event_name": .string(event), "cwd": .string("/tmp/proj")]
    p.merge(extra) { $1 }
    return HookMessage(id: id, wantsReply: event == "PermissionRequest", payload: .object(p),
                       env: HookEnv(claudePid: pid, shellPid: 99, tty: "ttys001", attended: "1"))
}

func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

/// Parses installer output as a JSON object.
func obj(_ d: Data?) throws -> [String: Any] {
    let data = try #require(d)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A hook message with a tool_use_id.
func toolHook(_ event: String, id: String = UUID().uuidString, tool: String = "Bash", useId: String) -> HookMessage {
    hook(event, id: id, extra: ["tool_name": .string(tool), "tool_use_id": .string(useId)])
}

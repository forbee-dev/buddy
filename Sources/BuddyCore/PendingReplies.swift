import Foundation

/// Hook connections that wait for Buddy's reply, by request id. `Token` names one connection; the app uses the
/// connection object. A reply goes only to the request a card showed, never to whatever is pending now.
public struct PendingReplies<Token: Hashable> {
    private var held: [String: (token: Token, sid: String)] = [:]
    public init() {}

    public func contains(_ requestId: String) -> Bool { held[requestId] != nil }

    /// A hook is held only when its session now shows exactly this request (a hidden session never holds one).
    public static func shouldHold(_ msg: HookMessage, in store: SessionStore) -> Bool {
        guard msg.wantsReply, let sid = msg.payload["session_id"]?.string else { return false }
        return store.sessions[sid]?.pending?.id == msg.id
    }

    /// False for a duplicate id: the first connection keeps it.
    @discardableResult
    public mutating func hold(_ requestId: String, sid: String, token: Token) -> Bool {
        guard held[requestId] == nil else { return false }
        held[requestId] = (token, sid)
        return true
    }

    /// Removes the connection that waits on `requestId`.
    public mutating func take(_ requestId: String) -> Token? { held.removeValue(forKey: requestId)?.token }

    /// Held ids from `StoreChange.staleRequests` or `reap`; each of these connections gets `output: null`.
    public mutating func takeStale(_ ids: [String]) -> [(id: String, token: Token)] {
        ids.compactMap { id in take(id).map { (id, $0) } }
    }

    /// The connection closed: its request ids with their sessions. Other connections keep theirs.
    public mutating func closed(_ token: Token) -> [(id: String, sid: String)] {
        let mine = held.filter { $0.value.token == token }
        for id in mine.keys { held[id] = nil }
        return mine.map { (id: $0.key, sid: $0.value.sid) }.sorted { $0.id < $1.id }
    }

    public enum Answer: Equatable {
        /// The session no longer shows `requestId`: send nothing.
        case stale
        /// The card was current, but its hook is gone.
        case notDelivered
        case send(Token)
    }

    /// A user's answer on the card that showed `requestId`. A stale id changes nothing.
    public mutating func answer(sid: String, requestId: String, store: inout SessionStore) -> Answer {
        guard store.sessions[sid]?.pending?.id == requestId, store.resolve(sid: sid, requestId: requestId) else { return .stale }
        guard held[requestId]?.sid == sid else { return .notDelivered }
        return take(requestId).map(Answer.send) ?? .notDelivered
    }
}

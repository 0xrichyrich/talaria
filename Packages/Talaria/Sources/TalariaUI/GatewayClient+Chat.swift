import Foundation
import TalariaKit

// Chat-surface RPCs the TalariaKit wrapper doesn't carry yet: message
// reactions and the two mid-turn steering verbs. Shapes verified against
// .research/ws-protocol.md §6.2 / §7.4 (tui_gateway/methods_session.py:1241,
// 3406, 3443) — nothing here guesses a payload.

/// Validate the application-level acknowledgement before exposing its status
/// to chat mutation fallback logic. Some gateway revisions put a plausible
/// status beside `ok: false`; returning that status would make the caller
/// treat a refusal as an accepted steer/redirect and release its fence.
enum SessionMutationReceipt {
    static func requireStatus(_ value: JSONValue, operation: String,
                              accepted: Set<String>) throws -> String {
        if value["ok"]?.boolValue == false {
            throw GatewayError(code: 409,
                               message: "Hermes refused " + operation.lowercased() + ".")
        }
        guard let status = value["status"]?.stringValue,
              accepted.contains(status) else {
            throw AckValidationError(
                operation: operation,
                detail: "Hermes did not return an authoritative "
                    + operation.lowercased() + " status.")
        }
        return status
    }
}

extension GatewayClient {

    /// `message.react` — one emoji per author per message, iOS Tapback
    /// semantics enforced server-side (re-sending the same emoji retracts it,
    /// `emoji: null` clears). A live bubble has no durable `row_id` until it
    /// round-trips a resume, so the gateway also accepts `newest_role` to name
    /// the newest row of a role; send exactly one of the two.
    /// Returns the durable row id the reaction landed on.
    @discardableResult
    public func reactToMessage(sessionID: String, rowID: Int? = nil,
                               newestRole: String? = nil, emoji: String?) async throws -> Int? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let rowID {
            params["row_id"] = .number(Double(rowID))
        } else if let newestRole {
            params["newest_role"] = .string(newestRole)
        }
        params["emoji"] = emoji.map(JSONValue.string) ?? .null
        let result = try await rpc("message.react", .object(params))
        return result["row_id"]?.intValue
    }

    /// `session.steer` — inject text into the running turn's next tool result
    /// without interrupting it. Returns `"queued"` or `"rejected"` (rejected
    /// when the turn is past the point where a steer can land).
    public func steerTurn(sessionID: String, text: String) async throws -> String {
        let result = try await rpc("session.steer", ["session_id": .string(sessionID),
                                                     "text": .string(text)])
        return try SessionMutationReceipt.requireStatus(
            result, operation: "session.steer", accepted: ["queued", "rejected"])
    }

    /// `session.redirect` — re-aim the active turn, preserving context.
    /// Returns `"redirected"`, `"queued"` or `"rejected"`.
    public func redirectTurn(sessionID: String, text: String) async throws -> String {
        let result = try await rpc("session.redirect", ["session_id": .string(sessionID),
                                                        "text": .string(text)])
        return try SessionMutationReceipt.requireStatus(
            result, operation: "session.redirect",
            accepted: ["redirected", "queued", "rejected"])
    }
}

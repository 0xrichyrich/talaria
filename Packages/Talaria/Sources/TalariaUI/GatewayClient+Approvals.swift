import Foundation
import TalariaKit

// The approval + blocking-bridge RPCs (ws-protocol.md §8). Everything in this
// file answers a *parked agent thread*: the gateway's `_block()`
// (server.py:3472) holds the tool on a threading.Event until the client
// responds or the bounded wait expires, so a missing wrapper is not a cosmetic
// gap — it stalls a real turn for minutes and then fails the tool.
//
// TalariaKit already wraps approval.respond / approval.pending /
// clarify.respond. Added here is what the card and the prompt overlay need on
// top: the raw approval payload (TalariaKit's ApprovalRequest drops
// `smart_denied`), the resolved count, delivery acknowledgement, the
// multi-select clarify encoding, and the sudo/secret bridges.

/// One approval as the gateway derived it, keeping the protocol fields the
/// shared `Approval` display model has no room for.
///
/// `choices` is server-derived (`_approval_request_payload`, server.py:1922):
/// `["once","deny"]` when smart-denied, `["once","session","deny"]` when the
/// pattern cannot be permanently allowed, otherwise the full four.
public struct ApprovalDetail: Sendable, Equatable, Identifiable {
    public var id: String { request.requestID }
    public var request: ApprovalRequest
    /// The command guard already refused this pattern once, so the gateway
    /// hands back a reduced set. Desktop says so on the card.
    public var smartDenied: Bool
    /// Choices in the gateway's own order, never empty.
    public var choices: [ApprovalChoice]
    /// True when this came from an `approval.pending` sweep rather than a live
    /// `approval.request` — the card must not claim it arrived "now".
    public var replayed: Bool

    public init(_ payload: JSONValue?, sessionID: String, replayed: Bool = false) {
        let request = ApprovalRequest(payload, sessionID: sessionID)
        // A payload with no `choices` array falls back to once/deny inside
        // ApprovalRequest — that default must not masquerade as smart-denied,
        // so only derive the flag when the gateway actually sent a set.
        let sentChoices = payload?["choices"]?.arrayValue?.isEmpty == false
        self.request = request
        self.smartDenied = payload?["smart_denied"]?.boolValue
            ?? (sentChoices && !request.choices.contains(ApprovalChoice.session.rawValue))
        self.replayed = replayed
        let parsed = request.choices.compactMap(ApprovalChoice.init(rawValue:))
        self.choices = parsed.isEmpty ? [.once, .deny] : parsed
    }

    /// Wrap an approval that arrived already-typed — `session.resume` replays
    /// the oldest pending one through `LiveSession.pendingApproval`.
    public init(request: ApprovalRequest, replayed: Bool) {
        self.request = request
        self.replayed = replayed
        let parsed = request.choices.compactMap(ApprovalChoice.init(rawValue:))
        self.choices = parsed.isEmpty ? [.once, .deny] : parsed
        self.smartDenied = !self.choices.contains(.session)
    }
}

extension GatewayClient {

    // MARK: - Approvals

    /// `approval.pending` — the session's whole unresolved FIFO, not just the
    /// oldest entry `session.resume` replays. This is the only way to recover
    /// approvals raised while the socket was down: the `approval.request`
    /// event fired into a dead transport and is never re-emitted.
    public func pendingApprovalDetails(sessionID: String) async throws -> [ApprovalDetail] {
        let result = try await rpc("approval.pending",
                                   ["session_id": .string(sessionID)], timeout: 30)
        return result["approvals"]?.arrayValue?
            .map { ApprovalDetail($0, sessionID: sessionID, replayed: true) } ?? []
    }

    /// `approval.received` — marks the entry delivered so the gateway knows a
    /// client has the card on screen (it drives re-notification decisions
    /// server-side). Best-effort: a gateway without the method just errors.
    @discardableResult
    public func acknowledgeApproval(sessionID: String, requestID: String) async throws -> Bool {
        let result = try await rpc("approval.received",
                                   ["session_id": .string(sessionID),
                                    "request_id": .string(requestID)], timeout: 30)
        return result["acknowledged"]?.boolValue ?? false
    }

    /// `approval.respond` returning the gateway's `resolved` count. TalariaKit's
    /// wrapper drops it, but the count is how the UI tells "the run is moving
    /// again" from "nothing was waiting" — the 300 s timeout already denied it,
    /// `session.interrupt` cleared it, or the desktop answered first.
    ///
    /// Omitting `requestID` resolves the oldest entry (FIFO), which is the path
    /// a notification action takes when it has no id to match.
    @discardableResult
    public func answerApproval(sessionID: String, choice: ApprovalChoice,
                               requestID: String? = nil) async throws -> Int {
        var params: [String: JSONValue] = ["session_id": .string(sessionID),
                                           "choice": .string(choice.rawValue)]
        if let requestID, !requestID.isEmpty { params["request_id"] = .string(requestID) }
        let result = try await rpc("approval.respond", .object(params), timeout: 30)
        return result["resolved"]?.intValue ?? 0
    }

    // MARK: - Blocking bridges (clarify / sudo / secret)

    /// `clarify.respond` for a multi-select question. The tool decodes the
    /// answer with `_parse_multi_select_response` (tools/clarify_tool.py:127),
    /// which tries a JSON array first and comma-splitting only as a fallback —
    /// so send the array and choice labels containing commas survive intact.
    public func respondToClarify(sessionID: String, requestID: String,
                                 selections: [String]) async throws {
        let encoded: String
        if let data = try? JSONEncoder().encode(selections),
           let json = String(data: data, encoding: .utf8) {
            encoded = json
        } else {
            encoded = selections.joined(separator: ", ")
        }
        try await respondToClarify(sessionID: sessionID, requestID: requestID, answer: encoded)
    }

    /// `sudo.respond` — `{request_id, password}`. No session_id: `_respond`
    /// (server.py:11712) keys the pending registry by request_id alone.
    /// An empty password is the refusal; the terminal tool then reports that
    /// no sudo is available instead of retrying.
    public func respondToSudo(requestID: String, password: String) async throws {
        try await rpc("sudo.respond", ["request_id": .string(requestID),
                                       "password": .string(password)], timeout: 30)
    }

    /// `secret.respond` — `{request_id, value}`. An empty value is the refusal
    /// and the skills tool returns `skipped:true` rather than storing anything.
    public func respondToSecret(requestID: String, value: String) async throws {
        try await rpc("secret.respond", ["request_id": .string(requestID),
                                         "value": .string(value)], timeout: 30)
    }
}

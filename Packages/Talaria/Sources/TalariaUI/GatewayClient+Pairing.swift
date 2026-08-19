import Foundation
import TalariaKit

// Messaging-platform pairing — who is allowed to DM your bots.
//
// Shapes verified against the upstream checkout, not guessed:
//   gateway/pairing.py           — PairingStore: list_pending 770,
//                                  approve_request 735, list_approved 524,
//                                  revoke 557, looks_like_request_id 724,
//                                  generate_code 609 (entry shape)
//   hermes_cli/pairing.py        — `hermes pairing list|approve|revoke`, the
//                                  CLI this screen exists to replace
//   hermes_cli/web_server.py     — GET /api/pairing 13437,
//                                  POST /api/pairing/approve 13446,
//                                  POST /api/pairing/revoke 13482
//   hermes_cli/web_models.py:445 — PairingApprove / PairingRevoke bodies
//
// THE RULE THIS FILE EXISTS TO ENFORCE: an approval grants on `request_id`,
// never on the pairing code. The 8-character code is DM'd to the person asking
// for access and is *their* proof that the channel is theirs; the store keeps
// only a salted hash of it and no endpoint ever returns it
// (pairing.py:609-664). An admin surface is already looking at the row, so it
// needs no secret — which is also why `approve_request` is deliberately exempt
// from the brute-force lockout that guards the code path (pairing.py:744-756).
// No pairing code is accepted, rendered, logged or stored anywhere in Talaria.
//
// This surface is REST, not JSON-RPC: pairing lives on the dashboard app the
// gateway mounts (`hermes_cli/web_server.py`), and the WS gateway carries only
// the `pairing.changed` broadcast (server.py:3841). A gateway that does not
// mount those routes answers 404, which reads as `.unsupported` and hides the
// surface rather than showing an error nobody can act on.

// MARK: - Wire models

/// A person waiting to be let in: they DM'd a bot, the bot replied with a
/// one-time code, and they are blocked until an admin approves this row.
public struct PairingRequest: Identifiable, Sendable, Equatable {
    /// Stable across refreshes; falls back to the user id for the legacy rows
    /// that have no approvable id.
    public var id: String { platform + "/" + (requestID.isEmpty ? userID : requestID) }
    public var platform: String
    /// `secrets.token_hex(8)` — 16 lowercase hex chars. Empty for pre-hash
    /// entries written by an older gateway: `list_pending` reports them with no
    /// id and they age out at the 1-hour TTL (pairing.py:770-802).
    public var requestID: String
    public var userID: String
    public var userName: String
    public var ageMinutes: Int

    /// A row with no `request_id` cannot be granted by any admin surface —
    /// only by the code its owner holds, which this app will not accept.
    public var isApprovable: Bool { !requestID.isEmpty }

    init(_ v: JSONValue) {
        platform = v["platform"]?.stringValue ?? ""
        requestID = v["request_id"]?.stringValue ?? ""
        userID = v["user_id"]?.stringValue ?? ""
        userName = v["user_name"]?.stringValue ?? ""
        ageMinutes = max(0, v["age_minutes"]?.intValue ?? 0)
    }

    init(platform: String, requestID: String, userID: String,
         userName: String, ageMinutes: Int) {
        self.platform = platform; self.requestID = requestID
        self.userID = userID; self.userName = userName; self.ageMinutes = ageMinutes
    }
}

/// Someone who currently holds access. `list_approved` merges every platform's
/// `approved.json`; `approved_at` is a unix timestamp written at grant time
/// (pairing.py:524-533, 560-568).
public struct PairedUser: Identifiable, Sendable, Equatable {
    public var id: String { platform + "/" + userID }
    public var platform: String
    public var userID: String
    public var userName: String
    public var approvedAt: Double?

    init(_ v: JSONValue) {
        platform = v["platform"]?.stringValue ?? ""
        userID = v["user_id"]?.stringValue ?? ""
        userName = v["user_name"]?.stringValue ?? ""
        approvedAt = v["approved_at"]?.doubleValue
    }

    init(platform: String, userID: String, userName: String, approvedAt: Double?) {
        self.platform = platform; self.userID = userID
        self.userName = userName; self.approvedAt = approvedAt
    }
}

/// One `GET /api/pairing` read: everyone waiting, and everyone already in.
public struct PairingSnapshot: Sendable, Equatable {
    public var pending: [PairingRequest]
    public var approved: [PairedUser]

    public static let empty = PairingSnapshot(pending: [], approved: [])

    public var isEmpty: Bool { pending.isEmpty && approved.isEmpty }

    /// Platforms present in either list, in display order.
    public var platforms: [String] {
        var seen: [String] = []
        for name in pending.map(\.platform) + approved.map(\.platform)
        where !name.isEmpty && !seen.contains(name) {
            seen.append(name)
        }
        return seen.sorted()
    }

    public init(pending: [PairingRequest], approved: [PairedUser]) {
        // Longest wait first: the person who has been blocked for 40 minutes
        // is the one the operator opened this screen for.
        self.pending = pending.sorted {
            $0.ageMinutes == $1.ageMinutes ? $0.id < $1.id : $0.ageMinutes > $1.ageMinutes
        }
        self.approved = approved.sorted {
            $0.platform == $1.platform
                ? $0.userID.localizedCaseInsensitiveCompare($1.userID) == .orderedAscending
                : $0.platform < $1.platform
        }
    }
}

/// What went wrong, in the terms the screen has copy for. Everything else is
/// `.failed` with the gateway's own message.
public enum PairingFailure: Error, Sendable, Equatable {
    /// No `/api/pairing` on this gateway — hide the surface entirely.
    case unsupported
    /// The row is gone: approved elsewhere, cleared, or aged out at the 1-hour
    /// TTL. The list is stale, not the app broken.
    case expired
    /// 429 — the platform is locked out after repeated failed *code* approvals
    /// (pairing.py:835-855). Request-id grants do not count toward it and are
    /// not gated by it, so this can only reach us through an intermediary, but
    /// it is a real answer and gets real copy.
    case lockedOut
    /// Revoke found no such user in the approved list.
    case notFound
    case failed(String)
}

extension GatewayClient {

    // MARK: - Pairing

    /// `GET /api/pairing` → `{pending: [...], approved: [...]}`.
    ///
    /// `profile` scopes which store is read (`_pairing_store`,
    /// web_server.py:13340). nil means the gateway's active profile — the same
    /// store `hermes pairing list` prints — which is the only scope a phone can
    /// name without inventing a profile picker for a store that is not
    /// per-bot in the first place.
    public func pairingSnapshot(profile: String? = nil) async throws -> PairingSnapshot {
        do {
            let result = try await restJSON(path: "api/pairing",
                                            query: Self.pairingQuery(profile), timeout: 20)
            return PairingSnapshot(
                pending: result["pending"]?.arrayValue?.map(PairingRequest.init) ?? [],
                approved: result["approved"]?.arrayValue?.map(PairedUser.init) ?? [])
        } catch {
            // On the *read*, a 404 means the routes are not mounted: this
            // gateway has no pairing surface at all. (On the write paths the
            // same status means "that row is gone" — see below.)
            throw Self.pairingFailure(error, missingMeans: .unsupported)
        }
    }

    /// `POST /api/pairing/approve {platform, request_id, profile}`.
    ///
    /// `requestID` is the row's server-side id from `pairingSnapshot`. There is
    /// deliberately no code parameter: `approve_code` exists upstream for the
    /// person who received the DM, not for an admin, and a client that can send
    /// a code is a client that can be phished into leaking one.
    @discardableResult
    public func approvePairingRequest(platform: String, requestID: String,
                                      profile: String? = nil) async throws -> PairedUser {
        let platform = platform.lowercased().trimmingCharacters(in: .whitespaces)
        let requestID = requestID.trimmingCharacters(in: .whitespaces)
        guard !platform.isEmpty, !requestID.isEmpty else { throw PairingFailure.expired }

        var body: [String: JSONValue] = ["platform": .string(platform),
                                         "request_id": .string(requestID)]
        // These endpoints read the profile off the BODY, not the query string
        // (hermes.ts:1477) — a query-only scope approves into the wrong store.
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        do {
            let result = try await restJSON(path: "api/pairing/approve", method: "POST",
                                            query: Self.pairingQuery(profile),
                                            body: .object(body), timeout: 20)
            let user = result["user"]
            return PairedUser(platform: platform,
                              userID: user?["user_id"]?.stringValue ?? "",
                              userName: user?["user_name"]?.stringValue ?? "",
                              approvedAt: Date().timeIntervalSince1970)
        } catch {
            throw Self.pairingFailure(error, missingMeans: .expired)
        }
    }

    /// `POST /api/pairing/revoke {platform, user_id, profile}`. Also removes the
    /// mirrored entry from the platform's own `*_ALLOWED_USERS` allowlist when
    /// the operator configured one (pairing.py:557-579, `_sync_allowlist_remove`).
    public func revokePairedUser(platform: String, userID: String,
                                 profile: String? = nil) async throws {
        let platform = platform.lowercased().trimmingCharacters(in: .whitespaces)
        guard !platform.isEmpty, !userID.isEmpty else { throw PairingFailure.notFound }

        var body: [String: JSONValue] = ["platform": .string(platform),
                                         "user_id": .string(userID)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        do {
            try await restJSON(path: "api/pairing/revoke", method: "POST",
                               query: Self.pairingQuery(profile),
                               body: .object(body), timeout: 20)
        } catch {
            throw Self.pairingFailure(error, missingMeans: .notFound)
        }
    }

    // MARK: Internals

    private static func pairingQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// HTTP status → the vocabulary the screen has copy for. `restData` throws
    /// `GatewayError` whose `code` IS the status, so 404 has to be interpreted
    /// per call site: on the read it means "no such surface", on a write it
    /// means "no such row".
    private static func pairingFailure(_ error: Error,
                                       missingMeans missing: PairingFailure) -> PairingFailure {
        if let failure = error as? PairingFailure { return failure }
        guard let error = error as? GatewayError else {
            return .failed((error as NSError).localizedDescription)
        }
        switch error.code {
        case 404, 405, 501: return missing
        case 429: return .lockedOut
        default: return .failed(error.message)
        }
    }
}

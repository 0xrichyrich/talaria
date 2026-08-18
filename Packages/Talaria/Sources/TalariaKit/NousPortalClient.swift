import Foundation
import Security

// Nous Portal as a direct model provider — the same OAuth device-code flow
// the CLI runs for `hermes auth add nous` (client_id "hermes-cli", scope
// "inference:invoke"), then the OpenAI-compatible inference API at
// https://inference-api.nousresearch.com/v1.
//
// Wire facts mirrored from hermes_cli/auth.py (see .research/auth-flows.md
// §5–6 for file:line refs):
// - Device authorization: POST {portal}/api/oauth/device/code (form-encoded
//   client_id + scope) → {device_code, user_code, verification_uri,
//   verification_uri_complete, expires_in, interval} — all fields required.
// - Polling: POST {portal}/api/oauth/token with
//   grant_type=urn:ietf:params:oauth:grant-type:device_code. Pending → non-200
//   {"error":"authorization_pending"}; the CLI caps its poll sleep at 1 s.
//   "slow_down" → interval += 1 (cap 30 s). Any other error code aborts.
// - Refresh: POST {portal}/api/oauth/token with the refresh token in the
//   x-nous-refresh-token HEADER (device-flow convention — keeps it out of
//   body access logs) and form grant_type=refresh_token&client_id=hermes-cli.
//   The RT rotates and is SINGLE-USE; the rotated RT must always be
//   persisted immediately. invalid_grant / invalid_token /
//   refresh_token_reused are terminal → drop tokens, re-run the device flow.
//   Refresh is triggered within 120 s of expiry (ACCESS_TOKEN_REFRESH_SKEW).
// - Server-provided inference_base_url is accepted only when https:// with
//   host in the hard allowlist {inference-api.nousresearch.com}; portal base
//   URLs only for {portal.nousresearch.com, localhost, 127.0.0.1} (§5.4).
// - Inference: GET {base}/models and POST {base}/chat/completions with
//   Authorization: Bearer <invoke JWT>; streaming via SSE `data:` lines.

// MARK: - Constants & allowlists

public enum NousPortal {
    public static let defaultPortalURL = URL(string: "https://portal.nousresearch.com")!
    public static let defaultInferenceBaseURL = URL(string: "https://inference-api.nousresearch.com/v1")!
    public static let clientID = "hermes-cli"
    public static let defaultScope = "inference:invoke"
    /// Refresh when the access token is within this many seconds of expiry
    /// (ACCESS_TOKEN_REFRESH_SKEW_SECONDS in hermes_cli/auth.py).
    public static let refreshSkew: TimeInterval = 120
    /// DEVICE_AUTH_POLL_INTERVAL_CAP_SECONDS — the CLI polls at most this
    /// often while waiting for the user to approve the device code.
    public static let pollIntervalCap: TimeInterval = 1
    /// slow_down growth is capped here, mirroring the CLI.
    public static let pollIntervalMax: TimeInterval = 30

    /// _ALLOWED_NOUS_INFERENCE_HOSTS (auth.py:2377-2426).
    static let allowedInferenceHosts: Set<String> = ["inference-api.nousresearch.com"]
    /// _NOUS_PORTAL_ALLOWED_HOSTS (auth.py:2347-2351).
    static let allowedPortalHosts: Set<String> = ["portal.nousresearch.com", "localhost", "127.0.0.1"]

    /// Validate a server-provided inference base URL against the hard host
    /// allowlist. Anything failing validation is discarded (the previous /
    /// default base URL stays in effect) — never trust a URL off the wire.
    public static func validatedInferenceBaseURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              url.scheme == "https",
              let host = url.host()?.lowercased(),
              allowedInferenceHosts.contains(host) else { return nil }
        return url
    }

    /// Validate a portal base URL before persisting it. Loopback hosts are
    /// allowed for self-host/dev setups, matching the CLI allowlist; plain
    /// http is accepted for loopback only — the real portal must be https.
    public static func validatedPortalURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let host = url.host()?.lowercased(),
              allowedPortalHosts.contains(host) else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && isLoopback) else { return nil }
        return url
    }
}

// MARK: - Device-code grant

/// Response of POST /api/oauth/device/code. All fields are required upstream.
public struct NousDeviceCode: Sendable, Equatable {
    public var deviceCode: String
    /// Short human code ("ABCD2345") shown as a fallback when the user must
    /// type it at `verificationURI` themselves.
    public var userCode: String
    public var verificationURI: URL
    /// Open this in the browser — it carries the code pre-filled.
    public var verificationURIComplete: URL
    /// Seconds until the device code dies and the flow must restart.
    public var expiresIn: TimeInterval
    /// Server-suggested poll interval in seconds.
    public var interval: TimeInterval

    init(_ v: JSONValue) throws {
        guard let device = v["device_code"]?.stringValue,
              let user = v["user_code"]?.stringValue,
              let uriRaw = v["verification_uri"]?.stringValue,
              let uri = URL(string: uriRaw),
              let completeRaw = v["verification_uri_complete"]?.stringValue,
              let complete = URL(string: completeRaw),
              let expires = v["expires_in"]?.doubleValue,
              let interval = v["interval"]?.doubleValue else {
            throw NousPortalError.protocolError("device/code response missing required fields")
        }
        deviceCode = device; userCode = user
        verificationURI = uri; verificationURIComplete = complete
        expiresIn = expires; self.interval = interval
    }
}

// MARK: - Token set

/// The persisted Portal credential — analogous to one provider entry in
/// ~/.hermes/auth.json, minus CLI-only fields. Stored in the Keychain keyed
/// by portal base URL; the access token doubles as the runtime inference key
/// (the "agent_key" — an RS256 JWT carrying scope inference:invoke).
public struct NousTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var tokenType: String
    public var scope: String
    /// Unix seconds.
    public var expiresAt: TimeInterval
    /// Unix seconds when the grant landed.
    public var obtainedAt: TimeInterval
    /// Allowlist-validated inference base URL (server-provided or default).
    public var inferenceBaseURL: URL

    public init(accessToken: String, refreshToken: String, tokenType: String,
                scope: String, expiresAt: TimeInterval, obtainedAt: TimeInterval,
                inferenceBaseURL: URL) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.tokenType = tokenType; self.scope = scope
        self.expiresAt = expiresAt; self.obtainedAt = obtainedAt
        self.inferenceBaseURL = inferenceBaseURL
    }

    /// True within the CLI's 120 s refresh skew of expiry.
    public var needsRefresh: Bool {
        Date().timeIntervalSince1970 >= expiresAt - NousPortal.refreshSkew
    }

    /// Space-delimited scope check (billing step-up parity helper).
    public func hasScope(_ scope: String) -> Bool {
        self.scope.split(separator: " ").contains(Substring(scope))
    }
}

// MARK: - Errors

public enum NousPortalError: Error, Sendable, Equatable {
    /// No stored tokens — run the device-code flow first.
    case notSignedIn
    /// The device code expired before the user approved it.
    case deviceCodeExpired
    /// Portal refused the device grant (user declined, code invalid, …).
    case authorizationFailed(code: String, description: String?)
    /// Terminal refresh failure (invalid_grant / invalid_token /
    /// refresh_token_reused) — tokens are dropped; re-run the device flow.
    /// Reuse detection revokes the whole session chain server-side.
    case sessionExpired
    /// Network / 5xx while talking to Portal — keep tokens, retry later.
    case portalUnreachable(String)
    /// Non-200 from the inference API.
    case http(status: Int, message: String)
    case protocolError(String)
}

// MARK: - Keychain persistence

/// Keychain store for Portal tokens, keyed by portal base URL. Separate
/// service from gateway credentials — a Portal identity is not tied to any
/// gateway connection. Rotated refresh tokens are single-use, so every
/// grant/refresh writes through here immediately.
public struct NousPortalTokenStore: Sendable {
    public var service: String

    public init(service: String = "bot.talaria.nous-portal") {
        self.service = service
    }

    public func save(_ tokens: NousTokens, portalURL: URL) throws {
        let data = try JSONEncoder().encode(tokens)
        let account = Self.account(for: portalURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func load(portalURL: URL) -> NousTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: portalURL),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NousTokens.self, from: data)
    }

    public func delete(portalURL: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: portalURL),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func account(for portalURL: URL) -> String {
        portalURL.absoluteString.lowercased()
    }
}

// MARK: - Client

/// Nous Portal client: device-code sign-in, rotating-refresh token
/// maintenance, and the InferenceProvider face over the OpenAI-compatible
/// inference API. One instance per portal; safe to share across the app.
public actor NousPortalClient: InferenceProvider {
    public let portalURL: URL
    private let urlSession: URLSession
    private let store: NousPortalTokenStore
    private var tokens: NousTokens?
    /// Dedupes concurrent refresh attempts — the RT is single-use, so two
    /// racing refreshes would trip Portal's reuse detection and kill the
    /// whole session chain.
    private var refreshTask: Task<NousTokens, Error>?
    /// Sticky routing key sent as top-level `session_id` so provider-side
    /// prompt caches stay warm across turns (auth-flows.md §6).
    private let stickySessionID = UUID().uuidString

    public init(portalURL: URL = NousPortal.defaultPortalURL,
                urlSession: URLSession = .shared,
                store: NousPortalTokenStore = NousPortalTokenStore()) {
        self.portalURL = portalURL
        self.urlSession = urlSession
        self.store = store
        self.tokens = store.load(portalURL: portalURL)
    }

    // MARK: State

    public var isSignedIn: Bool { tokens != nil }

    /// Current token set (nil when signed out). UI reads expiry/scope here.
    public var currentTokens: NousTokens? { tokens }

    /// The inference base URL in effect (allowlist-validated).
    public var inferenceBaseURL: URL {
        tokens?.inferenceBaseURL ?? NousPortal.defaultInferenceBaseURL
    }

    /// Drop tokens locally. Portal has no public revocation grant — logout
    /// is client-side and the RT dies at its TTL (auth.py revoke_session).
    public func signOut() {
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        store.delete(portalURL: portalURL)
    }

    // MARK: Device-code flow

    /// Step 1: request a device code. Show `userCode` and open
    /// `verificationURIComplete` in the browser, then call
    /// `waitForAuthorization(_:)`.
    public func requestDeviceCode(scope: String = NousPortal.defaultScope) async throws -> NousDeviceCode {
        var req = URLRequest(url: portalURL.appending(path: "api/oauth/device/code"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody([
            ("client_id", NousPortal.clientID),
            ("scope", scope),
        ])
        let (data, response) = try await send(req)
        guard response.statusCode == 200 else {
            throw NousPortalError.portalUnreachable("device/code returned \(response.statusCode)")
        }
        return try NousDeviceCode(try JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Step 2: poll POST /api/oauth/token with the device grant until the
    /// user approves in the browser. Handles authorization_pending (sleep
    /// min(interval, 1 s) — the CLI's poll cap) and slow_down (interval += 1,
    /// cap 30 s; slow_down sleeps the full grown interval since the server
    /// explicitly asked to back off). Persists tokens on success. Cancel the
    /// surrounding task to abort.
    @discardableResult
    public func waitForAuthorization(_ grant: NousDeviceCode) async throws -> NousTokens {
        var interval = max(grant.interval, 1)
        let deadline = Date().addingTimeInterval(grant.expiresIn)

        while Date() < deadline {
            try Task.checkCancellation()

            var req = URLRequest(url: portalURL.appending(path: "api/oauth/token"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formBody([
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", NousPortal.clientID),
                ("device_code", grant.deviceCode),
            ])
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await send(req)
            } catch {
                // Transient network blip while the user is off approving in
                // the browser (app backgrounded, cell↔Wi-Fi handoff) — keep
                // polling until the device code itself expires. Only real
                // cancellation aborts.
                if error is CancellationError { throw error }
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                try await Self.sleep(max(interval, NousPortal.pollIntervalCap))
                continue
            }
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)

            if response.statusCode == 200, let body {
                let fresh = try mergeGrant(body, previous: nil)
                adopt(fresh)
                return fresh
            }

            switch body?["error"]?.stringValue {
            case "authorization_pending":
                try await Self.sleep(min(interval, NousPortal.pollIntervalCap))
            case "slow_down":
                interval = min(interval + 1, NousPortal.pollIntervalMax)
                try await Self.sleep(interval)
            case let code?:
                throw NousPortalError.authorizationFailed(
                    code: code, description: body?["error_description"]?.stringValue)
            case nil:
                throw NousPortalError.portalUnreachable("token poll returned \(response.statusCode)")
            }
        }
        throw NousPortalError.deviceCodeExpired
    }

    // MARK: Refresh

    /// A valid access token, refreshing when inside the 120 s skew window.
    /// Concurrent callers share one refresh (single-use RT!).
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw NousPortalError.notSignedIn }
        if !forceRefresh && !current.needsRefresh { return current.accessToken }

        if let running = refreshTask {
            return try await running.value.accessToken
        }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func performRefresh(_ current: NousTokens) async throws -> NousTokens {
        var req = URLRequest(url: portalURL.appending(path: "api/oauth/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Header grant — the RT rides x-nous-refresh-token, NOT the form body
        // (device-flow convention; auth.py:5825-5880).
        req.setValue(current.refreshToken, forHTTPHeaderField: "x-nous-refresh-token")
        req.httpBody = Self.formBody([
            ("grant_type", "refresh_token"),
            ("client_id", NousPortal.clientID),
        ])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(req)
        } catch {
            // Network failure: keep tokens, caller retries later.
            throw NousPortalError.portalUnreachable(String(describing: error))
        }

        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        if response.statusCode == 200, let body {
            let fresh = try mergeGrant(body, previous: current)
            adopt(fresh)
            return fresh
        }

        switch body?["error"]?.stringValue {
        case "invalid_grant", "invalid_token", "refresh_token_reused":
            // Terminal — the chain is dead (reuse detection revokes it all).
            signOut()
            throw NousPortalError.sessionExpired
        default:
            if (400..<500).contains(response.statusCode) {
                signOut()
                throw NousPortalError.sessionExpired
            }
            throw NousPortalError.portalUnreachable("refresh returned \(response.statusCode)")
        }
    }

    /// Build the stored token set from a grant response, carrying forward
    /// previous values where the response omits optional fields, and
    /// allowlist-validating any server-provided inference_base_url.
    private func mergeGrant(_ v: JSONValue, previous: NousTokens?) throws -> NousTokens {
        guard let access = v["access_token"]?.stringValue else {
            throw NousPortalError.protocolError("token response missing access_token")
        }
        // The RT rotates on every refresh but is optional in the response
        // shape; absent ⇒ the previous RT stays valid.
        guard let refresh = v["refresh_token"]?.stringValue ?? previous?.refreshToken else {
            throw NousPortalError.protocolError("token response missing refresh_token")
        }
        let now = Date().timeIntervalSince1970
        let expiresIn = v["expires_in"]?.doubleValue ?? 3600
        let base = NousPortal.validatedInferenceBaseURL(v["inference_base_url"]?.stringValue)
            ?? previous?.inferenceBaseURL
            ?? NousPortal.defaultInferenceBaseURL
        return NousTokens(
            accessToken: access,
            refreshToken: refresh,
            tokenType: v["token_type"]?.stringValue ?? previous?.tokenType ?? "Bearer",
            scope: v["scope"]?.stringValue ?? previous?.scope ?? NousPortal.defaultScope,
            expiresAt: now + expiresIn,
            obtainedAt: now,
            inferenceBaseURL: base)
    }

    /// Adopt a fresh token set: memory first, then write-through to the
    /// Keychain immediately (the rotated RT is single-use — losing it means
    /// a forced re-login). A Keychain write failure must not fail inference,
    /// so it is swallowed; the in-memory copy stays authoritative for the
    /// process lifetime.
    private func adopt(_ fresh: NousTokens) {
        tokens = fresh
        try? store.save(fresh, portalURL: portalURL)
    }

    // MARK: Account (entitlements)

    /// GET {portal}/api/oauth/account — org/subscription/paid-access payload
    /// for billing and entitlement UI (auth-flows.md §6).
    public func account() async throws -> JSONValue {
        let token = try await validAccessToken()
        var req = URLRequest(url: portalURL.appending(path: "api/oauth/account"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(req)
        guard response.statusCode == 200 else {
            throw NousPortalError.http(status: response.statusCode,
                                       message: Self.errorMessage(from: data))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: InferenceProvider

    public nonisolated var providerID: String { "nous-portal" }

    /// GET {inference_base}/models → {"data":[{"id": …}]} — the full hosted
    /// list, unfiltered (the CLI's "hermes"-id filter is an agentic-use
    /// concern; direct chat may use any of them).
    public func models() async throws -> [String] {
        do {
            return try await fetchModels(token: validAccessToken())
        } catch NousPortalError.http(let status, _) where status == 401 {
            return try await fetchModels(token: validAccessToken(forceRefresh: true))
        }
    }

    private func fetchModels(token: String) async throws -> [String] {
        var req = URLRequest(url: inferenceBaseURL.appending(path: "models"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(req)
        guard response.statusCode == 200 else {
            throw NousPortalError.http(status: response.statusCode,
                                       message: Self.errorMessage(from: data))
        }
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let rows = v["data"]?.arrayValue else {
            throw NousPortalError.protocolError("models response missing data array")
        }
        return rows.compactMap { $0["id"]?.stringValue }.sorted()
    }

    /// POST {inference_base}/chat/completions with stream:true, parsing the
    /// SSE `data:` lines off URLSession.bytes. Retries once through a forced
    /// refresh on 401 (expired-but-unrefreshed JWT edge).
    @discardableResult
    public func chat(messages: [InferenceMessage], model: String,
                     stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        do {
            return try await runChat(messages: messages, model: model,
                                     token: validAccessToken(), handler: handler)
        } catch NousPortalError.http(let status, _) where status == 401 {
            return try await runChat(messages: messages, model: model,
                                     token: validAccessToken(forceRefresh: true), handler: handler)
        }
    }

    private func runChat(messages: [InferenceMessage], model: String, token: String,
                         handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        var req = URLRequest(url: inferenceBaseURL.appending(path: "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(model),
            "messages": .array(messages.map {
                .object(["role": .string($0.role.rawValue), "content": .string($0.content)])
            }),
            "stream": .bool(true),
            // Sticky routing key — keeps provider-side prompt caches warm
            // across turns (same top-level field hermes sends via extra_body).
            "session_id": .string(stickySessionID),
        ]))

        let (bytes, rawResponse) = try await urlSession.bytes(for: req)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw NousPortalError.protocolError("non-HTTP response")
        }
        guard response.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 65536 { break } }
            throw NousPortalError.http(status: response.statusCode,
                                       message: Self.errorMessage(from: body))
        }

        var assembled = ""
        var finishReason: String?
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else {
                continue
            }
            if let err = chunk["error"] {
                throw NousPortalError.http(status: response.statusCode,
                                           message: err["message"]?.stringValue ?? "stream error")
            }
            guard let choice = chunk["choices"]?.arrayValue?.first else { continue }
            if let delta = choice["delta"]?["content"]?.stringValue, !delta.isEmpty {
                assembled += delta
                handler(.delta(delta))
            }
            if let reasoning = choice["delta"]?["reasoning_content"]?.stringValue, !reasoning.isEmpty {
                handler(.reasoningDelta(reasoning))
            }
            if let reason = choice["finish_reason"]?.stringValue {
                finishReason = reason
            }
        }
        handler(.finished(reason: finishReason))
        return assembled
    }

    // MARK: Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NousPortalError.protocolError("non-HTTP response")
        }
        return (data, http)
    }

    /// application/x-www-form-urlencoded body; unreserved chars only, so
    /// scope colons etc. are percent-encoded exactly like the CLI sends them.
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    static func errorMessage(from data: Data) -> String {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return String(data: data.prefix(512), encoding: .utf8) ?? "unreadable error body"
        }
        return v["error"]?["message"]?.stringValue
            ?? v["error"]?.stringValue
            ?? v["detail"]?.stringValue
            ?? v["error_description"]?.stringValue
            ?? "request failed"
    }

    static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

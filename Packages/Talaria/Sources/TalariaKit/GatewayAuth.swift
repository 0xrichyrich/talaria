import Foundation
import CryptoKit

// Authentication against a hermes gateway, at parity with Hermes Desktop:
//
// 1. Loopback / trusted setups — static session token:
//    REST header `X-Hermes-Session-Token`, WS query `?token=`.
// 2. Gated mode (any non-loopback bind) — the native PKCE broker flow
//    (RFC 8252): the gateway is the authorization server to the app and an
//    OAuth client to Nous Portal (or a self-hosted OIDC IdP / the basic
//    username-password provider). The app opens the system browser at
//    /auth/native/authorize with a loopback redirect, then redeems the
//    one-time code at /auth/native/token.
// 3. WebSocket access in gated mode — single-use 30 s tickets minted at
//    POST /api/auth/ws-ticket immediately before every (re)connect.
//
// See .research/auth-flows.md for the full upstream map (file:line refs).

// MARK: - Status probe

public struct GatewayStatus: Sendable {
    public var version: String?
    public var authRequired: Bool
    public var authProviders: [String]
    public var authFlows: [String]
    public var gatewayRunning: Bool
    public var activeAgents: Int
    public var activeSessions: Int
    public var overall: String
    public var raw: JSONValue?

    public init(_ v: JSONValue?) {
        version = v?["version"]?.stringValue
        authRequired = v?["auth_required"]?.boolValue ?? false
        authProviders = v?["auth_providers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        authFlows = v?["auth_flows"]?.arrayValue?.compactMap(\.stringValue) ?? []
        gatewayRunning = v?["gateway_running"]?.boolValue ?? false
        activeAgents = v?["active_agents"]?.intValue ?? 0
        activeSessions = v?["active_sessions"]?.intValue ?? 0
        overall = v?["overall"]?.stringValue ?? "unknown"
        raw = v
    }

    public var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }
}

public struct AuthProviderInfo: Sendable {
    public var name: String
    public var displayName: String
    public var supportsPassword: Bool
}

// MARK: - Token set

/// Result of the native token exchange; stored in the Keychain keyed by the
/// normalized gateway base URL (desktop stores the same shape via safeStorage).
public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Unix seconds.
    public var expiresAt: TimeInterval
    public var provider: String
    public var userID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval,
                provider: String, userID: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.provider = provider; self.userID = userID
    }

    /// Desktop refreshes at expiresAt - 60 s.
    public var needsRefresh: Bool {
        Date().timeIntervalSince1970 >= expiresAt - 60
    }
}

/// Stored credential for one gateway connection.
public enum GatewayCredential: Codable, Sendable, Equatable {
    /// Loopback / pasted dashboard session token.
    case sessionToken(String)
    /// Native PKCE broker tokens (nous / self-hosted / basic providers).
    case oauth(TokenSet)
}

// MARK: - Base URL normalization

public enum GatewayURL {
    /// Normalize a user-pasted base URL like desktop's connection-config.ts:
    /// prefix scheme-less input with http://, strip trailing slash, keep any
    /// reverse-proxy path prefix.
    public static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host() != nil,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// ws(s):// URL for /api/ws with the given query item.
    public static func webSocket(base: URL, query: URLQueryItem) -> URL? {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.scheme = base.scheme == "https" ? "wss" : "ws"
        comps?.path += "/api/ws"
        comps?.queryItems = [query]
        return comps?.url
    }
}

// MARK: - Auth API client

public struct GatewayAuthClient: Sendable {
    public var baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func status() async throws -> GatewayStatus {
        let (data, _) = try await session.data(from: baseURL.appending(path: "api/status"))
        return GatewayStatus(try JSONDecoder().decode(JSONValue.self, from: data))
    }

    public func providers() async throws -> [AuthProviderInfo] {
        let (data, _) = try await session.data(from: baseURL.appending(path: "api/auth/providers"))
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        return v["providers"]?.arrayValue?.map {
            AuthProviderInfo(name: $0["name"]?.stringValue ?? "",
                             displayName: $0["display_name"]?.stringValue ?? "",
                             supportsPassword: $0["supports_password"]?.boolValue ?? false)
        } ?? []
    }

    /// Mint a single-use WS ticket (30 s TTL). Call immediately before every
    /// (re)connect; in gated mode legacy ?token= is rejected.
    public func mintWSTicket(credential: GatewayCredential) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "api/auth/ws-ticket"))
        req.httpMethod = "POST"
        apply(credential: credential, to: &req)
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.unauthorized(parse401(data))
        }
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let ticket = v["ticket"]?.stringValue else {
            throw AuthError.protocolError("ws-ticket response missing ticket")
        }
        return ticket
    }

    /// Refresh native tokens. 401 session_expired ⇒ drop tokens and re-login;
    /// 503 (provider unreachable) ⇒ keep tokens and retry later.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        var req = URLRequest(url: baseURL.appending(path: "auth/native/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "refresh_token": .string(tokens.refreshToken),
            "provider": .string(tokens.provider),
        ]))
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try Self.parseTokenResponse(data)
        case 401:
            throw AuthError.sessionExpired
        case 503:
            throw AuthError.providerUnreachable
        default:
            throw AuthError.protocolError("refresh failed with status \(code)")
        }
    }

    public func me(credential: GatewayCredential) async throws -> JSONValue {
        var req = URLRequest(url: baseURL.appending(path: "api/auth/me"))
        apply(credential: credential, to: &req)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Attach REST auth: bearer for oauth tokens, X-Hermes-Session-Token for
    /// loopback session tokens.
    public func apply(credential: GatewayCredential, to request: inout URLRequest) {
        switch credential {
        case .sessionToken(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .oauth(let tokens):
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    /// WS URL for the given credential (ticket must be freshly minted for oauth).
    public func webSocketURL(credential: GatewayCredential, ticket: String?) throws -> URL {
        let query: URLQueryItem
        switch credential {
        case .sessionToken(let token):
            query = URLQueryItem(name: "token", value: token)
        case .oauth:
            guard let ticket else { throw AuthError.protocolError("gated mode requires a ws ticket") }
            query = URLQueryItem(name: "ticket", value: ticket)
        }
        guard let url = GatewayURL.webSocket(base: baseURL, query: query) else {
            throw AuthError.protocolError("could not build ws url")
        }
        return url
    }

    static func parseTokenResponse(_ data: Data) throws -> TokenSet {
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let at = v["access_token"]?.stringValue,
              let rt = v["refresh_token"]?.stringValue else {
            throw AuthError.protocolError("token response missing fields")
        }
        return TokenSet(accessToken: at, refreshToken: rt,
                        expiresAt: v["expires_at"]?.doubleValue ?? 0,
                        provider: v["provider"]?.stringValue ?? "nous",
                        userID: v["user_id"]?.stringValue)
    }

    private func parse401(_ data: Data) -> String {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue ?? "unauthorized"
    }
}

public enum AuthError: Error, Sendable, Equatable {
    case unauthorized(String)
    /// Refresh token expired/invalid — drop tokens, start a new sign-in.
    case sessionExpired
    /// IdP unreachable — keep tokens, retry.
    case providerUnreachable
    case flowCancelled
    case stateMismatch
    case protocolError(String)
}

// MARK: - Native PKCE flow (RFC 8252)

/// The client half of the gateway's native broker flow. The app opens
/// `authorizeURL(...)` in the system browser (ASWebAuthenticationSession is
/// unsuitable — the redirect target is a loopback listener on the phone, so
/// use SFSafariViewController / openURL plus this listener).
public struct NativePKCEFlow: Sendable {
    public var codeVerifier: String
    public var codeChallenge: String
    public var state: String

    public init() {
        // Desktop: verifier = base64url(32 random bytes), state = base64url(24).
        codeVerifier = Self.base64url(Self.randomBytes(32))
        state = Self.base64url(Self.randomBytes(24))
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        codeChallenge = Self.base64url(Data(digest))
    }

    /// The system-browser URL. `redirectPort` is the app's loopback listener;
    /// the host must be literally 127.0.0.1 (localhost is rejected upstream).
    public func authorizeURL(base: URL, redirectPort: UInt16, provider: String? = nil) -> URL? {
        var comps = URLComponents(url: base.appending(path: "auth/native/authorize"),
                                  resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(redirectPort)/callback"),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider { items.append(URLQueryItem(name: "provider", value: provider)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// Redeem the one-time gateway code (120 s TTL, single-use). Verify the
    /// callback `state` equals ours BEFORE calling this.
    public func redeem(code: String, base: URL, session: URLSession = .shared) async throws -> TokenSet {
        var req = URLRequest(url: base.appending(path: "auth/native/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "code": .string(code),
            "code_verifier": .string(codeVerifier),
        ]))
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.protocolError("Invalid or expired authorization code.")
        }
        return try GatewayAuthClient.parseTokenResponse(data)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                base.storeBytes(of: UInt8.random(in: 0...255), toByteOffset: i, as: UInt8.self)
            }
        }
        return data
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

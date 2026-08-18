import Foundation

// High-level typed client for one gateway connection. Owns the transport,
// re-mints WS tickets on every (re)connect, refreshes OAuth tokens, and wraps
// the RPC surface Talaria uses. Method/param shapes follow
// .research/ws-protocol.md (verified against tui_gateway/*.py).

public struct HermesProfile: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var path: String?
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var description: String?
    public var skillCount: Int
    public var lastSession: ProfileSessionRef?
    public var uiMeta: JSONValue?
    public var hasAvatar: Bool

    public struct ProfileSessionRef: Sendable {
        public var id: String
        public var title: String?
        public var preview: String?
        public var startedAt: Double?
        public var lastActive: Double?
        public var messageCount: Int

        init?(_ v: JSONValue?) {
            guard let id = v?["id"]?.stringValue else { return nil }
            self.id = id
            title = v?["title"]?.stringValue
            preview = v?["preview"]?.stringValue
            startedAt = v?["started_at"]?.doubleValue
            lastActive = v?["last_active"]?.doubleValue
            messageCount = v?["message_count"]?.intValue ?? 0
        }
    }

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        path = v["path"]?.stringValue
        isDefault = v["is_default"]?.boolValue ?? false
        model = v["model"]?.stringValue
        provider = v["provider"]?.stringValue
        description = v["description"]?.stringValue
        skillCount = v["skill_count"]?.intValue ?? 0
        lastSession = ProfileSessionRef(v["last_session"])
        uiMeta = v["ui_meta"]
        hasAvatar = v["has_avatar"]?.boolValue ?? false
    }
}

public struct StoredSession: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var preview: String?
    public var startedAt: Double?
    public var messageCount: Int
    public var source: String?

    init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? ""
        title = v["title"]?.stringValue ?? ""
        preview = v["preview"]?.stringValue
        startedAt = v["started_at"]?.doubleValue
        messageCount = v["message_count"]?.intValue ?? 0
        source = v["source"]?.stringValue
    }
}

public struct LiveSession: Sendable {
    /// Runtime sid (8 hex chars) — use for all RPCs and event routing.
    public var sessionID: String
    /// Durable key — use for session.resume across reconnects.
    public var storedSessionID: String
    public var messages: [JSONValue]
    public var info: SessionInfo
    public var running: Bool
    /// Partial in-flight turn replayed after a reconnect.
    public var inflight: JSONValue?
    /// Oldest unresolved approval, replayed on resume.
    public var pendingApproval: ApprovalRequest?
    /// Clarify question still blocking this session, replayed on resume
    /// (server.py `_pending_clarify_request_payload`). Unlike approvals there
    /// is no `clarify.pending` RPC, so this block is the only way to recover a
    /// question raised while the transport was detached.
    public var pendingClarify: JSONValue?

    init(_ v: JSONValue) {
        sessionID = v["session_id"]?.stringValue ?? ""
        storedSessionID = v["stored_session_id"]?.stringValue
            ?? v["session_key"]?.stringValue
            ?? v["resumed"]?.stringValue ?? ""
        messages = v["messages"]?.arrayValue ?? []
        info = SessionInfo(v["info"])
        running = v["running"]?.boolValue ?? false
        inflight = v["inflight"]
        pendingApproval = v["pending_approval"].map { ApprovalRequest($0, sessionID: v["session_id"]?.stringValue ?? "") }
        pendingClarify = v["pending_clarify"]
    }
}

public struct CronJob: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var schedule: String
    public var enabled: Bool
    public var nextRun: Double?
    public var lastRun: Double?
    public var raw: JSONValue

    init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? v["name"]?.stringValue ?? UUID().uuidString
        name = v["name"]?.stringValue ?? ""
        schedule = v["schedule"]?.stringValue ?? v["cron"]?.stringValue ?? ""
        enabled = v["enabled"]?.boolValue ?? true
        nextRun = v["next_run"]?.doubleValue
        lastRun = v["last_run"]?.doubleValue
        raw = v
    }
}

/// One gateway connection: transport lifecycle + typed RPCs.
public actor GatewayClient {
    public let baseURL: URL
    private let auth: GatewayAuthClient
    private var credential: GatewayCredential
    private var transport: GatewayTransport?
    private let keychain: KeychainStore

    /// Re-published stream of all events from the current transport.
    public private(set) var eventsTask: Task<Void, Never>?
    private var eventHandlers: [UUID: @Sendable (GatewayEvent) -> Void] = [:]

    public init(baseURL: URL, credential: GatewayCredential,
                keychain: KeychainStore = KeychainStore()) {
        self.baseURL = baseURL
        self.auth = GatewayAuthClient(baseURL: baseURL)
        self.credential = credential
        self.keychain = keychain
    }

    // MARK: - Event fan-out

    public func addEventHandler(_ handler: @escaping @Sendable (GatewayEvent) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    public func removeEventHandler(_ id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }

    // MARK: - Connection lifecycle

    public var isConnected: Bool {
        get async {
            guard let transport else { return false }
            return await transport.state == .ready
        }
    }

    /// Connect (or reconnect). Refreshes OAuth tokens when near expiry and
    /// mints a fresh single-use WS ticket per attempt.
    public func connect() async throws {
        if case .oauth(let tokens) = credential, tokens.needsRefresh {
            do {
                let refreshed = try await auth.refresh(tokens)
                credential = .oauth(refreshed)
                try? keychain.save(credential, for: baseURL)
            } catch AuthError.sessionExpired {
                keychain.delete(for: baseURL)
                throw AuthError.sessionExpired
            } catch AuthError.providerUnreachable {
                // Keep tokens; the access token may still be valid.
            }
        }

        let ticket: String?
        if case .oauth = credential {
            ticket = try await auth.mintWSTicket(credential: credential)
        } else {
            ticket = nil
        }

        let url = try auth.webSocketURL(credential: credential, ticket: ticket)
        let transport = GatewayTransport(url: url)
        self.transport = transport
        try await transport.connect()

        eventsTask?.cancel()
        eventsTask = Task {
            for await event in transport.events {
                for handler in self.handlerSnapshot() {
                    handler(event)
                }
            }
        }
    }

    private func handlerSnapshot() -> [@Sendable (GatewayEvent) -> Void] {
        Array(eventHandlers.values)
    }

    public func disconnect() async {
        await transport?.close()
        transport = nil
        eventsTask?.cancel()
    }

    @discardableResult
    public func rpc(_ method: String, _ params: JSONValue? = nil,
                    timeout: TimeInterval = 120) async throws -> JSONValue {
        guard let transport else { throw GatewayError(code: -3, message: "not connected") }
        return try await transport.request(method, params: params, timeout: timeout)
    }

    // MARK: - Status

    public func status() async throws -> GatewayStatus {
        try await auth.status()
    }

    // MARK: - Profiles (the bot roster)

    public func listProfiles(includeSessions: Bool = true) async throws -> [HermesProfile] {
        let result = try await rpc("profiles.list", ["include_sessions": .bool(includeSessions)])
        return result["profiles"]?.arrayValue?.map(HermesProfile.init) ?? []
    }

    public func describeProfile(_ name: String) async throws -> JSONValue {
        try await rpc("profiles.describe", ["name": .string(name)])
    }

    /// Create a profile. `soul` becomes SOUL.md; `cloneFrom` = desktop
    /// Duplicate semantics.
    public func createProfile(name: String, description: String? = nil,
                              soul: String? = nil, cloneFrom: String? = nil,
                              model: String? = nil, provider: String? = nil) async throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let cloneFrom { params["clone_from"] = .string(cloneFrom); params["clone_all"] = .bool(true) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        try await rpc("profiles.create", .object(params))
    }

    public func configureProfile(name: String, description: String? = nil,
                                 soul: String? = nil, model: String? = nil,
                                 provider: String? = nil, disabledSkills: [String]? = nil,
                                 uiMeta: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        if let disabledSkills { params["disabled_skills"] = .array(disabledSkills.map(JSONValue.string)) }
        if let uiMeta { params["ui_meta"] = uiMeta }
        try await rpc("profiles.configure", .object(params))
    }

    /// Custom avatar portrait (PNG/JPEG/WebP ≤ 2 MB), e.g. from image.generate.
    public func setProfileAvatar(name: String, dataURL: String) async throws {
        try await rpc("profiles.set_asset", ["name": .string(name), "asset": "avatar",
                                             "data": .string(dataURL)])
    }

    public func profileAvatar(name: String) async throws -> String? {
        let result = try await rpc("profiles.get_asset", ["name": .string(name), "asset": "avatar"])
        guard result["found"]?.boolValue == true else { return nil }
        return result["data"]?.stringValue
    }

    // MARK: - Sessions

    /// `includeHidden` is for the surfaces that OWN hidden sessions — the
    /// per-bot browser and the canonical-chat resolver. The flag stays off for
    /// every shared/global list, which is what `hidden` means upstream
    /// (methods_session.py:180-186). An older gateway ignores the unknown
    /// param and simply keeps hidden rows out.
    public func listSessions(limit: Int = 200, profile: String? = nil,
                             includeHidden: Bool = false) async throws -> [StoredSession] {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let profile { params["profile"] = .string(profile) }
        if includeHidden { params["include_hidden"] = .bool(true) }
        let result = try await rpc("session.list", .object(params))
        return result["sessions"]?.arrayValue?.map(StoredSession.init) ?? []
    }

    /// `hidden` marks a session plugin-owned: it stays out of shared lists
    /// (recents, the resume picker) and is browsed only by the surface that
    /// owns it. Bot Mode's canonical chats are always born this way
    /// (plugin.js:2758-2763). Applied as `pending_hidden` until the row exists
    /// (methods_session.py:100, server.py:3014-3021); older gateways ignore it.
    public func createSession(profile: String? = nil, title: String? = nil,
                              model: String? = nil, hidden: Bool = false) async throws -> LiveSession {
        var params: [String: JSONValue] = ["source": "talaria", "cols": 100]
        if let profile { params["profile"] = .string(profile) }
        if let title { params["title"] = .string(title) }
        if let model { params["model"] = .string(model) }
        if hidden { params["hidden"] = .bool(true) }
        return LiveSession(try await rpc("session.create", .object(params)))
    }

    /// Resume a stored session by durable key. Within ~20 s of a disconnect
    /// this reattaches the live in-memory session with in-flight state.
    public func resumeSession(_ storedID: String, profile: String? = nil,
                              deferHistory: Bool = false) async throws -> LiveSession {
        var params: [String: JSONValue] = ["session_id": .string(storedID), "source": "talaria"]
        if let profile { params["profile"] = .string(profile) }
        if deferHistory { params["defer_history"] = .bool(true) }
        return LiveSession(try await rpc("session.resume", .object(params), timeout: 180))
    }

    public func closeSession(_ sessionID: String) async throws {
        try await rpc("session.close", ["session_id": .string(sessionID)])
    }

    public func interruptSession(_ sessionID: String) async throws {
        try await rpc("session.interrupt", ["session_id": .string(sessionID)])
    }

    public func sessionUsage(_ sessionID: String) async throws -> Usage {
        Usage(try await rpc("session.usage", ["session_id": .string(sessionID)]))
    }

    public func contextBreakdown(_ sessionID: String) async throws -> [ContextSegment] {
        let result = try await rpc("session.context_breakdown", ["session_id": .string(sessionID)])
        let max = result["context_max"]?.doubleValue ?? 0
        return result["categories"]?.arrayValue?.compactMap { cat -> ContextSegment? in
            guard let label = cat["label"]?.stringValue ?? cat["name"]?.stringValue else { return nil }
            let tokens = cat["tokens"]?.doubleValue ?? cat["value"]?.doubleValue ?? 0
            let pct = max > 0 ? Int((tokens / max * 100).rounded()) : 0
            return ContextSegment(label: label, percent: pct)
        } ?? []
    }

    // MARK: - Prompting

    /// Submit a prompt; returns once accepted ({"status":"streaming"}).
    /// Tokens/tool events then stream to event handlers.
    public func submitPrompt(sessionID: String, text: String, queued: Bool = false) async throws {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), "text": .string(text)]
        if queued { params["queued"] = .bool(true) }
        try await rpc("prompt.submit", .object(params), timeout: 1800)
    }

    public func steer(sessionID: String, text: String) async throws {
        try await rpc("session.steer", ["session_id": .string(sessionID), "text": .string(text)])
    }

    // MARK: - Approvals

    /// Answer a blocking approval. The parked run resumes on resolve.
    public func respondToApproval(sessionID: String, choice: ApprovalChoice,
                                  requestID: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(sessionID),
                                           "choice": .string(choice.rawValue)]
        if let requestID { params["request_id"] = .string(requestID) }
        try await rpc("approval.respond", .object(params))
    }

    public func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        let result = try await rpc("approval.pending", ["session_id": .string(sessionID)])
        return result["approvals"]?.arrayValue?.map { ApprovalRequest($0, sessionID: sessionID) } ?? []
    }

    public func respondToClarify(sessionID: String, requestID: String, answer: String) async throws {
        try await rpc("clarify.respond", ["session_id": .string(sessionID),
                                          "request_id": .string(requestID),
                                          "answer": .string(answer)])
    }

    // MARK: - YOLO (per-session approval bypass, desktop status-bar parity)

    public func setYolo(sessionID: String, enabled: Bool) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID), "key": "yolo",
                                     "value": .string(enabled ? "on" : "off"),
                                     "scope": "session"])
    }

    // MARK: - Models

    public func modelOptions(sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await rpc("model.options", .object(params))
    }

    public func setSessionModel(sessionID: String, model: String) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "model", "value": .string(model)])
    }

    /// Reasoning effort for the session ("none" | "low" | "medium" | "high" —
    /// the gateway validates; desktop's status-bar reasoning control parity).
    public func setReasoningEffort(sessionID: String, value: String) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "reasoning", "value": .string(value)])
    }

    // MARK: - Push relay (talaria-push gateway plugin)

    /// Register this device with the gateway-side APNs relay. No-op errors
    /// surface to the caller (the plugin may simply not be installed).
    public func registerPushDevice(tokenHex: String, environment: String) async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/plugins/talaria-push/devices"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        auth.apply(credential: credential, to: &req)
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "device_token": .string(tokenHex),
            "platform": "ios",
            "environment": .string(environment),
        ]))
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw GatewayError(code: -9, message: "push relay registration failed")
        }
    }

    // MARK: - Cron (Routines)

    /// Jobs are namespaced "[bot:<name>] <routine>" by convention; runs land
    /// in the bot's own chat.
    public func cronManage(_ params: JSONValue) async throws -> JSONValue {
        try await rpc("cron.manage", params)
    }

    public func cronList() async throws -> [CronJob] {
        let result = try await rpc("cron.manage", ["action": "list"])
        let rows = result["jobs"]?.arrayValue ?? result["entries"]?.arrayValue ?? []
        return rows.map(CronJob.init)
    }

    // MARK: - Image generation (avatar portraits; works over remote gateways)

    public func generateImage(prompt: String, aspectRatio: String = "square") async throws -> String? {
        let result = try await rpc("image.generate",
                                   ["prompt": .string(prompt), "aspect_ratio": .string(aspectRatio)],
                                   timeout: 300)
        return result["image_data"]?.stringValue ?? result["image"]?.stringValue
    }

    // MARK: - Voice

    public func voiceStatus() async throws -> JSONValue {
        try await rpc("voice.toggle", ["action": "status"])
    }

    public func voiceSet(on: Bool) async throws {
        try await rpc("voice.toggle", ["action": .string(on ? "on" : "off")])
    }

    // MARK: - REST helpers

    // MARK: - Authenticated REST

    /// Perform an authenticated REST call against this gateway and return the
    /// raw body. The public seam cross-module extensions need: `auth` and
    /// `credential` are file-private, so TalariaUI extensions cannot build
    /// their own authorized requests.
    ///
    /// `path` is relative to the gateway root ("api/sessions/search"), and any
    /// reverse-proxy path prefix in `baseURL` is preserved.
    @discardableResult
    public func restData(path: String, method: String = "GET",
                         query: [URLQueryItem] = [], body: Data? = nil,
                         contentType: String = "application/json",
                         timeout: TimeInterval = 30) async throws -> Data {
        var comps = URLComponents(url: baseURL.appending(path: path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else {
            throw GatewayError(code: -11, message: "bad REST path: \(path)")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        auth.apply(credential: credential, to: &req)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?.stringValue
            throw GatewayError(code: code, message: detail ?? "HTTP \(code) for \(path)")
        }
        return data
    }

    /// `restData` decoded as JSON.
    @discardableResult
    public func restJSON(path: String, method: String = "GET",
                         query: [URLQueryItem] = [], body: JSONValue? = nil,
                         timeout: TimeInterval = 30) async throws -> JSONValue {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let data = try await restData(path: path, method: method, query: query,
                                      body: payload, timeout: timeout)
        guard !data.isEmpty else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // Transcript hydration lives in `latestSessionMessages`
    // (TalariaUI/AppModelLive+CanonicalChat.swift). The wrapper that used to
    // sit here sent only limit+offset, and the endpoint pages from the OLDEST
    // message whenever a `limit` arrives without `order`
    // (hermes_cli/web_routers/sessions.py:601-640) — so it opened a long chat
    // at its beginning — while omitting `profile` made it read the DEFAULT
    // profile's state.db and 404 for every other bot.
}

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
    /// The row summary a roster paints. Identity and stamps stay
    /// `last_session`'s — liveness, ranking and the row timestamp are
    /// last_session semantics by design (plugin.js:3852-3858: *any* recent
    /// activity, from any client, means the bot is alive) — while the preview
    /// text comes from the resolved canonical-chat pin when the gateway
    /// answered one. See `foldingCanonicalPreview()`; `rawLastSession` keeps
    /// the untouched wire value.
    public var lastSession: ProfileSessionRef?
    /// `last_session` exactly as the gateway sent it, before any preview fold.
    public var rawLastSession: ProfileSessionRef?
    /// `preferred_session` — the gateway's precise answer about the ONE
    /// session this client asked about (its canonical-chat pin), as opposed to
    /// `last_session`'s "whatever is newest".
    public var preferredSession: PreferredSession
    public var uiMeta: JSONValue?
    public var hasAvatar: Bool

    public struct ProfileSessionRef: Sendable {
        public var id: String
        /// `resolved_id` — the live compression tip for `id`, equal to `id`
        /// when the lineage was never compressed. Only `preferred_session`
        /// carries it (methods_profiles.py:104-112); `last_session` leaves it
        /// nil. `id` stays the caller's durable pin, which is why a compaction
        /// on the laptop does not orphan a phone's pin.
        public var resolvedID: String?
        public var title: String?
        public var preview: String?
        public var startedAt: Double?
        public var lastActive: Double?
        public var messageCount: Int

        init?(_ v: JSONValue?) {
            guard let id = v?["id"]?.stringValue else { return nil }
            self.id = id
            resolvedID = v?["resolved_id"]?.stringValue
            title = v?["title"]?.stringValue
            preview = v?["preview"]?.stringValue
            startedAt = v?["started_at"]?.doubleValue
            lastActive = v?["last_active"]?.doubleValue
            messageCount = v?["message_count"]?.intValue ?? 0
        }
    }

    /// The three answers `profiles.list` can give about a pin, and the reason
    /// the difference is load-bearing rather than pedantic
    /// (methods_profiles.py:63-130, plugin.js:2857-2880):
    ///
    /// - **absent** — this client sent no pin for the profile, *or* the
    ///   gateway predates `preferred_session_ids` and ignored the parameter.
    ///   Verified against a live 0.20.3 gateway on 2026-08-18: the row keys
    ///   come back `name, path, is_default, model, provider, description,
    ///   skill_count, last_session, ui_meta, has_avatar` — no
    ///   `preferred_session` at all. The pin is innocent.
    /// - **null** — a gateway that *does* speak the contract saying the row is
    ///   definitively gone (missing, archived, or a denied internal source).
    ///   Modelled, but deliberately not wired to canonical-chat recovery:
    ///   `attachCanonicalSession` re-anchors off `session.resume`'s 4007
    ///   instead, which is definitive for the exact operation the tap is about
    ///   to perform and costs no extra round trip. Kept distinct from *absent*
    ///   so the distinction survives in the model — collapsing the two is what
    ///   would let an old gateway's silence read as "the pin is dead".
    /// - **a summary** — the pin resolved, hidden sessions included and
    ///   compression lineages followed to their live tip.
    public enum PreferredSession: Sendable {
        case notRequested
        case gone
        case resolved(ProfileSessionRef)

        public var session: ProfileSessionRef? {
            if case .resolved(let session) = self { return session }
            return nil
        }

        /// True only when a gateway that speaks the contract said so. An older
        /// gateway can never produce this, which is what keeps a pin alive
        /// across a downgrade.
        public var isDefinitivelyGone: Bool {
            if case .gone = self { return true }
            return false
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
        rawLastSession = lastSession
        switch v["preferred_session"] {
        case .none: preferredSession = .notRequested
        case .some(.null): preferredSession = .gone
        case .some(let node): preferredSession = ProfileSessionRef(node).map(
            PreferredSession.resolved) ?? .gone
        }
        uiMeta = v["ui_meta"]
        hasAvatar = v["has_avatar"]?.boolValue ?? false
    }

    /// Desktop's `previewSession = bot.preferred_session || last`
    /// (plugin.js:3867), applied at the one door every roster caller comes
    /// through so the preview and the tap describe the same conversation
    /// (hermes-agent#88200).
    ///
    /// Only the *text* moves. The row keeps `last_session`'s id, stamps and
    /// message count because that is what the 90 s liveness window, the
    /// recency ranking and the relative timestamp are built on — a bot that
    /// just spoke in a scratch session is still awake. The one exception is a
    /// profile with no `last_session` at all (a locked state.db, or a bot
    /// whose only conversation is its hidden forever chat, which
    /// `_latest_profile_session_row` cannot see): there the pin is the only
    /// conversation the row knows about, and previewing it beats an empty row.
    func foldingCanonicalPreview() -> HermesProfile {
        guard let pinned = preferredSession.session else { return self }
        var folded = self
        guard var row = lastSession else {
            folded.lastSession = pinned
            return folded
        }
        if let preview = pinned.preview, !preview.isEmpty { row.preview = preview }
        if let title = pinned.title, !title.isEmpty { row.title = title }
        folded.lastSession = row
        return folded
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
        // `_format_job` (cronjob_tools.py:620) emits `job_id`, never `id`, and
        // every mutation addresses a job by it. Falling through to `name` — as
        // this did — meant enable/disable/delete targeted a title, so a
        // renamed or duplicate-titled job hit the wrong row or nothing at all.
        // Verified against a live gateway 2026-08-18: rows carry job_id.
        id = v["job_id"]?.stringValue ?? v["id"]?.stringValue ?? v["name"]?.stringValue ?? UUID().uuidString
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
    public struct TrafficLease: Sendable {
        private let releaseOperation: @Sendable () async -> Void

        public init(release: @escaping @Sendable () async -> Void) {
            releaseOperation = release
        }

        public func release() async { await releaseOperation() }
    }

    public typealias TrafficAdmission = @Sendable () async -> TrafficLease?

    /// Local fail-closed rejection before any WebSocket or HTTP request can
    /// reach a gateway whose profile namespace is being mutated.
    public static let trafficFenced = -32_900

    public let baseURL: URL
    private let auth: GatewayAuthClient
    private var credential: GatewayCredential
    private var transport: GatewayTransport?
    private let keychain: KeychainStore
    private var trafficAdmission: TrafficAdmission?

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

    /// Install the owning app's source-qualified lifecycle admission. The
    /// check lives on the client rather than only in route resolution so a
    /// mutation that begins after a caller obtains this actor still wins the
    /// final race immediately before transport use.
    public func setTrafficAdmission(_ admission: TrafficAdmission?) {
        trafficAdmission = admission
    }

    public func acquireTrafficLease() async throws -> TrafficLease? {
        if let trafficAdmission, let lease = await trafficAdmission() {
            return lease
        }
        if trafficAdmission != nil {
            throw GatewayError(
                code: Self.trafficFenced,
                message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        return nil
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
        let lease = try await acquireTrafficLease()
        do {
            guard let transport else { throw GatewayError(code: -3, message: "not connected") }
            let result = try await transport.request(method, params: params, timeout: timeout)
            await lease?.release()
            return result
        } catch {
            await lease?.release()
            throw error
        }
    }

    // MARK: - Status

    public func status() async throws -> GatewayStatus {
        try await auth.status()
    }

    // MARK: - Profiles (the bot roster)

    /// The roster, with each row's canonical-chat pin resolved precisely.
    ///
    /// `preferred_session_ids` — `{profile: stored_session_id}` — is the
    /// enabling call for the whole roster region: it lets the *gateway* answer
    /// "what about THIS conversation" per row (hidden sessions included,
    /// compression lineages followed) instead of the client inferring the
    /// canonical chat from `last_session` and previewing a conversation the
    /// tap will not open (hermes-agent#88200). Deliberately not `session.list`
    /// — a paginated, hidden-excluding window once misjudged live hidden pins
    /// as gone.
    ///
    /// Server side: `methods_profiles.py` `_preferred_session_row` +
    /// `profiles.list` (`preferred_ids = params.get("preferred_session_ids")`,
    /// resolved only when `include_sessions` is on). Client side this mirrors
    /// `preferredSessionIds(allMeta)` (plugin.js:2208-2231).
    ///
    /// Pins default to the ones harvested from the previous answer's own
    /// `ui_meta["hermes-bots"].chat` — the same store desktop reads them from
    /// — so every existing caller gets the round trip without threading pins
    /// through. A gateway that predates the parameter ignores it and simply
    /// omits `preferred_session`; verified live 2026-08-18 against 0.20.3,
    /// where the roster came back identical with and without the field.
    public func listProfiles(includeSessions: Bool = true,
                             preferredSessionIDs: [String: String]? = nil) async throws -> [HermesProfile] {
        var params: JSONValue = ["include_sessions": .bool(includeSessions)]
        let pins = preferredSessionIDs ?? preferredSessionPins
        // Sending an empty map would be a no-op the gateway still has to
        // parse; desktop omits the key entirely for the same reason.
        if includeSessions, !pins.isEmpty,
           case .object(var fields) = params {
            fields["preferred_session_ids"] = .object(pins.mapValues(JSONValue.string))
            params = .object(fields)
        }
        let result = try await rpc("profiles.list", params)
        guard let rawRows = result["profiles"]?.arrayValue else {
            throw GatewayError(code: -8, message: "profiles.list malformed response")
        }
        let rows = rawRows.map(HermesProfile.init)
        guard rows.allSatisfy({ !$0.name.isEmpty }) else {
            throw GatewayError(code: -8, message: "profiles.list contained malformed profile")
        }
        if !rows.isEmpty { rememberPins(from: rows) }
        return rows.map { $0.foldingCanonicalPreview() }
    }

    /// Canonical-chat pins to resolve on the NEXT roster call. Self-priming
    /// from the block every answer already carries, which is where desktop's
    /// `$botMeta` gets them too.
    private var preferredSessionPins: [String: String] = [:]

    private func rememberPins(from rows: [HermesProfile]) {
        var harvested: [String: String] = [:]
        for row in rows {
            if let pin = row.uiMeta?["hermes-bots"]?["chat"]?.stringValue, !pin.isEmpty {
                harvested[row.name] = pin
            } else if row.uiMeta?["hermes-bots"]?.objectValue == nil,
                      let kept = preferredSessionPins[row.name] {
                // No server block at all — an older gateway, or one that
                // cannot persist ui_meta. Desktop's rule (plugin.js:441-470)
                // is that only an EXISTING block is authoritative, so a pin
                // this client learned locally survives; a block that exists
                // and omits `chat` really is a deletion and drops through.
                harvested[row.name] = kept
            }
        }
        preferredSessionPins = harvested
    }

    /// Tell the client about a pin before the gateway can: a canonical chat
    /// minted seconds ago is not in `ui_meta` until its write lands, and the
    /// poll in between would otherwise preview the wrong session once.
    public func notePreferredSessions(_ pins: [String: String]) {
        for (name, id) in pins where !id.isEmpty { preferredSessionPins[name] = id }
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
        guard let rawRows = result["sessions"]?.arrayValue else {
            throw GatewayError(code: -8, message: "session.list malformed response")
        }
        let rows = rawRows.map(StoredSession.init)
        guard rows.allSatisfy({ !$0.id.isEmpty }) else {
            throw GatewayError(code: -8, message: "session.list contained malformed session")
        }
        return rows
    }

    /// `hidden` marks a session plugin-owned: it stays out of shared lists
    /// (recents, the resume picker) and is browsed only by the surface that
    /// owns it. Bot Mode's canonical chats are always born this way
    /// (plugin.js:2758-2763). Applied as `pending_hidden` until the row exists
    /// (methods_session.py:100, server.py:3014-3021); older gateways ignore it.
    /// Flip the generic hidden flag on a stored session and its compression
    /// lineage (methods_session.py:1183). Bot Mode uses this to keep forever
    /// chats and room member sessions out of shared recents while remaining
    /// resumable from the per-bot browser. Older gateways reject the RPC;
    /// callers must treat that as unsupported, not as a user-visible failure.
    @discardableResult
    public func setSessionHidden(_ sessionID: String, hidden: Bool) async throws -> Bool {
        let result = try await rpc("session.set_hidden",
                                   ["session_id": .string(sessionID),
                                    "hidden": .bool(hidden)])
        return result["hidden"]?.boolValue ?? hidden
    }

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
    @discardableResult
    public func submitPrompt(sessionID: String, text: String, queued: Bool = false,
                             truncate: TranscriptActing.TruncateAddress = .init()) async throws -> JSONValue {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), "text": .string(text)]
        if queued { params["queued"] = .bool(true) }
        for (key, value) in TranscriptActing.truncateParams(truncate) {
            params[key] = value
        }
        return try await rpc("prompt.submit", .object(params), timeout: 1800)
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

    /// Pass `provider` whenever it is known: `parse_model_switch_args`
    /// resolves a bare name within the CURRENT aggregator first
    /// (model_switch.py:713-716), so a self-hosted model set while a
    /// subscription provider is active gets looked up on the wrong endpoint.
    /// `--provider <slug>` is the documented spelling (model_switch.py:515).
    public func setSessionModel(sessionID: String, model: String,
                                provider: String? = nil) async throws {
        let slug = (provider ?? "").trimmingCharacters(in: .whitespaces)
        let value = slug.isEmpty ? model : "\(model) --provider \(slug)"
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "model", "value": .string(value)])
    }

    /// Reasoning effort for the session ("none" | "low" | "medium" | "high" —
    /// the gateway validates; desktop's status-bar reasoning control parity).
    public func setReasoningEffort(sessionID: String, value: String) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "reasoning", "value": .string(value)])
    }

    // Device registration for the talaria-push relay lives in
    // GatewayClient+Providers.swift. It is deliberately the ONLY spelling: the
    // relay's upsert replaces the whole record, so a registration call that
    // cannot express `profile_filter` erases the caller's per-bot push filter
    // every time it runs. An earlier two-argument version here did exactly
    // that on every gateway connect.

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
        let lease = try await acquireTrafficLease()
        do {
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
            await lease?.release()
            return data
        } catch {
            await lease?.release()
            throw error
        }
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

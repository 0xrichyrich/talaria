import Foundation
import TalariaKit

// Live-gateway side of AppModel: connect, route events into observable state,
// and back the shared actions with real RPCs. Demo mode never touches this.
//
// Protocol contract: .research/ws-protocol.md / auth-flows.md. Key behaviors:
// - profiles.list is the roster; cosmetics ride ui_meta — desktop Bot Mode's
//   own ui_meta["hermes-bots"] block first, Talaria's ui_meta["talaria"]
//   mirror second, a hash of the profile name only when there is neither
//   (TalariaKit/BotCosmetics.swift).
// - Turn events (message.*/tool.*/session.usage) route by runtime session id.
// - approval.request blocks the agent until approval.respond.
// - On socket loss the server parks live sessions for ~20 s; we reconnect with
//   exponential backoff and session.resume open chats to reattach in-flight
//   state, then flush the offline compose queue.

// MARK: - Live runtime (side table)

/// Book-keeping for the live link. `AppModel`'s stored properties live in
/// AppModel.swift (another owner); extensions cannot add storage, so the
/// runtime rides in a MainActor singleton — Talaria drives one gateway link
/// per process.
@MainActor
final class LiveRuntime {
    static let shared = LiveRuntime()

    /// Runtime session id (8-hex sid) → bot/profile id.
    var sessionToBot: [String: String] = [:]
    /// Bots with a turn in flight (drives BotStatus.working).
    var workingBotIDs: Set<String> = []
    /// approval request_id → runtime session id (for approval.respond).
    var approvalSessions: [String: String] = [:]
    /// bot id → durable stored-session key from profiles.list last_session.
    var lastSessionByBot: [String: String] = [:]
    /// The gateway's default profile — owner of un-namespaced cron jobs and
    /// approvals we cannot attribute.
    var defaultBotID: String?
    /// In-flight create/resume per bot so a tap + a send never double-create.
    var attachTasks: [String: Task<String, Error>] = [:]
    /// Normalized base URL of the connected gateway (mirror of the client's,
    /// readable without hopping onto its actor).
    var baseURL: URL?
    /// Saved-connection id of the primary client. Secondary clients use the
    /// same id key in `GatewayClientPool`.
    var gatewayID: String?

    /// Bumped on every (re)connect + teardown; stale monitors check it.
    var generation = 0
    var eventPump: Task<Void, Never>?
    var monitorTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?

    func resetSessionState() {
        sessionToBot.removeAll()
        workingBotIDs.removeAll()
        approvalSessions.removeAll()
        for task in attachTasks.values { task.cancel() }
        attachTasks.removeAll()
    }
}

extension AppModel {

    // MARK: - Connection

    /// Connect to a gateway from a user-entered URL string. Normalizes like
    /// desktop's connection-config, then connects.
    public func connectGateway(urlString: String, credential: GatewayCredential) async throws {
        guard let base = GatewayURL.normalize(urlString) else {
            throw AuthError.protocolError("not a gateway URL")
        }
        try await connectGateway(baseURL: base, credential: credential)
    }

    /// Connect to a gateway and become live. Credential comes from the
    /// onboarding auth flow (AuthController) or the Keychain. Registers the
    /// gateway in the ConnectionRegistry and starts the disconnect monitor.
    public func connectGateway(baseURL: URL, credential: GatewayCredential) async throws {
        let runtime = LiveRuntime.shared

        // Tear down any previous link.
        runtime.generation += 1
        runtime.reconnectTask?.cancel(); runtime.reconnectTask = nil
        runtime.monitorTask?.cancel(); runtime.monitorTask = nil
        runtime.eventPump?.cancel(); runtime.eventPump = nil
        runtime.resetSessionState()
        // Session ids are per-gateway; a pin from the previous one resolves to
        // nothing (or worse, something else) here.
        CanonicalChatRuntime.shared.reset()
        // Switching gateways reaches here WITHOUT going through
        // disconnectGateway (switchGateway calls connectGateway directly), so
        // the per-gateway caches have to be dropped on both paths. Done before
        // the old socket closes, so the pairing watch can still surrender its
        // handler to the client that owns it.
        dropPerGatewayCaches()
        let registry = ConnectionRegistry.shared
        if let oldGatewayID = runtime.gatewayID {
            await registry.clientPool.disconnect(gatewayID: oldGatewayID)
        } else if let old = client {
            await old.disconnect()
        }
        runtime.gatewayID = nil

        let client = GatewayClient(baseURL: baseURL, credential: credential)
        self.client = client
        runtime.baseURL = baseURL
        // The unread marks survive a switch (being durable is the point), but
        // the store has to be pointed at the gateway now being answered for.
        // Nothing else does it until the first roster answer lands, and an
        // `acknowledge` inside that window would otherwise advance the DEPARTED
        // gateway's mark for a profile that merely shares a name.
        rescopeUnreadWatermarks()

        // Events fan out of the client on its own actor; funnel them through
        // one AsyncStream so MainActor delivery preserves wire order (deltas
        // arrive in ~30 fps bursts and must append in order).
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        _ = await client.addEventHandler { continuation.yield($0) }
        runtime.eventPump = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event: event) }
        }

        try await client.connect()
        // Entering the real world: the canned demo content must not survive
        // next to live data.
        if demoDataLoaded { flushDemoWorld() }
        mode = .live
        isOffline = false

        guard let savedGateway = registry.upsert(urlString: baseURL.absoluteString,
                                                 credential: credential) else {
            await client.disconnect()
            self.client = nil
            runtime.baseURL = nil
            throw AuthError.protocolError("connected gateway could not be registered")
        }
        runtime.gatewayID = savedGateway.id
        await registry.clientPool.adopt(client, for: savedGateway.id)
        registry.noteState(.connected, forURL: baseURL)

        startDisconnectMonitor(for: client)

        #if os(iOS)
        // Hand the APNs token to this gateway's push relay (if installed).
        PushCoordinator.shared.registerWithRelayIfConnected()
        #endif

        try await refreshRoster()
        try? await refreshRoutines()
        connections = registry.rows
        await flushComposeQueue()
    }

    /// Deliberate disconnect (Settings → Connections). No reconnect follows.
    public func disconnectGateway() async {
        let runtime = LiveRuntime.shared
        runtime.generation += 1
        runtime.reconnectTask?.cancel(); runtime.reconnectTask = nil
        runtime.monitorTask?.cancel(); runtime.monitorTask = nil
        runtime.eventPump?.cancel(); runtime.eventPump = nil
        runtime.resetSessionState()
        if let gatewayID = runtime.gatewayID {
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gatewayID)
        } else if let client {
            await client.disconnect()
        }
        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
        }
        runtime.baseURL = nil
        runtime.gatewayID = nil
        // No gateway, no scope: with the key cleared the store records nothing
        // until a connection names one again, so a disconnected app can never
        // write a mark into the departed gateway's bucket.
        rescopeUnreadWatermarks()
        client = nil
        isOffline = false
        // Each area's router owns state belonging to *that* gateway. Without
        // this they survive the disconnect: cached session titles from a store
        // that is gone, and — the visible one — a parked clarify/sudo/secret
        // prompt left modal over an empty world with no socket to answer on.
        // The attach* calls all early-return once `client` is nil, so this is
        // the only chance to tear them down.
        detachApprovalBridges()
        detachSessionEventRouter()
        detachVoiceRouter()
        // The liveness watches are not event subscriptions but they have the
        // same lifetime: a reaper polling `session.active_list`, a foreground
        // observer and an NWPathMonitor all outlive this call otherwise, and
        // every conclusion they draw is scoped to the gateway that just left.
        stopLivenessSupervision()
        // Canonical-chat pins name sessions in THIS gateway's per-profile
        // state.db; carrying them to the next gateway would resume ids that
        // mean nothing there.
        CanonicalChatRuntime.shared.reset()
        // ~11 MB of decoded spritesheets and a per-profile pet cache belong to
        // the gateway that served them, not to the next one.
        detachPetEventRouter()
        // Same rule for the About panel's facts: `desktop_contract`, the health
        // probe and the runtime model all describe THIS gateway. Left standing,
        // the next gateway's About page would report the departed one's
        // contract version — which is precisely the number a client uses to
        // decide which RPC shapes it may send.
        detachSettingsDiagnostics()
        dropPerGatewayCaches()
        connections = ConnectionRegistry.shared.rows
    }

    /// Everything Phase 3 caches per gateway, dropped in one place because two
    /// paths end a link: `disconnectGateway()` (sign out, Connections →
    /// disconnect) and `connectGateway()` (a switch, which never disconnects
    /// first). A cache that only one of them clears is a cache that survives
    /// half the time — which is worse than one that never clears, because the
    /// bug only reproduces on one route.
    private func dropPerGatewayCaches() {
        // Cron detail: the `cron.changed` subscription, per-job records, run
        // histories, and the "this gateway has no cron REST router" verdict —
        // the last of which decides whether editing and history exist at all.
        detachCronDetailRouter()
        // The approval-policy store re-probes itself on the next load, but its
        // `pairing.changed` subscription is a live registration on the socket
        // being closed and has to be surrendered while that client is still
        // around to surrender it to.
        detachPairingWatch()
        // Up to 40 MB of decoded artifact bodies and thumbnails fetched from
        // the departing gateway. Keys are gateway-scoped, so this is about the
        // memory rather than a mix-up — but holding another machine's files
        // resident after leaving it is not a thing to do quietly.
        ArtifactStore.shared.flush()
        // Agent-to-agent: a `sessions.changed` subscription on the socket being
        // closed, plus reply watches holding stored-session ids that only mean
        // something on the departing gateway. Those watches re-read `client`
        // every tick, so left standing they poll the NEXT gateway with the last
        // one's ids — the one way a2a state can cross a switch.
        detachA2ARouter()
        // A toast is the app answering a mutation aimed at THIS gateway. Left
        // standing across a switch, "Duplicating inbox…" hangs over a roster
        // that never had an `inbox`, and its ledger row would settle into the
        // next gateway's journal when the answer finally arrives.
        clearToasts()
    }

    /// Probe every saved gateway and sync the Connections rows.
    public func refreshConnections() async {
        await ConnectionRegistry.shared.probeAll()
        if mode == .live { connections = ConnectionRegistry.shared.rows }
    }

    // MARK: - Roster (profiles.list → bots)

    /// Ask the gateway for the roster and fold the answer in.
    public func refreshRoster() async throws {
        guard let client else { return }
        // Sampled BEFORE the await: any pin written while this poll was in
        // flight makes the block it returns stale, and the merge below reads a
        // missing `chat` key as an authoritative deletion.
        let pinWrites = CanonicalChatRuntime.shared.writeCount
        let profiles = try await client.listProfiles()
        applyRosterAnswer(profiles, pinWrites: pinWrites)
    }

    /// THE roster builder. Every path holding a `profiles.list` answer — the
    /// connect-time refresh, the 10 s signals poll, a create/duplicate/delete,
    /// a `sessions.changed` event — folds it in here, and nothing else writes a
    /// row's cosmetics, its ranking signal or its timestamp.
    ///
    /// It is one function because it used to be two, and the split WAS the bug.
    /// This map owned cosmetics and ignored `has_avatar`; `RosterSignals.ingest`
    /// owned recency, liveness and `has_avatar` and ignored cosmetics. A cold
    /// launch ran only the first (the poll's opening tick bails until the socket
    /// lands), the poll's second tick then ran only the second, and the roster
    /// visibly changed identity between them: avatars swapped to the gateway's
    /// stored rasters, timestamps flipped absolute → relative, the rows
    /// reordered and an Active Now rail appeared, all on one tick about eight
    /// seconds in. One answer in, one roster out, one instant.
    func applyRosterAnswer(_ profiles: [HermesProfile], pinWrites: [String: Int]) {
        let runtime = LiveRuntime.shared
        runtime.defaultBotID = profiles.first(where: \.isDefault)?.name ?? profiles.first?.name

        // Scoped to this gateway BEFORE the fold, with no await in between.
        // `rescope` clears every table when the gateway changes, and the roster
        // screen arms its poll with a rescope of its own — so an answer folded
        // in while the scope was still unset would be wiped moments later by
        // that arming call, leaving the rows with no recency, no liveness and
        // no `has_avatar` until the next poll landed. Which is the same flip
        // this whole path exists to prevent, one layer down.
        RosterSignals.shared.rescope(to: runtime.baseURL)
        // Ranking, the 90 s liveness window and `has_avatar`, taken from the
        // SAME answer the map below reads — not from a second call landing
        // seconds later.
        RosterSignals.shared.ingest(profiles)
        // …and the unread diff off the stamps that ingest just restated. It runs
        // HERE, synchronously between the fold and the rows, rather than from an
        // observer on `lastActive`: an observer's MainActor hop lands the badge
        // write either side of `bots` being rebuilt purely by run-loop ordering,
        // which is a race that has to be insured against instead of avoided.
        let moved = unreadMoves(scope: runtime.baseURL)
        // A bot with a cosmetics write in flight keeps the look the user just
        // picked: this answer was composed before that write, and reading it as
        // authority would flip the row back under their thumb.
        let writing = RosterSignals.shared.writing

        bots = profiles.map { profile in
            if let last = profile.lastSession?.id {
                runtime.lastSessionByBot[profile.name] = last
            }
            let existing = bots.first { $0.id == profile.name }
            // Desktop Bot Mode's own metadata block wins over Talaria's, so a
            // bot titled/recolored on desktop reads identically here. The
            // precedence — desktop's block, then Talaria's mirror, then a hash
            // of the name as a last resort — lives in one place for the whole
            // app (TalariaKit/BotCosmetics.swift).
            let deskMeta = BotModeMeta(uiMeta: profile.uiMeta)
            // The canonical-chat pin travels in that same block, and desktop's
            // mergeServerMeta is precise about it (plugin.js:441-470): when the
            // server block EXISTS it is authoritative and an omitted `chat` key
            // is a deletion — so this assignment, nil included, is the whole
            // merge. When there is no block at all (a gateway that cannot store
            // ui_meta) the locally resolved pin survives instead. A bot whose
            // own pin write is still in flight — or landed while this poll was
            // out — is skipped: that answer predates the write, and reading it
            // as a deletion would drop the pin just made.
            let canonical = CanonicalChatRuntime.shared
            if let deskMeta, !canonical.hasLocalPinWrite(profile.name, since: pinWrites) {
                canonical.pins[profile.name] = deskMeta.pinnedChat
            }
            // `stripPreviewMarkdown` (plugin.js:2991-3007): without it a bot
            // that answers with a bulleted list puts literal asterisks in the
            // roster. Folded in here because the 10 s poll used to do it in a
            // second pass of its own, and a row's text and its face must land
            // on the same tick.
            let fresh = (profile.lastSession?.preview).map(Self.flattenPreview) ?? ""
            var bot = Bot(
                id: profile.name,
                job: profile.description ?? "",
                shape: BotCosmetics.shape(for: profile),
                hue: BotCosmetics.hue(for: profile),
                status: .idle,
                task: existing?.task,
                minutesElapsed: existing?.minutesElapsed ?? 0,
                preview: fresh.isEmpty ? (existing?.preview ?? "Ready when you are.") : fresh,
                previewTime: Self.shortTime(profile.lastSession?.lastActive),
                unread: existing?.unread ?? 0,
                mentionsYou: existing?.mentionsYou ?? false,
                description: profile.description,
                pinnedModel: profile.model,
                title: deskMeta?.title)
            // A look whose write is still in flight keeps the value the user
            // just picked — this answer was composed before it.
            if let existing, writing.contains(profile.name) {
                bot.shape = existing.shape
                bot.hue = existing.hue
                bot.title = existing.title
            }
            if approvals.contains(where: { $0.botID == bot.id }) { bot.status = .approval }
            if runtime.workingBotIDs.contains(bot.id) { bot.status = .working }
            return bot
        }

        applyUnreadWatermark(moved)
        // `has_avatar` drives the FETCH and only the fetch — never which face a
        // row draws. Desktop reads the same flag the same way, walking the whole
        // roster fire-and-forget (`pullServerAvatars`, plugin.js:397-409), which
        // is also what keeps a shape-only roster at zero `profiles.get_asset`
        // calls instead of one per row.
        for profile in profiles where profile.hasAvatar
            && !ProfileAssetStore.shared.isResolved(profile.name) {
            Task { await self.refreshAvatar(botID: profile.name) }
        }

        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteBotCount(bots.count, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
    }

    /// Deterministic across launches (String.hashValue is seeded per-process).
    /// The roster's own use of it lives in `BotCosmetics`; this stays as the
    /// spelling the feed dedupe keys and the row-sway offsets already use.
    static func stableHash(_ s: String) -> Int { BotCosmetics.stableHash(s) }

    static func shortTime(_ unix: Double?) -> String {
        guard let unix, unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: unix)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE"
        return f.string(from: date)
    }

    // MARK: - Opening a chat (canonical forever-chat + hydration)

    /// Navigate into a bot's chat. THE entry point: every route into a bot —
    /// roster row, deep link, notification tap, search result, activity row,
    /// banner — goes through here, because this is what resumes the bot's
    /// conversation instead of leaving the chat empty and letting the first
    /// send fork a brand-new session.
    ///
    /// Live mode lands in the bot's canonical forever-chat, resolved in
    /// AppModelLive+CanonicalChat.swift (plugin.js:2802-2896). Never "the most
    /// recent session": a cron delivery or a CLI run would otherwise hijack
    /// what a tap opens.
    public func openChat(botID: String) {
        // Some routes in carry a @handle rather than a profile id — an A2A
        // attribution prefix names the sender `@hermes`, and a deep link or
        // push payload can quote whatever the desktop displayed. Every
        // gateway call below wants the profile id, so resolve once, here, at
        // the single entry point (Components/BotIdentity.swift).
        let botID = resolvedBotID(botID)
        openBotID = botID
        selectedTab = .home
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].unread = 0
            bots[idx].mentionsYou = false
        }
        // The durable mark has to move with the badge, or the next roster poll
        // finds activity this app already counted from the event stream and
        // raises the dot again on a chat the user is reading
        // (AppModelLive+Unread.swift).
        noteChatOpened(botID)
        guard mode == .live, !isOffline else { return }
        Task { @MainActor in await self.enterCanonicalChat(botID: botID) }
    }

    /// Create-or-resume the bot's session and bind it to the chat. Coalesces
    /// concurrent callers (openChat racing a send) onto one attach.
    ///
    /// The resolution itself lives in `attachCanonicalSession`: an explicit
    /// binding wins, otherwise the canonical chat. That is what keeps a send
    /// typed before the chat finished opening out of a fresh forked session.
    func ensureSession(botID: String, hydrate: Bool) async throws -> String {
        let runtime = LiveRuntime.shared
        if let sid = chat(for: botID).sessionID { return sid }
        if let pending = runtime.attachTasks[botID] { return try await pending.value }
        guard client != nil else { throw GatewayError(code: -3, message: "not connected") }

        let task = Task<String, Error> { @MainActor in
            try await self.attachCanonicalSession(botID: botID, hydrate: hydrate)
        }
        runtime.attachTasks[botID] = task
        // Clear only OUR entry. `openStoredSession` cancels the in-flight
        // attach and drops the slot, so by the time this frame resumes the
        // slot may already hold a newer task; blanking it unconditionally
        // un-coalesces that one, and two concurrent resolutions of the same
        // bot can mint two canonical chats — the fork this phase exists to
        // prevent. Task is Equatable, so identity is exact.
        defer { if runtime.attachTasks[botID] == task { runtime.attachTasks[botID] = nil } }
        return try await task.value
    }

    func bindSession(_ live: LiveSession, botID: String) {
        let chat = chat(for: botID)
        chat.sessionID = live.sessionID
        if !live.storedSessionID.isEmpty { chat.storedSessionID = live.storedSessionID }
        LiveRuntime.shared.sessionToBot[live.sessionID] = botID
        if live.running {
            setWorking(botID, true)
            chat.isTyping = true
        }
    }

    /// Map transcript rows to chat messages. Two shapes reach here and both
    /// have to work, because the REST route is the hydration fallback:
    ///
    /// - the WS display projection (server.py:_history_to_messages) —
    ///   `{role, text, timestamp?, row_id?, reasoning?, display_kind?}`, tool
    ///   rows carrying `{role:"tool", name, args}`;
    /// - raw `messages` rows from GET /api/sessions/{id}/messages
    ///   (hermes_state.py:get_messages returns `SELECT *`) — the same fields
    ///   under their column names: `content` for the body, `id` for the row.
    ///
    /// Hidden scaffolding and tool rows are dropped either way.
    static func chatMessages(fromTranscript payload: JSONValue) -> [ChatMessage] {
        var rows = payload["messages"]?.arrayValue ?? payload.arrayValue ?? []
        // The REST page may serve newest-first; normalize to oldest-first.
        if rows.count > 1,
           let first = rows.first?["timestamp"]?.doubleValue,
           let last = rows.last?["timestamp"]?.doubleValue,
           first > last {
            rows.reverse()
        }
        return rows.compactMap { row in
            guard row["display_kind"]?.stringValue != "hidden" else { return nil }
            let role = row["role"]?.stringValue
            let text = transcriptText(row)
            guard !text.isEmpty else { return nil }
            // Gateway bookkeeping (model switches, personality notices) is
            // persisted as role=user "[System: …]" so strict providers accept
            // it mid-history. The WS projection filters it
            // (server.py:_is_display_hidden_marker); raw DB rows do not, so it
            // has to be filtered here too or it renders as a user bubble.
            guard !(role == "user" && text.hasPrefix("[System:")) else { return nil }
            let time = row["timestamp"]?.doubleValue.map { shortTime($0) }
            let reasoning = row["reasoning"]?.stringValue
                ?? row["reasoning_content"]?.stringValue
            // Durable row identity (_history_to_messages stamps `row_id` from
            // _rows_to_conversation; the DB column it comes from is `id`).
            // Without it only the newest assistant row is addressable by
            // `message.react`, which names rows by id.
            let rowID = row["row_id"]?.intValue ?? row["id"]?.intValue
            switch role {
            case "user": return ChatMessage(author: .user, time: time, text: text,
                                            rowID: rowID)
            case "assistant": return ChatMessage(author: .bot, time: time, text: text,
                                                 reasoning: reasoning, rowID: rowID)
            case "system": return ChatMessage(author: .system, time: time, text: text)
            default: return nil
            }
        }
    }

    /// The body of a transcript row. `text` is the projection's field name and
    /// `content` the column's; a multimodal `content` is a parts array
    /// (`[{type:"text", text:…}, {type:"image_url", …}]`), whose text parts are
    /// the only renderable half.
    private static func transcriptText(_ row: JSONValue) -> String {
        if let text = row["text"]?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let content = row["content"] else { return "" }
        if let text = content.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let parts = content.arrayValue else { return "" }
        return parts.compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replay a reconnect/resume inflight snapshot ({user, assistant,
    /// streaming, error?}) into the chat so a dropped socket loses nothing.
    func replayInflight(_ live: LiveSession, botID: String) {
        guard let inflight = live.inflight, inflight != .null else { return }
        let chat = chat(for: botID)
        if let user = inflight["user"]?.stringValue, !user.isEmpty,
           !chat.messages.suffix(4).contains(where: { $0.author == .user && $0.text == user }) {
            chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: user))
        }
        let partial = inflight["assistant"]?.stringValue ?? ""
        let streaming = inflight["streaming"]?.boolValue ?? false
        if !partial.isEmpty {
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].text = partial
                chat.messages[chat.messages.count - 1].isStreaming = streaming
            } else {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: partial, isStreaming: streaming))
            }
            chat.isTyping = false
        }
        if let error = inflight["error"]?.stringValue, !error.isEmpty {
            chat.messages.append(ChatMessage(author: .system, text: error))
        }
    }

    /// Replay the blocking prompts `session.resume` carries. Both park a real
    /// agent thread, and neither is re-emitted as an event after a reconnect:
    /// the approval sweep would find the approval a round trip later, but a
    /// clarify has no `*.pending` RPC at all, so this block is its only
    /// recovery channel. Routed through the approvals surface so a replayed
    /// approval arrives with its real choice set rather than once/deny.
    func replayPendingPrompts(_ live: LiveSession) {
        if let pending = live.pendingApproval { ingestPendingApproval(pending) }
        if let clarify = live.pendingClarify, clarify != .null {
            ingestPendingClarify(clarify, sessionID: live.sessionID)
        }
    }

    // MARK: - Event routing

    func botID(forSession sessionID: String) -> String? {
        LiveRuntime.shared.sessionToBot[sessionID]
    }

    public func handle(event: GatewayEvent) {
        let botID = botID(forSession: event.sessionID)
        switch TypedGatewayEvent(event) {
        case .messageStart:
            if let botID {
                chat(for: botID).isTyping = true
                setWorking(botID, true)
            }

        case .messageDelta(let text):
            guard let botID, !text.isEmpty else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].text += text
            } else {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: text, isStreaming: true))
            }

        case .thinkingDelta(let text), .reasoningDelta(let text):
            // Reasoning usually precedes the first visible token — open the
            // streaming bubble early so the "Thought" block has a home.
            guard let botID, !text.isEmpty else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].reasoning =
                    (last.reasoning ?? "") + text
            } else {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: "", isStreaming: true, reasoning: text))
            }

        case .messageInterim(let text, let alreadyStreamed):
            // Complete assistant segment between tool calls: finalize the
            // streaming bubble, or append when it never streamed.
            guard let botID, !text.isEmpty else { return }
            let chat = chat(for: botID)
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].text = text
                chat.messages[chat.messages.count - 1].isStreaming = false
            } else if !alreadyStreamed {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(), text: text))
            }
            chat.isTyping = true   // the turn continues (tools next)

        case .messageComplete(let payload):
            guard let botID else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            if let last = chat.messages.last, last.isStreaming {
                if !payload.text.isEmpty { chat.messages[chat.messages.count - 1].text = payload.text }
                chat.messages[chat.messages.count - 1].isStreaming = false
                if let reasoning = payload.reasoning, !reasoning.isEmpty,
                   chat.messages[chat.messages.count - 1].reasoning == nil {
                    chat.messages[chat.messages.count - 1].reasoning = reasoning
                }
            } else if !payload.text.isEmpty, chat.messages.last?.text != payload.text {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(), text: payload.text))
            }
            if let error = payload.error, payload.status == .error {
                chat.messages.append(ChatMessage(author: .system, text: error))
            }
            chat.usage = payload.usage
            pruneApprovals(sessionID: event.sessionID)
            setWorking(botID, false)
            if let idx = bots.firstIndex(where: { $0.id == botID }) {
                if !payload.text.isEmpty {
                    bots[idx].preview = Self.previewLine(payload.text)
                    bots[idx].previewTime = AppModel.clock()
                }
                if openBotID != botID { bots[idx].unread += 1 }
            }

        case .sessionUsage(let usage):
            if let botID { chat(for: botID).usage = usage }

        case .sessionInfo(let info):
            guard let botID else { return }
            let chat = chat(for: botID)
            chat.yolo = info.yolo
            if chat.storedSessionID == nil, !info.storedSessionID.isEmpty {
                chat.storedSessionID = info.storedSessionID
            }

        case .toolGenerating(let name):
            if let botID, let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = name
            }

        case .toolStart(let tool):
            if let botID, let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = tool.context.isEmpty ? tool.name : "\(tool.name) · \(tool.context)"
            }

        case .statusUpdate(_, let text):
            if let botID, !text.isEmpty,
               LiveRuntime.shared.workingBotIDs.contains(botID),
               let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = text
            }

        case .approvalRequest(let request):
            ingest(request)

        case .errorEvent(let message):
            if let botID, !message.isEmpty {
                chat(for: botID).messages.append(ChatMessage(author: .system, text: message))
            }

        case .changed(let what):
            Task { @MainActor in
                if what == "sessions.changed" { try? await self.refreshRoster() }
                if what == "cron.changed" { try? await self.refreshRoutines() }
            }

        case .notificationShow(let payload):
            showAgentNotice(payload)

        case .notificationClear(let key):
            clearAgentNotice(key)

        case .backgroundComplete(let taskID, let text):
            reportBackgroundCompletion(taskID: taskID, text: text, botID: botID)

        case .other(let raw) where raw.type == "session.reclaimed":
            // Backend reclaimed a parked runtime session (idle TTL / orphan
            // reap): drop the cached sid so the next open/send re-resumes
            // from the durable key.
            let sid = raw.payload?["session_id"]?.stringValue ?? ""
            guard !sid.isEmpty else { return }
            for chat in chats.values where chat.sessionID == sid || chat.storedSessionID == sid {
                chat.sessionID = nil
                chat.isTyping = false
            }
            if let owner = LiveRuntime.shared.sessionToBot.removeValue(forKey: sid) {
                setWorking(owner, false)
            }

        default:
            break
        }
    }

    // MARK: - Approvals

    private func ingest(_ request: ApprovalRequest) {
        guard !request.requestID.isEmpty,
              !approvals.contains(where: { $0.id == request.requestID }) else { return }
        let runtime = LiveRuntime.shared
        let owner = runtime.sessionToBot[request.sessionID]
            ?? runtime.defaultBotID ?? bots.first?.id ?? "default"
        runtime.approvalSessions[request.requestID] = request.sessionID
        approvals.append(Approval(
            id: request.requestID,
            botID: owner,
            kind: Self.approvalKind(for: request),
            title: request.description.isEmpty ? request.command : request.description,
            target: request.patternKey ?? runtime.baseURL?.host() ?? "",
            subject: request.command,
            body: request.command,
            why: request.description,
            age: "now"))
        if let idx = bots.firstIndex(where: { $0.id == owner }) {
            bots[idx].status = .approval
        }
    }

    /// A finished turn can hold no approvals — drop the stale ones (they were
    /// answered elsewhere, timed out, or denied by an interrupt).
    private func pruneApprovals(sessionID: String) {
        let runtime = LiveRuntime.shared
        let stale = runtime.approvalSessions.filter { $0.value == sessionID }.map(\.key)
        guard !stale.isEmpty else { return }
        for id in stale { runtime.approvalSessions.removeValue(forKey: id) }
        let owners = Set(approvals.filter { stale.contains($0.id) }.map(\.botID))
        approvals.removeAll { stale.contains($0.id) }
        for owner in owners { recomputeStatus(for: owner) }
    }

    static func approvalKind(for request: ApprovalRequest) -> ApprovalKind {
        let text = (request.command + " " + request.description).lowercased()
        if text.contains("mail") || text.contains("smtp") { return .email }
        if text.contains("post") || text.contains("publish") || text.contains("tweet") { return .post }
        if request.patternKey != nil || !request.command.isEmpty { return .command }
        return .other
    }

    // MARK: - Live actions (called from AppModel's mode dispatch)

    func liveSend(text: String, botID: String, chat: ChatState) {
        Task { @MainActor in
            do {
                let sid = try await ensureSession(botID: botID, hydrate: false)
                guard let client else { return }
                try await client.submitPrompt(sessionID: sid, text: text)
            } catch let error as GatewayError where error.code == -3 || error.code == -7 {
                // Link died mid-send — the bubble stays, the text queues, the
                // reconnect flush retries it.
                isOffline = true
                composeQueue.append((botID, text))
            } catch {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    func liveResolveApproval(_ approval: Approval, approve: Bool) {
        Task { @MainActor in
            guard let client else { return }
            let runtime = LiveRuntime.shared
            // The request → session binding was recorded when the approval
            // arrived; fall back to the bot's live session.
            let sid = runtime.approvalSessions.removeValue(forKey: approval.id)
                ?? chats[approval.botID]?.sessionID
            if let sid {
                try? await client.respondToApproval(sessionID: sid,
                                                    choice: approve ? .once : .deny,
                                                    requestID: approval.id)
            }
            recomputeStatus(for: approval.botID)
        }
    }

    func liveToggleRoutine(_ routine: Routine) {
        Task { @MainActor in
            guard let client else { return }
            _ = try? await client.cronManage(.object([
                "action": .string(routine.isOn ? "enable" : "disable"),
                "id": .string(routine.id),
            ]))
        }
    }

    // MARK: - Routines (Hermes cron)

    /// cron.manage list → routines. Jobs are namespaced "[bot:<name>] <title>"
    /// by convention; anything else belongs to the gateway's default profile.
    public func refreshRoutines() async throws {
        guard let client else { return }
        let jobs = try await client.cronList()
        let fallback = LiveRuntime.shared.defaultBotID ?? bots.first?.id ?? "default"
        routines = jobs.map { job in
            var botID = fallback
            var name = job.name
            if job.name.hasPrefix("[bot:"), let close = job.name.firstIndex(of: "]") {
                botID = String(job.name.dropFirst(5).prefix(while: { $0 != "]" }))
                name = String(job.name[job.name.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return Routine(id: job.id, botID: botID, name: name, schedule: job.schedule,
                           next: Self.relativeNext(job.nextRun),
                           last: Self.shortTime(job.lastRun),
                           isOn: job.enabled)
        }
    }

    /// "in 22h 18m" — matches the design's next-run column.
    static func relativeNext(_ unix: Double?) -> String {
        guard let unix else { return "" }
        let delta = Int(unix - Date().timeIntervalSince1970)
        guard delta > 0 else { return "" }
        let d = delta / 86_400, h = (delta % 86_400) / 3600, m = (delta % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(m, 1))m"
    }

    // MARK: - Working state

    private func setWorking(_ botID: String, _ working: Bool) {
        let runtime = LiveRuntime.shared
        if working {
            runtime.workingBotIDs.insert(botID)
        } else {
            runtime.workingBotIDs.remove(botID)
        }
        if !working, let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].task = nil
        }
        recomputeStatus(for: botID)
    }

    private func recomputeStatus(for botID: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { return }
        if approvals.contains(where: { $0.botID == botID }) {
            bots[idx].status = .approval
        } else if LiveRuntime.shared.workingBotIDs.contains(botID) {
            bots[idx].status = .working
        } else {
            bots[idx].status = .idle
        }
    }

    static func previewLine(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        return firstLine.count > 120 ? String(firstLine.prefix(119)) + "…" : firstLine
    }

    // MARK: - Disconnect → backoff reconnect → grace-window resume

    /// The client's event pump finishes exactly when the socket dies; awaiting
    /// it is the disconnect signal (no polling, no heartbeats — ws-protocol §3).
    private func startDisconnectMonitor(for client: GatewayClient) {
        let runtime = LiveRuntime.shared
        let generation = runtime.generation
        runtime.monitorTask?.cancel()
        runtime.monitorTask = Task { [weak self] in
            guard let pump = await client.eventsTask else { return }
            await pump.value
            guard !Task.isCancelled else { return }
            self?.noteDisconnect(generation: generation)
        }
    }

    private func noteDisconnect(generation: Int) {
        let runtime = LiveRuntime.shared
        guard generation == runtime.generation, mode == .live, client != nil else { return }
        // Last known state stays on screen (the bots keep working server-side);
        // the offline banner + queued composes communicate the rest.
        isOffline = true
        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
        scheduleReconnect()
    }

    /// Exponential backoff: 1, 2, 4, … capped at 30 s with jitter. The server
    /// parks live sessions for ~20 s, so the first attempts usually reattach
    /// the in-memory session with its in-flight turn intact.
    private func scheduleReconnect() {
        let runtime = LiveRuntime.shared
        guard runtime.reconnectTask == nil, let client else { return }
        let generation = runtime.generation
        runtime.reconnectTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let backoff = min(30.0, Double(1 << min(attempt, 5))) + Double.random(in: 0...0.5)
                try? await Task.sleep(for: .seconds(backoff))
                guard let self, !Task.isCancelled,
                      LiveRuntime.shared.generation == generation else { return }
                do {
                    try await client.connect()
                    LiveRuntime.shared.reconnectTask = nil
                    await self.reattachAfterReconnect(client: client)
                    return
                } catch AuthError.sessionExpired {
                    // Refresh token is dead — stay offline until re-auth.
                    LiveRuntime.shared.reconnectTask = nil
                    return
                } catch {
                    attempt += 1
                }
            }
        }
    }

    private func reattachAfterReconnect(client: GatewayClient) async {
        let runtime = LiveRuntime.shared
        runtime.generation += 1
        runtime.resetSessionState()
        approvals.removeAll()   // pending ones replay via session.resume below

        isOffline = false
        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteState(.connected, forURL: base)
        }
        startDisconnectMonitor(for: client)

        // Reattach every chat that had a session. Within the ~20 s grace this
        // is the live fast path (inflight + pending approval replayed); later
        // it's a cold resume from the durable key.
        for (botID, chat) in chats {
            guard let stored = chat.storedSessionID else { continue }
            chat.sessionID = nil
            chat.isTyping = false
            if let live = try? await client.resumeSession(stored, profile: botID, deferHistory: true) {
                bindSession(live, botID: botID)
                replayInflight(live, botID: botID)
                replayPendingPrompts(live)
            }
        }

        try? await refreshRoster()
        try? await refreshRoutines()
        connections = ConnectionRegistry.shared.rows
        await flushComposeQueue()
    }

    // MARK: - Model / reasoning / YOLO controls (chat model strip)

    /// Switch the session model (live: config.set model, may defer mid-turn)
    /// and remember it as the bot's pin.
    public func setModel(botID: String, to modelID: String) {
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].pinnedModel = modelID
        }
        guard mode == .live else { return }
        Task { @MainActor in
            guard let client else { return }
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid else { return }
            try? await client.setSessionModel(sessionID: sid, model: modelID)
        }
    }

    /// Session reasoning effort ("none"/"low"/"medium"/"high").
    public func setReasoningEffort(botID: String, to effort: String) {
        chat(for: botID).reasoningEffort = effort
        guard mode == .live else { return }
        Task { @MainActor in
            guard let client else { return }
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid else { return }
            try? await client.setReasoningEffort(sessionID: sid, value: effort)
        }
    }

    /// Per-session YOLO toggle, wired through to the gateway when live.
    public func setYolo(botID: String, enabled: Bool) {
        chat(for: botID).yolo = enabled
        guard mode == .live else { return }
        Task { @MainActor in
            guard let client else { return }
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid else { return }
            try? await client.setYolo(sessionID: sid, enabled: enabled)
        }
    }

    // The flat `availableModels()` that used to live here is superseded by the
    // typed catalog in AppModelLive+Models.swift, which keeps the same
    // signature for the profile editor's fallback path.

    // MARK: - Offline queue

    /// Send everything composed while unreachable. The user bubbles were
    /// appended at compose time, so this goes straight to the RPC — calling
    /// send() again would duplicate them.
    public func flushComposeQueue() async {
        guard !composeQueue.isEmpty, mode == .live, !isOffline else { return }
        let queued = composeQueue
        composeQueue.removeAll()
        for item in queued {
            liveSend(text: item.text, botID: item.botID, chat: chat(for: item.botID))
        }
    }
}

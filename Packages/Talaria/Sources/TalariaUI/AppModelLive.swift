import Foundation
import TalariaKit

// Live-gateway side of AppModel: connect, route events into observable state,
// and back the shared actions with real RPCs. Demo mode never touches this.
//
// Protocol contract: .research/ws-protocol.md / auth-flows.md. Key behaviors:
// - profiles.list is the roster; cosmetics ride ui_meta["talaria"].
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
        if let old = client { await old.disconnect() }

        let client = GatewayClient(baseURL: baseURL, credential: credential)
        self.client = client
        runtime.baseURL = baseURL

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

        let registry = ConnectionRegistry.shared
        registry.upsert(urlString: baseURL.absoluteString, credential: credential)
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
        if let client { await client.disconnect() }
        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
        }
        runtime.baseURL = nil
        client = nil
        isOffline = false
        connections = ConnectionRegistry.shared.rows
    }

    /// Probe every saved gateway and sync the Connections rows.
    public func refreshConnections() async {
        await ConnectionRegistry.shared.probeAll()
        if mode == .live { connections = ConnectionRegistry.shared.rows }
    }

    // MARK: - Roster (profiles.list → bots)

    /// Map the gateway roster (profiles) into bots. Shape/hue cosmetics come
    /// from ui_meta["talaria"] when present, else a stable hash of the name.
    /// Status folds in live sessions and pending approvals; unread counts and
    /// task lines survive the refresh.
    public func refreshRoster() async throws {
        guard let client else { return }
        let profiles = try await client.listProfiles()
        let runtime = LiveRuntime.shared
        runtime.defaultBotID = profiles.first(where: \.isDefault)?.name ?? profiles.first?.name

        bots = profiles.map { profile in
            if let last = profile.lastSession?.id {
                runtime.lastSessionByBot[profile.name] = last
            }
            let existing = bots.first { $0.id == profile.name }
            var bot = Bot(
                id: profile.name,
                job: profile.description ?? "",
                shape: Self.derivedShape(for: profile),
                hue: Self.derivedHue(for: profile),
                status: .idle,
                task: existing?.task,
                minutesElapsed: existing?.minutesElapsed ?? 0,
                preview: profile.lastSession?.preview ?? existing?.preview ?? "Ready when you are.",
                previewTime: Self.shortTime(profile.lastSession?.lastActive),
                unread: existing?.unread ?? 0,
                mentionsYou: existing?.mentionsYou ?? false,
                description: profile.description,
                pinnedModel: profile.model)
            if approvals.contains(where: { $0.botID == bot.id }) { bot.status = .approval }
            if runtime.workingBotIDs.contains(bot.id) { bot.status = .working }
            return bot
        }

        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteBotCount(bots.count, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
    }

    static func derivedShape(for profile: HermesProfile) -> AvatarShape {
        if let raw = profile.uiMeta?["talaria"]?["shape"]?.stringValue,
           let shape = AvatarShape(rawValue: raw) { return shape }
        let cases = AvatarShape.allCases
        return cases[(stableHash(profile.name) & Int.max) % cases.count]
    }

    static func derivedHue(for profile: HermesProfile) -> AvatarHue {
        if let raw = profile.uiMeta?["talaria"]?["hue"]?.stringValue,
           let hue = AvatarHue(rawValue: raw) { return hue }
        // .gateway is reserved for gateway-originated feed items.
        let cases: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]
        return cases[(stableHash(profile.name + "hue") & Int.max) % cases.count]
    }

    /// Deterministic across launches (String.hashValue is seeded per-process).
    static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return h
    }

    static func shortTime(_ unix: Double?) -> String {
        guard let unix, unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: unix)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE"
        return f.string(from: date)
    }

    // MARK: - Opening a chat (resume latest session + hydrate history)

    /// Navigate into a bot's chat. Live mode resumes the profile's most
    /// recent stored session with deferred history, then hydrates the
    /// transcript over REST (GET /api/sessions/{id}/messages).
    public func openChat(botID: String) {
        openBotID = botID
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].unread = 0
            bots[idx].mentionsYou = false
        }
        guard mode == .live, !isOffline else { return }
        guard chat(for: botID).sessionID == nil else { return }
        Task { @MainActor in
            _ = try? await self.ensureSession(botID: botID, hydrate: true)
        }
    }

    /// Create-or-resume the bot's session and bind it to the chat. Coalesces
    /// concurrent callers (openChat racing a send) onto one attach.
    func ensureSession(botID: String, hydrate: Bool) async throws -> String {
        let runtime = LiveRuntime.shared
        let chat = chat(for: botID)
        if let sid = chat.sessionID { return sid }
        if let pending = runtime.attachTasks[botID] { return try await pending.value }
        guard let client else { throw GatewayError(code: -3, message: "not connected") }

        let stored = chat.storedSessionID ?? runtime.lastSessionByBot[botID]
        let task = Task<String, Error> { @MainActor in
            var live: LiveSession
            var resumed = false
            if let stored {
                do {
                    // Full projection in the resume ack (deferHistory returns a
                    // bounded stub and leaves history to a REST shape that has
                    // proven flaky) — one round trip, authoritative rows.
                    live = try await client.resumeSession(stored, profile: botID, deferHistory: false)
                    resumed = true
                } catch let error as GatewayError where error.code == GatewayError.sessionNotFound {
                    live = try await client.createSession(profile: botID)
                }
            } else {
                live = try await client.createSession(profile: botID)
            }
            guard !live.sessionID.isEmpty else {
                throw GatewayError(code: -8, message: "session create/resume returned no id")
            }
            self.bindSession(live, botID: botID)
            if hydrate, resumed {
                await self.hydrateTranscript(live, botID: botID)
            }
            self.replayInflight(live, botID: botID)
            if let pending = live.pendingApproval { self.ingest(pending) }
            return live.sessionID
        }
        runtime.attachTasks[botID] = task
        defer { runtime.attachTasks[botID] = nil }
        return try await task.value
    }

    private func bindSession(_ live: LiveSession, botID: String) {
        let chat = chat(for: botID)
        chat.sessionID = live.sessionID
        if !live.storedSessionID.isEmpty { chat.storedSessionID = live.storedSessionID }
        LiveRuntime.shared.sessionToBot[live.sessionID] = botID
        if live.running {
            setWorking(botID, true)
            chat.isTyping = true
        }
    }

    /// Replace local history with the stored transcript. REST hydration first
    /// (defer_history contract), falling back to the projection rows the
    /// resume ack carried.
    private func hydrateTranscript(_ live: LiveSession, botID: String) async {
        // The resume ack's projection is the known-good shape; REST is only a
        // fallback for resumes that omitted messages.
        var history = Self.chatMessages(fromTranscript: .array(live.messages))
        if history.isEmpty, !live.storedSessionID.isEmpty, let client,
           let payload = try? await client.fetchSessionMessages(storedID: live.storedSessionID) {
            history = Self.chatMessages(fromTranscript: payload)
        }
        guard !history.isEmpty else { return }
        chat(for: botID).messages = history
    }

    /// Map transcript projection rows (server.py:_history_to_messages shape:
    /// {role, text, timestamp?, display_kind?} + tool rows {role:"tool",…})
    /// to chat messages. Hidden scaffolding and tool rows are dropped.
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
            let text = row["text"]?.stringValue ?? ""
            guard !text.isEmpty else { return nil }
            let time = row["timestamp"]?.doubleValue.map { shortTime($0) }
            let reasoning = row["reasoning"]?.stringValue
                ?? row["reasoning_content"]?.stringValue
            switch row["role"]?.stringValue {
            case "user": return ChatMessage(author: .user, time: time, text: text)
            case "assistant": return ChatMessage(author: .bot, time: time, text: text,
                                                 reasoning: reasoning)
            case "system": return ChatMessage(author: .system, time: time, text: text)
            default: return nil
            }
        }
    }

    /// Replay a reconnect/resume inflight snapshot ({user, assistant,
    /// streaming, error?}) into the chat so a dropped socket loses nothing.
    private func replayInflight(_ live: LiveSession, botID: String) {
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
                if let pending = live.pendingApproval { ingest(pending) }
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

    /// Model ids offered by the gateway (model.options), demo list otherwise.
    /// Defensive parse: the picker payload nests models under providers.
    public func availableModels() async -> [String] {
        guard mode == .live, let client else { return DemoData.models }
        guard let payload = try? await client.modelOptions() else { return DemoData.models }
        var ids: [String] = []
        func harvest(_ value: JSONValue) {
            if let arr = value.arrayValue {
                for item in arr { harvest(item) }
            } else if let obj = value.objectValue {
                if let id = (obj["id"] ?? obj["model"] ?? obj["name"])?.stringValue,
                   obj["models"] == nil, ids.count < 200 {
                    ids.append(id)
                }
                for key in ["providers", "models", "groups", "items"] {
                    if let nested = obj[key] { harvest(nested) }
                }
            }
        }
        harvest(payload)
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        return unique.isEmpty ? DemoData.models : unique
    }

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

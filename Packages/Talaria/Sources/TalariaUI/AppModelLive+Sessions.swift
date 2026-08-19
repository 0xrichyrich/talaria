import Foundation
import TalariaKit
import TalariaTheme

// The live sessions area: the bot's stored-session list, the context
// breakdown, opening a stored session in chat, the row actions (rename,
// delete), the turn controls (branch, compress, export) and cross-session
// search.
//
// Two ids matter throughout and must never be mixed up (ws-protocol.md §5,
// §7.3): the RUNTIME sid (8 hex, routes events, addresses live-session RPCs)
// and the DURABLE key (`stored_session_id` / `session_key`, addresses the DB
// row and survives reconnects). Session lists, resume, delete and the
// session.title EVENT all speak the durable key; branch/compress/save and the
// session.title RPC all speak the runtime sid.

/// Side table for the sessions area. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so the
/// per-session extras Talaria's shared models don't carry ride here.
@MainActor
final class SessionsRuntime {
    static let shared = SessionsRuntime()

    /// Durable key → freshest title. The session.title event can land before
    /// (or after) any list fetch, so it is kept as an overlay and re-applied
    /// on every refresh instead of being lost between them.
    var titles: [String: String] = [:]
    /// Durable key → preview line. `SessionSummary` has no preview field and
    /// is shared with other screens, so the sheet reads previews from here.
    var previews: [String: String] = [:]
    /// bot id → why the last list fetch failed (nil once one succeeds).
    var loadErrors: [String: String] = [:]

    /// The extra event handler behind `attachSessionEventRouter()`, and the
    /// client it is registered on. A reconnect re-dials the transport but
    /// keeps the same `GatewayClient` (and its handler table); only a new
    /// gateway link needs re-arming, which is what this identity check buys.
    var handlerID: UUID?
    weak var attachedClient: GatewayClient?
    var routerTask: Task<Void, Never>?
    /// Debounce for the `sessions.changed` broadcast.
    var refreshTask: Task<Void, Never>?

    func reset() {
        titles.removeAll()
        previews.removeAll()
        loadErrors.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }
}

/// The result of a session action, ready to render as one themed line plus an
/// optional detail line.
public struct SessionActionOutcome: Sendable, Equatable {
    public var ok: Bool
    public var headline: String
    public var detail: String?

    public init(ok: Bool, headline: String, detail: String? = nil) {
        self.ok = ok; self.headline = headline; self.detail = detail
    }
}

extension AppModel {

    // MARK: - Listing

    /// Load this bot's stored sessions (session.list {limit:200, profile,
    /// include_hidden}) into `ChatState.storedSessions`. Demo mode serves the
    /// canned index so the sheet is never empty in the App Review walkthrough.
    ///
    /// `include_hidden` because this is the per-bot browser — the one surface
    /// that OWNS hidden sessions, which is exactly the case upstream carves
    /// the flag out for (methods_session.py:180-186; desktop's Bots pane does
    /// the same). Bot Mode sessions, the canonical forever-chat among them,
    /// are always hidden; without the flag a bot's own chat is missing from
    /// its own session list.
    public func refreshSessions(botID: String) async {
        let runtime = SessionsRuntime.shared
        guard mode == .live else {
            chat(for: botID).storedSessions = sessions[botID] ?? sessions["default"] ?? []
            runtime.loadErrors[botID] = nil
            return
        }
        guard let client, !isOffline else {
            runtime.loadErrors[botID] = theme.copy.sessUnreachable(theme.themeID)
            return
        }
        do {
            let rows = try await client.listSessions(limit: 200, profile: botID,
                                                     includeHidden: true)
            var summaries: [SessionSummary] = []
            summaries.reserveCapacity(rows.count)
            for row in rows where !row.id.isEmpty {
                let preview = (row.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if preview.isEmpty {
                    runtime.previews[row.id] = nil
                } else {
                    runtime.previews[row.id] = preview
                }
                // The event overlay wins: an auto-title that landed since the
                // list was built is newer than the row we just fetched.
                let title = runtime.titles[row.id]
                    ?? (row.title.isEmpty
                        ? GatewayClient.fallbackTitle(id: row.id, preview: preview)
                        : row.title)
                summaries.append(SessionSummary(id: row.id, title: title,
                                                when: SessionClock.stamp(row.startedAt),
                                                messageCount: row.messageCount))
            }
            chat(for: botID).storedSessions = summaries
            // The bot sheet's "Recent sessions" group reads `sessions[botID]`
            // (the demo-shaped index) — keep both in step so it goes live too.
            sessions[botID] = summaries
            runtime.loadErrors[botID] = nil
        } catch {
            runtime.loadErrors[botID] = Self.sessionFailure(error, theme: theme)
        }
    }

    /// Why the last `refreshSessions` failed, in the current theme's voice.
    public func sessionsLoadError(for botID: String) -> String? {
        SessionsRuntime.shared.loadErrors[botID]
    }

    /// The stored session's first transcript line, when session.list carried
    /// one. Session rows show it under the title.
    public func sessionPreview(_ sessionID: String) -> String? {
        SessionsRuntime.shared.previews[sessionID]
    }

    // MARK: - Context breakdown

    /// session.context_breakdown → `ChatState.contextSegments`. Deliberately
    /// does NOT mint a session: opening a bot sheet to look at it must not
    /// create a conversation, so a bot with no live session simply reports
    /// nothing to measure.
    public func refreshContext(botID: String) async {
        guard mode == .live else {
            chat(for: botID).contextSegments = contextMeter
            return
        }
        guard let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route),
              let sid = chats[botID]?.sessionID else {
            chat(for: botID).contextSegments = []
            return
        }
        guard let segments = try? await client.contextBreakdown(sid) else { return }
        chat(for: botID).contextSegments = segments
        // The bot sheet's meter reads the global `contextMeter`; it only ever
        // shows the bot whose sheet is open, so mirroring is correct.
        contextMeter = segments
    }

    // MARK: - Opening a stored session

    /// Rebind this bot's chat onto a stored session (session.resume by
    /// durable key) and hydrate its transcript. Mirrors `openChat` but for a
    /// session the user picked instead of the profile's most recent one.
    public func openStoredSession(_ id: String, botID: String) {
        guard !id.isEmpty else { return }
        openBotID = botID
        selectedTab = .home
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].unread = 0
            bots[idx].mentionsYou = false
        }
        // Same rule as `openChat`: this is a route into the bot's chat, so the
        // durable mark moves with the badge it just cleared.
        noteChatOpened(botID)

        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        guard mode == .live else { return }

        // Unbind first: a send racing this must not land in the session we
        // are leaving, and an in-flight attach for the old session is stale.
        runtime.attachTasks[botID]?.cancel()
        runtime.attachTasks[botID] = nil
        if let old = chat.sessionID { runtime.sessionToBot.removeValue(forKey: old) }
        chat.sessionID = nil
        chat.storedSessionID = id
        chat.isTyping = false
        chat.usage = nil
        chat.contextSegments = []
        chat.messages = []
        // The durable key is also what a reconnect resumes from.
        runtime.lastSessionByBot[botID] = id

        guard !isOffline, let client else { return }
        Task { @MainActor in
            do {
                // Full projection in the ack (deferHistory returns a bounded
                // stub) — one round trip, authoritative rows, same tradeoff
                // ensureSession makes.
                let live = try await client.resumeSession(id, profile: botID, deferHistory: false)
                guard !live.sessionID.isEmpty else {
                    throw GatewayError(code: -8, message: "session.resume returned no id")
                }
                chat.sessionID = live.sessionID
                chat.storedSessionID = live.storedSessionID.isEmpty ? id : live.storedSessionID
                runtime.sessionToBot[live.sessionID] = botID
                runtime.lastSessionByBot[botID] = chat.storedSessionID ?? id

                var history = AppModel.chatMessages(fromTranscript: .array(live.messages))
                if history.isEmpty, let stored = chat.storedSessionID,
                   let payload = try? await client.latestSessionMessages(storedID: stored,
                                                                         profile: botID) {
                    history = AppModel.chatMessages(fromTranscript: payload)
                }
                chat.messages = history

                if live.running {
                    chat.isTyping = true
                    runtime.workingBotIDs.insert(botID)
                    if let idx = self.bots.firstIndex(where: { $0.id == botID }) {
                        self.bots[idx].status = .working
                    }
                }
                // Same replay every other resume path uses: the approval keeps
                // its real choice set, and a parked clarify is recovered too.
                self.replayPendingPrompts(live)
                await self.refreshContext(botID: botID)
            } catch {
                chat.messages.append(ChatMessage(
                    author: .system, text: Self.sessionFailure(error, theme: self.theme)))
                // …and out loud (plugin.js:6782 `notifyError(err, 'Could not
                // open session')`). The system row above is the durable record,
                // but this tap came from a sheet that has just dismissed onto an
                // empty chat, and a blank screen with an explanation somewhere
                // below the fold reads as the app having done nothing at all.
                self.toast(kind: .failure,
                           title: self.theme.copy.toastOpenSessionFailed(self.theme.themeID),
                           message: Self.reason(error), botID: botID)
            }
        }
    }

    // MARK: - Row actions

    /// Delete a stored session. Returns nil on success, else a themed reason.
    /// The gateway answers **4023** for a session it still holds live — that
    /// is a real state the user has to resolve, not a bug.
    public func deleteStoredSession(_ id: String, botID: String) async -> String? {
        guard mode == .live else {
            dropSessionRow(id, botID: botID)
            return nil
        }
        guard let client, !isOffline else { return theme.copy.sessUnreachable(theme.themeID) }
        do {
            try await client.deleteSession(id, profile: botID)
        } catch let error as GatewayError where error.code == 4023 {
            return theme.copy.sessDeleteLive(theme.themeID)
        } catch let error as GatewayError where error.code == 4007 {
            // Already gone — the desktop treats an absent row as success and
            // so must we, or the row resurrects on the next refresh.
            dropSessionRow(id, botID: botID)
            return nil
        } catch {
            return Self.sessionFailure(error, theme: theme)
        }
        dropSessionRow(id, botID: botID)
        return nil
    }

    /// Rename a session. A live session goes over session.title (which
    /// re-emits session.info so every strip resyncs); a stored one goes over
    /// PATCH /api/sessions/{id}, the only path that resolves durable keys.
    /// Returns nil on success, else a themed reason.
    public func renameStoredSession(_ id: String, botID: String, to title: String) async -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return theme.copy.sessRenameEmpty(theme.themeID) }
        guard mode == .live else {
            applyTitle(clean, to: id, botID: botID)
            return nil
        }
        guard let client, !isOffline else { return theme.copy.sessUnreachable(theme.themeID) }
        let chat = chats[botID]
        do {
            if let sid = chat?.sessionID, chat?.storedSessionID == id {
                try await client.setSessionTitle(sessionID: sid, title: clean)
            } else {
                try await client.renameStoredSession(id, title: clean, profile: botID)
            }
        } catch {
            return Self.sessionFailure(error, theme: theme)
        }
        applyTitle(clean, to: id, botID: botID)
        return nil
    }

    // MARK: - Turn controls (branch / compress / export)

    /// Fork the bot's current session. The fork is persisted with the
    /// parent's lineage and appears in the list; it is deliberately NOT
    /// opened, so the conversation the user is reading never changes under
    /// them.
    public func branchSession(botID: String) async -> SessionActionOutcome {
        guard let sid = await liveSessionID(botID: botID) else { return needsLiveSession }
        guard let client else { return needsLiveSession }
        do {
            let branch = try await client.branchSession(sid)
            await refreshSessions(botID: botID)
            return SessionActionOutcome(
                ok: true,
                headline: theme.copy.sessBranched(theme.themeID),
                detail: branch.title.isEmpty ? nil : branch.title)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// Manual compaction, with the gateway's own before/after summary. The
    /// compacted transcript replaces the local one, matching desktop.
    public func compressSession(botID: String) async -> SessionActionOutcome {
        guard let sid = await liveSessionID(botID: botID) else { return needsLiveSession }
        guard let client else { return needsLiveSession }
        do {
            let result = try await client.compressSession(sid)
            if !result.messages.isEmpty {
                let rebuilt = Self.chatMessages(fromTranscript: .array(result.messages))
                if !rebuilt.isEmpty { chat(for: botID).messages = rebuilt }
            }
            await refreshContext(botID: botID)
            var detail = result.tokenLine
            if let note = result.note, !note.isEmpty {
                detail = detail.isEmpty ? note : detail + "\n" + note
            }
            return SessionActionOutcome(ok: result.outcome != .aborted,
                                        headline: result.headline,
                                        detail: detail.isEmpty ? nil : detail)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// session.save — a JSON snapshot written on the GATEWAY host, not the
    /// phone. The path is the whole result, so it is what we show.
    public func exportSession(botID: String) async -> SessionActionOutcome {
        guard let sid = await liveSessionID(botID: botID) else { return needsLiveSession }
        guard let client else { return needsLiveSession }
        do {
            let path = try await client.saveSession(sid)
            return SessionActionOutcome(ok: true,
                                        headline: theme.copy.sessExported(theme.themeID),
                                        detail: path.isEmpty ? nil : path)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// branch/compress/save all resolve runtime sids, so they need a session
    /// this process holds live. These are explicit user actions, so minting
    /// one when the chat was never opened is the right call.
    private func liveSessionID(botID: String) async -> String? {
        guard mode == .live, !isOffline, client != nil else { return nil }
        if let sid = chats[botID]?.sessionID { return sid }
        return try? await ensureSession(botID: botID, hydrate: false)
    }

    private var needsLiveSession: SessionActionOutcome {
        SessionActionOutcome(ok: false, headline: theme.copy.sessNoLiveSession(theme.themeID))
    }

    // MARK: - Cross-session search

    /// Full-text search over every bot's sessions. Each profile owns its own
    /// state.db (web_server.py:_open_session_db_for_profile), so this is a
    /// fan-out — one GET /api/sessions/search per roster entry, merged newest
    /// first. Consumed by the search palette.
    public func searchSessions(_ query: String) async -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard mode == .live, !isOffline, let client else { return demoSearch(trimmed) }
        let profiles = bots.map(\.id)
        guard !profiles.isEmpty else { return [] }
        var merged: [SessionSearchHit] = []
        await withTaskGroup(of: [SessionSearchHit].self) { group in
            for profile in profiles {
                group.addTask {
                    ((try? await client.searchSessions(query: trimmed, profile: profile, limit: 8))
                        ?? []).map { hit in
                            var tagged = hit
                            tagged.botID = profile
                            return tagged
                        }
                }
            }
            for await batch in group { merged.append(contentsOf: batch) }
        }
        var seen = Set<String>()
        return merged
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.lastActive > $1.lastActive }
    }

    /// The same search scoped to one bot — the sessions sheet's filter falls
    /// through to it so a phrase from inside a conversation finds it.
    public func searchSessions(_ query: String, botID: String) async -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard mode == .live, !isOffline, let client else {
            return demoSearch(trimmed).filter { $0.botID == botID }
        }
        guard let hits = try? await client.searchSessions(query: trimmed, profile: botID, limit: 20)
        else { return [] }
        return hits.map { hit in
            var tagged = hit
            tagged.botID = botID
            return tagged
        }
    }

    /// Demo mode has no gateway index; the canned session titles are the
    /// whole world, so filter those.
    private func demoSearch(_ query: String) -> [SessionSearchHit] {
        let needle = query.lowercased()
        return sessions
            .filter { $0.key != "default" }
            .sorted { $0.key < $1.key }
            .flatMap { botID, list in
                list.filter { $0.title.lowercased().contains(needle) }
                    .map { SessionSearchHit(sessionID: $0.id, botID: botID, title: $0.title,
                                            snippet: "", when: $0.when, lastActive: 0) }
            }
    }

    // MARK: - session.title event + router

    /// The auto-title lands as a `session.title` event whose payload
    /// `session_id` is the DURABLE key (the envelope's is the runtime sid —
    /// ws-protocol.md §5.3). Patches every list showing that row and keeps an
    /// overlay so a later refresh cannot regress to the untitled row.
    public func applySessionTitle(_ event: GatewayEvent) {
        guard event.type == "session.title" else { return }
        let stored = event.payload?["session_id"]?.stringValue ?? ""
        let title = (event.payload?["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty, !title.isEmpty else { return }
        SessionsRuntime.shared.titles[stored] = title

        var patched = false
        for (botID, chat) in chats {
            guard let idx = chat.storedSessions.firstIndex(where: { $0.id == stored }) else { continue }
            chat.storedSessions[idx].title = title
            if var list = sessions[botID], let row = list.firstIndex(where: { $0.id == stored }) {
                list[row].title = title
                sessions[botID] = list
            }
            patched = true
        }
        guard !patched else { return }
        // A first-turn auto-title arrives before any list holds that row. Pull
        // the owning bot's list so the freshly named session shows up.
        let owner = botID(forSession: event.sessionID)
            ?? chats.first { $0.value.storedSessionID == stored }?.key
        guard let owner else { return }
        Task { @MainActor in await self.refreshSessions(botID: owner) }
    }

    /// Register the sessions-area event handler on the live client. The main
    /// pump in AppModelLive drops `session.title`, so this adds a second
    /// handler rather than contending for that switch. Idempotent; call after
    /// `connectGateway`.
    public func attachSessionEventRouter() {
        guard mode == .live, let client else { return }
        let runtime = SessionsRuntime.shared
        if runtime.routerTask != nil, runtime.attachedClient === client { return }
        detachSessionEventRouter()
        runtime.attachedClient = client
        // One AsyncStream so MainActor delivery preserves wire order, same
        // shape as the main event pump.
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        runtime.routerTask = Task { @MainActor [weak self] in
            for await event in stream { self?.routeSessionEvent(event) }
        }
        Task {
            let id = await client.addEventHandler { continuation.yield($0) }
            await MainActor.run { SessionsRuntime.shared.handlerID = id }
        }
    }

    /// Drop the sessions-area handler (gateway swap / sign-out). The cached
    /// titles and previews go with it — they belong to that gateway's store.
    public func detachSessionEventRouter() {
        let runtime = SessionsRuntime.shared
        runtime.routerTask?.cancel()
        runtime.routerTask = nil
        runtime.reset()
        if let id = runtime.handlerID, let target = runtime.attachedClient {
            Task { await target.removeEventHandler(id) }
        }
        runtime.handlerID = nil
        runtime.attachedClient = nil
    }

    private func routeSessionEvent(_ event: GatewayEvent) {
        switch event.type {
        case "session.title":
            applySessionTitle(event)
        case "sessions.changed":
            // Global broadcast, already floored at 2 s server-side. Only the
            // open bot's list is on screen, so refresh that one — and debounce
            // it, because a busy turn can trip the broadcast repeatedly.
            guard let botID = openBotID else { return }
            let runtime = SessionsRuntime.shared
            runtime.refreshTask?.cancel()
            runtime.refreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await self?.refreshSessions(botID: botID)
            }
        default:
            break
        }
    }

    // MARK: - Local list maintenance

    private func dropSessionRow(_ id: String, botID: String) {
        let runtime = SessionsRuntime.shared
        runtime.titles[id] = nil
        runtime.previews[id] = nil
        if let chat = chats[botID] {
            chat.storedSessions.removeAll { $0.id == id }
            // The deleted row was this chat's binding: forget it so the next
            // open creates a fresh session instead of resuming a dead key.
            if chat.storedSessionID == id {
                chat.storedSessionID = nil
                if let sid = chat.sessionID { LiveRuntime.shared.sessionToBot.removeValue(forKey: sid) }
                chat.sessionID = nil
                chat.messages = []
                chat.isTyping = false
            }
        }
        sessions[botID]?.removeAll { $0.id == id }
        if LiveRuntime.shared.lastSessionByBot[botID] == id {
            LiveRuntime.shared.lastSessionByBot[botID] = nil
        }
    }

    private func applyTitle(_ title: String, to id: String, botID: String) {
        SessionsRuntime.shared.titles[id] = title
        if let chat = chats[botID], let idx = chat.storedSessions.firstIndex(where: { $0.id == id }) {
            chat.storedSessions[idx].title = title
        }
        if var list = sessions[botID], let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].title = title
            sessions[botID] = list
        }
    }

    /// One themed line for any failure the sessions area can hit. Transport
    /// codes read as a dropped link; everything else keeps the gateway's own
    /// message, which is written for humans.
    static func sessionFailure(_ error: Error, theme: ThemeManager) -> String {
        guard let gateway = error as? GatewayError else {
            return theme.copy.sessFailed(theme.themeID)
        }
        if gateway.code <= -1, gateway.code >= -9 {
            return theme.copy.sessUnreachable(theme.themeID)
        }
        return gateway.message.isEmpty ? theme.copy.sessFailed(theme.themeID) : gateway.message
    }
}

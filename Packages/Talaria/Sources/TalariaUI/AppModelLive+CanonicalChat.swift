import Foundation
import TalariaKit

// ── The canonical forever-chat ───────────────────────────────────────────────
//
// "Each bot has exactly one chat, forever." Its stored-session id is pinned in
// the profile's SERVER-side ui_meta["hermes-bots"].chat, so the pin follows the
// profile between machines, and opening a bot ALWAYS lands there. It is never
// re-derived from recency: recency drifts the moment the profile is touched
// from the CLI, from Sessions mode, or by a cronjob, and the user's
// relationship with the bot would silently move into a scratch conversation
// they never opened (plugin.js:2726-2738, BOT-MODE-PARITY §canonical-chat).
//
// Ported from apps/desktop/src/plugins/hermes-bots/plugin.js:
//   openBotCanonicalChat  2802-2896  resolution order, verification, recovery
//   createCanonicalChat   2744-2800  birth: canonical title, pin immediately
//   saveBotMeta            201-270   whole-block write, three-valued outcome
//   mergeServerMeta        432-482   server block authoritative; an omitted
//                                    `chat` key is an authoritative deletion
//
// Gateway contract cited inline from tui_gateway/methods_session.py,
// tui_gateway/methods_profiles.py and hermes_cli/web_routers/sessions.py.

// MARK: - Runtime (side table)

/// Canonical-chat bookkeeping. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like `LiveRuntime` does.
@MainActor
final class CanonicalChatRuntime {
    static let shared = CanonicalChatRuntime()

    /// bot id → the stored-session id of its forever chat. Seeded from the
    /// server block on every roster poll (`refreshRoster`) and updated when a
    /// chat is adopted or minted here. Desktop keeps the same value in its
    /// plugin-local store so the pin survives a gateway that cannot persist it
    /// (plugin.js:205-212).
    var pins: [String: String] = [:]

    /// Bots with a pin write in flight. A roster poll that races the write
    /// still carries the OLD block, and mergeServerMeta's deletion rule would
    /// read the missing key as an authoritative clear of the pin just made.
    var writing: Set<String> = []

    /// Local pin writes per bot, counted. `writing` alone cannot close the
    /// race: a poll dispatched BEFORE a pin write and answered after it
    /// completes finds `writing` already empty, and its stale block — which
    /// has no `chat` key yet — reads as an authoritative deletion of the pin
    /// just made. Minting a chat fires `sessions.changed`, which itself
    /// triggers `refreshRoster` (AppModelLive.swift), so that ordering is the
    /// common one, not a corner case. Comparing this counter across the poll's
    /// own await tells a stale answer from a current one.
    var writeCount: [String: Int] = [:]

    /// One resolution per bot at a time — a double tap must not mint two
    /// canonical chats (plugin.js:2742, `canonicalCreations`).
    var opens: [String: Task<Void, Never>] = [:]

    /// True when `pins[botID]` is newer than a roster answer taken at
    /// `sampled`, and the server block must not be allowed to overwrite it.
    func hasLocalPinWrite(_ botID: String, since sampled: [String: Int]) -> Bool {
        writing.contains(botID) || writeCount[botID] != sampled[botID]
    }

    /// Clear bare ids owned by the primary gateway while retaining qualified
    /// remote chats whose clients remain connected.
    func resetPrimaryScope() {
        let primary = pins.keys.filter { GatewayBotRoute(qualifiedID: $0) == nil }
        for key in primary { pins.removeValue(forKey: key) }
        writing = Set(writing.filter { GatewayBotRoute(qualifiedID: $0) != nil })
        writeCount = writeCount.filter { GatewayBotRoute(qualifiedID: $0.key) != nil }
        let primaryOpens = opens.filter { GatewayBotRoute(qualifiedID: $0.key) == nil }
        for task in primaryOpens.values { task.cancel() }
        for key in primaryOpens.keys { opens.removeValue(forKey: key) }
    }

    func resetRoutedScope(gatewayID: String) {
        let prefix = gatewayID + GatewayBotRoute.separator
        let keys = pins.keys.filter { $0.hasPrefix(prefix) }
        for key in keys { pins.removeValue(forKey: key) }
        writing = Set(writing.filter { !$0.hasPrefix(prefix) })
        writeCount = writeCount.filter { !$0.key.hasPrefix(prefix) }
        let tasks = opens.filter { $0.key.hasPrefix(prefix) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys { opens.removeValue(forKey: key) }
    }
}

extension GatewayError {
    /// `session.resume` answers **4007** for a durable key with no DB row
    /// (methods_session.py:367) — the definitive "this conversation is gone".
    /// Distinct from 4001 (`sessionNotFound`), which upstream uses for "no
    /// live session" on the runtime-sid RPCs (methods_tools.py:607).
    static let storedSessionGone = 4007
}

// MARK: - Resolution

/// What one resume attempt settled on.
private enum CanonicalAttach {
    case attached(sessionID: String, storedID: String)
    /// The gateway is certain the row does not exist (4007).
    case missing
    /// Anything else — transport, backend restart, an older gateway. The pin
    /// is innocent until proven guilty (plugin.js:2864-2871).
    case failed(Error)
}

extension AppModel {

    /// Desktop titles every canonical chat "Bot Chat" (plugin.js:2757). The
    /// title is load-bearing, not decoration: `session.resume` falls back to an
    /// exact title lookup when the id misses (methods_session.py:349-352 →
    /// hermes_state.py:8468), so this is how a phone finds a forever chat
    /// minted on the laptop when the pin never reached it — and why it can
    /// never mint a second one alongside it.
    static var canonicalChatTitle: String { "Bot Chat" }

    // MARK: The primary tap

    /// Land in the bot's forever chat, whatever the chat was last bound to.
    /// An artifact/inbox/sessions-sheet jump leaves a scratch session behind;
    /// desktop's roster row still opens the pin (plugin.js:2726-2738), so the
    /// primary tap re-resolves rather than resuming whatever is bound.
    func enterCanonicalChat(botID: String) async {
        guard mode == .live,
              !isOffline || GatewayBotRoute(qualifiedID: botID) != nil else { return }
        let runtime = CanonicalChatRuntime.shared

        // Coalesce: a double tap, or a tap racing a deep link, must resolve
        // once (plugin.js:2742).
        if let inflight = runtime.opens[botID] {
            await inflight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // A send that beat the tap owns an attach. Let it settle before
            // touching the binding, so the rebind below cannot be undone by a
            // task that is already resolving.
            if let pending = LiveRuntime.shared.attachTasks[botID] { _ = try? await pending.value }

            let chat = self.chat(for: botID)
            let canonical = CanonicalChatRuntime.shared.pins[botID]
            // Already there with a live binding — nothing to resolve.
            if chat.storedSessionID == canonical, chat.sessionID != nil { return }
            if chat.storedSessionID != nil, chat.storedSessionID != canonical {
                // Drop the scratch binding: the resolver honors an explicit
                // binding, and this tap is explicitly asking for the forever
                // chat instead.
                self.unbindChat(botID: botID)
            }
            do {
                _ = try await self.ensureSession(botID: botID, hydrate: true)
                await self.refreshContext(botID: botID)
            } catch is CancellationError {
                // Superseded by another attach; that one owns the outcome.
            } catch {
                self.reportCanonicalFailure(error, botID: botID)
            }
        }
        runtime.opens[botID] = task
        // Released in a defer, and only if the slot is still ours: a tap that
        // arrived between this task finishing and the slot being cleared would
        // otherwise await an already-finished resolution and return having
        // done nothing, leaving that tap on whatever chat was bound.
        defer { if runtime.opens[botID] == task { runtime.opens[botID] = nil } }
        await task.value
    }

    /// Resolve and attach the session a send/open should land in, in desktop's
    /// order: the explicit binding, the pin, the canonical title, the
    /// previewed session, then birth. Returns the live runtime sid.
    ///
    /// `ensureSession` funnels every create/resume through here, so a message
    /// typed before the chat finished opening lands in the forever chat rather
    /// than forking a fresh session — the failure this phase exists to fix.
    func attachCanonicalSession(botID: String, route: GatewayBotRoute,
                                client: GatewayClient, hydrate: Bool) async throws -> String {
        let chat = chat(for: botID)
        let runtime = CanonicalChatRuntime.shared
        let profile = route.profile

        // An explicit binding wins: the user named this conversation (sessions
        // sheet, artifact jump, inbox jump), or a reconnect is re-attaching it.
        if let bound = chat.storedSessionID, !bound.isEmpty {
            switch await attach(bound, botID: botID, route: route,
                                hydrate: hydrate, client: client) {
            case .attached(let sid, _): return sid
            case .missing: break            // vanished under us — re-resolve
            case .failed(let error): throw error
            }
        }

        // (a) The pin. `session.resume` IS the precise verification desktop
        //     performs up front through profiles.list {preferred_session_ids}
        //     (plugin.js:2841-2855): it reads the row directly — hidden rows
        //     resolve — and follows a compression lineage to its live tip
        //     (methods_session.py:346-380). One round trip instead of two, and
        //     the answer describes the exact operation we care about.
        if let pin = runtime.pins[botID], !pin.isEmpty, pin != chat.storedSessionID {
            switch await attach(pin, botID: botID, route: route,
                                hydrate: hydrate, client: client) {
            case .attached(let sid, _): return sid
            case .missing: break            // definitively gone → recover below
            case .failed(let error): throw error
            }
        }

        // (b) The canonical title. Only Bot Mode names a session "Bot Chat",
        //     so an exact title hit IS this bot's forever chat — the plugin's
        //     own recovery rule, "re-pin the newest session carrying the
        //     canonical title" (plugin.js:2735-2737). Ahead of the previewed
        //     session deliberately: adopting whatever ran last would let a
        //     cron delivery become the forever chat, which is the hijack the
        //     pin exists to prevent.
        switch await attach(Self.canonicalChatTitle, botID: botID, route: route,
                            hydrate: hydrate, client: client) {
        case .attached(let sid, let stored):
            await pinCanonicalChat(stored, botID: botID)
            return sid
        case .missing: break
        case .failed(let error): throw error
        }

        // (c) Grandfather. First open of a bot that already has history adopts
        //     the session the roster row was previewing, so continuity starts
        //     from the chat in use rather than an empty one
        //     (plugin.js:2822-2836; the row must open the session its preview
        //     describes — hermes-agent#88200). This is also the migration path
        //     for a profile that predates Bot Mode: its existing conversation
        //     becomes the forever chat instead of being orphaned.
        var candidates: [String] = []
        if let previewed = LiveRuntime.shared.lastSessionByBot[botID], !previewed.isEmpty {
            candidates.append(previewed)
        }
        // profiles.list's `last_session` is best-effort and degrades to null on
        // a busy or locked state.db (methods_profiles.py:_latest_profile_session_row).
        // Birth must never be reached for a bot that HAS history — that is the
        // fork this phase exists to prevent — so confirm emptiness against
        // session.list, which reads the same store through a different query
        // and returns newest-first (methods_session.py:186-200).
        //
        // `include_hidden` is required, not incidental: Bot Mode sessions are
        // always hidden and session.list excludes them by default
        // (methods_session.py:180-186), so without it this "does the bot have
        // history?" probe reads a desktop-born forever chat as no history at
        // all — and answers by minting a second one.
        if let newest = (try? await client.listSessions(limit: 20, profile: profile,
                                                        includeHidden: true))?
            .first(where: { !$0.id.isEmpty })?.id, !candidates.contains(newest) {
            candidates.append(newest)
        }
        for candidate in candidates {
            switch await attach(candidate, botID: botID, route: route,
                                hydrate: hydrate, client: client) {
            case .attached(let sid, let stored):
                await pinCanonicalChat(stored, botID: botID)
                return sid
            case .missing:
                continue
            case .failed(let error):
                // Desktop falls through to a fresh chat here (plugin.js:2884).
                // Deliberately not ported: on a transient failure that mints a
                // SECOND chat for a bot that demonstrably has history — exactly
                // the silent fork this phase removes. Report and change nothing.
                throw error
            }
        }

        // (d) Birth. A brand-new bot: mint the chat under the canonical title
        //     and pin it immediately (plugin.js:2751-2766).
        //
        //     Desktop also submits a kickoff prompt here ("Hey, tell me about
        //     yourself!", plugin.js:2790) so the chat is born with the bot
        //     introducing itself. Deliberately NOT ported: tapping a bot on a
        //     phone would spend a model turn nobody asked for, and the pin does
        //     not need it — the gateway persists no row until the first prompt
        //     (methods_session.py:114-120), so an untyped chat is simply pruned
        //     and the next open re-mints and re-pins. Left as a product call.
        //
        //     Born hidden, like every Bot Mode session (plugin.js:2758-2763,
        //     BOT-MODE-PARITY §canonical-chat): hidden means *owned*, not
        //     secret. Without it a phone-born forever chat drops a "Bot Chat"
        //     row into every shared list — desktop recents, the resume picker
        //     — that a desktop-born one never appears in.
        let live = try await client.createSession(profile: profile,
                                                  title: Self.canonicalChatTitle,
                                                  hidden: true)
        guard !live.sessionID.isEmpty else {
            throw GatewayError(code: -8, message: "session.create returned no id")
        }
        let stored = live.storedSessionID
        adopt(live, storedID: stored.isEmpty ? nil : stored, botID: botID,
              sourceGatewayID: route.gatewayID)
        if !stored.isEmpty { await pinCanonicalChat(stored, botID: botID) }
        return live.sessionID
    }

    /// Resume `target` — a durable key or the canonical title — and bind the
    /// bot's chat to whatever it resolved to.
    private func attach(_ target: String, botID: String, route: GatewayBotRoute, hydrate: Bool,
                        client: GatewayClient) async -> CanonicalAttach {
        let chat = chat(for: botID)
        let rebinding = chat.storedSessionID != target
        do {
            // Full projection in the ack: `defer_history` returns a bounded
            // stub (methods_session.py:434-439) and leaves history to a REST
            // shape that has proven flaky, so one round trip with
            // authoritative rows is the better trade — the same one
            // `openStoredSession` makes.
            let live = try await client.resumeSession(target, profile: route.profile,
                                                      deferHistory: false)
            guard !live.sessionID.isEmpty else {
                return .failed(GatewayError(code: -8, message: "session.resume returned no id"))
            }
            // `target` may have been the TITLE; the ack carries the real key.
            let stored = live.storedSessionID.isEmpty ? target : live.storedSessionID
            adopt(live, storedID: stored, botID: botID,
                  sourceGatewayID: route.gatewayID)
            if hydrate {
                await hydrateCanonical(live, botID: botID, profile: route.profile,
                                       client: client, clearWhenEmpty: rebinding)
            }
            replayInflight(live, botID: botID)
            replayPendingPrompts(live, sourceGatewayID: route.gatewayID)
            return .attached(sessionID: live.sessionID, storedID: stored)
        } catch let error as GatewayError where error.code == GatewayError.storedSessionGone {
            forget(target, botID: botID)
            return .missing
        } catch {
            return .failed(error)
        }
    }

    // MARK: Binding

    /// Bind the chat to a resolved session. Message history is left alone —
    /// the hydration step owns it, so a message typed before the chat finished
    /// opening keeps its optimistic bubble.
    private func adopt(_ live: LiveSession, storedID: String?, botID: String,
                       sourceGatewayID: String) {
        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        if let old = chat.sessionID, old != live.sessionID {
            if sourceGatewayID == runtime.gatewayID {
                runtime.sessionToBot.removeValue(forKey: old)
            } else {
                runtime.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                    gatewayID: sourceGatewayID, sessionID: old))
            }
        }
        if let storedID, !storedID.isEmpty {
            chat.storedSessionID = storedID
            // What a reconnect resumes from.
            runtime.lastSessionByBot[botID] = storedID
        }
        chat.isTyping = false
        bindSession(live, botID: botID, sourceGatewayID: sourceGatewayID)
    }

    /// Drop the current binding so the next attach re-resolves from scratch.
    /// Callers wait out any in-flight attach first — an attach that lands
    /// after this would re-bind the session being left.
    private func unbindChat(botID: String) {
        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        if let sid = chat.sessionID, let route = gatewayRoute(for: botID) {
            if route.gatewayID == runtime.gatewayID {
                runtime.sessionToBot.removeValue(forKey: sid)
            } else {
                runtime.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                    gatewayID: route.gatewayID, sessionID: sid))
            }
        }
        chat.sessionID = nil
        chat.storedSessionID = nil
        chat.isTyping = false
        chat.usage = nil
        chat.contextSegments = []
        chat.messages = []
    }

    /// A durable key the gateway just declared gone (4007) must not be handed
    /// back by any of the fallbacks below it.
    private func forget(_ storedID: String, botID: String) {
        let runtime = CanonicalChatRuntime.shared
        if runtime.pins[botID] == storedID { runtime.pins[botID] = nil }
        if LiveRuntime.shared.lastSessionByBot[botID] == storedID {
            LiveRuntime.shared.lastSessionByBot[botID] = nil
        }
        let chat = chat(for: botID)
        if chat.storedSessionID == storedID { chat.storedSessionID = nil }
        // The server pin is left as-is on purpose: the recovery path below
        // re-pins the session it settles on, so one write carries the final
        // value instead of a null followed by a replacement.
    }

    // MARK: Hydration

    /// Replace the transcript with the stored conversation. The resume ack's
    /// projection is primary (it is the shape every surface reads,
    /// server.py:_history_to_messages); REST is the fallback for a resume that
    /// omitted messages.
    private func hydrateCanonical(_ live: LiveSession, botID: String, profile: String,
                                  client: GatewayClient,
                                  clearWhenEmpty: Bool) async {
        var history = Self.chatMessages(fromTranscript: .array(live.messages))
        if history.isEmpty, !live.storedSessionID.isEmpty,
           let payload = try? await client.latestSessionMessages(storedID: live.storedSessionID,
                                                                 profile: profile) {
            history = Self.chatMessages(fromTranscript: payload)
        }
        let chat = chat(for: botID)
        guard !history.isEmpty else {
            // An empty chat must LOOK empty rather than borrow the roster
            // preview as a fake message. Only a transcript of our own system
            // lines is cleared — anything the user typed stays.
            if clearWhenEmpty, chat.messages.allSatisfy({ $0.author == .system }) {
                chat.messages = []
            }
            return
        }
        // Keep a user bubble typed while the resume was in flight: prompt.submit
        // has not persisted it yet, so replacing the transcript wholesale would
        // swallow the message the user is watching for.
        let optimistic = Array(chat.messages.reversed().prefix { $0.author == .user }.reversed())
        let known = Set(history.suffix(8).filter { $0.author == .user }.map(\.text))
        chat.messages = history + optimistic.filter { !known.contains($0.text) }
    }

    // MARK: The pin

    /// Write the canonical pin back so desktop opens the same chat
    /// (ROADMAP decision #3 — phone edits are visible to desktop).
    ///
    /// Desktop's `saveBotMeta` sends the WHOLE ui_meta["hermes-bots"] block
    /// (plugin.js:246) because `profiles.configure` merges only TOP-LEVEL
    /// ui_meta keys and replaces a nested block wholesale
    /// (methods_profiles.py:714-724): writing `{chat: …}` on its own would
    /// erase the bot's title, shape and color. So read the live block, merge
    /// one key, write it back. Sibling top-level blocks — Talaria's own
    /// ui_meta["talaria"] included — are untouched by that merge.
    func pinCanonicalChat(_ storedID: String, botID: String) async {
        guard !storedID.isEmpty else { return }
        let runtime = CanonicalChatRuntime.shared
        let previous = runtime.pins[botID]
        // Local first, unconditionally: the pin has to hold even when the
        // gateway cannot store it (older gateway, read-only profile), which is
        // exactly what desktop's plugin-local store buys (plugin.js:205-212).
        runtime.pins[botID] = storedID
        // Counted before the early return too: a local-only pin (offline, or a
        // gateway that cannot store ui_meta) still has to outrank the stale
        // roster answer that a poll already in flight is about to deliver.
        runtime.writeCount[botID, default: 0] += 1
        guard previous != storedID, mode == .live,
              let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route) else { return }

        _ = try? await withBotModeMetaMutation(route: route) {
            runtime.writing.insert(botID)
            defer { runtime.writing.remove(botID) }
            do {
                // Fresh read: ui_meta rides every profiles.list, and desktop may
                // have rewritten the block since the last roster poll. Sessions are
                // not needed here and cost a per-profile db scan.
                let profiles = try await client.listProfiles(includeSessions: false)
                guard let row = profiles.first(where: { $0.name == route.profile }) else { return }
                var block = row.uiMeta?["hermes-bots"]?.objectValue ?? [:]
                block["chat"] = .string(storedID)
                try await client.applyProfileEdit(
                    name: route.profile,
                    ProfileEdit(uiMeta: .object(["hermes-bots": .object(block)])))
            } catch {
                // Desktop's three-valued outcome (plugin.js:250-270) exists so an
                // older gateway that does not speak the contract produces no toast
                // at all. Neither outcome is actionable here: the chat is already
                // open and the pin holds locally, so nothing is surfaced.
            }
        }
    }

    // MARK: Failure

    /// One themed line in the transcript, in the voice every session failure
    /// uses. Never a fork: a failed open is transient and the pin stays
    /// (plugin.js:2864-2871).
    ///
    /// Since Phase D it also says so out loud — `notifyError(error, "Could not
    /// open <name>'s chat — try again")` (plugin.js:2878). The transcript line
    /// alone was not enough: the tap has already switched tabs and put an empty
    /// chat on screen, so the one surface carrying the explanation is the one
    /// the user is least likely to be looking at, and "try again" is the whole
    /// instruction — the pin is innocent and a second tap usually works.
    ///
    /// Both halves are guarded by the same repeat check. A retry loop against a
    /// dead link would otherwise stack an identical card three times over.
    private func reportCanonicalFailure(_ error: Error, botID: String) {
        let text = Self.sessionFailure(error, theme: theme)
        let chat = chat(for: botID)
        guard chat.messages.last?.text != text else { return }
        chat.messages.append(ChatMessage(author: .system, text: text))
        toast(kind: .failure,
              title: theme.copy.toastOpenChatFailed(botName(botID, theme.themeID), theme.themeID),
              message: Self.reason(error), botID: botID)
    }
}

// MARK: - REST hydration

extension GatewayClient {

    /// The newest page of a stored transcript, in desktop's exact shape
    /// (hermes.ts:786-800 `getLatestSessionMessages`).
    ///
    /// Three query params the core wrapper omits, each load-bearing
    /// (hermes_cli/web_routers/sessions.py:601-640):
    /// - `profile` — the route opens THAT profile's state.db, so without it a
    ///   non-default bot's transcript 404s;
    /// - `order=latest` — the endpoint pages from the OLDEST message whenever a
    ///   `limit` is sent, which opens a long forever-chat at its beginning;
    /// - `include_compacted` — rows preserved by in-place compaction are
    ///   durable display history; without them the transcript silently ends at
    ///   the compaction boundary (hermes_state.py:10155-10161).
    func latestSessionMessages(storedID: String, profile: String?,
                               limit: Int = 200) async throws -> JSONValue {
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "order", value: "latest"),
                     URLQueryItem(name: "include_compacted", value: "true")]
        if let profile, !profile.isEmpty {
            query.insert(URLQueryItem(name: "profile", value: profile), at: 0)
        }
        return try await restJSON(path: "api/sessions/\(storedID)/messages", query: query)
    }
}


extension AppModel {
    /// Reconcile every Bot Mode-owned stored session onto `hidden:true`
    /// (plugin.js:setHideBotChats). Canonical pins plus room member sessions
    /// stay out of shared recents; the per-bot Sessions sheet still lists them
    /// via `include_hidden`. Older gateways reject `session.set_hidden`; that
    /// is unsupported, not a toast.
    func hideOwnedBotSessions() async {
        guard mode == .live else { return }
        var grouped: [String: Set<String>] = [:]
        func add(_ gatewayID: String?, _ sessionID: String) {
            let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let gatewayID, !gatewayID.isEmpty, !sid.isEmpty else { return }
            grouped[gatewayID, default: []].insert(sid)
        }
        let fallback = LiveRuntime.shared.gatewayID
        for (botID, pin) in CanonicalChatRuntime.shared.pins {
            add(gatewayRoute(for: botID)?.gatewayID ?? fallback, pin)
        }
        for room in rooms {
            for (memberID, sessionID) in room.memberSessions {
                add(gatewayRoute(for: memberID)?.gatewayID ?? fallback, sessionID)
            }
        }
        for (gatewayID, ids) in grouped {
            do {
                let client = try await routedClient(gatewayID: gatewayID)
                for sid in ids {
                    do { _ = try await client.setSessionHidden(sid, hidden: true) }
                    catch { /* older gateway or vanished row */ }
                }
            } catch { /* unreachable gateway */ }
        }
    }

    /// Desktop's "New chat with this agent": a scratch session on this
    /// profile, explicitly NOT the forever-chat (plugin.js:3503). The
    /// `/new` guard's copy points here.
    public func openScratchChat(botID: String) async {
        let botID = resolvedBotID(botID)
        guard mode == .live else { return }
        do {
            guard let route = gatewayRoute(for: botID) else { throw GatewayRouteError.noRoute }
            let client = try await routedClient(for: route)
            let live = try await client.createSession(profile: route.profile, hidden: false)
            let stored = live.storedSessionID.isEmpty ? live.sessionID : live.storedSessionID
            guard !stored.isEmpty else {
                throw GatewayError(code: -8, message: "session.create returned no id")
            }
            openStoredSession(stored, botID: botID)
        } catch {
            toast(kind: .failure,
                  title: theme.copy.toastScratchFailed(theme.themeID),
                  message: (error as? GatewayError)?.message ?? error.localizedDescription,
                  botID: botID)
        }
    }

}

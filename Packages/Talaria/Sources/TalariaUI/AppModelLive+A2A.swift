import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

// ── Agent-to-agent: @mentions, delivery, and a live Agent Inbox ──────────────
//
// Bot Mode's a2a layer is one idea in three halves: a bot is addressed by its
// @handle, the message is delivered into the recipient's ONE canonical chat
// carrying a sender-attribution prefix, and the reply comes back through the
// same channel, attributed. Ported from
// apps/desktop/src/plugins/hermes-bots/plugin.js:
//
//   botHandle                    2406        the @handle namespace
//   isActiveRosterBot            2414        "a bot never @s itself"
//   resolveRosterMentions        2434-2493   prose scan, form map, ambiguity
//   ensureRemoteCanonicalChat    2506-2544   pin → resume-by-title → create hidden
//   pollRemoteDmReply            2549-2586   bounded wait for the reply
//   deliverRemoteRosterMentions  2593-2660   attributed submit + relay
//   mention autocomplete         7996-8046   prefix-on-handle, cap 8
//   mention middleware           8206-8321   the fast bail, the fallback path
//
// Two deliberate divergences from the plugin, both documented at their site:
//
// 1. Talaria does NOT append desktop's `[@mention handoff — …]` instruction
//    block (plugin.js:8305-8311). That block asks the *sending agent* to shell
//    out to `hermes -p <bot> chat …` on its own machine. A phone has no
//    terminal and no shell to quote into; it has a socket. So a mention here
//    takes desktop's OTHER delivery path — the cross-connection one at
//    plugin.js:2593, which submits the same attributed text over RPC and
//    relays the reply — which is exactly the shape a phone can honor.
//
// 2. Every handoff submits with `queued: true`. See `submitHandoff`: it is the
//    whole of "a mid-run bot cannot be interrupted".
//
// Gateway shapes cited inline from tui_gateway/.

// MARK: - Policy

/// The tuned constants. Upstream's are ported verbatim except where a phone
/// radio makes a loopback cadence wrong; those carry their reason.
enum A2APolicy {
    /// plugin.js:2499 `REMOTE_DM_TIMEOUT_MS` — 3 minutes, verbatim. A teammate
    /// that has not answered in three minutes is not an error, it is busy.
    static let replyDeadline: Double = 180

    /// plugin.js:2500 `REMOTE_DM_POLL_MS` is 2 s over a loopback socket. Each
    /// poll here is a radio round trip, so the interval is doubled; the cheap
    /// probe below (`session.list`, a pure DB read) makes the extra latency
    /// invisible in practice — the expensive transcript read happens once,
    /// after the counter has already moved.
    static let replyPoll: Double = 4

    /// `sessions.changed` is the cross-process signal — a CLI handoff, a cron
    /// run or another machine writing state.db all move it (server.py:3678,
    /// `_sessions_sig`) — and the gateway already floors it to one broadcast
    /// per 2 s (server.py:3760). Debounce past that floor so the burst a
    /// single streaming turn produces collapses into one sweep.
    static let changeDebounce: Double = 2.5

    /// Safety net for traffic no event reaches us for: the change watcher
    /// stats the ACTIVE profile's home only (`_watcher_home`, server.py:3626),
    /// so a message written into another profile's state.db can be silent.
    static let idleSweep: Double = 90

    /// Outbound handoffs remembered for their delivery note. Older ones lose
    /// the note and become ordinary inbox rows.
    static let deliveryLimit = 60

    /// A sweep is N profiles × up to 2 transcripts; these caps are what keep
    /// it affordable on a phone.
    static let scanProfiles = 10
    static let scanSessionsPerProfile = 2
    static let scanMessages = 60
    static let feedLimit = 80
}

// MARK: - Runtime (side table)

/// What one outbound handoff is doing.
public struct A2ADelivery: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Submitted; the reply watch is running.
        case waiting
        /// The recipient answered and the reply is in the feed.
        case replied
        /// The deadline passed with no reply. Not an error — it is in their
        /// chat, and the next sweep will find it.
        case quiet
        case failed(String)
    }

    public var to: String
    /// The gateway parked this behind a turn that was already running. Kept
    /// after the reply lands, because it explains a slow answer.
    public var queuedBehindRun: Bool
    public var state: State
    public var at: Date
}

/// Book-keeping the a2a surfaces need. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like `FeedsRuntime` and `LiveRuntime` do.
@MainActor
@Observable
final class A2ARuntime {
    static let shared = A2ARuntime()

    /// Handoffs this app sent, keyed by recipient + body. NOT by message id:
    /// an inbox sweep rebuilds every row from the transcript with a fresh
    /// UUID, and the delivery note has to survive that.
    var deliveries: [String: A2ADelivery] = [:]

    @ObservationIgnored var watchers: [String: Task<Void, Never>] = [:]
    /// Bumped every time a watch is (re)started for a key. A cancelled watch
    /// finishes asynchronously, so it must not tidy up after the watch that
    /// replaced it.
    @ObservationIgnored var watcherGeneration: [String: Int] = [:]
    @ObservationIgnored var eventToken: UUID?
    /// Which gateway the state above belongs to; a swap owns none of it.
    @ObservationIgnored var routedClient: ObjectIdentifier?
    @ObservationIgnored var attachTask: Task<Void, Never>?
    @ObservationIgnored var sweepDebounce: Task<Void, Never>?
    @ObservationIgnored var idlePoll: Task<Void, Never>?
    /// Screens currently showing the inbox. Events keep arriving when it is
    /// zero; sweeping for a screen nobody is looking at is just radio.
    @ObservationIgnored var viewers = 0

    func reset() {
        deliveries.removeAll()
        for task in watchers.values { task.cancel() }
        watchers.removeAll()
        watcherGeneration.removeAll()
        sweepDebounce?.cancel(); sweepDebounce = nil
        idlePoll?.cancel(); idlePoll = nil
        eventToken = nil
    }

    /// Keep the note table bounded; oldest deliveries lose their note first.
    func prune() {
        guard deliveries.count > A2APolicy.deliveryLimit else { return }
        let doomed = deliveries.sorted { $0.value.at < $1.value.at }
            .prefix(deliveries.count - A2APolicy.deliveryLimit)
        for (key, _) in doomed {
            deliveries.removeValue(forKey: key)
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
        }
    }
}

// MARK: - Mention grammar (plugin.js:2434-2493)

/// The @handle grammar, ported token for token. Strict on purpose: a false
/// positive here sends a real message to a real agent, so an @ must start a
/// word, the first character must be alphanumeric, dots are not part of a
/// handle, and anything inside code never counts.
public enum BotMention {
    /// `[a-z0-9][a-z0-9_-]*` — the same namespace `NAME_RE` defines for a
    /// profile name (plugin.js:78), which is why the profile name IS the
    /// handle. Underscores are legal even though Talaria's creator does not
    /// offer them: a bot named `code_review` on desktop must stay mentionable.
    static func isHandleBody(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
    }

    /// Text with fenced and inline code replaced by a space, so a handle
    /// inside a snippet never fires a handoff. Done FIRST, before any token
    /// scan (plugin.js:2434).
    public static func prose(_ text: String) -> String {
        var out = replace(text, pattern: "```[\\s\\S]*?```", with: " ")
        out = replace(out, pattern: "`[^`\\n]*`", with: " ")
        return out
    }

    /// Every @token in prose order, lowercased. Duplicates are kept; the
    /// resolver dedupes by bot, not by token.
    public static func tokens(in text: String) -> [String] {
        let prose = prose(text)
        guard let regex = Self.tokenRegex else { return [] }
        let ns = prose as NSString
        return regex.matches(in: prose, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 2 else { return nil }
                return ns.substring(with: match.range(at: 2)).lowercased()
            }
    }

    /// The cheap gate the middleware runs on every keystroke's worth of draft
    /// before doing any real work (plugin.js:8243).
    public static func mentions(_ text: String) -> Bool {
        guard let regex = Self.tokenRegex else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// The @token the composer is mid-way through typing — the trailing one,
    /// with the same word-boundary rule the resolver uses. `@` on its own
    /// returns an empty token, which offers the whole roster.
    ///
    /// Anchored to the END of the string rather than to the caret: SwiftUI's
    /// `TextField` publishes its text, never its selection.
    public static func activeToken(in text: String) -> (range: Range<String.Index>, token: String)? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex {
            guard text[text.index(before: at)].isWhitespace else { return nil }
        }
        let body = text[text.index(after: at)...]
        guard body.allSatisfy(isHandleBody) else { return nil }
        if let first = body.first, !(first.isLetter || first.isNumber) { return nil }
        return (at..<text.endIndex, body.lowercased())
    }

    /// Replace the token being typed with a chosen handle, leaving one
    /// trailing space so the next word is not swallowed into it.
    public static func complete(_ text: String, range: Range<String.Index>,
                                with handle: String) -> String {
        text.replacingCharacters(in: range, with: "@" + handle + " ")
    }

    /// Append a handle as a new mention (the roster strip's tap).
    public static func append(_ handle: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "@\(handle) " : trimmed + " @\(handle) "
    }

    /// Drop every mention of `handle`, keeping the whitespace that introduced
    /// it so the surrounding prose still reads.
    public static func remove(_ handle: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        let stripped = replace(text, pattern: "(^|\\s)@\(escaped)(?![a-z0-9_-])",
                               with: "$1", options: [.caseInsensitive])
        return replace(stripped, pattern: "[ \\t]{2,}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // plugin.js:2470 — the @ must start a word, so `user@host` and `a@b` are
    // not mentions; no dots, unlike the group-room parser at 3104.
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "(^|\\s)@([a-z0-9][a-z0-9_-]*)", options: [.caseInsensitive])

    private static func replace(_ text: String, pattern: String, with template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }
}

/// What the roster made of the @tokens in a draft.
public struct MentionResolution: Sendable, Equatable {
    /// Resolved bots, first-mention order, deduped.
    public var bots: [Bot] = []
    /// Tokens whose bare form is shared by more than one bot. Upstream
    /// resolves these to NOTHING rather than guessing, because guessing sends
    /// a real message to the wrong machine (plugin.js:2455-2462).
    public var ambiguous: [String] = []
    /// Tokens no bot answers to. Silently skipped upstream; surfaced here,
    /// quietly, because a phone gives no other feedback that a handle was
    /// mistyped.
    public var unknown: [String] = []

    public var isEmpty: Bool { bots.isEmpty && ambiguous.isEmpty && unknown.isEmpty }
}

/// One row of the @-autocomplete popover.
public struct MentionSuggestion: Identifiable, Sendable, Equatable {
    public var id: String { botID }
    public var botID: String
    public var handle: String
    /// `Bot · <display>` upstream (plugin.js:8035). On a phone the popover is
    /// bots-only, so the slot carries the display name and the bot's job
    /// instead — the parity note's suggested mobile reading.
    public var meta: String
    public var shape: AvatarShape
    public var hue: AvatarHue
}

// MARK: - Resolving mentions against the roster

public extension AppModel {

    /// Resolve @handles in a draft against the live roster.
    ///
    /// `speaker` is the bot doing the talking; it is excluded, because a bot
    /// never @s itself (plugin.js:2414 `isActiveRosterBot` — the multi-source
    /// half of that rule collapses to a name comparison while Talaria binds
    /// one gateway at a time).
    func resolveMentions(in text: String, speaking speaker: String?) -> MentionResolution {
        guard BotMention.mentions(text) else { return MentionResolution() }

        // The form map: every string that addresses this bot. A form claimed
        // by two different bots is poisoned to nil and STAYS poisoned — a
        // third bot cannot claim it — so the bare name of a duplicated profile
        // stops resolving and the user must type the @name-device form.
        var byForm: [String: Bot] = [:]
        var poisoned: Set<String> = []
        for bot in bots {
            let name = bot.id.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !isSpeaker(bot, speaker) else { continue }
            var forms: Set<String> = [bot.handle.lowercased(), name.lowercased()]
            if let override = bot.handleOverride, !override.isEmpty {
                forms.insert(override.lowercased())
            }
            for form in forms where !form.isEmpty {
                if poisoned.contains(form) { continue }
                if let existing = byForm[form] {
                    if existing.id != bot.id {
                        byForm.removeValue(forKey: form)
                        poisoned.insert(form)
                    }
                } else {
                    byForm[form] = bot
                }
            }
        }

        var resolution = MentionResolution()
        var seen: Set<String> = []
        for token in BotMention.tokens(in: text) {
            if poisoned.contains(token) {
                if !resolution.ambiguous.contains(token) { resolution.ambiguous.append(token) }
                continue
            }
            guard let bot = byForm[token] else {
                // `hermes` addresses the primary profile, which is literally
                // named `default` — `Bot.handle` already maps it, so reaching
                // here means no such bot is on this gateway (plugin.js:2474
                // keeps the same guard as a no-op for the same reason).
                if !resolution.unknown.contains(token) { resolution.unknown.append(token) }
                continue
            }
            guard seen.insert(bot.id).inserted else { continue }
            resolution.bots.append(bot)
        }
        return resolution
    }

    /// The @-autocomplete provider (plugin.js:7998-8043): PREFIX match, on the
    /// HANDLE only — never the title — because the token it inserts has to be
    /// a legal handle. Deliberately asymmetric with roster search, which
    /// matches four fields loosely. Capped at 8; never throws, never awaits.
    func mentionSuggestions(for query: String, speaking speaker: String?) -> [MentionSuggestion] {
        let needle = query.lowercased()
        var out: [MentionSuggestion] = []
        for bot in bots {
            guard !bot.id.trimmingCharacters(in: .whitespaces).isEmpty,
                  !isSpeaker(bot, speaker) else { continue }
            let handle = bot.handle
            guard needle.isEmpty || handle.lowercased().hasPrefix(needle) else { continue }
            let job = bot.job.trimmingCharacters(in: .whitespaces)
            let meta = job.isEmpty ? bot.displayTitle : "\(bot.displayTitle) · \(job)"
            out.append(MentionSuggestion(botID: bot.id, handle: handle, meta: meta,
                                         shape: bot.shape, hue: bot.hue))
            if out.count == 8 { break }
        }
        return out
    }

    /// The delivery note for an inbox row, when this app is the one that sent
    /// it. Keyed by recipient + body so it survives a feed rebuild.
    func delivery(for message: A2AMessage) -> A2ADelivery? {
        A2ARuntime.shared.deliveries[Self.deliveryKey(to: message.toBotID, body: message.text)]
    }

    /// Recipient + body. The sender half is deliberately not in the key: the
    /// attribution prefix carries a display NAME, and reading it back gives a
    /// token, not a profile id.
    static func deliveryKey(to: String, body: String) -> String {
        "\(to.lowercased())|\(stableHash(body))"
    }
}

// MARK: - Liveness

public extension AppModel {

    /// The inbox is on screen: sweep now, follow the gateway's change signal,
    /// and keep a slow poll behind it.
    ///
    /// Desktop gets this for free from a 5 s roster poll it runs anyway
    /// (plugin.js:2218). Talaria's inbox is a transcript scan across profiles
    /// — far too expensive to run on a timer — so it is event-first: the
    /// gateway's `sessions.changed` fires on any state.db write, INCLUDING the
    /// ones other processes make (a CLI handoff, a cron run, the laptop), and
    /// the idle poll only covers what the watcher cannot see.
    func beginInboxLive() {
        A2ARuntime.shared.viewers += 1
        armInboxAttach()
    }

    /// Surrender everything this surface registered on the departing gateway.
    ///
    /// Every piece of a2a state names something that only exists on ONE
    /// gateway: a `sessions.changed` subscription on its socket, delivery notes
    /// keyed by its profile names, and reply watches holding its stored-session
    /// ids. Left standing across a switch, those watches keep polling — against
    /// the NEW gateway, since they re-read `self.client` each tick — and can
    /// relay a stranger's transcript into the feed as an answer to a message
    /// that was never sent there. Called from `dropPerGatewayCaches`, which is
    /// the one hook both ways out of a link go through.
    func detachA2ARouter() {
        let runtime = A2ARuntime.shared
        let departing = client.map(ObjectIdentifier.init)
        // While the departing client is still around to surrender it to.
        if let token = runtime.eventToken, let client {
            Task { await client.removeEventHandler(token) }
        }
        runtime.attachTask?.cancel(); runtime.attachTask = nil
        runtime.reset()
        runtime.routedClient = nil
        agentInbox.removeAll()
        FeedsRuntime.shared.inboxSessions.removeAll()
        FeedsRuntime.shared.lastInboxScan = nil
        // The inbox may be the screen the user is looking at while the switch
        // happens; it re-attaches itself to the incoming gateway rather than
        // sitting empty until they navigate away and back.
        armInboxAttach(avoiding: departing)
    }

    /// The inbox left the screen. Reply watches deliberately outlive it — a
    /// handoff sent from here is still owed an answer, and the answer lands in
    /// the activity ledger whichever tab the user is on.
    func endInboxLive() {
        let runtime = A2ARuntime.shared
        runtime.viewers = max(0, runtime.viewers - 1)
        guard runtime.viewers == 0 else { return }
        runtime.attachTask?.cancel(); runtime.attachTask = nil
        runtime.sweepDebounce?.cancel(); runtime.sweepDebounce = nil
        runtime.idlePoll?.cancel(); runtime.idlePoll = nil
    }

    /// Rebuild the feed, coalescing a burst of change events into one scan.
    func sweepInbox(after delay: Double) {
        let runtime = A2ARuntime.shared
        runtime.sweepDebounce?.cancel()
        runtime.sweepDebounce = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.refreshInboxLive()
            if !Task.isCancelled { A2ARuntime.shared.sweepDebounce = nil }
        }
    }

    /// One sweep: every profile's own a2a conversation, split back into
    /// attributed rows.
    ///
    /// The session a profile receives handoffs in is its CANONICAL chat — the
    /// `-c "Bot Chat"` the CLI recipe names (plugin.js:8307) and the one
    /// `ensureRemoteCanonicalChat` resolves (2506). So the pin is read first
    /// and the title match is the fallback, in that order: a bot whose forever
    /// chat was grandfathered from an older conversation has a pin but no
    /// session called "Bot Chat", and scanning by title alone would show none
    /// of its traffic — including handoffs sent from this phone, which land
    /// wherever the pin points.
    func refreshInboxLive() async {
        guard mode == .live, let client, !bots.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        guard !runtime.inboxScanning else { return }
        // Transcripts are REST-only; the WS surface has no history endpoint.
        guard let (base, credential) = gatewayRESTContext() else {
            runtime.inboxNote = theme.copy.needsRESTNote(theme.themeID)
            return
        }
        runtime.inboxScanning = true
        defer { runtime.inboxScanning = false; runtime.lastInboxScan = Date() }

        var collected: [(A2AMessage, Date, SessionRef)] = []
        var scanned = 0

        for bot in bots.prefix(A2APolicy.scanProfiles) {
            guard !Task.isCancelled else { return }
            var targets: [String] = []
            if let pin = CanonicalChatRuntime.shared.pins[bot.id], !pin.isEmpty {
                targets.append(pin)
            }
            // Bot Mode sessions are hidden, and session.list drops hidden rows
            // unless asked (methods_session.py:180-186).
            if let sessions = try? await client.listSessions(limit: 40, profile: bot.id,
                                                             includeHidden: true) {
                for session in sessions where AppModel.isInboxSession(session.title) {
                    guard targets.count < A2APolicy.scanSessionsPerProfile else { break }
                    if !targets.contains(session.id) { targets.append(session.id) }
                }
            }
            for stored in targets.prefix(A2APolicy.scanSessionsPerProfile) {
                guard !Task.isCancelled else { return }
                guard let rows = try? await GatewayREST.sessionMessages(
                    baseURL: base, credential: credential, storedID: stored,
                    profile: bot.id, limit: A2APolicy.scanMessages) else { continue }
                scanned += 1
                let ref = SessionRef(botID: bot.id, storedID: stored)
                for (message, at) in AppModel.inboxMessages(in: rows, owner: bot.id) {
                    collected.append((message, at, ref))
                }
            }
        }

        let ordered = collected.sorted { $0.1 > $1.1 }.prefix(A2APolicy.feedLimit)
        var refs: [UUID: SessionRef] = [:]
        for entry in ordered { refs[entry.0.id] = entry.2 }
        runtime.inboxSessions = refs
        agentInbox = ordered.map(\.0)
        runtime.inboxNote = theme.copy.inboxSourceNote(theme.themeID, sessions: scanned)
    }
}

private extension AppModel {

    /// Wait briefly for a live socket, then bind the feed to it.
    ///
    /// `client` is published before the socket is up, and the tab can be opened
    /// mid-connect (or the gateway swapped underneath a tab already open) — so
    /// this waits rather than leaving an empty feed until the user navigates
    /// away and back. No-op when nobody is watching.
    /// `avoiding` is the client this call is walking away from. A switch tears
    /// the a2a state down BEFORE `AppModel.client` is replaced, so without it
    /// the very first check would re-attach to the socket that is closing and
    /// then never notice the one that replaced it.
    func armInboxAttach(avoiding stale: ObjectIdentifier? = nil) {
        let runtime = A2ARuntime.shared
        guard runtime.viewers > 0, mode == .live else { return }
        runtime.attachTask?.cancel()
        runtime.attachTask = Task { @MainActor [weak self] in
            for attempt in 0..<10 {
                guard !Task.isCancelled, let self,
                      A2ARuntime.shared.viewers > 0 else { return }
                if let client = self.client, ObjectIdentifier(client) != stale {
                    self.attachInboxLive(to: client)
                    return
                }
                if attempt < 9 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// Bind the live feed to a connected gateway.
    func attachInboxLive(to client: GatewayClient) {
        let runtime = A2ARuntime.shared
        let identity = ObjectIdentifier(client)
        if runtime.routedClient != identity {
            // A different gateway owns none of the previous traffic: its
            // deliveries and reply watches were all about another fleet.
            runtime.reset()
            runtime.routedClient = identity
            subscribeToA2AChanges(client)
        }
        sweepInbox(after: 0)
        startIdleInboxPoll()
    }

    func isSpeaker(_ bot: Bot, _ speaker: String?) -> Bool {
        guard let speaker, !speaker.isEmpty else { return false }
        return bot.id.caseInsensitiveCompare(speaker) == .orderedSame
    }

    func subscribeToA2AChanges(_ client: GatewayClient) {
        Task { @MainActor in
            let token = await client.addEventHandler { event in
                Task { @MainActor [weak self] in self?.a2aChange(event) }
            }
            A2ARuntime.shared.eventToken = token
        }
    }

    func a2aChange(_ event: GatewayEvent) {
        guard mode == .live, A2ARuntime.shared.viewers > 0 else { return }
        guard case .changed(let what) = TypedGatewayEvent(event),
              what == "sessions.changed" else { return }
        sweepInbox(after: A2APolicy.changeDebounce)
    }

    func startIdleInboxPoll() {
        let runtime = A2ARuntime.shared
        guard runtime.idlePoll == nil else { return }
        runtime.idlePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(A2APolicy.idleSweep))
                guard !Task.isCancelled, let self,
                      A2ARuntime.shared.viewers > 0, !self.isOffline else { continue }
                await self.refreshInboxLive()
            }
        }
    }
}

// MARK: - Composing a handoff

public extension AppModel {

    /// Hand a message from one bot to others, over the socket.
    ///
    /// The shape is desktop's cross-connection delivery (plugin.js:2593):
    /// resolve each recipient's canonical Bot Chat, submit the attributed
    /// text, then watch that session for the reply and relay it back into the
    /// feed. Recipients are independent — one unreachable bot does not cancel
    /// the rest — so a per-recipient failure is recorded on that delivery and
    /// only a total failure throws.
    ///
    /// Returns the number of recipients the gateway accepted.
    @discardableResult
    func deliverHandoff(from sender: String, to recipients: [String],
                        text: String) async throws -> Int {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return 0 }
        var targets: [String] = []
        for id in recipients where !id.isEmpty && id != sender && !targets.contains(id) {
            targets.append(id)
        }
        guard !targets.isEmpty else { return 0 }
        guard mode == .live, let client else {
            throw GatewayError(code: -3, message: "connect a gateway to hand off")
        }

        // Both halves of the prefix are the sender's IDENTITY, not its profile
        // id: desktop sends `Message from 🤖 ${senderName} (@${senderHandle})`
        // (plugin.js:2635), where senderName is the display title. Sending the
        // raw profile name writes "Message from 🤖 default (@default)" into
        // another bot's permanent transcript for the profile that presents as
        // Hermes/@hermes.
        let identity = identity(sender)
        let attributed = "Message from 🤖 \(identity.displayTitle) (@\(identity.handle)): \(body)"

        var accepted = 0
        var firstFailure: Error?
        for target in targets {
            do {
                let session = try await canonicalInboxSession(for: target, client: client)
                // Baseline BEFORE the submit, so the watch can tell the reply
                // from what was already there (plugin.js:2620). A canonical
                // chat that has never been prompted has no db row at all
                // (methods_session.py:114-120), so a missing count is a real
                // zero rather than a failed read — and a stale zero is
                // harmless, because the reply scan anchors on our own message.
                let baseline = await storedMessageCount(of: session.stored, profile: target) ?? 0
                let queued = try await client.submitHandoff(sessionID: session.runtime,
                                                            text: attributed)
                accepted += 1
                record(handoff: body, from: sender, to: target, queued: queued)
                watchForReply(to: target, sender: sender, body: body, attributed: attributed,
                              stored: session.stored, baseline: baseline)
            } catch {
                if firstFailure == nil { firstFailure = error }
                recordFailure(error, to: target, body: body)
            }
        }
        if accepted == 0, let firstFailure { throw firstFailure }
        // The optimistic rows above are ours; the sweep replaces them with the
        // stored ones so every row in the feed came from a real transcript.
        sweepInbox(after: 1.5)
        return accepted
    }
}

private extension AppModel {

    /// A recipient's canonical Bot Chat, resolved in desktop's exact order:
    /// the `ui_meta["hermes-bots"].chat` pin, then resume-by-title, then a
    /// hidden create (plugin.js:2506-2544). Never "the most recent session":
    /// a handoff has to land in the conversation tapping that bot opens.
    func canonicalInboxSession(for botID: String,
                               client: GatewayClient) async throws -> (runtime: String, stored: String) {
        var pin = CanonicalChatRuntime.shared.pins[botID]
        if pin == nil || pin?.isEmpty == true {
            // The roster poll seeds the pin table, but a bot this phone has
            // never opened may not be in it yet. Sessions are not needed and
            // cost a per-profile db scan (methods_profiles.py).
            if let profiles = try? await client.listProfiles(includeSessions: false),
               let row = profiles.first(where: { $0.name == botID }) {
                pin = row.uiMeta?["hermes-bots"]?.objectValue?["chat"]?.stringValue
            }
        }
        for target in [pin, Self.canonicalChatTitle].compactMap({ $0 }) where !target.isEmpty {
            // `session.resume` takes a durable key OR an exact title
            // (methods_session.py:349-352), which is how a phone finds a
            // forever chat minted on the laptop when the pin never reached it.
            guard let live = try? await client.resumeSession(target, profile: botID,
                                                             deferHistory: true),
                  !live.sessionID.isEmpty else { continue }
            let stored = live.storedSessionID.isEmpty ? target : live.storedSessionID
            return (live.sessionID, stored)
        }
        // Born hidden, like every Bot Mode session (plugin.js:2540-2542): a
        // handoff must not drop a stray "Bot Chat" row into desktop's recents.
        let created = try await client.createSession(profile: botID,
                                                     title: Self.canonicalChatTitle, hidden: true)
        guard !created.sessionID.isEmpty else {
            throw GatewayError(code: -8, message: "session.create returned no id")
        }
        if !created.storedSessionID.isEmpty {
            // Same block desktop pins into, so the phone's handoff and the
            // laptop's roster tap open the same conversation.
            await pinCanonicalChat(created.storedSessionID, botID: botID)
        }
        return (created.sessionID, created.storedSessionID)
    }

    /// Stored row count for a session this app does not own — the cheap side
    /// of the reply watch. `session.list` reads the profile's db directly and
    /// returns `message_count` per row (methods_session.py:210) without
    /// touching the live session, so it can be polled without disturbing a
    /// turn in flight. `include_hidden` because every Bot Mode session is
    /// hidden (methods_session.py:180-186).
    func storedMessageCount(of storedID: String, profile: String) async -> Int? {
        guard !storedID.isEmpty, let client else { return nil }
        guard let rows = try? await client.listSessions(limit: 40, profile: profile,
                                                        includeHidden: true) else { return nil }
        return rows.first(where: { $0.id == storedID })?.messageCount
    }

    func record(handoff body: String, from sender: String, to target: String, queued: Bool) {
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(to: target, body: body)
        runtime.watchers.removeValue(forKey: key)?.cancel()
        runtime.deliveries[key] = A2ADelivery(to: target, queuedBehindRun: queued,
                                              state: .waiting, at: Date())
        runtime.prune()

        // Show it immediately; the sweep replaces it with the stored row.
        agentInbox.insert(A2AMessage(fromBotID: sender, toBotID: target,
                                     time: Self.clock(), text: body), at: 0)
        FeedsRuntime.shared.lastInboxScan = nil
        recordActivity(kind: .mention, botID: target,
                       text: theme.copy.feedHandoffSent(theme.themeID)
                           + " @" + identity(sender).handle,
                       subtext: Self.previewLine(body))
    }

    /// One recipient could not be reached while others could. The composer has
    /// already closed on the ones that worked, so the ledger is the only place
    /// left to say so — and it is the right place: the row survives the sweep,
    /// which is about to rebuild the feed from transcripts this message never
    /// reached.
    func recordFailure(_ error: Error, to target: String, body: String) {
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(to: target, body: body)
        runtime.watchers.removeValue(forKey: key)?.cancel()
        runtime.deliveries[key] = A2ADelivery(to: target, queuedBehindRun: false,
                                              state: .failed(Self.reason(error)), at: Date())
        runtime.prune()
        recordActivity(kind: .mention, botID: target,
                       text: theme.copy.a2aFailedNote(theme.themeID,
                                                      reason: Self.reason(error)),
                       subtext: Self.previewLine(body))
    }

    /// Wait out the recipient's turn and relay its answer, bounded
    /// (plugin.js:2549). A timeout is not an error — the message is in their
    /// chat and the next sweep will find the reply whenever it lands.
    func watchForReply(to target: String, sender: String, body: String, attributed: String,
                       stored: String, baseline: Int) {
        guard !stored.isEmpty else { return }
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(to: target, body: body)
        let generation = (runtime.watcherGeneration[key] ?? 0) + 1
        runtime.watcherGeneration[key] = generation
        let deadline = Date().addingTimeInterval(A2APolicy.replyDeadline)
        runtime.watchers[key] = Task { @MainActor [weak self] in
            defer {
                // Only if this is still the live watch for the key.
                if A2ARuntime.shared.watcherGeneration[key] == generation {
                    A2ARuntime.shared.watchers[key] = nil
                }
            }
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(A2APolicy.replyPoll))
                guard !Task.isCancelled, let self, self.mode == .live,
                      let client = self.client else { return }
                // Cheap probe first: nothing has been written, nothing to read.
                let count = await self.storedMessageCount(of: stored, profile: target)
                if let count, count <= baseline { continue }
                // Something landed. One authoritative read — `running` and
                // `inflight` are what say the turn is finished rather than
                // half-written (plugin.js:2566).
                guard let live = try? await client.resumeSession(stored, profile: target,
                                                                 deferHistory: false),
                      !live.running, live.inflight == nil,
                      let reply = Self.reply(to: attributed, in: live.messages) else { continue }
                self.relay(reply: reply, from: target, to: sender, key: key)
                return
            }
            guard A2ARuntime.shared.watcherGeneration[key] == generation else { return }
            if var delivery = A2ARuntime.shared.deliveries[key], delivery.state == .waiting {
                delivery.state = .quiet
                A2ARuntime.shared.deliveries[key] = delivery
            }
        }
    }

    /// The reply to OUR message: the newest assistant turn that follows the
    /// user row we wrote. Upstream takes the last assistant message outright
    /// (plugin.js:2569-2583); anchoring to our own row instead keeps a queued
    /// handoff from relaying the answer to whatever the bot was already doing.
    static func reply(to attributed: String, in messages: [JSONValue]) -> String? {
        // -1 when our row is not in this page of the transcript, which makes
        // the scan below fall back to upstream's plain "last assistant".
        var anchor = -1
        for (index, row) in messages.enumerated() where row["role"]?.stringValue == "user" {
            if ArtifactScan.text(of: row).contains(attributed) { anchor = index }
        }
        var index = messages.count - 1
        while index > anchor {
            let row = messages[index]
            if row["role"]?.stringValue == "assistant" {
                let text = ArtifactScan.text(of: row)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            index -= 1
        }
        return nil
    }

    func relay(reply: String, from target: String, to sender: String, key: String) {
        if var delivery = A2ARuntime.shared.deliveries[key] {
            delivery.state = .replied
            A2ARuntime.shared.deliveries[key] = delivery
        }
        agentInbox.insert(A2AMessage(fromBotID: target, toBotID: sender,
                                     time: Self.clock(), text: Self.previewLine(reply)), at: 0)
        recordActivity(kind: .mention, botID: sender,
                       text: theme.copy.feedHandoffReply(theme.themeID)
                           + " @" + identity(target).handle,
                       subtext: Self.previewLine(reply))
        // Let the transcript be the source of truth for the row.
        sweepInbox(after: 0.5)
    }
}

// MARK: - The wire

extension GatewayClient {

    /// Deliver a handoff into a recipient's canonical chat WITHOUT interrupting
    /// whatever it is doing.
    ///
    /// This is the one place Talaria's a2a path is not a straight port, and it
    /// is load-bearing. A plain `prompt.submit` into a busy session takes the
    /// gateway's default busy policy — `interrupt` — which redirects the live
    /// turn in place (server.py:8056-8058, 8097-8113): a handoff would hijack
    /// the work the recipient is already doing. That is why upstream delivers
    /// bot-to-bot traffic per invocation (`hermes -p <bot> chat …` spawns a
    /// fresh run) instead of submitting into a live one.
    ///
    /// `queued: true` is the socket equivalent: the gateway parks the message
    /// and drains it as the NEXT turn, and the flag "must NEVER become a
    /// live-turn correction or interrupt" (server.py:8060-8065). It is only
    /// consulted when the session is actually running (methods_prompt.py:359),
    /// so sending it unconditionally also closes the race where the recipient
    /// starts a turn between the resume and the submit.
    ///
    /// Returns true when the gateway parked it behind a run — the recipient
    /// was mid-turn, and the answer will take at least that long.
    func submitHandoff(sessionID: String, text: String) async throws -> Bool {
        let result = try await rpc("prompt.submit",
                                   ["session_id": .string(sessionID),
                                    "text": .string(text),
                                    "queued": .bool(true)],
                                   timeout: 1800)
        return result["status"]?.stringValue == "queued"
    }
}

// MARK: - Copy

extension CopyPack {

    /// Activity row when a relayed reply lands.
    func feedHandoffReply(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reply from"
        case .control: "REPLY RX FROM"
        case .ink: "An answer from"
        }
    }

    /// Composer field prompt — it doubles as the documentation for the
    /// routing grammar, the way desktop's room composer does (plugin.js:7390).
    func mentionPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What should they do? @handle to address a bot"
        case .control: "PAYLOAD — @HANDLE TO ADDRESS"
        case .ink: "what shall they do? name a familiar with @"
        }
    }

    func mentionRecipients(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Goes to"
        case .control: "ROUTE"
        case .ink: "carried unto"
        }
    }

    func mentionRosterLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap to address"
        case .control: "ROSTER"
        case .ink: "the familiars"
        }
    }

    func mentionNoRecipients(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name a bot with @ to send this."
        case .control: "NO ROUTE — @HANDLE REQUIRED."
        case .ink: "Name a familiar with @, and it shall be carried."
        }
    }

    /// Ambiguity refuses rather than guesses (plugin.js:2455).
    func mentionAmbiguous(_ t: ThemeID, token: String) -> String {
        switch t {
        case .soft: "@\(token) fits more than one bot — use its @name-device handle."
        case .control: "@\(token) AMBIGUOUS — USE @NAME-DEVICE."
        case .ink: "@\(token) answers for more than one — call it by @name-device."
        }
    }

    func mentionUnknown(_ t: ThemeID, token: String) -> String {
        switch t {
        case .soft: "No bot answers to @\(token)."
        case .control: "@\(token) — NO SUCH HANDLE."
        case .ink: "None answers to @\(token)."
        }
    }

    /// The honest limit, said once in the composer.
    func a2aLimitNote(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "Delivery is one message per run. A bot mid-run finishes first and reads yours next — nothing interrupts it."
        case .control:
            "PER-RUN DELIVERY. A BUSY BOT FINISHES ITS TURN, THEN READS. NO INTERRUPT."
        case .ink:
            "A word waits its turn. A familiar at work finishes, then hears you; nothing cuts across it."
        }
    }

    func a2aQueuedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Queued behind a run — it goes next"
        case .control: "QUEUED — RUNS NEXT"
        case .ink: "waits behind work already begun"
        }
    }

    func a2aWaitingNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delivered — waiting for a reply"
        case .control: "DELIVERED — AWAITING REPLY"
        case .ink: "carried — the answer is awaited"
        }
    }

    func a2aRepliedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Replied"
        case .control: "REPLIED"
        case .ink: "answered"
        }
    }

    func a2aQuietNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No reply yet — it is in their chat"
        case .control: "NO REPLY YET — SEE ITS BOT CHAT"
        case .ink: "no answer yet; the word is kept in its chat"
        }
    }

    func a2aFailedNote(_ t: ThemeID, reason: String) -> String {
        switch t {
        case .soft: "Could not reach it — \(reason)"
        case .control: "UNREACHABLE — \(reason.uppercased())"
        case .ink: "the word did not arrive — \(reason)"
        }
    }
}

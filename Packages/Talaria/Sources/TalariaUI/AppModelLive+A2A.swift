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
// Two deliberate mobile adaptations from the plugin:
//
// 1. Talaria does NOT append desktop's `[@mention handoff — …]` instruction
//    block (plugin.js:8305-8311). That block asks the *sending agent* to shell
//    out to `hermes -p <bot> chat …` on its own machine. A phone has no
//    terminal and no shell to quote into; it has retained gateway clients. So
//    every mention takes desktop's cross-connection path at plugin.js:2593,
//    source-routed through the owning client, with the same attributed submit
//    and reply relay. The primary connection never changes for a handoff.
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
    /// Exact gateway/profile that accepted this attempt. Nil only for legacy
    /// in-memory entries constructed by older tests/callers.
    public var route: GatewayBotRoute?
    /// The sender is part of the delivery's ownership too. A recipient route
    /// alone cannot tell a profile rename whether this watch belongs to the
    /// profile being renamed or to a sibling that merely shares its gateway.
    public var senderRoute: GatewayBotRoute?
    /// The roster spelling used by the sender at submit time. This is kept
    /// separately from `senderRoute` because primary rows are bare while
    /// retained secondary rows are source-qualified.
    public var senderRosterID: String?
    /// Submit-time fence metadata for an accepted prompt whose publication
    /// raced lifecycle. It is portable evidence, not permission to rearm.
    public var submitScopeGeneration: Int?
    public var submitTargetGeneration: UInt64?
    public var submitSenderGeneration: UInt64?
    public var submitClientID: ObjectIdentifier?
    public var requiresExplicitRearm: Bool
    /// One identity per submit attempt. Equal recipient/body pairs must not
    /// replace each other's watcher or delivery outcome.
    public var attemptID: UUID
    /// Stable body fingerprint used to reconnect transcript rows to the most
    /// recent matching attempt without making it the attempt identity.
    public var bodyHash: Int?
    /// The gateway parked this behind a turn that was already running. Kept
    /// after the reply lands, because it explains a slow answer.
    public var queuedBehindRun: Bool
    public var state: State
    public var at: Date

    public init(to: String, route: GatewayBotRoute? = nil,
                senderRoute: GatewayBotRoute? = nil, senderRosterID: String? = nil,
                submitScopeGeneration: Int? = nil,
                submitTargetGeneration: UInt64? = nil,
                submitSenderGeneration: UInt64? = nil,
                submitClientID: ObjectIdentifier? = nil,
                requiresExplicitRearm: Bool = false,
                attemptID: UUID = UUID(),
                bodyHash: Int? = nil, queuedBehindRun: Bool,
                state: State, at: Date) {
        self.to = to; self.route = route
        self.senderRoute = senderRoute; self.senderRosterID = senderRosterID
        self.submitScopeGeneration = submitScopeGeneration
        self.submitTargetGeneration = submitTargetGeneration
        self.submitSenderGeneration = submitSenderGeneration
        self.submitClientID = submitClientID
        self.requiresExplicitRearm = requiresExplicitRearm
        self.attemptID = attemptID
        self.bodyHash = bodyHash; self.queuedBehindRun = queuedBehindRun
        self.state = state; self.at = at
    }
}

/// A bot identity after roster resolution and before any wire work. Both the
/// UI identity and the exact gateway route travel together; no dispatch API
/// accepts a bare profile id.
struct A2AEndpoint: Sendable, Equatable {
    var rosterID: String
    var route: GatewayBotRoute
    var displayTitle: String
    var handle: String
    /// Sender-attribution form. Upstream derives this from the bare profile,
    /// not the source-annotated roster row (plugin.js:8298).
    var attributionHandle: String
    var connectionLabel: String?
}

struct A2ACanonicalSession: Sendable, Equatable {
    var runtime: String
    var stored: String
}

/// Pure session-selection policy, split out so pin/title/create precedence is
/// testable without a socket. Only an exact title is a title candidate.
enum A2ASessionResolver {
    /// Durable pin first, then the gateway's authoritative exact-title lookup.
    /// No bounded session.list window participates in canonical identity.
    static func lookupTargets(pin: String?, title: String) -> [String] {
        var targets: [String] = []
        if let pin, !pin.isEmpty { targets.append(pin) }
        if !title.isEmpty, !targets.contains(title) { targets.append(title) }
        return targets
    }
}

enum A2APinAuthority {
    static func choose(cached: String?, current: String?, sampledWrite: Int,
                       currentWrite: Int, serverReadSucceeded: Bool,
                       serverPin: String?) -> String? {
        if currentWrite != sampledWrite { return current }
        return serverReadSucceeded ? serverPin : cached
    }
}

/// Wire-only attempt identity. The anchor sits inside the attribution prefix,
/// before its final colon, so `strippedA2A` removes it from every inbox/preview
/// surface while the canonical transcript can distinguish repeated bodies.
enum A2AWire {
    /// The attempt marker is deliberately anchored to the attribution line.
    /// A title/body can contain marker-looking text, but it cannot become the
    /// wire identity unless it is the terminal marker before the body colon.
    private static let attemptPrefixPattern =
        #"^Message from .*?\[Talaria handoff attempt ([0-9a-fA-F-]{36})\]:"#

    private static func escapeMarkerValue(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func unescapeMarkerValue(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    static func attributed(displayTitle: String, handle: String, body: String,
                           attemptID: UUID,
                           senderRoute: GatewayBotRoute? = nil) -> String {
        let source = senderRoute.map {
            " [Talaria handoff source \(escapeMarkerValue($0.qualifiedID))]"
        } ?? ""
        return "Message from 🤖 \(displayTitle) (@\(handle)) "
            + source
            + "[Talaria handoff attempt \(attemptID.uuidString.lowercased())]: \(body)"
    }

    static func senderRoute(in attributed: String) -> GatewayBotRoute? {
        guard let attempt = attributed.range(
            of: attemptPrefixPattern, options: .regularExpression) else { return nil }
        guard let markerStart = attributed[..<attempt.upperBound].lastIndex(of: "[") else {
            return nil
        }
        let prefixText = String(attributed[..<markerStart])
        let sourcePattern = #"\[Talaria handoff source ([^\]]+)\]"#
        var range: Range<String.Index>?
        var searchStart = prefixText.startIndex
        while let candidate = prefixText.range(of: sourcePattern,
                                                options: .regularExpression,
                                                range: searchStart..<prefixText.endIndex) {
            range = candidate
            searchStart = candidate.upperBound
        }
        guard let range else { return nil }
        let marker = String(attributed[range])
        let prefix = "[Talaria handoff source "
        guard marker.hasPrefix(prefix), marker.hasSuffix("]") else { return nil }
        let qualified = unescapeMarkerValue(
            String(marker.dropFirst(prefix.count).dropLast()))
        return GatewayBotRoute(qualifiedID: qualified)
    }

    static func attemptID(in attributed: String) -> UUID? {
        guard let range = attributed.range(
            of: attemptPrefixPattern,
            options: .regularExpression) else { return nil }
        let marker = String(attributed[range])
        guard let markerStart = marker.lastIndex(of: "[") else { return nil }
        let attemptMarker = String(marker[markerStart...])
        guard let idRange = attemptMarker.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression) else { return nil }
        return UUID(uuidString: String(attemptMarker[idRange]))
    }

    /// Deterministic companion id for the assistant row belonging to an
    /// attempt. Distinct from its user row while surviving transcript rebuilds.
    static func replyID(for attemptID: UUID) -> UUID {
        var bytes = attemptID.uuid
        bytes.15 ^= 0x80
        return UUID(uuid: bytes)
    }
}

struct A2AAcceptedOutcome: Sendable, Equatable {
    var state: A2ADelivery.State
    var retainWatcher: Bool

    static func afterSubmit(scopeIsCurrent: Bool) -> Self {
        scopeIsCurrent
            ? Self(state: .waiting, retainWatcher: true)
            : Self(state: .quiet, retainWatcher: false)
    }
}

/// The two source-qualified identities a reply watch must retain. Keeping
/// this in the runtime, rather than only in a task closure, lets a committed
/// profile rename update the sender/recipient before the same watch relays its
/// answer. A deleted route simply removes the registration.
@MainActor
struct A2AWatcherRegistration: Equatable {
    var target: A2AEndpoint
    var sender: A2AEndpoint
    var targetGeneration: UInt64
    var senderGeneration: UInt64
    var paused = false
}

@MainActor
struct A2AOptimisticOwner: Equatable {
    var target: GatewayBotRoute
    var targetRosterID: String
    var sender: GatewayBotRoute
    var senderRosterID: String
}

enum A2AInboxMerge {
    static func source(of message: A2AMessage, ref: SessionRef?,
                       optimisticRows: [UUID: String],
                       primaryGatewayID: String?) -> String? {
        if let source = optimisticRows[message.id] { return source }
        if let source = ref?.gatewayID, !source.isEmpty { return source }
        if let route = GatewayBotRoute(qualifiedID: message.toBotID) { return route.gatewayID }
        if let route = GatewayBotRoute(qualifiedID: message.fromBotID) { return route.gatewayID }
        return primaryGatewayID
    }

    static func merge(existing: [A2AMessage], existingRefs: [UUID: SessionRef],
                      server: [(A2AMessage, Date, SessionRef)],
                      successfulGateways: Set<String>, optimisticRows: [UUID: String],
                      primaryGatewayID: String?, limit: Int)
        -> (messages: [A2AMessage], refs: [UUID: SessionRef], settled: Set<UUID>) {
        let serverOrdered = server.sorted { $0.1 > $1.1 }
        let serverIDs = Set(serverOrdered.map { $0.0.id })
        let preserved = existing.filter { message in
            guard let gatewayID = source(of: message, ref: existingRefs[message.id],
                                         optimisticRows: optimisticRows,
                                         primaryGatewayID: primaryGatewayID) else { return true }
            if !successfulGateways.contains(gatewayID) { return true }
            return optimisticRows[message.id] != nil && !serverIDs.contains(message.id)
        }
        var seen: Set<UUID> = []
        let messages = Array((preserved + serverOrdered.map(\.0))
            .filter { seen.insert($0.id).inserted }.prefix(limit))
        var refs = existingRefs.filter { id, _ in
            preserved.contains(where: { $0.id == id })
        }
        for entry in serverOrdered { refs[entry.0.id] = entry.2 }
        let visibleIDs = Set(messages.map(\.id))
        refs = refs.filter { visibleIDs.contains($0.key) }
        return (messages, refs, serverIDs)
    }
}

/// Exact-attribution reply selection. A substring or an absent prompt anchor
/// must never relay an unrelated answer from a busy canonical chat.
enum A2AReplyResolver {
    static func reply(to attributed: String, in messages: [JSONValue]) -> String? {
        var anchor: Int?
        for (index, row) in messages.enumerated() where row["role"]?.stringValue == "user" {
            if ArtifactScan.text(of: row) == attributed { anchor = index }
        }
        guard let anchor else { return nil }
        var reply: String?
        var index = anchor + 1
        while index < messages.count {
            let row = messages[index]
            // This exact attempt owns one turn only. Crossing the next user row
            // is how two identical queued handoffs used to steal one reply.
            if row["role"]?.stringValue == "user" { break }
            if row["role"]?.stringValue == "assistant" {
                let text = ArtifactScan.text(of: row)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply = text }
            }
            index += 1
        }
        return reply
    }
}

/// Book-keeping the a2a surfaces need. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like `FeedsRuntime` and `LiveRuntime` do.
@MainActor
@Observable
final class A2ARuntime {
    static let shared = A2ARuntime()

    /// Handoffs this app sent, keyed by source-qualified recipient + body hash
    /// + attempt UUID. A rebuilt transcript row has a fresh UUID, so lookup can
    /// fall back to its qualified recipient/body while live optimistic rows
    /// retain exact attempt identity.
    var deliveries: [String: A2ADelivery] = [:]

    @ObservationIgnored var watchers: [String: Task<Void, Never>] = [:]
    /// Bumped every time a watch is (re)started for a key. A cancelled watch
    /// finishes asynchronously, so it must not tidy up after the watch that
    /// replaced it.
    @ObservationIgnored var watcherGeneration: [String: Int] = [:]
    /// Gateway owning each live watcher, including the interval between submit
    /// and delivery-table publication. Enables exact-source detach.
    @ObservationIgnored var watcherScopes: [String: String] = [:]
    /// Invalidates a task even when cancellation races an RPC already in flight.
    @ObservationIgnored var scopeGenerations: [String: Int] = [:]
    /// Profile-route generations are narrower than `scopeGenerations`: a
    /// secondary gateway can retain several profiles, and renaming/deleting
    /// one must not invalidate a sibling's handoff. Every canonical-open,
    /// watcher, and accepted-completion path captures this token before its
    /// first await and checks it again before publishing.
    @ObservationIgnored var routeGenerations: [GatewayBotRoute: UInt64] = [:]
    /// Coalesce concurrent handoffs to the same bot so pin/title misses cannot
    /// mint two hidden canonical chats in parallel.
    @ObservationIgnored var canonicalOpens: [GatewayBotRoute: Task<A2ACanonicalSession, Error>] = [:]
    @ObservationIgnored var canonicalOpenGenerations: [GatewayBotRoute: Int] = [:]
    /// Reply-watch ownership is mutable across a committed rename. The task
    /// reads this registration after each network await, so its captured
    /// sender/recipient cannot relay into a retired bare or qualified id.
    @ObservationIgnored var watcherRegistrations: [String: A2AWatcherRegistration] = [:]
    /// Optimistic rows that a sweep must retain until the exact anchored rows
    /// appear in the owning gateway's transcript.
    @ObservationIgnored var optimisticRows: [UUID: String] = [:]
    @ObservationIgnored var optimisticOwners: [UUID: A2AOptimisticOwner] = [:]
    @ObservationIgnored var pendingRearms: Set<String> = []
    /// A rename fences a watch while Hermes moves the profile directory. The
    /// task remains retained so the commit hook can migrate it in place; a
    /// delete removes it instead. This set is intentionally route-qualified.
    @ObservationIgnored var pausedRoutes: Set<GatewayBotRoute> = []
    /// Profile lifecycle parks this exact route before a primary disconnect;
    /// reset(gatewayID:) must not mistake that deliberate teardown for a
    /// request to erase its portable handoff/watch state.
    @ObservationIgnored var routesPreservedAcrossGatewayReset: Set<GatewayBotRoute> = []
    /// Restore hooks can run while the lifecycle exclusive lease still fences
    /// ordinary traffic. Keep the rearm pending instead of unpausing a route
    /// that cannot yet reacquire its client.
    @ObservationIgnored var deferredRestores: [GatewayBotRoute: Set<String>] = [:]
    @ObservationIgnored var deferredRestoreTasks: [GatewayBotRoute: Task<Void, Never>] = [:]
    @ObservationIgnored var eventToken: UUID?
    /// addEventHandler is asynchronous; a late token from a departing client
    /// must not replace the subscription installed for its successor.
    @ObservationIgnored var eventClient: ObjectIdentifier?
    @ObservationIgnored var eventGeneration: UInt64 = 0
    /// Which gateway the state above belongs to; a swap owns none of it.
    @ObservationIgnored var routedClient: ObjectIdentifier?
    @ObservationIgnored var inboxGatewayID: String?
    @ObservationIgnored var attachTask: Task<Void, Never>?
    @ObservationIgnored var sweepDebounce: Task<Void, Never>?
    @ObservationIgnored var idlePoll: Task<Void, Never>?
    /// Screens currently showing the inbox. Events keep arriving when it is
    /// zero; sweeping for a screen nobody is looking at is just radio.
    @ObservationIgnored var viewers = 0
    /// Invalidates an inbox sweep still awaiting a profile during reset.
    @ObservationIgnored var inboxSweepGeneration: UInt64 = 0

    func routeGeneration(for route: GatewayBotRoute) -> UInt64 {
        routeGenerations[route, default: 0]
    }

    func accepts(route: GatewayBotRoute, generation: UInt64) -> Bool {
        routeGenerations[route, default: 0] == generation
            && !pausedRoutes.contains(route)
    }

    /// Acceptance is owned by both ends of a handoff. This seam keeps the
    /// post-submit boundary testable without constructing a live client and
    /// prevents a sender rename from being mistaken for a valid recipient
    /// completion (or vice versa).
    func acceptsCompletion(senderRoute: GatewayBotRoute,
                           senderGeneration: UInt64,
                           targetRoute: GatewayBotRoute,
                           targetGeneration: UInt64) -> Bool {
        accepts(route: senderRoute, generation: senderGeneration)
            && accepts(route: targetRoute, generation: targetGeneration)
    }

    /// Invalidate one exact profile route without disturbing siblings on the
    /// same gateway. The caller may preserve accepted delivery state for a
    /// rename; it is then paused until `migrateProfileRoute` or
    /// `restoreProfileRoute` supplies a new owner.
    func retireProfileRoute(_ route: GatewayBotRoute,
                            sourceBotIDs: Set<String>,
                            preserveForRename: Bool = false) {
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.insert(route)
        deferredRestoreTasks.removeValue(forKey: route)?.cancel()
        deferredRestores.removeValue(forKey: route)

        let canonicalRoutes = canonicalOpens.keys.filter { $0 == route }
        for route in canonicalRoutes {
            canonicalOpens.removeValue(forKey: route)?.cancel()
        }

        var keys = Set(deliveries.compactMap { key, delivery in
            let ownsRecipient = delivery.route == route
                || delivery.to == route.qualifiedID
                || sourceBotIDs.contains(delivery.to)
            let ownsSender = delivery.senderRoute == route
                || delivery.senderRosterID.map(sourceBotIDs.contains) == true
            return ownsRecipient || ownsSender ? key : nil
        }).union(watcherRegistrations.compactMap { key, registration in
            let ownsRecipient = registration.target.route == route
                || sourceBotIDs.contains(registration.target.rosterID)
            let ownsSender = registration.sender.route == route
                || sourceBotIDs.contains(registration.sender.rosterID)
            return ownsRecipient || ownsSender ? key : nil
        })
        // Older callers may have installed a primary watch before sender
        // ownership was recorded. A bare primary cannot prove which profile
        // owns such a closure, so retire those legacy watches rather than let
        // them relay into a replacement profile. New watches always carry a
        // registration and are migrated above.
        let barePrimary = sourceBotIDs.contains(route.profile)
        let legacyWatchers = barePrimary
            ? Set(watchers.keys.filter { watcherRegistrations[$0] == nil }) : []
        let legacyDeliveries = barePrimary
            ? Set(deliveries.compactMap { key, delivery in
                delivery.senderRoute == nil && delivery.route != route ? key : nil
            }) : []
        let retireLegacy: (String) -> Void = { key in
            self.watchers.removeValue(forKey: key)?.cancel()
            self.watcherGeneration.removeValue(forKey: key)
            self.watcherScopes.removeValue(forKey: key)
            self.watcherRegistrations.removeValue(forKey: key)
            if let delivery = self.deliveries.removeValue(forKey: key) {
                self.optimisticRows.removeValue(forKey: delivery.attemptID)
                self.optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }

        if preserveForRename {
            for key in keys {
                watcherRegistrations[key]?.paused = true
                if watcherRegistrations[key] == nil { retireLegacy(key) }
            }
            for key in legacyWatchers.union(legacyDeliveries) { retireLegacy(key) }
            // Keep accepted delivery records and optimistic rows. They are
            // portable state and are migrated after Hermes confirms the name.
            return
        }
        keys.formUnion(legacyWatchers)
        keys.formUnion(legacyDeliveries)

        for key in keys {
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
            if let delivery = deliveries.removeValue(forKey: key) {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }
        let optimistic = optimisticOwners.compactMap { id, owner in
            let ownsRecipient = owner.target == route
                || sourceBotIDs.contains(owner.targetRosterID)
            let ownsSender = owner.sender == route
                || sourceBotIDs.contains(owner.senderRosterID)
            return ownsRecipient || ownsSender ? id : nil
        }
        for id in optimistic {
            optimisticOwners.removeValue(forKey: id)
            optimisticRows.removeValue(forKey: id)
        }
    }

    /// A successful explicit profile create/recreate re-authorizes a route
    /// that a prior delete permanently retired. Bump once more so no task
    /// captured before the new directory existed can publish into it.
    func activateProfileRoute(_ route: GatewayBotRoute) {
        deferredRestoreTasks.removeValue(forKey: route)?.cancel()
        deferredRestores.removeValue(forKey: route)
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.remove(route)
    }

    /// Restore a refused rename. Canonical opens were intentionally retired;
    /// only accepted deliveries/watchers are unpaused and allowed to continue
    /// against the original source route.
    func restoreProfileRoute(_ route: GatewayBotRoute, sourceBotIDs: Set<String>) {
        guard ProfileLifecycleTrafficAdmission.allows(route.gatewayID) else {
            deferredRestores[route, default: []].formUnion(sourceBotIDs)
            if deferredRestoreTasks[route] == nil {
                deferredRestoreTasks[route] = Task { @MainActor [weak self] in
                    while !Task.isCancelled,
                          !ProfileLifecycleTrafficAdmission.allows(route.gatewayID) {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    guard let self, !Task.isCancelled,
                          ProfileLifecycleTrafficAdmission.allows(route.gatewayID) else { return }
                    let ids = self.deferredRestores.removeValue(forKey: route) ?? []
                    self.deferredRestoreTasks[route] = nil
                    self.restoreProfileRoute(route, sourceBotIDs: ids)
                }
            }
            return
        }
        deferredRestores.removeValue(forKey: route)
        deferredRestoreTasks.removeValue(forKey: route)
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.remove(route)
        for key in watcherRegistrations.keys {
            guard var registration = watcherRegistrations[key] else { continue }
            let owns = registration.target.route == route
                || registration.sender.route == route
                || sourceBotIDs.contains(registration.target.rosterID)
                || sourceBotIDs.contains(registration.sender.rosterID)
            guard owns else { continue }
            if registration.target.route == route {
                registration.targetGeneration = routeGeneration(for: route)
            }
            if registration.sender.route == route {
                registration.senderGeneration = routeGeneration(for: route)
            }
            registration.paused = false
            watcherRegistrations[key] = registration
            pendingRearms.remove(key)
        }

        for key in deliveries.keys {
            guard var delivery = deliveries[key],
                  delivery.route == route || delivery.senderRoute == route else { continue }
            delivery.requiresExplicitRearm = false
            deliveries[key] = delivery
            pendingRearms.remove(key)
        }
    }

    /// Re-key accepted delivery/watch state after a committed profile rename.
    /// The old route remains fenced forever; all mutable watcher ownership is
    /// moved to the destination before ordinary traffic is released.
    func migrateProfileRoute(from source: GatewayBotRoute,
                             to destination: GatewayBotRoute,
                             sourceBotIDs: Set<String>,
                             destinationBotID: String) {
        guard source != destination else {
            restoreProfileRoute(source, sourceBotIDs: sourceBotIDs)
            return
        }
        // Never allow a canonical-open completion from the old directory to
        // become a destination pin/create. The profile lifecycle parks the
        // portable pin separately and will re-key it at reconciliation.
        canonicalOpens.removeValue(forKey: source)?.cancel()
        routeGenerations[source, default: 0] &+= 1
        routeGenerations[destination, default: 0] &+= 1
        // Keep the old route permanently fenced. Only the destination may
        // accept a late completion after a committed rename.
        pausedRoutes.insert(source)
        pausedRoutes.remove(destination)

        for key in deliveries.keys {
            guard var delivery = deliveries[key] else { continue }
            var changed = false
            if delivery.route == source {
                delivery.route = destination
                delivery.to = destinationBotID
                changed = true
            }
            if delivery.senderRoute == source {
                delivery.senderRoute = destination
                delivery.senderRosterID = destinationBotID
                changed = true
            }
            if changed { deliveries[key] = delivery }
            if changed {
                delivery.requiresExplicitRearm = false
                deliveries[key] = delivery
                pendingRearms.remove(key)
            }
        }

        for key in watcherRegistrations.keys {
            guard var registration = watcherRegistrations[key] else { continue }
            var changed = false
            if registration.target.route == source {
                registration.target.route = destination
                registration.target.rosterID = destinationBotID
                registration.targetGeneration = routeGeneration(for: destination)
                changed = true
            }
            if registration.sender.route == source {
                registration.sender.route = destination
                registration.sender.rosterID = destinationBotID
                registration.senderGeneration = routeGeneration(for: destination)
                changed = true
            }
            if changed {
                registration.paused = false
                watcherRegistrations[key] = registration
                pendingRearms.remove(key)
            }
        }

        for id in optimisticOwners.keys {
            guard var owner = optimisticOwners[id] else { continue }
            if owner.target == source {
                owner.target = destination
                owner.targetRosterID = destinationBotID
            }
            if owner.sender == source {
                owner.sender = destination
                owner.senderRosterID = destinationBotID
            }
            optimisticOwners[id] = owner
        }
    }

    func installWatcher(key: String, target: A2AEndpoint,
                        sender: A2AEndpoint) -> Int {
        let generation = (watcherGeneration[key] ?? 0) + 1
        watcherGeneration[key] = generation
        watcherScopes[key] = target.route.gatewayID
        watcherRegistrations[key] = A2AWatcherRegistration(
            target: target, sender: sender,
            targetGeneration: routeGeneration(for: target.route),
            senderGeneration: routeGeneration(for: sender.route))
        if pendingRearms.contains(key) {
            watcherRegistrations[key]?.paused = true
        }
        return generation
    }

    func watcherRegistration(key: String, generation: Int)
        -> A2AWatcherRegistration? {
        guard watcherGeneration[key] == generation,
              let registration = watcherRegistrations[key], !registration.paused,
              accepts(route: registration.target.route,
                      generation: registration.targetGeneration),
              accepts(route: registration.sender.route,
                      generation: registration.senderGeneration) else { return nil }
        return registration
    }

    func watcherIsPaused(key: String, generation: Int) -> Bool {
        watcherGeneration[key] == generation
            && watcherRegistrations[key]?.paused == true
    }

    func removeWatcher(key: String, generation: Int) {
        guard watcherGeneration[key] == generation else { return }
        watchers.removeValue(forKey: key)
        watcherGeneration.removeValue(forKey: key)
        watcherScopes.removeValue(forKey: key)
        watcherRegistrations.removeValue(forKey: key)
        pendingRearms.remove(key)
    }

    func preserveRouteAcrossGatewayReset(_ route: GatewayBotRoute) {
        routesPreservedAcrossGatewayReset.insert(route)
    }

    func reset() {
        let gateways = Set(watcherScopes.values)
            .union(deliveries.values.compactMap { $0.route?.gatewayID })
            .union(canonicalOpens.keys.map(\.gatewayID))
        for gatewayID in gateways { scopeGenerations[gatewayID, default: 0] += 1 }
        let routes = Set(routeGenerations.keys)
            .union(deliveries.values.compactMap { $0.route })
            .union(deliveries.values.compactMap { $0.senderRoute })
            .union(canonicalOpens.keys)
            .union(watcherRegistrations.values.flatMap { [$0.target.route, $0.sender.route] })
        for route in routes { routeGenerations[route, default: 0] &+= 1 }
        inboxSweepGeneration &+= 1
        deliveries.removeAll()
        for task in watchers.values { task.cancel() }
        watchers.removeAll()
        watcherGeneration.removeAll()
        watcherScopes.removeAll()
        for task in canonicalOpens.values { task.cancel() }
        canonicalOpens.removeAll()
        watcherRegistrations.removeAll()
        pendingRearms.removeAll()
        optimisticRows.removeAll()
        optimisticOwners.removeAll()
        pausedRoutes.removeAll()
        routesPreservedAcrossGatewayReset.removeAll()
        for task in deferredRestoreTasks.values { task.cancel() }
        deferredRestoreTasks.removeAll()
        deferredRestores.removeAll()
        sweepDebounce?.cancel(); sweepDebounce = nil
        idlePoll?.cancel(); idlePoll = nil
        eventToken = nil
        eventClient = nil
        eventGeneration &+= 1
        inboxGatewayID = nil
    }

    /// Surrender only one retained gateway. Other gateway reply watches keep
    /// their captured client/session and continue independently.
    func reset(gatewayID: String) {
        scopeGenerations[gatewayID, default: 0] += 1
        for route in Array(deferredRestoreTasks.keys) where route.gatewayID == gatewayID {
            deferredRestoreTasks.removeValue(forKey: route)?.cancel()
            deferredRestores.removeValue(forKey: route)
        }
        if inboxGatewayID == gatewayID {
            eventGeneration &+= 1
            eventToken = nil
            eventClient = nil
        }
        let preservedRoutes = routesPreservedAcrossGatewayReset.filter {
            $0.gatewayID == gatewayID
        }
        let routes = Set(routeGenerations.keys.filter {
            $0.gatewayID == gatewayID && !preservedRoutes.contains($0)
        })
            .union(deliveries.values.compactMap { $0.route }.filter { $0.gatewayID == gatewayID })
            .union(deliveries.values.compactMap { $0.senderRoute }.filter { $0.gatewayID == gatewayID })
            .union(canonicalOpens.keys.filter { $0.gatewayID == gatewayID })
            .union(watcherRegistrations.values.flatMap { [$0.target.route, $0.sender.route] }
                .filter { $0.gatewayID == gatewayID })
        for route in routes { routeGenerations[route, default: 0] &+= 1 }
        inboxSweepGeneration &+= 1
        let keys: Set<String> = Set(deliveries.compactMap { key, delivery in
            let preserved = delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
            if preserved { return nil }
            return delivery.route?.gatewayID == gatewayID
                || delivery.senderRoute?.gatewayID == gatewayID
                || GatewayBotRoute(qualifiedID: delivery.to)?.gatewayID == gatewayID ? key : nil
        }).union(watcherScopes.compactMap { key, value in
            guard value == gatewayID else { return nil }
            guard let registration = watcherRegistrations[key] else { return key }
            return preservedRoutes.contains(registration.target.route)
                || preservedRoutes.contains(registration.sender.route) ? nil : key
        })
            .union(watcherRegistrations.compactMap { key, registration in
                if preservedRoutes.contains(registration.target.route)
                    || preservedRoutes.contains(registration.sender.route) { return nil }
                return registration.target.route.gatewayID == gatewayID
                    || registration.sender.route.gatewayID == gatewayID ? key : nil
            })
        for key in keys {
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
            pendingRearms.remove(key)
            if let delivery = deliveries.removeValue(forKey: key) {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }
        let canonicalRoutes = canonicalOpens.keys.filter { $0.gatewayID == gatewayID }
        for route in canonicalRoutes {
            canonicalOpens.removeValue(forKey: route)?.cancel()
        }
        let preservedAttempts = Set(deliveries.values.compactMap { delivery in
            delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
                ? delivery.attemptID : nil
        })
        optimisticRows = optimisticRows.filter {
            $0.value != gatewayID || preservedAttempts.contains($0.key)
        }
        optimisticOwners = optimisticOwners.filter {
            ( $0.value.target.gatewayID != gatewayID
                && $0.value.sender.gatewayID != gatewayID )
                || preservedAttempts.contains($0.key)
        }
        pausedRoutes = Set(pausedRoutes.filter {
            $0.gatewayID != gatewayID || preservedRoutes.contains($0)
        })
        routesPreservedAcrossGatewayReset.subtract(preservedRoutes)
    }

    /// Keep the note table bounded; oldest deliveries lose their note first.
    func prune() {
        guard deliveries.count > A2APolicy.deliveryLimit else { return }
        let doomed = deliveries.sorted { $0.value.at < $1.value.at }
            .prefix(deliveries.count - A2APolicy.deliveryLimit)
        for (key, _) in doomed {
            if let delivery = deliveries[key] {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
            deliveries.removeValue(forKey: key)
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
        }
    }
}

// MARK: - Mention grammar (plugin.js:2434-2497)

// `BotMention`, `MentionResolution`, `MentionResolver`, `MentionSuggestion`
// and `MentionMiddleware` live in TalariaKit/BotMention.swift — they are pure,
// three surfaces share them, and `talaria-verify` links TalariaKit alone, so
// that is the only place their rules can be pinned by ProtocolChecks. What
// stays here is everything that needs a socket: the roster the resolver and
// the completion provider run against, the dispatch, and the reply watch.

// MARK: - Resolving mentions against the roster

public extension AppModel {

    /// Resolve @handles in a draft against the union roster
    /// (`MentionResolver`, plugin.js:2434-2497). The roster is the only thing
    /// this side supplies; every rule is the shared one.
    ///
    /// `unionRosterBots`, not `bots`: upstream resolves against the whole
    /// merged roster (8252-8256 reads the cached `profiles`, which
    /// `mergeMultiSourceRoster` has already unioned), and that is what makes
    /// the duplicate-name rule fire. Two `default` rows from two gateways
    /// poison the bare form between them, so `@default` refuses and only
    /// `@default-macbook` / `@default-homelab` resolve.
    func resolveMentions(in text: String, speaking speaker: String?) -> MentionResolution {
        MentionResolver.resolve(text, roster: unionRosterBots, speaking: speaker)
    }

    /// The @-autocomplete provider (plugin.js:8006-8043). Every rule is the
    /// shared one; the roster and the device it lives on are what this side
    /// supplies.
    ///
    /// Same union roster as the resolver, for the same reason plus one more:
    /// a `@name-device` handle that cannot be completed cannot be discovered,
    /// and it is not a form anyone guesses. The meta line is what keeps the
    /// two apart on screen — `Bot · Hermes · MacBook` above
    /// `Bot · Homelab · Homelab`, the far row naming itself by the machine it
    /// lives on in both slots (`displayName` rule 1, plugin.js:2941-2943).
    ///
    /// The label passed here is the live gateway's, because those rows all
    /// came off it — desktop stamps `connectionLabel` onto each row it merges
    /// from a source and reads it back out for the meta line (plugin.js:2337,
    /// 8034); foreign rows carry their own and override it. It is nil until
    /// the socket is bound to a saved Connection, and the meta line then reads
    /// `Bot · <name>` with no tail, which is the no-label shape upstream
    /// renders too.
    func mentionSuggestions(for query: String, speaking speaker: String?) -> [MentionSuggestion] {
        unionRosterBots.mentionSuggestions(for: query, speaking: speaker,
                                           connectionLabel: activeConnectionLabel)
    }

    /// The delivery note for an inbox row, when this app is the one that sent
    /// it. Transcript rows do not carry Talaria's attempt UUID, so choose the
    /// newest matching source-qualified recipient/body attempt after a rebuild.
    func delivery(for message: A2AMessage) -> A2ADelivery? {
        let hash = Self.stableHash(message.text)
        if let exact = A2ARuntime.shared.deliveries.values.first(where: {
            $0.attemptID == message.id
        }) { return exact }
        return A2ARuntime.shared.deliveries.values
            .filter { delivery in
                delivery.to == message.toBotID && (delivery.bodyHash ?? hash) == hash
            }
            .max(by: { $0.at < $1.at })
    }

    /// Legacy deterministic spelling retained for lifecycle tests and entries
    /// created before attempt-qualified delivery keys. New dispatch uses the
    /// route + UUID overload below.
    static func deliveryKey(to: String, body: String) -> String {
        "\(to.lowercased())|\(stableHash(body))"
    }

    /// Exact source + body fingerprint + attempt UUID. Profile, body and even
    /// runtime/stored session ids are allowed to collide across gateways and
    /// repeat submissions; none can replace another attempt's state.
    static func deliveryKey(route: GatewayBotRoute, body: String, attemptID: UUID) -> String {
        "\(route.gatewayID.count):\(route.gatewayID)|\(route.profile.count):\(route.profile)"
            + "|\(stableHash(body))|\(attemptID.uuidString.lowercased())"
    }

    /// Turn one union-roster row into a dispatch endpoint. Foreign rows already
    /// carry their source; local rows are scoped to the current primary.
    internal func a2aEndpoint(for bot: Bot) -> A2AEndpoint? {
        let route: GatewayBotRoute
        if let source = bot.remoteSource {
            route = GatewayBotRoute(gatewayID: source.gatewayID, profile: source.profile)
        } else {
            guard let activeGatewayID else { return nil }
            route = GatewayBotRoute(gatewayID: activeGatewayID, profile: bot.profileName)
        }
        return A2AEndpoint(rosterID: bot.id, route: route,
                           displayTitle: bot.displayTitle, handle: bot.handle,
                           attributionHandle: Bot.unlisted(id: route.profile).handle,
                           connectionLabel: bot.remoteSource?.connectionLabel
                               ?? (route.gatewayID == activeGatewayID ? activeConnectionLabel : nil))
    }

    internal func a2aEndpoint(forRosterID rosterID: String) -> A2AEndpoint? {
        if let bot = unionRosterBots.first(where: { $0.id == rosterID }) {
            return a2aEndpoint(for: bot)
        }
        guard let route = gatewayRoute(for: rosterID) else { return nil }
        let bot = identity(rosterID)
        let label = ConnectionRegistry.shared.saved.first(where: { $0.id == route.gatewayID })?.name
        return A2AEndpoint(rosterID: rosterID, route: route,
                           displayTitle: bot.displayTitle, handle: bot.handle,
                           attributionHandle: Bot.unlisted(id: route.profile).handle,
                           connectionLabel: label)
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
    /// Every piece of a2a state names one gateway: its `sessions.changed`
    /// subscription, source-qualified delivery notes, and reply watches holding
    /// that source's client/session. Teardown cancels only the captured primary;
    /// retained secondary watches continue on their own clients. Called from
    /// `dropPerGatewayCaches`, the hook both ways out of a primary link use.
    func detachA2ARouter(departingGatewayID capturedGatewayID: String? = nil) {
        let runtime = A2ARuntime.shared
        let departing = client.map(ObjectIdentifier.init)
        let departingGatewayID = capturedGatewayID ?? activeGatewayID
            ?? LiveRuntime.shared.gatewayID
        // While the departing client is still around to surrender it to.
        if let token = runtime.eventToken, let client {
            Task { await client.removeEventHandler(token) }
        }
        runtime.attachTask?.cancel(); runtime.attachTask = nil
        if let departingGatewayID {
            dropA2AScope(gatewayID: departingGatewayID, wasPrimary: true)
        } else {
            runtime.reset()
        }
        runtime.routedClient = nil
        runtime.inboxGatewayID = nil
        FeedsRuntime.shared.lastInboxScan = nil
        // The inbox may be the screen the user is looking at while the switch
        // happens; it re-attaches itself to the incoming gateway rather than
        // sitting empty until they navigate away and back.
        armInboxAttach(avoiding: departing)
    }

    /// Drop one retained gateway's handoff attempts without disturbing any
    /// other source. `detachRoutedEvents(gatewayID:)` calls this when a pooled
    /// secondary is retired; the primary detach path above uses the same hook.
    func dropA2AScope(gatewayID: String, wasPrimary: Bool = false) {
        let a2a = A2ARuntime.shared
        let inboxRefs = FeedsRuntime.shared.inboxSessions
        // A primary profile rename marks its exact route portable before the
        // disconnect path reaches this gateway-wide scrub. Keep those rows
        // visible; reset(gatewayID:) will preserve the matching deliveries
        // and watchers for postcondition migration.
        let preservedRoutes = a2a.routesPreservedAcrossGatewayReset.filter {
            $0.gatewayID == gatewayID
        }
        let preservedOptimisticIDs = Set(a2a.deliveries.values.compactMap { delivery in
            delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
                ? delivery.attemptID : nil
        })
        let ownedInboxIDs = Set(inboxRefs.compactMap {
            id, ref in ref.gatewayID == gatewayID ? id : nil
        }).subtracting(preservedOptimisticIDs)
        // Optimistic rows can be visible before the next transcript sweep and
        // therefore have no SessionRef yet. Use the exact delivery/source
        // owner first, including replies from a remote target into a departing
        // bare primary sender.
        let ownedOptimisticIDs = Set(a2a.optimisticRows.compactMap {
            id, sourceGateway in sourceGateway == gatewayID ? id : nil
        }).union(a2a.optimisticOwners.compactMap { id, owner in
            owner.sender.gatewayID == gatewayID || owner.target.gatewayID == gatewayID
                ? id : nil
        }).union(a2a.deliveries.values.compactMap { delivery in
            delivery.senderRoute?.gatewayID == gatewayID || delivery.route?.gatewayID == gatewayID
                ? delivery.attemptID : nil
        }).subtracting(preservedOptimisticIDs)
        A2ARuntime.shared.reset(gatewayID: gatewayID)
        let prefix = gatewayID + GatewayBotRoute.separator
        agentInbox.removeAll { message in
            !preservedOptimisticIDs.contains(message.id)
                && (ownedInboxIDs.contains(message.id) || ownedOptimisticIDs.contains(message.id)
                    || message.fromBotID.hasPrefix(prefix) || message.toBotID.hasPrefix(prefix)
                    || (wasPrimary
                        && GatewayBotRoute(qualifiedID: message.fromBotID) == nil
                        && GatewayBotRoute(qualifiedID: message.toBotID) == nil
                        && (inboxRefs[message.id].map { $0.gatewayID == gatewayID } ?? true)))
        }
        FeedsRuntime.shared.inboxSessions = FeedsRuntime.shared.inboxSessions.filter { _, ref in
            ref.gatewayID != gatewayID
        }
        FeedsRuntime.shared.lastInboxScan = nil
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

    /// Primary and retained-secondary session signals share one federated
    /// sweep. The source is carried by the caller even though the merge itself
    /// refreshes every eligible source.
    func routeA2AChange(_ event: GatewayEvent, sourceGatewayID: String?) {
        guard mode == .live, A2ARuntime.shared.viewers > 0 else { return }
        guard case .changed(let what) = TypedGatewayEvent(event),
              what == "sessions.changed" else { return }
        _ = sourceGatewayID
        sweepInbox(after: A2APolicy.changeDebounce)
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
        guard mode == .live else { return }
        let endpoints = unionRosterBots.compactMap(a2aEndpoint(for:))
        guard !endpoints.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        guard !runtime.inboxScanning else { return }
        runtime.inboxScanning = true
        defer { runtime.inboxScanning = false; runtime.lastInboxScan = Date() }

        var collected: [(A2AMessage, Date, SessionRef)] = []
        let a2aRuntime = A2ARuntime.shared
        let sweepGeneration = a2aRuntime.inboxSweepGeneration
        var routeGenerations: [GatewayBotRoute: UInt64] = [:]
        var scanned = 0
        var completedProfiles: [String: Int] = [:]
        var failedGateways: Set<String> = []
        let selected = Array(endpoints.prefix(A2APolicy.scanProfiles))
        let totalProfiles = Dictionary(grouping: endpoints, by: { $0.route.gatewayID })
            .mapValues(\.count)
        let selectedProfiles = Dictionary(grouping: selected, by: { $0.route.gatewayID })
            .mapValues(\.count)
        for (gatewayID, count) in totalProfiles
        where selectedProfiles[gatewayID, default: 0] < count {
            // A capped partial source cannot authoritatively replace rows from
            // profiles this sweep did not inspect.
            failedGateways.insert(gatewayID)
        }

        for endpoint in selected {
            guard !Task.isCancelled else { return }
            let route = endpoint.route
            let routeGeneration = A2ARuntime.shared.routeGeneration(for: route)
            routeGenerations[route] = routeGeneration
            guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                  a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
            guard let sourceClient = try? await routedClient(for: route),
                  let (base, credential) = gatewayRESTContext(gatewayID: route.gatewayID) else {
                failedGateways.insert(route.gatewayID)
                continue
            }
            await attachRoutedEventsIfNeeded(client: sourceClient,
                                             gatewayID: route.gatewayID,
                                             preserveStateOnReplacement: true)
            guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                  a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
            var targets: [String] = []
            if let pin = CanonicalChatRuntime.shared.pins[endpoint.rosterID], !pin.isEmpty {
                targets.append(pin)
            }

            // Exact database/title resolution is independent of recency and
            // finds a canonical chat even behind >40 newer sessions.
            do {
                let live = try await sourceClient.resumeSession(
                    Self.canonicalChatTitle, profile: route.profile, deferHistory: true)
                guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                      a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
                let stored = live.storedSessionID
                if !stored.isEmpty, !targets.contains(stored) { targets.append(stored) }
            } catch let error as GatewayError where error.code == GatewayError.storedSessionGone {
                // Brand-new profile: no canonical transcript yet.
            } catch {
                failedGateways.insert(route.gatewayID)
                continue
            }

            // Legacy "Agent Inbox" sessions have no canonical pin/title.
            do {
                let sessions = try await sourceClient.listSessions(
                    limit: 200, profile: route.profile, includeHidden: true)
                guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                      a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
                for session in sessions where session.title.lowercased().contains("agent inbox") {
                    guard targets.count < A2APolicy.scanSessionsPerProfile else { break }
                    if !targets.contains(session.id) { targets.append(session.id) }
                }
            } catch {
                failedGateways.insert(route.gatewayID)
                continue
            }

            var profileComplete = true
            for stored in targets.prefix(A2APolicy.scanSessionsPerProfile) {
                guard !Task.isCancelled else { return }
                do {
                    let rows = try await GatewayREST.sessionMessages(
                        baseURL: base, credential: credential, storedID: stored,
                        profile: route.profile, limit: A2APolicy.scanMessages)
                    guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                          a2aRuntime.accepts(route: route, generation: routeGeneration) else {
                        profileComplete = false
                        continue
                    }
                    scanned += 1
                    let ref = SessionRef(gatewayID: route.gatewayID,
                                         botID: endpoint.rosterID, storedID: stored)
                    for (message, at) in AppModel.inboxMessages(
                        in: rows, owner: endpoint.rosterID,
                        sourceGatewayID: route.gatewayID) {
                        collected.append((message, at, ref))
                    }
                } catch {
                    profileComplete = false
                    failedGateways.insert(route.gatewayID)
                }
            }
            if profileComplete { completedProfiles[route.gatewayID, default: 0] += 1 }
        }

        guard a2aRuntime.inboxSweepGeneration == sweepGeneration else { return }
        collected = collected.filter { _, _, ref in
            let profile = GatewayBotRoute(qualifiedID: ref.botID)?.profile ?? ref.botID
            let route = GatewayBotRoute(gatewayID: ref.gatewayID, profile: profile)
            guard let generation = routeGenerations[route] else { return false }
            return a2aRuntime.accepts(route: route, generation: generation)
        }

        let successfulGateways = Set(totalProfiles.compactMap { gatewayID, count in
            !failedGateways.contains(gatewayID)
                && completedProfiles[gatewayID, default: 0] == count ? gatewayID : nil
        })
        let merged = A2AInboxMerge.merge(
            existing: agentInbox, existingRefs: runtime.inboxSessions,
            server: collected, successfulGateways: successfulGateways,
            optimisticRows: A2ARuntime.shared.optimisticRows,
            primaryGatewayID: LiveRuntime.shared.gatewayID, limit: A2APolicy.feedLimit)
        for id in merged.settled { A2ARuntime.shared.optimisticRows[id] = nil }
        runtime.inboxSessions = merged.refs
        agentInbox = merged.messages
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
            // Replace only the inbox subscription's source. Reply watches for
            // retained secondary gateways carry their own client and survive.
            if let previous = runtime.inboxGatewayID,
               previous != activeGatewayID {
                runtime.reset(gatewayID: previous)
            }
            runtime.routedClient = identity
            runtime.inboxGatewayID = activeGatewayID
            runtime.eventGeneration &+= 1
            runtime.eventClient = identity
            runtime.eventToken = nil
            subscribeToA2AChanges(client, generation: runtime.eventGeneration,
                                   gatewayID: activeGatewayID)
        }
        sweepInbox(after: 0)
        startIdleInboxPoll()
    }

    func subscribeToA2AChanges(_ client: GatewayClient, generation: UInt64,
                                gatewayID sourceGatewayID: String?) {
        let identity = ObjectIdentifier(client)
        Task { @MainActor in
            let token = await client.addEventHandler { event in
                Task { @MainActor [weak self] in
                    self?.routeA2AChange(event, sourceGatewayID: sourceGatewayID)
                }
            }
            let runtime = A2ARuntime.shared
            guard runtime.eventGeneration == generation,
                  runtime.eventClient == identity,
                  runtime.routedClient == identity,
                  runtime.inboxGatewayID == sourceGatewayID else {
                await client.removeEventHandler(token)
                return
            }
            runtime.eventToken = token
        }
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

// MARK: - The composer middleware (plugin.js:8206-8321)

public extension AppModel {

    /// Route the @handles in a chat draft, and return the text the submit
    /// should actually carry.
    ///
    /// This is desktop's `mention-middleware` composer registration
    /// (plugin.js:8206-8321) at Talaria's matching point in the pipeline:
    /// `sendOrSteer` → here → `composedPrompt` → `send`. Upstream's handler
    /// also carries the `/new` → `/compact` reroute (8218-8241), which shares
    /// the handler and nothing else; Talaria's slash path never reaches this
    /// function, because `ChatView.send()` hands a leading "/" to `runSlash`
    /// first.
    ///
    /// Three things happen, in upstream's order:
    ///
    ///  1. the fast gate, on the RAW draft (8244) — an ordinary message does
    ///     no work at all;
    ///  2. resolution against the live roster (8252-8256 → 2434), which strips
    ///     code FIRST, so an @handle inside a fence or `backticks` is literal
    ///     text and never a handoff;
    ///  3. delivery, and then the note (8319). The note is appended; the
    ///     handles are never rewritten or stripped out of the message.
    ///
    /// An ambiguous handle is refused rather than guessed, and the refusal is
    /// said out loud — see `refuse`.
    ///
    /// Runs only against a live, online gateway. Demo mode has nobody to hand
    /// off to (`deliverHandoff` throws), and offline the draft is queued —
    /// a note promising a delivery that never happened would be a lie the
    /// agent acts on. Both return the draft untouched, which is upstream's own
    /// rule for its failure path: a mention must never block a send
    /// (8263-8265).
    func routeMentions(in text: String, from botID: String) -> String {
        guard mode == .live, !isOffline, BotMention.mentions(text) else { return text }
        let routed = MentionMiddleware.route(text, roster: unionRosterBots, speaking: botID)
        // Every dropped handle is named, whether or not something else in the
        // draft routed — a silently swallowed @token is the one outcome a
        // phone cannot afford. What changes with `delivered` is only the
        // SUBJECT of the sentence: a draft mixing "@ops" (two machines) with
        // "@ci" (one) is a handoff that happened, so "Nothing was handed off"
        // would contradict the note this same function is about to append to
        // the outgoing message — and send the user back to retype a mention
        // @ci has already received.
        let recipients = routed.recipients.compactMap(a2aEndpoint(for:))
        let delivered = !recipients.isEmpty && recipients.count == routed.recipients.count
        for collision in routed.refused { refuse(collision, in: botID, delivered: delivered) }
        guard delivered else { return text }
        guard let sender = a2aEndpoint(forRosterID: botID) else { return text }

        // Fire-and-forget, the way upstream fires `deliverRemoteRosterMentions`
        // (`void`, 8295-8300): the user's own turn starts now, not after N
        // canonical chats have been resolved over the radio. What the
        // recipients receive is the RAW draft — handles and all, not
        // fence-stripped and not the noted text (plugin.js:2599, 2635) — since
        // the note is an instruction to the SENDING agent, not part of the
        // message. Per-recipient failures are recorded on the delivery and in
        // the activity ledger by `deliverHandoff`; only a total failure earns
        // a line in this chat, because the note in the message above it has
        // already told the agent the delivery happened.
        Task { @MainActor in
            do {
                try await dispatchHandoff(from: sender, to: recipients, text: text)
            } catch {
                chat(for: botID).messages.append(ChatMessage(
                    author: .system, time: Self.clock(),
                    text: theme.copy.a2aFailedNote(theme.themeID, reason: Self.reason(error))))
            }
        }
        return routed.text
    }
}

private extension AppModel {

    /// An ambiguous handle, said out loud in the chat it was typed in.
    ///
    /// Upstream refuses silently and totally: the form map holds `null`, the
    /// token is skipped, and there is no notify anywhere in 2434-2497 or
    /// 8206-8321 for it. Silence is affordable on desktop, where the roster
    /// sits beside the composer and the two duplicate rows are visible. On a
    /// phone the roster is a screen away, so the refusal costs one system
    /// line naming the bots that collided — the same divergence, for the same
    /// reason, as `MentionResolution.ambiguous` existing at all.
    ///
    /// The message itself still sends. Refusing the mention is not refusing
    /// the turn (plugin.js:8285-8287 returns the draft untouched) — which is
    /// also why the line is appended one hop later: the middleware runs BEFORE
    /// `send()` has put the user's own bubble in the transcript, and a
    /// refusal that appears above the message it is about reads as an answer
    /// to the previous turn.
    ///
    /// `delivered` picks the SUBJECT, not whether to speak. A draft can carry
    /// an ambiguous handle and a good one at once — `MentionMiddleware.route`
    /// returns `refused` beside a non-empty `recipients` by design (2457-2466
    /// poisons one form; the rest of the draft resolves normally) — and in
    /// that case the whole-message wording ("Nothing was handed off") is
    /// simply false: the note appended to the outgoing message names a
    /// delivery that IS under way. The scoped wording says which handle was
    /// dropped and leaves the rest alone.
    func refuse(_ collision: MentionCollision, in botID: String, delivered: Bool) {
        let copy = theme.copy
        let line = delivered
            ? copy.mentionRefusedOne(theme.themeID, token: collision.token,
                                     options: collision.labels)
            : copy.mentionRefused(theme.themeID, token: collision.token,
                                  options: collision.labels)
        Task { @MainActor in
            chat(for: botID).messages.append(
                ChatMessage(author: .system, time: Self.clock(), text: line))
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
    /// feed. Recipients are independent — one failed gateway does not cancel
    /// the rest — so a per-recipient failure is recorded on that delivery and
    /// only a total failure throws.
    ///
    /// Returns the number of recipients the gateway accepted.
    /// UI boundary for the handoff sheet. Resolve all ids to source-qualified
    /// endpoints before entering dispatch; a missing route fails closed.
    @discardableResult
    func deliverHandoff(from senderID: String, to recipientIDs: [String],
                        text: String) async throws -> Int {
        guard let sender = a2aEndpoint(forRosterID: senderID) else {
            throw GatewayRouteError.noRoute
        }
        let recipients = recipientIDs.compactMap(a2aEndpoint(forRosterID:))
        guard recipients.count == recipientIDs.count else { throw GatewayRouteError.noRoute }
        return try await dispatchHandoff(from: sender, to: recipients, text: text)
    }

    @discardableResult
    internal func dispatchHandoff(from sender: A2AEndpoint, to recipients: [A2AEndpoint],
                                  text: String) async throws -> Int {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return 0 }
        var targets: [A2AEndpoint] = []
        var seen: Set<GatewayBotRoute> = []
        for endpoint in recipients
        where endpoint.route != sender.route && seen.insert(endpoint.route).inserted {
            targets.append(endpoint)
        }
        guard !targets.isEmpty else { return 0 }
        guard mode == .live else {
            throw GatewayError(code: -3, message: "connect a gateway to hand off")
        }

        // Both halves of the prefix are the sender's IDENTITY, not its profile
        // id: desktop sends `Message from 🤖 ${senderName} (@${senderHandle})`
        // (plugin.js:2635), where senderName is the display title. Sending the
        // raw profile name writes "Message from 🤖 default (@default)" into
        // another bot's permanent transcript for the profile that presents as
        // Hermes/@hermes.
        //
        // `A2AEndpoint.attributionHandle` derives from the UN-annotated profile
        // on purpose, so the handle here is the bare/alias form even when the
        // sender's name is duplicated across gateways. That is upstream's own choice, not an
        // oversight: it builds the sender with `botHandle(live.name)` —  one
        // argument, no row, so the `@name-device` branch at 2407 cannot fire
        // (plugin.js:8298). The prefix says who spoke, and the recipient reads
        // it back as a name; the device suffix belongs to addressing, which is
        // the other direction.
        var accepted = 0
        var firstFailure: Error?
        var routeWasFenced = false
        for target in targets {
            var submissionClient: GatewayClient?
            var submissionStored: String?
            var submissionBaseline: Int?
            let attemptID = UUID()
            let attributed = A2AWire.attributed(displayTitle: sender.displayTitle,
                                                handle: sender.attributionHandle,
                                                body: body, attemptID: attemptID,
                                                senderRoute: sender.route)
            let scopeGeneration = A2ARuntime.shared.scopeGenerations[
                target.route.gatewayID] ?? 0
            let targetRouteGeneration = A2ARuntime.shared.routeGeneration(for: target.route)
            let senderRouteGeneration = A2ARuntime.shared.routeGeneration(for: sender.route)
            func scopeIsCurrent() -> Bool {
                (A2ARuntime.shared.scopeGenerations[target.route.gatewayID] ?? 0)
                    == scopeGeneration
                    && A2ARuntime.shared.acceptsCompletion(
                        senderRoute: sender.route,
                        senderGeneration: senderRouteGeneration,
                        targetRoute: target.route,
                        targetGeneration: targetRouteGeneration)
            }
            do {
                let client = try await routedClient(for: target.route)
                submissionClient = client
                guard scopeIsCurrent() else { throw CancellationError() }
                let session = try await canonicalInboxSession(for: target, client: client)
                guard scopeIsCurrent() else { throw CancellationError() }
                // Baseline BEFORE the submit, so the watch can tell the reply
                // from what was already there (plugin.js:2620). A canonical
                // chat that has never been prompted has no db row at all
                // (methods_session.py:114-120), so a missing count is a real
                // zero rather than a failed read — and a stale zero is
                // harmless, because the reply scan anchors on our own message.
                let baseline = await storedMessageCount(of: session.stored,
                                                        route: target.route,
                                                        client: client) ?? 0
                submissionStored = session.stored
                submissionBaseline = baseline
                guard scopeIsCurrent() else { throw CancellationError() }
                let queued = try await client.submitHandoff(sessionID: session.runtime,
                                                            text: attributed)
                // Returning from prompt.submit is the acceptance boundary.
                // A detach racing immediately after it may stop observation,
                // but cannot turn a delivered prompt into a failure/nothing.
                let outcome = A2AAcceptedOutcome.afterSubmit(
                    scopeIsCurrent: scopeIsCurrent())
                accepted += 1
                let current = scopeIsCurrent()
                let key: String
                if current {
                    key = record(handoff: body, from: sender, to: target,
                                 attemptID: attemptID, queued: queued,
                                 state: outcome.state)
                } else {
                    // The gateway accepted the durable prompt, but lifecycle
                    // fencing won before publication. Retain only portable
                    // delivery ownership; migration can re-key it and the
                    // paused watcher can rearm without creating an old-route
                    // optimistic row or failure notice.
                    key = recordAcceptedUntracked(handoff: body, from: sender,
                                                  to: target, attemptID: attemptID,
                                                  queued: queued,
                                                  scopeGeneration: scopeGeneration,
                                                  targetGeneration: targetRouteGeneration,
                                                  senderGeneration: senderRouteGeneration,
                                                  clientID: ObjectIdentifier(client))
                }
                if outcome.retainWatcher || !current {
                    watchForReply(to: target, sender: sender, body: body,
                                  attemptID: attemptID, attributed: attributed,
                                  stored: session.stored, baseline: baseline, client: client)
                } else {
                    reportQuietHandoff(to: target, key: key)
                }
            } catch {
                if PromptMutationFailure.isAmbiguous(error) {
                    // The gateway may have accepted the prompt before the
                    // transport/decode failure. Preserve accepted-unknown
                    // ownership and fence replay; reconciliation/watch will
                    // discover the durable row without submitting again.
                    accepted += 1
                    guard let client = submissionClient,
                          let stored = submissionStored,
                          let baseline = submissionBaseline else {
                        if firstFailure == nil { firstFailure = error }
                        continue
                    }
                    _ = recordAcceptedUntracked(
                        handoff: body, from: sender, to: target,
                        attemptID: attemptID, queued: false,
                        scopeGeneration: scopeGeneration,
                        targetGeneration: targetRouteGeneration,
                        senderGeneration: senderRouteGeneration,
                        clientID: ObjectIdentifier(client))
                    watchForReply(to: target, sender: sender, body: body,
                                  attemptID: attemptID, attributed: attributed,
                                  stored: stored, baseline: baseline, client: client)
                    continue
                }
                if firstFailure == nil { firstFailure = error }
                if scopeIsCurrent() {
                    recordFailure(error, from: sender, to: target, body: body,
                                  attemptID: attemptID)
                } else {
                    routeWasFenced = true
                }
            }
        }
        // Lifecycle teardown is an expected supersession, not a transport
        // failure to announce in the old sender chat. In particular, a
        // canonical-open cancellation racing a rename must not become a late
        // `a2aFailedNote` after the profile route was retired.
        if accepted == 0, routeWasFenced { return 0 }
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
    func canonicalInboxSession(for endpoint: A2AEndpoint,
                               client: GatewayClient) async throws -> (runtime: String, stored: String) {
        let runtime = A2ARuntime.shared
        let routeGeneration = runtime.routeGeneration(for: endpoint.route)
        guard runtime.accepts(route: endpoint.route, generation: routeGeneration) else {
            throw CancellationError()
        }
        if let existing = runtime.canonicalOpens[endpoint.route] {
            guard runtime.accepts(route: endpoint.route, generation: routeGeneration) else {
                throw CancellationError()
            }
            let result = try await existing.value
            guard runtime.accepts(route: endpoint.route, generation: routeGeneration) else {
                throw CancellationError()
            }
            return (result.runtime, result.stored)
        }
        let generation = (runtime.canonicalOpenGenerations[endpoint.route] ?? 0) + 1
        runtime.canonicalOpenGenerations[endpoint.route] = generation
        let task = Task { @MainActor [weak self] () throws -> A2ACanonicalSession in
            guard let self else {
                throw GatewayError(code: -3, message: "handoff route was released")
            }
            return try await self.resolveCanonicalInboxSession(
                for: endpoint, client: client, routeGeneration: routeGeneration)
        }
        runtime.canonicalOpens[endpoint.route] = task
        defer {
            if runtime.canonicalOpenGenerations[endpoint.route] == generation {
                runtime.canonicalOpens[endpoint.route] = nil
            }
        }
        let result = try await task.value
        guard runtime.accepts(route: endpoint.route, generation: routeGeneration) else {
            throw CancellationError()
        }
        return (result.runtime, result.stored)
    }

    private func resolveCanonicalInboxSession(for endpoint: A2AEndpoint,
                                              client: GatewayClient,
                                              routeGeneration: UInt64) async throws
        -> A2ACanonicalSession {
        let botID = endpoint.rosterID
        let profile = endpoint.route.profile
        let canonical = CanonicalChatRuntime.shared
        let sampledWrite = canonical.writeCount[botID] ?? 0
        let cachedPin = canonical.pins[botID]
        var pin: String?
        do {
            guard A2ARuntime.shared.accepts(route: endpoint.route,
                                            generation: routeGeneration) else {
                throw CancellationError()
            }
            let profiles = try await client.listProfiles(includeSessions: false)
            guard A2ARuntime.shared.accepts(route: endpoint.route,
                                            generation: routeGeneration) else {
                throw CancellationError()
            }
            guard let row = profiles.first(where: { $0.name == profile }) else {
                throw GatewayRouteError.noRoute
            }
            // A successful fresh read is authoritative, including deletion;
            // only a concurrent local write may outrank this sampled answer.
            pin = A2APinAuthority.choose(
                cached: cachedPin, current: canonical.pins[botID],
                sampledWrite: sampledWrite,
                currentWrite: canonical.writeCount[botID] ?? 0,
                serverReadSucceeded: true,
                serverPin: BotModeMeta(uiMeta: row.uiMeta)?.pinnedChat)
            guard A2ARuntime.shared.accepts(route: endpoint.route,
                                            generation: routeGeneration) else {
                throw CancellationError()
            }
            canonical.pins[botID] = pin
        } catch let error as GatewayRouteError {
            throw error
        } catch {
            pin = A2APinAuthority.choose(
                cached: cachedPin, current: canonical.pins[botID],
                sampledWrite: sampledWrite,
                currentWrite: canonical.writeCount[botID] ?? 0,
                serverReadSucceeded: false, serverPin: nil)
        }
        try Task.checkCancellation()
        guard A2ARuntime.shared.accepts(route: endpoint.route,
                                        generation: routeGeneration) else {
            throw CancellationError()
        }

        // 1. Fresh server pin. 2. Gateway/database exact-title resolver. The
        // latter searches the profile store directly and cannot miss a Bot Chat
        // merely because forty newer sessions exist.
        for target in A2ASessionResolver.lookupTargets(
            pin: pin, title: Self.canonicalChatTitle) {
            do {
                let live = try await client.resumeSession(target, profile: profile,
                                                          deferHistory: true)
                try Task.checkCancellation()
                guard A2ARuntime.shared.accepts(route: endpoint.route,
                                                generation: routeGeneration) else {
                    throw CancellationError()
                }
                guard !live.sessionID.isEmpty else {
                    throw GatewayError(code: -8, message: "session.resume returned no id")
                }
                let stored = live.storedSessionID.isEmpty ? target : live.storedSessionID
                if target == Self.canonicalChatTitle, !stored.isEmpty {
                    await pinA2ACanonicalChat(stored, botID: botID,
                                              route: endpoint.route,
                                              generation: routeGeneration)
                }
                return A2ACanonicalSession(runtime: live.sessionID, stored: stored)
            } catch let error as GatewayError where error.code == GatewayError.storedSessionGone {
                continue
            } catch {
                throw error
            }
        }
        try Task.checkCancellation()
        guard A2ARuntime.shared.accepts(route: endpoint.route,
                                        generation: routeGeneration) else {
            throw CancellationError()
        }

        // 3. No exact canonical session exists: mint one hidden.
        // Born hidden, like every Bot Mode session (plugin.js:2540-2542): a
        // handoff must not drop a stray "Bot Chat" row into desktop's recents.
        let created = try await client.createSession(profile: profile,
                                                     title: Self.canonicalChatTitle, hidden: true)
        try Task.checkCancellation()
        guard A2ARuntime.shared.accepts(route: endpoint.route,
                                        generation: routeGeneration) else {
            throw CancellationError()
        }
        guard !created.sessionID.isEmpty else {
            throw GatewayError(code: -8, message: "session.create returned no id")
        }
        if !created.storedSessionID.isEmpty {
            // Same block desktop pins into, so the phone's handoff and the
            // laptop's roster tap open the same conversation.
            await pinA2ACanonicalChat(created.storedSessionID, botID: botID,
                                      route: endpoint.route,
                                      generation: routeGeneration)
        }
        try Task.checkCancellation()
        guard A2ARuntime.shared.accepts(route: endpoint.route,
                                        generation: routeGeneration) else {
            throw CancellationError()
        }
        return A2ACanonicalSession(runtime: created.sessionID,
                                   stored: created.storedSessionID)
    }

    /// `pinCanonicalChat` is shared with the ordinary chat opener and has no
    /// A2A route token of its own. Keep this narrow wrapper at every A2A
    /// pin/create completion so a late old-profile result cannot write a pin
    /// into a renamed/deleted profile.
    private func pinA2ACanonicalChat(_ storedID: String, botID: String,
                                     route: GatewayBotRoute,
                                     generation: UInt64) async {
        guard A2ARuntime.shared.accepts(route: route, generation: generation) else {
            return
        }
        await pinCanonicalChat(storedID, botID: botID)
    }

    /// Stored row count for a session this app does not own — the cheap side
    /// of the reply watch. `session.list` reads the profile's db directly and
    /// returns `message_count` per row (methods_session.py:210) without
    /// touching the live session, so it can be polled without disturbing a
    /// turn in flight. `include_hidden` because every Bot Mode session is
    /// hidden (methods_session.py:180-186).
    func storedMessageCount(of storedID: String, route: GatewayBotRoute,
                            client: GatewayClient) async -> Int? {
        guard !storedID.isEmpty else { return nil }
        guard let rows = try? await client.listSessions(limit: 40, profile: route.profile,
                                                        includeHidden: true) else { return nil }
        return rows.first(where: { $0.id == storedID })?.messageCount
    }

    @discardableResult
    func record(handoff body: String, from sender: A2AEndpoint, to target: A2AEndpoint,
                attemptID: UUID, queued: Bool, state: A2ADelivery.State = .waiting) -> String {
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(route: target.route, body: body, attemptID: attemptID)
        runtime.watchers.removeValue(forKey: key)?.cancel()
        runtime.watcherRegistrations.removeValue(forKey: key)
        runtime.deliveries[key] = A2ADelivery(to: target.rosterID, route: target.route,
                                              senderRoute: sender.route,
                                              senderRosterID: sender.rosterID,
                                              attemptID: attemptID,
                                              bodyHash: Self.stableHash(body),
                                              queuedBehindRun: queued,
                                              state: state, at: Date())
        runtime.prune()

        // Show it immediately; the sweep replaces it with the stored row.
        agentInbox.insert(A2AMessage(id: attemptID, fromBotID: sender.rosterID,
                                     toBotID: target.rosterID,
                                     time: Self.clock(), text: body), at: 0)
        runtime.optimisticRows[attemptID] = target.route.gatewayID
        runtime.optimisticOwners[attemptID] = A2AOptimisticOwner(
            target: target.route, targetRosterID: target.rosterID,
            sender: sender.route, senderRosterID: sender.rosterID)
        FeedsRuntime.shared.lastInboxScan = nil
        recordActivity(kind: .mention, botID: target.rosterID,
                       text: theme.copy.feedHandoffSent(theme.themeID)
                           + " @" + sender.handle,
                       subtext: Self.previewLine(body))
        // …and out loud, the first of desktop's three delivery outcomes
        // (plugin.js:2637-2641). The composer has already closed on the send, so
        // without this a handoff typed in one bot's chat vanishes with nothing
        // to say it is on its way — the promise being made here is specifically
        // *"will relay the reply here"*, which is the part a user cannot guess.
        //
        // `ledger: false` on all three: the rows above and in `relay` /
        // `recordFailure` are this event's ledger entries already, written by the
        // A2A path with its own keys. A mirror would file a second row for one
        // delivery, which is the thing `toast()`'s key pairing exists to prevent.
        toast(kind: .info,
              title: theme.copy.toastHandoffSent(target.handle,
                                                 on: target.connectionLabel, theme.themeID),
              message: Self.previewLine(body),
              botID: target.rosterID, key: "handoff:\(key)", ledger: false)
        return key
    }

    /// One recipient could not be reached while others could. The composer has
    /// already closed on the ones that worked, so the ledger is the only place
    /// left to say so — and it is the right place: the row survives the sweep,
    /// which is about to rebuild the feed from transcripts this message never
    /// reached.
    /// The prompt crossed the wire, but lifecycle fencing won before the UI
    /// could publish it. Keep only portable delivery ownership; migration
    /// re-keys it and the paused watcher can rearm without an old-route row.
    @discardableResult
    func recordAcceptedUntracked(handoff body: String, from sender: A2AEndpoint,
                                 to target: A2AEndpoint, attemptID: UUID,
                                 queued: Bool, scopeGeneration: Int,
                                 targetGeneration: UInt64, senderGeneration: UInt64,
                                 clientID: ObjectIdentifier) -> String {
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(route: target.route, body: body, attemptID: attemptID)
        runtime.deliveries[key] = A2ADelivery(
            to: target.rosterID, route: target.route,
            senderRoute: sender.route, senderRosterID: sender.rosterID,
            submitScopeGeneration: scopeGeneration,
            submitTargetGeneration: targetGeneration,
            submitSenderGeneration: senderGeneration,
            submitClientID: clientID,
            requiresExplicitRearm: true,
            attemptID: attemptID, bodyHash: Self.stableHash(body),
            queuedBehindRun: queued, state: .waiting, at: Date())
        runtime.prune()
        runtime.pendingRearms.insert(key)
        return key
    }

    func recordFailure(_ error: Error, from sender: A2AEndpoint,
                       to target: A2AEndpoint, body: String, attemptID: UUID) {
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(route: target.route, body: body, attemptID: attemptID)
        runtime.watchers.removeValue(forKey: key)?.cancel()
        runtime.watcherRegistrations.removeValue(forKey: key)
        runtime.deliveries[key] = A2ADelivery(to: target.rosterID, route: target.route,
                                              senderRoute: sender.route,
                                              senderRosterID: sender.rosterID,
                                              attemptID: attemptID,
                                              bodyHash: Self.stableHash(body),
                                              queuedBehindRun: false,
                                              state: .failed(Self.reason(error)), at: Date())
        runtime.prune()
        recordActivity(kind: .mention, botID: target.rosterID,
                       text: theme.copy.a2aFailedNote(theme.themeID,
                                                      reason: Self.reason(error)),
                       subtext: Self.previewLine(body))
        // plugin.js:2659 — `notifyError(error, "Could not reach <label>")`. It
        // replaces the "on its way" card under the same key, so one delivery
        // stays one card even when it ends badly.
        toast(kind: .failure,
              title: theme.copy.toastCouldNotReach(target.connectionLabel
                                                       ?? target.displayTitle,
                                                   theme.themeID),
              message: Self.reason(error),
              botID: target.rosterID, key: "handoff:\(key)", ledger: false)
    }

    /// Wait out the recipient's turn and relay its answer, bounded
    /// (plugin.js:2549). A timeout is not an error — the message is in their
    /// chat and the next sweep will find the reply whenever it lands.
    func watchForReply(to target: A2AEndpoint, sender: A2AEndpoint, body: String,
                       attemptID: UUID, attributed: String, stored: String, baseline: Int,
                       client: GatewayClient) {
        guard !stored.isEmpty else { return }
        let runtime = A2ARuntime.shared
        let key = Self.deliveryKey(route: target.route, body: body, attemptID: attemptID)
        let generation = runtime.installWatcher(key: key, target: target, sender: sender)
        var scopeGeneration = runtime.scopeGenerations[target.route.gatewayID] ?? 0
        var activeClient = client
        var deadline = Date().addingTimeInterval(A2APolicy.replyDeadline)
        runtime.watchers[key] = Task { @MainActor [weak self] in
            defer {
                // Only if this is still the live watch for the key.
                if A2ARuntime.shared.watcherGeneration[key] == generation {
                    A2ARuntime.shared.watchers[key] = nil
                    A2ARuntime.shared.watcherScopes[key] = nil
                    A2ARuntime.shared.watcherRegistrations[key] = nil
                }
            }
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(A2APolicy.replyPoll))
                if A2ARuntime.shared.watcherIsPaused(key: key, generation: generation) {
                    // A committed rename will update this registration in
                    // place. Do not let the old route poll or emit a quiet
                    // result while Hermes is moving its directory.
                    deadline = Date().addingTimeInterval(A2APolicy.replyDeadline)
                    continue
                }
                guard !Task.isCancelled, let self, self.mode == .live,
                      let ownership = A2ARuntime.shared.watcherRegistration(
                        key: key, generation: generation),
                      (A2ARuntime.shared.scopeGenerations[ownership.target.route.gatewayID]
                        ?? 0) >= scopeGeneration else { return }
                let currentTarget = ownership.target
                // A primary retirement or a secondary pool replacement can
                // invalidate the captured client while preserving this watch.
                // Reacquire by the migrated route before polling; never send
                // the old profile name through a dead client.
                guard let reacquired = try? await self.routedClient(for: currentTarget.route),
                      !Task.isCancelled,
                      let reacquiredOwnership = A2ARuntime.shared.watcherRegistration(
                        key: key, generation: generation) else { return }
                activeClient = reacquired
                scopeGeneration = A2ARuntime.shared.scopeGenerations[
                    reacquiredOwnership.target.route.gatewayID] ?? scopeGeneration
                // Cheap probe first: nothing has been written, nothing to read.
                let count = await self.storedMessageCount(of: stored,
                                                          route: currentTarget.route,
                                                          client: activeClient)
                // The probe itself suspended. Re-read ownership before
                // interpreting its count: a committed rename may have moved
                // the watcher to a new profile while the old request was in
                // flight. Restart that poll rather than resume the old
                // profile or relay against its route.
                guard let postProbeOwnership = A2ARuntime.shared.watcherRegistration(
                    key: key, generation: generation) else { return }
                guard postProbeOwnership.target == currentTarget else { continue }
                guard let postProbeClient = try? await self.routedClient(
                    for: postProbeOwnership.target.route),
                      !Task.isCancelled,
                      let currentAfterProbe = A2ARuntime.shared.watcherRegistration(
                        key: key, generation: generation) else { return }
                guard currentAfterProbe.target == currentTarget else { continue }
                activeClient = postProbeClient
                scopeGeneration = A2ARuntime.shared.scopeGenerations[
                    currentAfterProbe.target.route.gatewayID] ?? scopeGeneration
                if let count, count <= baseline { continue }
                // Something landed. One authoritative read — `running` and
                // `inflight` are what say the turn is finished rather than
                // half-written (plugin.js:2566).
                guard let live = try? await activeClient.resumeSession(stored,
                                                                 profile: currentTarget.route.profile,
                                                                 deferHistory: false),
                      !Task.isCancelled,
                      let currentOwnership = A2ARuntime.shared.watcherRegistration(
                        key: key, generation: generation),
                      (A2ARuntime.shared.scopeGenerations[currentOwnership.target.route.gatewayID]
                        ?? 0) == scopeGeneration,
                      !live.running, live.inflight == nil,
                      let reply = A2AReplyResolver.reply(to: attributed,
                                                        in: live.messages) else { continue }
                self.relay(reply: reply, from: currentOwnership.target,
                           to: currentOwnership.sender, key: key)
                return
            }
            guard A2ARuntime.shared.watcherGeneration[key] == generation,
                  let ownership = A2ARuntime.shared.watcherRegistration(
                    key: key, generation: generation),
                  (A2ARuntime.shared.scopeGenerations[ownership.target.route.gatewayID]
                    ?? 0) == scopeGeneration else { return }
            if var delivery = A2ARuntime.shared.deliveries[key], delivery.state == .waiting {
                delivery.state = .quiet
                A2ARuntime.shared.deliveries[key] = delivery
                // The third outcome (plugin.js:2652-2655). Not a failure and
                // deliberately not worded as one: the message IS in their chat
                // and the next sweep will find the answer whenever it lands —
                // what expired is this watch, not the delivery. Saying nothing
                // here is what left the "will relay the reply here" promise
                // with no ending at all.
                self?.reportQuietHandoff(to: ownership.target, key: key)
            }
        }
    }

    /// The reply watch ran out. Split off the closure above so the toast reads
    /// as one statement rather than four optional-chained fragments.
    private func reportQuietHandoff(to target: A2AEndpoint, key: String) {
        toast(kind: .info,
              title: theme.copy.toastNoReplyYet(target.handle,
                                                on: target.connectionLabel, theme.themeID),
              botID: target.rosterID, key: "handoff:\(key)", ledger: false)
    }

    /// The reply to OUR message: the newest assistant turn that follows the
    /// user row we wrote. Upstream takes the last assistant message outright
    /// (plugin.js:2569-2583); anchoring to our own row instead keeps a queued
    /// handoff from relaying the answer to whatever the bot was already doing.
    func relay(reply: String, from initialTarget: A2AEndpoint,
               to initialSender: A2AEndpoint, key: String) {
        var target = initialTarget
        var sender = initialSender
        // The watch may have resumed from an RPC after lifecycle teardown. Its
        // closure's endpoints are only fallbacks; an active registration is
        // the source of truth and is updated in place on rename. No
        // registration means delete/retire won the race, so do not relay.
        if let registration = A2ARuntime.shared.watcherRegistrations[key] {
            guard !registration.paused,
                  A2ARuntime.shared.accepts(
                    route: registration.target.route,
                    generation: registration.targetGeneration),
                  A2ARuntime.shared.accepts(
                    route: registration.sender.route,
                    generation: registration.senderGeneration) else { return }
            target = registration.target
            sender = registration.sender
        } else if let delivery = A2ARuntime.shared.deliveries[key] {
            guard let route = delivery.route,
                  A2ARuntime.shared.accepts(
                    route: route, generation: A2ARuntime.shared.routeGeneration(for: route)),
                  let senderRoute = delivery.senderRoute,
                  A2ARuntime.shared.accepts(
                    route: senderRoute,
                    generation: A2ARuntime.shared.routeGeneration(for: senderRoute)) else {
                return
            }
        } else {
            return
        }
        let attemptID = A2ARuntime.shared.deliveries[key]?.attemptID
        if var delivery = A2ARuntime.shared.deliveries[key] {
            delivery.state = .replied
            A2ARuntime.shared.deliveries[key] = delivery
        }
        let replyID = attemptID.map(A2AWire.replyID(for:)) ?? UUID()
        agentInbox.insert(A2AMessage(id: replyID, fromBotID: target.rosterID,
                                     toBotID: sender.rosterID,
                                     time: Self.clock(), text: Self.previewLine(reply)), at: 0)
        A2ARuntime.shared.optimisticRows[replyID] = target.route.gatewayID
        A2ARuntime.shared.optimisticOwners[replyID] = A2AOptimisticOwner(
            target: target.route, targetRosterID: target.rosterID,
            sender: sender.route, senderRosterID: sender.rosterID)
        recordActivity(kind: .mention, botID: sender.rosterID,
                       text: theme.copy.feedHandoffReply(theme.themeID)
                           + " @" + target.handle,
                       subtext: Self.previewLine(reply))
        // The answer, out loud (plugin.js:2646-2650): title `🤖 <name>
        // (<label>)`, body the reply clipped to 500. Filed under the RESPONDER,
        // whose face the card wears — the event being reported is that bot
        // having spoken, and the ledger row above is filed under the sender
        // because what IT records is the reply arriving back.
        toast(kind: .success,
              title: theme.copy.toastHandoffReply(target.displayTitle,
                                                  on: target.connectionLabel, theme.themeID),
              message: ActivityNotice.clip(reply, to: ActivityNotice.replyLimit),
              botID: target.rosterID, key: "handoff:\(key)", ledger: false)
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

    /// The same refusal, said in a bot chat rather than under a composer, and
    /// naming the bots that collided — the composer strip can show two rows,
    /// a transcript has to say it in a sentence. Falls back to the composer
    /// wording if the collision arrived without its cause.
    ///
    /// The subject is the WHOLE message ("nothing was handed off"), so this is
    /// the line for a draft where nothing routed at all. When something did,
    /// use `mentionRefusedOne`.
    func mentionRefused(_ t: ThemeID, token: String, options: [String]) -> String {
        guard !options.isEmpty else { return mentionAmbiguous(t, token: token) }
        let list = options.joined(separator: " or ")
        return switch t {
        case .soft: "Nothing was handed off — @\(token) fits \(list). Name the one you mean."
        case .control: "NO HANDOFF — @\(token) FITS \(list.uppercased()). NAME ONE."
        case .ink: "@\(token) answers for \(list) alike, so nothing was carried. Name the one you mean."
        }
    }

    /// One ambiguous handle in a draft that DID hand off to somebody else.
    ///
    /// Scoped to the token, because the message above it carries a note
    /// promising a delivery to the handles that resolved: a line claiming
    /// nothing was sent would contradict the transcript one bubble up, and
    /// would send the user back to retype a mention the other bot has already
    /// received. Same instruction, narrower subject.
    func mentionRefusedOne(_ t: ThemeID, token: String, options: [String]) -> String {
        guard !options.isEmpty else { return mentionAmbiguous(t, token: token) }
        let list = options.joined(separator: " or ")
        return switch t {
        case .soft: "@\(token) was left out — it fits \(list). Name the one you mean."
        case .control: "@\(token) DROPPED — FITS \(list.uppercased()). NAME ONE."
        case .ink: "@\(token) answers for \(list) alike, so that one alone was not carried. "
            + "Name the one you mean."
        }
    }

    func mentionUnknown(_ t: ThemeID, token: String) -> String {
        switch t {
        case .soft: "No bot answers to @\(token)."
        case .control: "@\(token) — NO SUCH HANDLE."
        case .ink: "None answers to @\(token)."
        }
    }

    /// Addressed, but on another gateway. Desktop delivers this one over
    /// Connections (plugin.js:8312-8317); a phone holds one socket, so it says
    /// where the bot is instead — naming the device the way upstream's own
    /// remote note does (8313, `@handle (label)`).
    func mentionElsewhere(_ t: ThemeID, handle: String, label: String) -> String {
        let where_ = label.trimmingCharacters(in: .whitespaces)
        guard !where_.isEmpty else {
            return switch t {
            case .soft: "@\(handle) is on another gateway — switch to it to send this."
            case .control: "@\(handle) — OTHER GATEWAY. SWITCH TO SEND."
            case .ink: "@\(handle) keeps another house; go there to be heard."
            }
        }
        return switch t {
        case .soft: "@\(handle) lives on \(where_) — switch to that gateway to send this."
        case .control: "@\(handle) — ON \(where_.uppercased()). SWITCH GATEWAY TO SEND."
        case .ink: "@\(handle) keeps house on \(where_); go there to be heard."
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

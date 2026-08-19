import Foundation
import Observation
import TalariaKit

// Phase 4 — one roster across every configured Connection.
//
// Desktop's Bot Mode roster is a union, not a list: `useRoster` merges the
// active gateway's rich `profiles.list` with `host.agents()` across every
// registered Connection (plugin.js:2265-2360). Same-source rows are annotated
// in place; rows from other sources are appended as thin `remoteSource` rows
// carrying a device label, and the duplicate-name rule mints `@name-device`
// handles once across all sources (electron/connection-registry.ts:330-372).
//
// `GatewayClientPool` keeps authenticated secondary connections alive and
// coalesces dials. Chat, events, sessions, approvals, and unread state retain
// their source route instead of switching the primary AppModel world.

/// Book-keeping for the union roster. `AppModel`'s stored properties live in
/// AppModel.swift (another owner); extensions cannot add storage, so the
/// in-flight switch rides a MainActor singleton — observable, because roster
/// rows read it from a view body to go inert while a switch is under way.
@MainActor
@Observable
final class MultiGatewayRuntime {
    static let shared = MultiGatewayRuntime()

    /// Gateway id of a switch in flight — a second tap while the world is
    /// being torn down and rebuilt would race `switchGateway` against itself.
    var switchingGatewayID: String?

    struct RoutedEvents {
        var client: GatewayClient
        var handlerID: UUID
        var pump: Task<Void, Never>
    }

    var routedEvents: [String: RoutedEvents] = [:]
    /// Unread counts for bots whose gateway is not currently primary.
    /// Primary rows keep the existing `Bot.unread` storage for compatibility;
    /// gateway switches move counts between the two representations.
    var routedUnread: [GatewayBotRoute: Int] = [:]
}

public extension AppModel {

    enum GatewayRouteError: LocalizedError {
        case noRoute
        case unknownGateway(String)
        case missingCredential(String)

        public var errorDescription: String? {
            switch self {
            case .noRoute: return "The bot has no gateway route."
            case .unknownGateway(let id): return "Gateway \(id) is no longer registered."
            case .missingCredential(let name): return "Sign in to \(name) to continue."
            }
        }
    }

    // MARK: - The active source

    /// Saved-gateway id of the live link, or nil when nothing is connected.
    /// Nil is meaningful: with no live gateway every saved one is a foreign
    /// source, so the honest empty roster still shows what it last knew.
    var activeGatewayID: String? {
        guard client != nil, let base = LiveRuntime.shared.baseURL else { return nil }
        return ConnectionRegistry.shared.gateway(forURL: base)?.id
    }

    /// Display label of the live gateway, for the "you are here" annotation.
    var activeConnectionLabel: String? {
        guard let base = LiveRuntime.shared.baseURL else { return nil }
        return ConnectionRegistry.shared.gateway(forURL: base)?.name
    }

    /// Resolve a roster identity without guessing which machine owns a bare
    /// profile name.
    func gatewayRoute(for rosterID: String) -> GatewayBotRoute? {
        GatewayBotRoute.resolve(rosterID: rosterID, activeGatewayID: activeGatewayID)
    }

    /// Resolve state ownership without requiring a connected client. Unlike
    /// `gatewayRoute`, this is valid during reconnect and gateway switching,
    /// when UI state still needs a collision-safe key.
    func stateRoute(for rosterID: String) -> GatewayBotRoute? {
        if let qualified = GatewayBotRoute(qualifiedID: rosterID) { return qualified }
        guard let gatewayID = LiveRuntime.shared.gatewayID, !rosterID.isEmpty else { return nil }
        return GatewayBotRoute(gatewayID: gatewayID, profile: rosterID)
    }

    func gatewayBaseURL(for route: GatewayBotRoute) -> URL? {
        if route.gatewayID == LiveRuntime.shared.gatewayID { return LiveRuntime.shared.baseURL }
        return ConnectionRegistry.shared.saved.first(where: { $0.id == route.gatewayID })?.baseURL
    }

    /// Obtain the client that owns a source-qualified bot. The primary client
    /// is reused directly; secondary clients are connected and retained by the
    /// registry pool without changing the app's active gateway.
    func routedClient(for route: GatewayBotRoute) async throws -> GatewayClient {
        try await routedClient(gatewayID: route.gatewayID)
    }

    /// Resolve a connection when the protocol request has no profile field
    /// (sudo/secret responses are keyed only by request_id).
    func routedClient(gatewayID: String) async throws -> GatewayClient {
        if gatewayID == activeGatewayID, let client { return client }
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL else {
            throw GatewayRouteError.unknownGateway(gatewayID)
        }
        guard let credential = registry.credential(for: gateway) else {
            throw GatewayRouteError.missingCredential(gateway.name)
        }
        return try await registry.clientPool.connect(gatewayID: gateway.id,
                                                     baseURL: baseURL,
                                                     credential: credential)
    }

    /// Subscribe once to a secondary gateway and retain source information on
    /// every event. An AsyncStream pump preserves the order in which the
    /// GatewayClient fan-out delivered deltas.
    func attachRoutedEventsIfNeeded(client: GatewayClient, gatewayID: String,
                                    preserveStateOnReplacement: Bool = false) async {
        guard gatewayID != activeGatewayID else { return }
        let runtime = MultiGatewayRuntime.shared
        if let existing = runtime.routedEvents[gatewayID],
           ObjectIdentifier(existing.client) == ObjectIdentifier(client) { return }
        if preserveStateOnReplacement {
            await removeRoutedEventSubscription(gatewayID: gatewayID)
        } else {
            await detachRoutedEvents(gatewayID: gatewayID)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let handlerID = await client.addEventHandler { continuation.yield($0) }
        let pump = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event: event, sourceGatewayID: gatewayID)
                self.handleBridgeEvent(event, sourceGatewayID: gatewayID)
                self.routeToolEvent(event, sourceGatewayID: gatewayID)
                self.routeSessionEvent(event, sourceGatewayID: gatewayID)
                self.routePetEvent(event, sourceGatewayID: gatewayID)
            }
        }
        runtime.routedEvents[gatewayID] = MultiGatewayRuntime.RoutedEvents(
            client: client, handlerID: handlerID, pump: pump)
        ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
        Task { @MainActor [weak self] in await self?.replayPendingApprovals() }
    }

    func detachRoutedEvents(gatewayID: String) async {
        await removeRoutedEventSubscription(gatewayID: gatewayID)
        dropApprovalScope(gatewayID: gatewayID)
        dropRoutineScope(gatewayID: gatewayID)
        dropCapabilityScope(gatewayID: gatewayID)
        ProfileAssetStore.shared.drop(gatewayID: gatewayID)
        dropPetScope(gatewayID: gatewayID)
        LiveRuntime.shared.resetRoutedState(gatewayID: gatewayID)
        CanonicalChatRuntime.shared.resetRoutedScope(gatewayID: gatewayID)
        SessionsRuntime.shared.resetRoutedScope(gatewayID: gatewayID)
    }

    private func removeRoutedEventSubscription(gatewayID: String) async {
        if let subscription = MultiGatewayRuntime.shared.routedEvents.removeValue(
            forKey: gatewayID) {
            subscription.pump.cancel()
            await subscription.client.removeEventHandler(subscription.handlerID)
        }
    }

    // MARK: - The union roster

    /// Roster rows that live on a gateway other than the live one.
    ///
    /// Empty in demo mode: the canned world is not a gateway, and mixing real
    /// machines into it would make the demo lie about what is connected.
    var foreignRosterEntries: [ForeignRosterEntry] {
        guard !demoDataLoaded else { return [] }
        return ConnectionRegistry.shared.foreignRoster(activeProfiles: bots.map(\.id),
                                                       activeGatewayID: activeGatewayID)
    }

    /// The foreign half of `filterBots` (plugin.js:2963-2981).
    ///
    /// Desktop keeps thin remote rows in the SAME roster array it filters
    /// (plugin.js:2345-2357, 7668), so one query narrows both halves of the
    /// list at once — and the fourth match field exists precisely for this
    /// half: typing "homelab" lists every bot living on the Homelab
    /// connection (plugin.js:2974-2976). Talaria draws the two halves as two
    /// blocks, so the filter has to be applied twice; the rules are the same
    /// ones, out of `RosterSearch`.
    ///
    /// Order is untouched, as everywhere else search runs: the entries come
    /// back in `foreignRoster`'s gateway-then-recency order.
    ///
    /// Filtered through `rosterBot(for:)` — the row this half actually paints
    /// — and not through fields re-derived from the entry. Upstream's
    /// `filterBots` reads every one of its four fields off the same helpers
    /// that render the row (`displayName` at 2971, `botHandle` at 2973), thin
    /// remote rows included, so search and paint cannot drift apart. Doing the
    /// derivation twice here did drift: `rosterBot` resolves a bare-name entry
    /// through `Bot.handle`, so a foreign `default` PAINTS `@hermes` while the
    /// entry's own `handle` field still says "default" — and typing the handle
    /// printed on the row dropped it from the list.
    func foreignRosterEntries(matching needle: String) -> [ForeignRosterEntry] {
        guard !needle.isEmpty else { return foreignRosterEntries }
        return foreignRosterEntries.filter { rosterBot(for: $0).matchesRosterSearch(needle) }
    }

    /// Saved gateways that contributed nothing and why — a footnote the user
    /// can act on (sign in, or wake the machine), never a bare error.
    var foreignRosterProblems: [SecondaryRosterProblem] {
        guard !demoDataLoaded else { return [] }
        return ConnectionRegistry.shared.secondaryRosterProblems(activeGatewayID: activeGatewayID)
    }

    /// True when there is a second source worth drawing a divider for.
    var rosterSpansGateways: Bool {
        !foreignRosterEntries.isEmpty || !foreignRosterProblems.isEmpty
    }

    /// A foreign entry as a `Bot`, so it renders through the same avatar and
    /// identity path as every other row — desktop's thin `remoteSource` row
    /// (plugin.js:2348-2356), which it pushes into the SAME array as the live
    /// ones.
    ///
    /// The id is the source-qualified `botRosterKey` (plugin.js:2669), which
    /// cannot collide with a live profile id — that is the point. The bare
    /// name and the device label travel in `remoteSource` rather than being
    /// derived from that id, because nothing can be: `Bot.displayTitle` would
    /// de-slug "homelab::default" into "Homelab::default", and the resolver
    /// would register a form no @token can spell.
    func rosterBot(for entry: ForeignRosterEntry) -> Bot {
        // A bare-name entry keeps the plain rules (default → Hermes/@hermes);
        // a disambiguated one already carries its `name-device` form, which
        // desktop's botHandle() prefers verbatim (plugin.js:2406-2412).
        let plain = Bot.unlisted(id: entry.profile)
        let handle = entry.handle == entry.profile ? plain.handle : entry.handle
        return Bot(id: entry.id,
                   job: entry.job,
                   shape: entry.shape ?? BotCosmetics.derivedShape(forName: entry.profile),
                   hue: entry.hue ?? BotCosmetics.derivedHue(forName: entry.profile),
                   status: .idle,
                   preview: entry.preview,
                   previewTime: Self.shortTime(entry.lastActive),
                   unread: MultiGatewayRuntime.shared.routedUnread[
                    GatewayBotRoute(gatewayID: entry.gatewayID, profile: entry.profile)
                   ] ?? 0,
                   description: entry.job,
                   // The far gateway's `ui_meta` title, or nothing — never a
                   // stand-in derived here. `Bot.displayTitle` applies the
                   // rules itself, and a synthesised "Hermes" in this slot
                   // claimed a user-set title the profile does not have,
                   // which is what shadowed the remote-default rule
                   // (plugin.js:2941-2943) and left both machines' primary
                   // agents reading `Hermes` on one screen.
                   title: entry.title,
                   handleOverride: handle,
                   remoteSource: BotSource(profile: entry.profile,
                                           gatewayID: entry.gatewayID,
                                           connectionLabel: entry.connectionLabel))
    }

    // MARK: - The @name-device rule, applied to BOTH sides

    /// The live gateway's own rows, with the duplicate-name rule applied.
    ///
    /// This is desktop's annotate-in-place path (plugin.js:2331-2338), whose
    /// comment is the whole justification: "the @name-device handle only
    /// differs from the bare name when the profile exists on several sources".
    /// Upstream applies `agentHandle` to EVERY colliding identity, the active
    /// connection's included (connection-registry.ts:362-370), so a phone
    /// bound to "MacBook" that also has a saved "Homelab" carrying `default`
    /// shows `@default-macbook` here and `@default-homelab` there — not a bare
    /// `@hermes` on the near side, which is what Talaria drew before: the
    /// counting already included the live profiles, but only foreign rows were
    /// ever stamped with the result.
    ///
    /// Nothing is annotated when there is no duplicate, so the common
    /// single-gateway phone keeps `@hermes` and this is a cheap no-op.
    ///
    /// WITHOUT A LABEL THERE IS NO SUFFIX TO MINT. The label is taken from the
    /// saved gateway `activeGatewayID` names — deliberately that one, and not
    /// `activeConnectionLabel`, so the gateway whose label goes into the
    /// suffix is EXACTLY the gateway `foreignRoster` leaves out of the foreign
    /// half. Anything looser lets the live gateway appear on both sides during
    /// a connect or a switch, and mint the same handle twice — which the
    /// resolver would then poison, making a bot unaddressable from its own
    /// roster row.
    ///
    /// So there is no suffix until the socket is bound to a saved Connection.
    /// Slugging an absent label would mint `default-connection` (`labelSlug`'s
    /// fallback), a handle naming a machine that does not exist. The live row
    /// keeps its bare handle instead, and if a saved gateway claims the same
    /// name the resolver poisons the bare form between them: the row stays
    /// reachable only through a form nothing else claims (`@hermes`, for the
    /// primary profile) and not at all for any other name. That is the safe
    /// side of the coin the whole rule is built on — refuse rather than guess
    /// (plugin.js:2457-2466) — because the alternative is delivering to
    /// whichever machine happens to be live.
    var liveRosterBots: [Bot] {
        guard !demoDataLoaded, let liveID = activeGatewayID,
              let label = ConnectionRegistry.shared.saved.first(where: { $0.id == liveID })?.name
        else { return bots }
        let duplicated = ConnectionRegistry.shared
            .duplicatedProfileNames(activeProfiles: bots.map(\.id), activeGatewayID: liveID)
        guard !duplicated.isEmpty else { return bots }
        return bots.map { bot in
            let name = AgentHandle.profileName(bot.id)
            guard duplicated.contains(name) else { return bot }
            var annotated = bot
            annotated.handleOverride = AgentHandle.mint(profile: name,
                                                       connectionLabel: label,
                                                       duplicated: true)
            return annotated
        }
    }

    /// One roster across every configured Connection — `mergeMultiSourceRoster`'s
    /// output (plugin.js:2270-2398): annotated live rows first, then the thin
    /// foreign ones, in one array.
    ///
    /// The mention surfaces read THIS, not `bots`. Both halves have to meet in
    /// one array before the duplicate-name rule can do anything at all: the
    /// resolver's form map is where two `default` rows collide and poison the
    /// bare name (2457-2466), and the completion provider is where the
    /// `@name-device` form is offered in the first place. Reading `bots` alone
    /// left the minted handle rendering on the roster and addressable by
    /// nobody.
    ///
    /// The roster surface draws the two halves as sections with a source
    /// divider, while actions still route through this one identity domain.
    var unionRosterBots: [Bot] {
        liveRosterBots + foreignRosterEntries.map { rosterBot(for: $0) }
    }

    // MARK: - Refresh

    /// Top up every secondary gateway's roster. Cheap when nothing is due:
    /// the registry rate-limits per gateway and skips hosts the status probe
    /// just found asleep.
    func refreshUnionRoster() async {
        // The canned world shows no foreign rows, so dialling real machines
        // for an answer nothing renders is pure radio — and a demo that
        // silently reaches a homelab is not a demo.
        guard !demoDataLoaded else { return }
        let excluded: Set<String> = client != nil
            ? Set([LiveRuntime.shared.baseURL?.absoluteString].compactMap { $0 })
            : []
        await ConnectionRegistry.shared.enumerateSecondaryRosters(excluding: excluded)
        applySecondaryUnreadAnswers()
    }

    /// Keep the union roster warm while the roster screen is on-stage. Driven
    /// by a SwiftUI `.task`, so it dies with the view rather than dialling
    /// other people's machines in the background forever.
    func superviseUnionRoster(every seconds: TimeInterval = 45) async {
        // The roster is the first screen the app paints, in a race with the
        // launch reconnect: at that instant nothing is live, so every saved
        // gateway — including the one about to become live — looks like a
        // secondary worth a probe socket. Letting the reconnect land first is
        // the same debounce `kickSecondaryEnumeration` takes, for the same
        // reason (`enumerate` re-checks at dial time for the slower case).
        try? await Task.sleep(for: .seconds(2))
        while !Task.isCancelled {
            await refreshUnionRoster()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - Opening a bot on another gateway

    /// A switch is being performed — rows stay tappable but inert.
    var isSwitchingGateway: Bool {
        MultiGatewayRuntime.shared.switchingGatewayID != nil
    }

    /// Tapping a foreign row opens its source-qualified canonical chat while
    /// the primary app gateway stays in place. The connection and transcript
    /// attach happen asynchronously through the same openChat door as local
    /// bots, so failures render in that bot's chat instead of erasing the
    /// current world.
    func openForeignBot(_ entry: ForeignRosterEntry) async {
        openChat(botID: entry.id)
    }

    /// Become a saved gateway, from a roster row rather than the Connections
    /// screen. Wraps `switchGateway` with the in-flight flag so a second tap
    /// during the teardown-and-redial cannot start a competing switch — the
    /// roster is a fast, thumb-sized surface and double taps are the norm.
    ///
    /// A gateway with no Keychain credential raises the re-auth banner from
    /// inside `switchGateway`; that IS the outcome, so there is nothing to
    /// report here.
    func becomeGateway(_ gateway: SavedGateway) async {
        let runtime = MultiGatewayRuntime.shared
        guard runtime.switchingGatewayID == nil else { return }
        runtime.switchingGatewayID = gateway.id
        defer { runtime.switchingGatewayID = nil }
        await switchGateway(to: gateway)
    }

    // Cosmetics for a profile we have only a name for live in
    // `BotCosmetics.derivedShape(forName:)` / `derivedHue(forName:)`, the same
    // last-resort the live roster uses — so a bot's face does not change the
    // instant the switch completes and the real row replaces the foreign one.
    // This file used to carry its own byte-identical copy of that hash.
}

// MARK: - Searching a foreign row
//
// There is no `ForeignRosterEntry.matchesRosterSearch`, and deliberately so.
// A thin remote row's side of `filterBots` (plugin.js:2970-2980) runs on the
// row, through the same identity helpers that painted it — see
// `foreignRosterEntries(matching:)`, which turns each entry into the `Bot` the
// list draws and calls `Bot.matchesRosterSearch`. That keeps the four match
// fields (display name, profile name, @handle, device label) pinned by
// `talaria-verify` in ONE place, on the type both halves of the union share.
//
// The id is the one thing neither side matches: it is `gatewayID::profile`
// (plugin.js:2669), and a needle that happened to fall inside a gateway id
// would silently match rows nothing on screen says it should. `profileName`
// is the field that carries the name a user can see and type.

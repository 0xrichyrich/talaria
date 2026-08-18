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
// WHAT IS REAL HERE, PRECISELY. Talaria drives ONE gateway socket. There is no
// multiplexing: a foreign row is a cached picture of another machine, taken by
// a short-lived probe socket (ConnectionRegistry.enumerateSecondaryRosters) and
// kept on disk so an asleep homelab still lists its bots. Opening one does not
// message it in place — it SWITCHES this phone to that gateway, flushing the
// outgoing world through `switchGateway` and then landing in the bot's
// canonical forever-chat through the single chat-open door.
//
// That divergence from desktop is deliberate and is the honest shape for a
// phone: desktop can route a message over a second connection while staying
// put ("Gateway stays on this device", plugin.js:3904-3908) because its main
// process holds every connection open. Talaria holds one, so it says so.

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
}

public extension AppModel {

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
    /// identity path as every other row.
    ///
    /// The id is the source-qualified `botRosterKey` (plugin.js:2669), which
    /// cannot collide with a live profile id — that is the point. Because the
    /// id is qualified, the title and handle are resolved here rather than
    /// derived from it: `Bot.displayTitle` would otherwise de-slug
    /// "homelab::default" instead of reading Hermes.
    func rosterBot(for entry: ForeignRosterEntry) -> Bot {
        // A bare-name entry keeps the plain rules (default → Hermes/@hermes);
        // a disambiguated one already carries its `name-device` form, which
        // desktop's botHandle() prefers verbatim (plugin.js:2401-2412).
        let plain = Bot.unlisted(id: entry.profile)
        let handle = entry.handle == entry.profile ? plain.handle : entry.handle
        return Bot(id: entry.id,
                   job: entry.job,
                   shape: entry.shape ?? Self.rosterShape(forProfileName: entry.profile),
                   hue: entry.hue ?? Self.rosterHue(forProfileName: entry.profile),
                   status: .idle,
                   preview: entry.preview,
                   previewTime: Self.shortTime(entry.lastActive),
                   description: entry.job,
                   title: entry.title?.isEmpty == false ? entry.title : plain.displayTitle,
                   handleOverride: handle)
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

    /// Tapping a foreign row: become that gateway, then open the bot.
    ///
    /// `switchGateway` is Phase 2's path and already does the hard part —
    /// flush the outgoing world (bot ids and session keys are per-gateway),
    /// dial, re-roster — and on failure it raises the re-auth banner or marks
    /// the gateway offline. Both of those already tell the user what happened,
    /// so a failed switch simply stops here rather than adding a second story.
    func openForeignBot(_ entry: ForeignRosterEntry) async {
        guard let gateway = ConnectionRegistry.shared.saved.first(where: { $0.id == entry.gatewayID })
        else { return }

        await becomeGateway(gateway)
        guard isActiveGateway(gateway) else { return }

        // The cached row may predate a profile being renamed or deleted on that
        // machine. The live roster is now authoritative; opening a name it does
        // not list would ask the gateway to create a session on a profile that
        // does not exist. Landing on the freshly-loaded roster is the honest
        // outcome — the bot the user tapped is simply not there any more.
        guard bots.contains(where: { $0.id == entry.profile }) else { return }

        // THE door into a chat (AppModelLive.openChat): resumes the canonical
        // forever-chat and hydrates it, instead of opening an empty chat whose
        // first send forks a new session away from the bot's real history.
        openChat(botID: entry.profile)
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

    // MARK: - Cosmetics for a profile we have only a name for

    // The live roster derives shape/hue from a stable hash of the profile name
    // when `ui_meta` carries no cosmetics (AppModelLive.derivedShape/derivedHue).
    // These are the same functions keyed by name alone, so a bot's face does
    // not change the instant the switch completes and the real row replaces
    // the foreign one.

    static func rosterShape(forProfileName name: String) -> AvatarShape {
        let cases = AvatarShape.allCases
        return cases[(stableHash(name) & Int.max) % cases.count]
    }

    static func rosterHue(forProfileName name: String) -> AvatarHue {
        // .gateway is reserved for gateway-originated feed items.
        let cases: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]
        return cases[(stableHash(name + "hue") & Int.max) % cases.count]
    }
}

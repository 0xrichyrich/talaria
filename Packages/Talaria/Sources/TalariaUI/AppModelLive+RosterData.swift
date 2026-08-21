import Foundation
import TalariaKit
import TalariaTheme

// ── Roster data: the canonical-chat round trip and the liveness set ──────────
//
// Two halves of BOT-PARITY-PLAN Phase B1, both derived from the SAME
// `profiles.list` answer the roster already polls — no second RPC, because
// `include_sessions` costs a per-profile database scan gateway-side
// (methods_profiles.py `_latest_profile_session_row`).
//
// **1. `preferred_session_ids`.** The enabling call for the whole region. The
// roster previews one session and the tap opens another unless the gateway is
// told which conversation the client actually cares about
// (hermes-agent#88200): `profiles.list {preferred_session_ids: {profile: id}}`
// answers "what about THIS conversation" per row — hidden sessions included,
// compression lineages resolved to their live tip, no pagination window. The
// wire work lives in `GatewayClient.listProfiles`, which harvests the pins out
// of each answer's own `ui_meta["hermes-bots"].chat` exactly as desktop reads
// them out of `$botMeta` (plugin.js:2208-2231). This file owns the app-side
// half: pushing a pin the app minted before the gateway can echo it back, and
// reading the tri-state answer.
//
// **2. The active-now set.** Desktop's `activeBots` (plugin.js:3831-3839): the
// bot the gateway is running a turn for, plus every bot whose conversation
// landed inside the 90-second liveness window or whose separate worker session
// is live for 150 seconds. Pure, and it follows the roster's own order —
// presence must never reorder or hide the list beneath it, which is the whole
// reason the upstream function is written as a filter over the roster rather
// than a sort of its own.
//
// Re-verified against the live gateway 2026-08-18 (0.20.3): `profiles.list`
// returns rows keyed `name, path, is_default, model, provider, description,
// skill_count, last_session, ui_meta, has_avatar` and carries no
// `preferred_session` key at all — byte-identical with pins, without pins, and
// with a pin naming a session that does not exist. That build has no
// `preferred_session` handler, so *absent* is the only branch reachable there
// and it is precisely the branch that must never read as "the pin is dead".

struct CanonicalPinBuckets: Equatable {
    var primary: [String: String]
    var routed: [String: [String: String]]
}

/// Canonical runtime keys are bare only for the primary source. Remote keys
/// are `gateway::profile` and must never be sent verbatim to the primary
/// client, where they could become a bogus profile name or resolve a colliding
/// local row.
enum CanonicalPinRouting {
    static func partition(_ pins: [String: String]) -> CanonicalPinBuckets {
        var primary: [String: String] = [:]
        var routed: [String: [String: String]] = [:]
        for (key, storedID) in pins where !storedID.isEmpty {
            if let route = GatewayBotRoute(qualifiedID: key) {
                routed[route.gatewayID, default: [:]][route.profile] = storedID
            } else {
                primary[key] = storedID
            }
        }
        return CanonicalPinBuckets(primary: primary, routed: routed)
    }
}

extension AppModel {

    // MARK: - The canonical-chat round trip

    /// Hand the client the pins this app knows about but the gateway has not
    /// echoed yet.
    ///
    /// `GatewayClient` primes itself from every answer's `ui_meta`, which
    /// covers the steady state. It cannot cover the one case that matters
    /// most: a canonical chat minted seconds ago is pinned locally *before*
    /// `profiles.configure` lands, so the poll in between would resolve
    /// nothing and preview the scratch session the birth kickoff just created.
    /// Cheap enough to call on every roster appearance.
    public func syncCanonicalPins() async {
        guard mode == .live else { return }
        let buckets = CanonicalPinRouting.partition(CanonicalChatRuntime.shared.pins)
        if let client, !buckets.primary.isEmpty {
            await client.notePreferredSessions(buckets.primary)
        }
        for (gatewayID, pins) in buckets.routed where !pins.isEmpty {
            guard let owner = try? await routedClient(gatewayID: gatewayID) else { continue }
            await owner.notePreferredSessions(pins)
        }
    }

    // The tri-state answer itself is read where it is acted on: `listProfiles`
    // folds a `.resolved` pin's preview onto the row it will open, and
    // `HermesProfile.PreferredSession` keeps *absent* and *null* apart so a
    // gateway that ignores `preferred_session_ids` can never be read as
    // declaring a pin dead. Canonical-chat recovery deliberately does not
    // consult it — `attachCanonicalSession` re-anchors off `session.resume`'s
    // 4007, which answers for the exact resume the tap is about to perform.

    // MARK: - The active-now set

    /// Bots that are working right now, in the roster's own order.
    ///
    /// Desktop's `activeBots` (plugin.js:3831-3839) is
    /// `busyTurn || inWindow`:
    ///
    /// * **busyTurn** — upstream is `bot.name === activeProfile &&
    ///   gatewayState === 'busy'`, which is a single-profile desktop's way of
    ///   saying "this bot is mid-turn". Talaria tracks that per bot already
    ///   (`LiveRuntime.workingBotIDs` → `Bot.status`), so the port reads the
    ///   per-bot flag instead of guessing from a global gateway state. The
    ///   upstream comment is emphatic that this is *not* "every bot whenever
    ///   the gateway is busy", and the per-bot form cannot drift into that.
    /// * **inWindow** — freshest conversation activity within 90 s, or a
    ///   separate `worker_session.last_active` inside Hermes' 150 s worker
    ///   window. The worker half is display-only liveness: it never enters the
    ///   rank or unread watermark, which both read conversation activity.
    ///
    /// Output follows `rankedBots`, so the strip reads top-to-bottom in the
    /// same order as the list under it and presence can never reorder that
    /// list. `remoteSource` needs no filter here: Talaria's `bots` are always
    /// the live gateway's own, and foreign rows live in their own section.
    public func activeNowBots(now: Date = .now) -> [Bot] {
        // Hidden is a display preference, so it does not suppress the worker
        // poll or unread watermark. It does suppress this visual rail: showing
        // a hidden bot above the roster would leak the very row the user chose
        // not to see. Foreign rows are never in `rankedBots` and therefore
        // remain untouched by this primary-only rule.
        rankedBots.filter {
            !isRosterHidden($0.id)
                && ($0.status == .working || isActiveNow($0.id, now: now))
        }
    }

    /// Just the ids — what a view diffs on to decide whether membership
    /// actually changed, without holding whole rows.
    public func activeNowBotIDs(now: Date = .now) -> [String] {
        activeNowBots(now: now).map(\.id)
    }
}

// MARK: - Copy

extension CopyPack {

    /// The strip's own label. Desktop prints an uppercase tracked "Active now"
    /// (plugin.js:6905-6908); each pack says the same thing in its own voice.
    static func activeNowTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active now"
        case .control: "ACTIVE NOW"
        case .ink: "stirring"
        }
    }

    /// Screen-reader name for the strip as a region.
    static func activeNowRegion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active now"
        case .control: "ACTIVE NOW"
        case .ink: "Those stirring now"
        }
    }

    /// Chip action. Desktop's tooltip is `Open <Name>'s chat`
    /// (plugin.js:6919); on a phone the same words are the VoiceOver label.
    static func activeNowOpen(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Open \(name)'s chat"
        case .control: "OPEN \(name.uppercased()) CHAT"
        case .ink: "Turn to \(name)"
        }
    }

    /// Announced when a bot joins the strip — desktop gets this free from
    /// `aria-live="polite"` on the region (plugin.js:6896-6898). VoiceOver
    /// needs the sentence written out.
    static func activeNowJoined(_ names: [String], _ t: ThemeID) -> String {
        let list = names.joined(separator: ", ")
        switch t {
        case .soft:
            return names.count == 1 ? "\(list) is active now" : "\(list) are active now"
        case .control:
            return "ACTIVE: \(list.uppercased())"
        case .ink:
            return names.count == 1 ? "\(list) stirs" : "\(list) stir"
        }
    }
}

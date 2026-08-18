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
// bot the gateway is running a turn for, plus every bot whose last message
// landed inside the 90-second liveness window. Pure, and it follows the
// roster's own order — presence must never reorder or hide the list beneath
// it, which is the whole reason the upstream function is written as a filter
// over the roster rather than a sort of its own.
//
// Verified against the live gateway 2026-08-18; see the notes on
// `preferredSessionState`.

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
        guard mode == .live, let client else { return }
        let pins = CanonicalChatRuntime.shared.pins.filter { !$0.value.isEmpty }
        guard !pins.isEmpty else { return }
        await client.notePreferredSessions(pins)
    }

    /// What the gateway last said about this bot's canonical-chat pin.
    ///
    /// Three answers, and the difference is the difference between a pin that
    /// survives a downgrade and one that gets thrown away by a gateway too old
    /// to have an opinion (plugin.js:2857-2880):
    ///
    /// * `.notRequested` — no pin was sent for this profile, **or** the
    ///   gateway predates the parameter and ignored it. Innocent until proven
    ///   guilty: never re-anchor on this.
    /// * `.gone` — a gateway that speaks the contract saying the row is
    ///   definitively absent (deleted, archived, or an internal `tool`/
    ///   `kanban` session). This is the only answer that may trigger the
    ///   recovery adoption in `AppModelLive+CanonicalChat`.
    /// * `.resolved` — the pin is live; `resolvedID` names its compression tip.
    public func preferredSessionState(_ botID: String) async -> HermesProfile.PreferredSession {
        guard let client else { return .notRequested }
        return await client.preferredSessionOutcome(botID)
    }

    /// True only when a contract-speaking gateway has said the pin is gone —
    /// the guard the canonical-chat recovery path wants before it re-anchors,
    /// so an older gateway or a sleeping laptop can never cost a user their
    /// forever chat.
    public func canonicalPinReportedGone(_ botID: String) async -> Bool {
        await preferredSessionState(botID).isDefinitivelyGone
    }

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
    /// * **inWindow** — `last_session.last_active` within `ACTIVE_WINDOW_S`
    ///   (90 s). This is the half that catches a cron run, a CLI turn, the
    ///   laptop, or a bot-to-bot handoff this phone never watched.
    ///
    /// Output follows `rankedBots`, so the strip reads top-to-bottom in the
    /// same order as the list under it and presence can never reorder that
    /// list. `remoteSource` needs no filter here: Talaria's `bots` are always
    /// the live gateway's own, and foreign rows live in their own section.
    public func activeNowBots(now: Date = .now) -> [Bot] {
        rankedBots.filter { $0.status == .working || isActiveNow($0.id, now: now) }
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

import Foundation
import TalariaKit
import TalariaTheme

// ── Unread watermarks: the durable half ──────────────────────────────────────
//
// BOT-PARITY-PLAN Phase D1. The diff itself — seeding, monotonicity, the strict
// `>` and the mark that advances before both guards — is
// `TalariaKit/UnreadWatermarks`, where `talaria-verify` can replay a captured
// roster sequence through it. This file is the three things a value type cannot
// own: which gateway the marks belong to, that they survive the process, and
// the single place a roster answer turns into a badge.
//
// Talaria already had the event half (AppModelLive.swift, AppModelLive+
// Liveness.swift) and, since Phase B, a process-lifetime poll half inside
// `RosterSignals`. What was missing is the half that survives the process —
// which on a phone is most of the story, because the process is killed minutes
// after the screen goes dark and everything this model exists to catch happens
// in exactly that window.
//
// **There is one watermark table and one badge writer.** `RosterSignals` used
// to keep `watermarks` + `watermarksSeeded` of its own and hand `moved` to
// `applyUnreadWatermark`; that state is gone, and `applyUnreadWatermark` below
// is now fed from this store. Two tables ingesting the same stamps under two
// sparing rules is this repo's named bug class, and being idempotent is not a
// defence — it makes the disagreement invisible instead of absent.

// MARK: - The durable store

/// Per-bot high-water marks of observed activity, scoped to a gateway and
/// persisted across launches.
///
/// Kept apart from `RosterSignals` on purpose: that table is process-lifetime
/// state which is *supposed* to be wiped on a gateway switch, and this one is
/// the opposite — the record that has to outlive both the switch and the
/// process. Two gateways can each serve a profile called `default`, so
/// everything here lives under a scope key and one gateway can never
/// acknowledge another's traffic.
@MainActor
public final class UnreadWatermarkStore {
    public static let shared = UnreadWatermarkStore()

    /// Prefix-matched by Settings' "delete local data" and the storage
    /// inspector (AppModelLive+Settings.swift), which is why it starts
    /// `talaria`.
    static let storageKey = "talaria.unread-watermarks"

    private let defaults: UserDefaults
    private var scopes: [String: UnreadWatermarkScope] = [:]
    private var scopeKey: String?

    /// Newest stamp seen for each bot in this scope, from the last ingest. Not
    /// persisted — the next roster answer restates it in full, and it exists
    /// only so `acknowledge` has something to advance to between polls.
    private var observed: [String: Double] = [:]

    /// Bots the NEXT ingest must not badge: the bot whose chat was open at the
    /// previous ingest, plus any explicit acknowledge. See `ingest`.
    private var suppressNext: Set<String> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let raw = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: UnreadWatermarkScope].self,
                                                      from: raw)
        else { return }
        scopes = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scopes) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// A gateway with no key of its own — nothing is recorded until one
    /// arrives, so a disconnected app cannot write marks into a shared bucket.
    private static func key(for base: URL?) -> String? { base?.absoluteString }

    // MARK: Scope

    /// Point the store at a gateway, loading whatever this phone already knew
    /// about it. Cheap and idempotent; call it as often as is convenient.
    func rescope(to base: URL?) {
        let next = Self.key(for: base)
        guard next != scopeKey else { return }
        scopeKey = next
        // Per-poll state belongs to the gateway that produced it. The marks do
        // not: they are already loaded from disk under every key.
        observed.removeAll()
        suppressNext.removeAll()
    }

    // MARK: The diff

    /// Fold one roster answer in and report the bots whose activity moved past
    /// their mark.
    ///
    /// `openBot` is the chat currently on screen, which is never badged
    /// (plugin.js:129-132). The bot that was on screen at the *previous* ingest
    /// is spared too, and that is a phone-shaped addition rather than
    /// upstream's: desktop's `$selectedBot` is sticky, because its chat pane
    /// always holds some bot, while `openBotID` goes nil the moment the user
    /// backs out to the roster. Without the one-poll tail, backing out of a chat
    /// whose reply landed between polls badges the user for the message they
    /// just finished reading. One poll of grace is the smallest window that
    /// closes that, and anything arriving after it still badges normally —
    /// including from the event path, which never stopped counting.
    ///
    /// This is the ONLY sparing rule. A caller that adds its own is the second
    /// code path this phase was rebuilt to remove.
    @discardableResult
    func ingest(_ activity: [String: Double], openBot: String?, scope: URL?) -> [String] {
        rescope(to: scope)
        guard let scopeKey, !activity.isEmpty else { return [] }
        // Read-or-create rather than read: `rescope` is a no-op when the gateway
        // has not changed, so a wipe in between would otherwise leave this scope
        // with no state and every later poll a no-op.
        let current = scopes[scopeKey] ?? UnreadWatermarkScope()
        let spared = suppressNext.union(openBot.map { [$0] } ?? [])
        let fold = UnreadWatermarks.fold(current, activity: activity, spared: spared,
                                         now: Date.now.timeIntervalSince1970)

        for (botID, stamp) in activity {
            observed[botID] = max(observed[botID] ?? 0, max(0, stamp))
        }
        scopes[scopeKey] = fold.scope
        scopes = UnreadWatermarks.evict(scopes)
        suppressNext = openBot.map { [$0] } ?? []
        persist()
        return fold.moved
    }

    // MARK: Acknowledging

    /// The user is looking at this bot. Advances its mark to the newest activity
    /// this phone has observed and spares it from the next ingest.
    public func acknowledge(_ botID: String) {
        guard let scopeKey else { return }
        // Read-or-create, the same way `ingest` does: a chat opened before this
        // gateway's first roster answer has no scope yet, and the difference
        // between recording that and dropping it on the floor is one line.
        let state = scopes[scopeKey] ?? UnreadWatermarkScope()
        scopes[scopeKey] = UnreadWatermarks.acknowledge(botID, observed: observed[botID] ?? 0,
                                                        in: state,
                                                        now: Date.now.timeIntervalSince1970)
        suppressNext.insert(botID)
        persist()
    }

    /// Drop every mark for every gateway, in memory and on disk. Paired with
    /// Settings' "delete local data": that path removes the backing key, and
    /// without this the next poll would write the whole lot straight back (the
    /// trap `ModelPresetStore.reset` documents).
    public func forgetEverything() {
        scopes.removeAll()
        observed.removeAll()
        suppressNext.removeAll()
        // Forget which gateway is current too, so the next roster answer
        // rebuilds the scope from nothing and seeds silently — a wipe should
        // leave the phone in exactly the state a fresh install is in.
        scopeKey = nil
        defaults.removeObject(forKey: Self.storageKey)
    }
}

// MARK: - The activity-toast preference (plugin.js:99-110, 8081-8090)

/// "Toast on every new bot activity" — OFF by default, persisted.
///
/// Upstream's reasoning is quoted at plugin.js:96-98 and holds harder on a
/// phone than on a laptop: "a busy roster (cron runs, bot-to-bot chatter) turns
/// the toasts into a firehose, and the unread badge already carries the signal".
/// So the badge is unconditional and only the narration is a preference — which
/// is also why this pref must never gate anything the badge depends on.
@MainActor
@Observable
public final class ActivityToastPref {
    public static let shared = ActivityToastPref()

    /// `ctx.storage['activity-toasts']` upstream. Prefixed `talaria` so
    /// Settings' "delete local data" and the storage inspector find it
    /// (AppModelLive+Settings.swift).
    static let storageKey = "talaria.activity-toasts"

    private let defaults: UserDefaults
    public private(set) var enabled: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An absent key reads false, which IS the documented default — so a
        // fresh install is silent without a registration pass.
        enabled = defaults.bool(forKey: Self.storageKey)
    }

    public func set(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.storageKey)
    }

    /// "Delete local data" — back to silent, like a fresh install.
    func forget() {
        enabled = false
        defaults.removeObject(forKey: Self.storageKey)
    }
}

// MARK: - Model surface

extension AppModel {

    /// The bell in the roster header reads and writes this.
    public var activityToastsEnabled: Bool { ActivityToastPref.shared.enabled }

    public func setActivityToasts(_ on: Bool) {
        ActivityToastPref.shared.set(on)
        // The toggle itself is the one activity notice that fires whatever the
        // pref says — turning it OFF has to be able to say it took, and a
        // preference that changes in silence reads as a dead button. Never
        // mirrored into the ledger: a settings flip is not history.
        toast(kind: .info, title: theme.copy.activityToastsToggled(on, theme.themeID),
              ledger: false)
    }

    /// THE badge writer. One caller: `applyRosterAnswer`, immediately after the
    /// rows are rebuilt from the same answer these marks were folded from.
    ///
    /// Talaria counts unread where desktop keeps a boolean, so a watermark move
    /// raises the count to at least one rather than incrementing it. The event
    /// path has already counted every message this app watched arrive, and
    /// adding to that from a poll would inflate the number by however many times
    /// the roster happened to refresh. Raising a zero is the honest translation
    /// of desktop's `true`: *something is here you have not seen*.
    ///
    /// Nothing is spared here. `UnreadWatermarkStore.ingest` already excluded
    /// the open chat and the one-poll tail, and re-deciding it in the writer is
    /// how the two rules drift apart.
    func applyUnreadWatermark(_ moved: [String]) {
        // Read once: the pref cannot change mid-loop, and re-reading it per row
        // would invite a future caller to think it might.
        let announcing = ActivityToastPref.shared.enabled
        for botID in moved {
            guard let index = bots.firstIndex(where: { $0.id == botID }) else { continue }
            if bots[index].unread == 0 { bots[index].unread = 1 }
            if announcing { announceActivity(botID) }
        }
    }

    /// The opt-in toast that goes with a badge (plugin.js:137-148).
    ///
    /// Two titles, chosen by an anchored test over the roster preview
    /// (`ActivityNotice.isInbound`, pinned in ProtocolChecks+Notices): a
    /// delivery another agent wrote into this bot's transcript reads as a
    /// message *for* the user, and everything else — a cron run, a CLI turn,
    /// the laptop — reads as activity. The body is the preview itself, clipped
    /// to 140, or an invitation when the gateway sent none.
    ///
    /// **Deliberately not mirrored into the Activity ledger.** The ledger
    /// already has three writers for inbound activity — the event stream's
    /// finished-turn rows, the preview sweep's A2A mentions, and the A2A path
    /// itself — each with its own dedupe key. A fourth, poll-derived one would
    /// file a second row for the common case (a turn this app watched land and
    /// already journaled), and "two rows for one event" is the exact failure the
    /// key-pairing in `toast()` exists to prevent. The ledger's account of
    /// activity is not a notification preference's to complete; what this raises
    /// is the badge.
    private func announceActivity(_ botID: String) {
        let copy = theme.copy
        let themeID = theme.themeID
        let label = botName(botID, themeID)
        // The RAW preview, not `Bot.preview`: that one is flattened for a roster
        // row and falls back to the previous answer's text when this answer has
        // none, so it would put stale words in a notification about new ones.
        let preview = RosterSignals.shared.previews[botID] ?? ""
        toast(kind: .info,
              title: ActivityNotice.isInbound(preview)
                  ? copy.activityToastInbound(label, themeID)
                  : copy.activityToastGeneric(label, themeID),
              message: ActivityNotice.body(preview,
                                           fallback: copy.activityToastNoPreview(themeID)),
              botID: botID, ledger: false)
    }

    /// Fold a roster answer's stamps into the durable marks and report the
    /// moves. Called from `applyRosterAnswer` with `RosterSignals.lastActive` —
    /// the table that answer just wrote — so the marks, the ranking and the rows
    /// all come off one payload on one tick.
    func unreadMoves(scope: URL?) -> [String] {
        guard mode == .live else { return [] }
        return UnreadWatermarkStore.shared.ingest(RosterSignals.shared.lastActive,
                                                  openBot: openBotID, scope: scope)
    }

    /// Point the store at whatever gateway is current. Called on both edges of a
    /// connection (AppModelLive.swift), because between a switch and that
    /// gateway's first roster answer there is no `ingest` to do it — and an
    /// `acknowledge` in that window would land on the departed gateway's marks
    /// for a profile that merely shares a name.
    public func rescopeUnreadWatermarks() {
        UnreadWatermarkStore.shared.rescope(to: LiveRuntime.shared.baseURL)
    }

    /// A chat was opened — the single door every route in reports through: the
    /// roster row tap and `openChat`, a stored session picked from the sheet, a
    /// push, a deep link, the command palette.
    ///
    /// The bot being read is never the bot that badges you, and the mark has to
    /// move with the badge or the next poll raises the same activity again.
    public func noteChatOpened(_ botID: String) {
        UnreadWatermarkStore.shared.acknowledge(botID)
    }

    /// "Delete local data" — drop every gateway's marks. The next roster answer
    /// re-seeds silently, exactly like a fresh install.
    public func forgetUnreadWatermarks() {
        UnreadWatermarkStore.shared.forgetEverything()
    }
}

// MARK: - Copy

extension CopyPack {

    /// Screen-reader name for the roster's unread badge. The badge renders a
    /// bare digit (RosterView `badge(for:)`), which VoiceOver reads as a number
    /// with no noun attached — beside a bot's name, "3" could as easily be a
    /// model or a position in the list.
    static func unreadBadge(_ count: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft: count == 1 ? "1 unread" : "\(count) unread"
        case .control: "\(count) UNREAD"
        case .ink: count == 1 ? "one unread word" : "\(count) unread words"
        }
    }

    // ── The activity toast (plugin.js:141-147) ──────────────────────────────
    //
    // Soft renders the plugin's own titles verbatim through `BotModeStrings`;
    // the other two packs restate the same two facts — WHO, and whether this is
    // a message addressed onward or the bot simply working.

    /// A delivery another agent wrote into this bot's transcript.
    func activityToastInbound(_ label: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.newMessageFor(label)
        case .control: "INBOUND → \(label.uppercased())"
        case .ink: "A letter has come for \(label)"
        }
    }

    /// Everything else that moved the mark: a cron run, a CLI turn, the laptop.
    func activityToastGeneric(_ label: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.hasNewActivity(label)
        case .control: "\(label.uppercased()) · NEW ACTIVITY"
        case .ink: "\(label) has been at work"
        }
    }

    /// The gateway had a stamp but no words to go with it.
    func activityToastNoPreview(_ t: ThemeID) -> String {
        switch t {
        case .soft: BotModeStrings.openTheChat
        case .control: "OPEN THE CHAT TO READ IT"
        case .ink: "Open the chat to read it."
        }
    }

    /// The bell's own answer. Upstream says this in a tooltip
    /// (plugin.js:7733-7734, "Activity toasts on — click to silence" / "off —
    /// click to enable"); a phone has no hover, so the tooltip's job is done by
    /// the toast the flip itself fires.
    func activityToastsToggled(_ on: Bool, _ t: ThemeID) -> String {
        switch t {
        case .soft: on ? "Activity toasts on" : "Activity toasts off"
        case .control: on ? "ACTIVITY TOASTS ON" : "ACTIVITY TOASTS OFF"
        case .ink: on ? "Every stirring shall be announced" : "Stirrings will pass in silence"
        }
    }

    /// The bell's accessibility label — and, on a phone, the only place the
    /// tooltip's wording can live.
    static func activityToastsToggle(_ on: Bool, _ t: ThemeID) -> String {
        switch t {
        case .soft: on ? "Activity toasts on — tap to silence" : "Activity toasts off — tap to enable"
        case .control: on ? "ACTIVITY TOASTS ON — TAP TO SILENCE"
                          : "ACTIVITY TOASTS OFF — TAP TO ENABLE"
        case .ink: on ? "Announcements are being made — tap for quiet"
                      : "All is quiet — tap to have stirrings announced"
        }
    }
}

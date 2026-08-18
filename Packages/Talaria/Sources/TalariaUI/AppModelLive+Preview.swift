import Observation
import SwiftUI
import TalariaKit
import TalariaTheme
#if os(iOS)
import UIKit
#endif

// Two pieces of roster *feel*: what the preview line says, and what the phone
// does when you commit to something.
//
// **Preview.** `rosterPreview(for:)` is the whole of desktop's row-preview
// pipeline in one place (plugin.js:3862-3874): classify the text with the A2A
// grammar, strip the delivery prefix when it is a bot-to-bot message, flatten
// the markdown, and fall back preview → description → "No conversations yet".
// The classifiers are the ones already ported for the Agent Inbox
// (`a2aSender` / `strippedA2A`, AppModelLive+Feeds.swift) — one attribution
// grammar for the whole app, so the inbox and the roster can never disagree
// about who sent what.
//
// **Haptics.** Desktop fires `haptic('tap')` as the FIRST statement of exactly
// three handlers — bot row open, group row open, Active-now chip
// (plugin.js:3900, 7532, 7783) — and nowhere else; the audit's reading is that
// it "marks departure, not every tap" (BOT-MODE-PARITY §12). Talaria keeps
// that discipline and extends it by exactly two moves, both of which are
// commitments a phone should confirm without the user looking: answering an
// approval, and pinning a bot to the head of the roster. Everything else stays
// silent.
//
// The haptic engine lives in this file rather than its own because feel is not
// worth a third file; it is ~40 lines and has one caller shape.

// MARK: - Preview

extension AppModel {

    /// The placeholder the roster loader writes when a profile has no
    /// conversation behind it yet (AppModelLive.swift:257). Recognised rather
    /// than replaced: that assignment belongs to another surface, and desktop's
    /// real fallback chain (preview → description → "no conversations yet")
    /// can be honoured here without reaching into it.
    static let seededEmptyPreview = "Ready when you are."

    /// A roster row's second line: flattened, attributed, ready to draw.
    ///
    /// Port of plugin.js:3862-3874. Note that the classification runs on the
    /// RAW text: the gateway explicitly keeps delivery prefixes in the preview
    /// it serves ("callers style them" — tui_gateway/methods_profiles.py:41),
    /// so this is the only place the prefix is removed for display.
    public func rosterPreview(for bot: Bot) -> RosterPreview {
        let raw = bot.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        // A dozen regex passes is ~21 µs, which is nothing per row and 0.8 ms
        // per repaint on a 40-bot roster — and this line repaints on every
        // poll tick and every live event. Keyed by everything the answer
        // depends on, so there is no invalidation to get wrong.
        let key = "\(theme.themeID.rawValue)\u{1}\(raw)\u{1}\(bot.description ?? "")"
        if let hit = PreviewCache.shared.entries[key] { return hit }
        let made = buildRosterPreview(raw: raw, bot: bot)
        PreviewCache.shared.store(made, for: key)
        return made
    }

    private func buildRosterPreview(raw: String, bot: Bot) -> RosterPreview {
        if let sender = Self.a2aSender(in: raw) {
            // Desktop's exact empty case: a delivery whose body is nothing but
            // the prefix still has to draw something, and "…" says "there was
            // a message" without inventing content.
            let body = PreviewMarkdown.flatten(Self.strippedA2A(raw))
            return RosterPreview(text: Self.capped(body.isEmpty ? "…" : body), sender: sender)
        }

        let flat = PreviewMarkdown.flatten(raw)
        // The sentinel only means "no conversation" in live mode. The demo
        // world hands the same sentence to its Hermes row deliberately
        // (DemoData.swift:28) and that screen is a prototype-faithful artifact
        // — a live-mode gap is no reason to repaint it.
        if !flat.isEmpty, mode == .demo || flat != Self.seededEmptyPreview {
            return RosterPreview(text: Self.capped(flat))
        }
        // A profile's description is the best thing to say about a bot nobody
        // has talked to yet — on this gateway that is a real sentence
        // ("Code review and adversarial security/correctness audit agent…")
        // where the placeholder was three words of nothing.
        let described = PreviewMarkdown.flatten(bot.description ?? "")
        if !described.isEmpty {
            return RosterPreview(text: Self.capped(described))
        }
        return RosterPreview(text: CopyPack.rosterNoConversations(theme.themeID))
    }

    /// Belt-and-braces length guard. `profiles.list` previews arrive capped at
    /// 80 characters and the live-event path runs through `previewLine`'s 120,
    /// but a single `Text` asked to measure a 40 KB line would cost the whole
    /// roster a frame, and no row can show more than a phrase anyway.
    private static func capped(_ text: String) -> String {
        text.count > 160 ? String(text.prefix(159)) + "…" : text
    }
}

/// Flattened previews, content-keyed. Bounded and dropped wholesale rather
/// than aged: a roster turns over slowly, and an LRU here would be more code
/// than the thing it protects.
@MainActor
private final class PreviewCache {
    static let shared = PreviewCache()
    private(set) var entries: [String: RosterPreview] = [:]

    func store(_ preview: RosterPreview, for key: String) {
        if entries.count > 256 { entries.removeAll(keepingCapacity: true) }
        entries[key] = preview
    }
}

// MARK: - Haptics

/// The three packs' feel: soft is warm and rounded, control is sharp and
/// mechanical, ink is restrained — a page turning, not a machine clunking.
@MainActor
public enum TalariaHaptics {

    /// The moves worth a buzz. Deliberately short; adding to it is a decision
    /// about the app's whole feel, not a local one.
    public enum Move: Sendable {
        /// Leaving the roster for a chat — desktop's `haptic('tap')`.
        case open
        case pin
        case unpin
        case approve
        case deny
    }

    public static func play(_ move: Move, _ theme: ThemeID) {
        #if os(iOS)
        switch (theme, move) {
        case (.soft, .open): Taptic.impact(.soft, 0.75)
        case (.soft, .pin): Taptic.impact(.light, 0.6)
        case (.soft, .unpin): Taptic.impact(.light, 0.4)
        case (.soft, .approve): Taptic.notify(.success)
        case (.soft, .deny): Taptic.notify(.warning)

        case (.control, .open): Taptic.impact(.rigid, 1.0)
        case (.control, .pin), (.control, .unpin): Taptic.selection()
        case (.control, .approve): Taptic.impact(.rigid, 0.9)
        case (.control, .deny): Taptic.notify(.error)

        case (.ink, .open): Taptic.selection()
        case (.ink, .pin): Taptic.impact(.soft, 0.35)
        case (.ink, .unpin): Taptic.selection()
        case (.ink, .approve): Taptic.impact(.soft, 0.45)
        case (.ink, .deny): Taptic.impact(.soft, 0.6)
        }
        #endif
    }
}

#if os(iOS)
/// Generators are cached and re-primed after every use: `prepare()` warms the
/// Taptic Engine for a second or so, which is the difference between a tap
/// that feels instant and one that feels like it is confirming an RPC.
@MainActor
private enum Taptic {
    private static var impacts: [Int: UIImpactFeedbackGenerator] = [:]
    private static let selector = UISelectionFeedbackGenerator()
    private static let notifier = UINotificationFeedbackGenerator()

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, _ intensity: CGFloat) {
        let generator: UIImpactFeedbackGenerator
        if let cached = impacts[style.rawValue] {
            generator = cached
        } else {
            generator = UIImpactFeedbackGenerator(style: style)
            impacts[style.rawValue] = generator
        }
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }

    static func selection() {
        selector.selectionChanged()
        selector.prepare()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notifier.notificationOccurred(type)
        notifier.prepare()
    }
}
#endif

extension AppModel {

    /// Play a move in the current pack's voice. Model-side rather than
    /// view-side so every surface that fires the same move feels the same,
    /// and so a screen never has to know which pack is loaded.
    func feedback(_ move: TalariaHaptics.Move) {
        TalariaHaptics.play(move, theme.themeID)
    }

    /// Start the approval-answer haptic. Idempotent; called from the roster,
    /// which is the first screen the app shows.
    func startFeelObservers() {
        ApprovalHaptics.shared.start(model: self)
    }
}

/// Approve/deny is answered from four surfaces (the Approvals tab, the inline
/// chat card, the push banner, a notification action) and every one of them
/// funnels through `ApprovalOutcomes.record`. Watching that one ledger is how
/// a single haptic covers all four without four call sites drifting apart —
/// and it keeps the feel out of files this phase does not own. A decision
/// taken from a notification action while the app is in the background plays
/// nothing, which is iOS behaviour rather than a special case here.
@MainActor
final class ApprovalHaptics {
    static let shared = ApprovalHaptics()

    private weak var model: AppModel?
    private var seen: Set<String> = []
    private var running = false

    func start(model: AppModel) {
        self.model = model
        guard !running else { return }
        running = true
        // Outcomes already on the books when the roster first appears are
        // history, not events: seed them so a relaunch does not buzz through
        // a backlog.
        seen = Set(ApprovalOutcomes.shared.outcomes.keys)
        observe()
    }

    /// One-shot by design — `withObservationTracking` fires once, so the
    /// handler re-arms it. The re-arm happens on the same MainActor hop as the
    /// haptic, after the write has landed.
    private func observe() {
        withObservationTracking {
            _ = ApprovalOutcomes.shared.outcomes.count
        } onChange: {
            Task { @MainActor in
                ApprovalHaptics.shared.fire()
                ApprovalHaptics.shared.observe()
            }
        }
    }

    private func fire() {
        guard let model else { return }
        let outcomes = ApprovalOutcomes.shared.outcomes
        var fresh: [Bool] = []
        for (id, approved) in outcomes where !seen.contains(id) {
            seen.insert(id)
            fresh.append(approved)
        }
        // The ledger is process-lifetime and only grows; keeping `seen` to its
        // keys stops it outliving a sign-out that clears the outcomes.
        seen.formIntersection(outcomes.keys)
        guard !fresh.isEmpty else { return }
        // One buzz per pass. Clearing a backlog is one act, and five taptic
        // hits in a row read as a malfunction rather than a confirmation; a
        // denial in the batch wins, because that is the outcome worth feeling.
        model.feedback(fresh.contains(false) ? .deny : .approve)
    }
}

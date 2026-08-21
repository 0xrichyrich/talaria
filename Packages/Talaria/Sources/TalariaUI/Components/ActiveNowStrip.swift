import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ── "Active now" ─────────────────────────────────────────────────────────────
//
// A rail of small faces above the roster for the bots that are working right
// now: the ones mid-turn, plus a fresh conversation (90 seconds) or an
// independently fresh worker-session signal (150 seconds). The worker signal
// reaches this visual rail only; it never changes conversation recency,
// unread state, or roster order. Each face opens that bot's canonical chat by the
// same door a roster row uses.
//
// Three rules carried over from `ActiveNowStrip` (plugin.js:6888-6937), and
// each of them is the reason the strip is usable rather than annoying:
//
// 1. **Omitted entirely when nothing is active.** Not an empty header, not a
//    collapsed placeholder — zero height, and zero frames: the animation
//    driver below only exists while somebody is on it.
// 2. **It never reorders the roster beneath it.** It is a separate view above
//    the list, and its own order is `rankedBots` order, so the rail and the
//    list read the same way top-to-bottom. A bot waking up lights up in place;
//    nothing moves under a thumb mid-tap.
// 3. **Additive.** It layers over the row-level signals (the pulsing live dot,
//    the working ring) rather than replacing them — the row answers "is this
//    one alive", the rail answers "who is alive at all", which is the question
//    you have when you come back to the phone after ten minutes away.
//
// Desktop gets change announcements free from `role="status"
// aria-live="polite"` on the container. VoiceOver needs the sentence written
// out, so joins are announced explicitly; departures are not news and stay
// silent.

public struct ActiveNowStrip: View {
    private let model: AppModel

    /// Ids as of the last poll-driven body evaluation — the baseline the
    /// announcement diffs against.
    @State private var announced: [String] = []
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }

    private var faceSize: CGFloat { 24 }

    public var body: some View {
        // Evaluated on every observation change — the roster's own
        // `profiles.list` poll rewrites `RosterSignals.lastActive` on each
        // tick, which is what re-arms this without a clock of its own.
        let active = model.activeNowBots()
        VStack(spacing: 0) {
            if !active.isEmpty {
                // Membership has to decay on its own once the strip is
                // populated: nothing about a bot *changes* when its live
                // window closes, so without a tick the last face would sit
                // there until the next roster answer happened to land. The
                // driver exists only while the strip does, which keeps the
                // common case — an idle roster — at zero frames.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    rail(model.activeNowBots(now: context.date))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .animation(reducedMotion ? nil : .easeOut(duration: 0.28), value: active.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CopyPack.activeNowRegion(theme.id)))
        // A screen reader should hear who just started working. Joins only:
        // "…is no longer active" is noise, and desktop's polite live region
        // behaves the same way in practice because the region shrinks
        // silently.
        .onChange(of: active.map(\.id)) { _, current in
            let joined = current.filter { !announced.contains($0) }
            announced = current
            guard !joined.isEmpty else { return }
            let names = joined.compactMap { id in
                model.bots.first { $0.id == id }
            }.map { TalariaVoice.displayName(for: $0, theme.id) }
            guard !names.isEmpty else { return }
            Self.announce(CopyPack.activeNowJoined(names, theme.id))
        }
        .task {
            // Whoever is already working when the roster opens is not news —
            // seed the baseline so the first real join is announced alone
            // rather than dragging the standing membership along with it.
            announced = model.activeNowBotIDs()
            // A canonical chat minted moments ago is pinned locally before the
            // gateway echoes it back; hand those pins to the client so the
            // very next `profiles.list` resolves them precisely rather than
            // previewing the scratch session underneath.
            await model.syncCanonicalPins()
        }
    }

    // MARK: - The rail

    @ViewBuilder private func rail(_ bots: [Bot]) -> some View {
        if bots.isEmpty {
            // The 15 s driver outlived the last member. Collapse to nothing
            // rather than leaving a bare header behind; the outer body drops
            // the whole strip on the next observation tick.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(CopyPack.activeNowTitle(theme.id))
                    .font(titleFont)
                    .tracking(theme.id == .soft ? 0.3 : 1.4)
                    .foregroundStyle(theme.faint)
                    .accessibilityHidden(true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(bots) { bot in
                            chip(for: bot)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1)
                }
                // The label lines up with the roster's own gutter; the rail
                // itself bleeds to the edges so a wide set scrolls off-screen
                // instead of stopping short of it.
                .padding(.horizontal, -16)
                if theme.id == .ink {
                    // Ink separates blocks with a rule rather than a gap.
                    Rectangle()
                        .fill(theme.line)
                        .frame(height: 1)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(for bot: Bot) -> some View {
        Button {
            model.openChat(botID: bot.id)
        } label: {
            HStack(spacing: 7) {
                face(for: bot)
                Text(TalariaVoice.displayName(for: bot, theme.id))
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Desktop caps the chip label at `max-w-28` (112 px) so one
                    // long name cannot push the rest of the rail off-screen.
                    .frame(maxWidth: 112, alignment: .leading)
            }
            .padding(.vertical, 5)
            // Ink draws no chip, so its face has to sit on the page's own
            // gutter or the rail reads as indented against the ledger below.
            .padding(.leading, theme.id == .ink ? 0 : 5)
            .padding(.trailing, theme.id == .ink ? 8 : 10)
            .background(chipBackground)
            .contentShape(chipShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CopyPack.activeNowOpen(
            TalariaVoice.displayName(for: bot, theme.id), theme.id)))
        .accessibilityAddTraits(.isButton)
    }

    /// The same face the row paints — portrait when the gateway says one
    /// exists, the geometric silhouette otherwise — held in its working pose.
    /// Desktop hardcodes `mood: 'work'` on these chips (plugin.js:6934): being
    /// on the rail *is* the statement that this bot is working, so the face
    /// must not contradict it while the row's own pose is still catching up.
    private func face(for bot: Bot) -> some View {
        BotPortraitView(model: model, bot: bot, size: faceSize, theme: theme,
                        isWorking: true)
    }

    // MARK: - Pack voices

    private var chipShape: some InsettableShape {
        RoundedRectangle(cornerRadius: theme.chipIsCapsule ? faceSize : theme.buttonRadius,
                         style: .continuous)
    }

    @ViewBuilder private var chipBackground: some View {
        switch theme.id {
        case .soft:
            chipShape.fill(theme.panel)
                .overlay(chipShape.strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
        case .control:
            chipShape.fill(theme.inset)
                .overlay(chipShape.strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            // Ink's roster is a ledger: no filled chips, just the face and the
            // name sitting on the page.
            Color.clear
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .semibold)
        case .control: theme.mono(9, weight: .semibold)
        case .ink: theme.mono(8.5)
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .semibold)
        case .control: theme.mono(11, weight: .semibold)
        case .ink: theme.body(13, weight: .semibold)
        }
    }

    // MARK: - Announcements

    /// One announcement, on whichever accessibility stack this platform has.
    /// Deliberately not `AccessibilityNotification`: the package builds for
    /// macOS 14 as well, and this form is available on both without a version
    /// gate.
    private static func announce(_ message: String) {
        #if canImport(UIKit) && !os(watchOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif canImport(AppKit)
        guard let window = NSApp?.mainWindow ?? NSApp?.windows.first else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        #endif
    }
}

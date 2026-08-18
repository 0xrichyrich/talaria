import SwiftUI
import TalariaKit
import TalariaTheme

// The roster — the app's home screen. Themed kicker+title header with the
// search glyph, theme cycler, network chip and "+" (new bot); an offline
// banner when the gateway is unreachable; staggered-entrance bot rows with
// live status lines (working bots tick an elapsed timer every second, in each
// theme's own time format); the roster-count footer.
// Ported from Talaria.dc.html `data-screen-label="Roster"`.

public struct RosterView: View {
    private let model: AppModel
    private let onSearch: () -> Void
    private let onCreate: () -> Void
    private let onConnections: () -> Void

    /// Global 1s ticker driving every elapsed readout (the prototype's `secs`).
    @State private var seconds = 0

    public init(model: AppModel,
                onSearch: @escaping () -> Void = {},
                onCreate: @escaping () -> Void = {},
                onConnections: @escaping () -> Void = {}) {
        self.model = model
        self.onSearch = onSearch
        self.onCreate = onCreate
        self.onConnections = onConnections
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Skipped onboarding with no gateway: an honest empty roster with a way
    /// forward, instead of silently faked demo data.
    private var emptyState: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(shape: .hexagon, hue: .violet, size: 40, theme: theme)
                    .opacity(0.35)
                AvatarView(shape: .squircle, hue: .amber, size: 32, theme: theme)
                    .opacity(0.25)
                AvatarView(shape: .diamond, hue: .pink, size: 28, theme: theme)
                    .opacity(0.18)
            }
            Text(copy.emptyRosterTitle)
                .font(theme.display(20))
                .foregroundStyle(theme.ink)
            Text(copy.emptyRosterBody)
                .font(theme.body(14))
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: onConnections) {
                Text(copy.obCta0)
                    .font(theme.mono(12, weight: .bold))
                    .foregroundStyle(theme.accentFg)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(theme.accent,
                                in: RoundedRectangle(cornerRadius: theme.buttonRadius == 0 ? 0 : theme.buttonRadius + 2))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.kickerHome, title: copy.titleHome) {
                headerControls
            }
            if model.isOffline {
                offlineBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: listGap) {
                    if model.bots.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        ForEach(Array(model.bots.enumerated()), id: \.element.id) { index, bot in
                            row(for: bot, index: index)
                                .modifier(RosterEntrance(delay: Double(index) * 0.045))
                        }
                        footer
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                seconds += 1
            }
        }
    }

    // MARK: - Header controls

    private var headerControls: some View {
        HStack(spacing: 8) {
            HeaderIconButton(theme: theme, action: onSearch) { searchGlyph }
            HeaderIconButton(theme: theme, action: { model.theme.cycle() }) { themeGlyph }
            netChip
            plusButton
        }
    }

    /// Hand-drawn magnifier, matching the prototype's ring + handle.
    private var searchGlyph: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(theme.ink, lineWidth: 1.5)
                .frame(width: 9, height: 9)
            Rectangle()
                .fill(theme.ink)
                .frame(width: 5.5, height: 1.5)
                .rotationEffect(.degrees(45), anchor: .leading)
                .offset(x: 7, y: 7.5)
        }
        .frame(width: 14, height: 14)
    }

    /// Theme-cycle glyph: accent circle (soft), square (control), lozenge (ink).
    @ViewBuilder private var themeGlyph: some View {
        switch theme.id {
        case .soft:
            Circle().fill(theme.accent).frame(width: 13, height: 13)
        case .control:
            RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 13, height: 13)
        case .ink:
            Rectangle().fill(theme.accent).frame(width: 11, height: 11)
                .rotationEffect(.degrees(45))
        }
    }

    private var netChip: some View {
        let chip = TalariaVoice.netChip(offline: model.isOffline,
                                        connections: model.connections,
                                        theme.id)
        let color = TalariaVoice.netColor(chip.tone, theme: theme)
        return Button(action: onConnections) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.glowRadius > 0 ? color : .clear, radius: 4)
                    .glowPulse(period: 2.3)
                Text(chip.label)
                    .lineLimit(1)
                    .font(chipFont)
                    .tracking(theme.id == .ink ? 1.5 : 0)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.6) : theme.ink)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .chipShell(theme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chipFont: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var plusButton: some View {
        Button(action: onCreate) {
            Text(verbatim: "+")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.id == .ink ? theme.bg : theme.accentFg)
                .padding(.bottom, 2)
                .frame(width: 32, height: 32)
                .background(theme.id == .ink ? theme.ink : theme.accent)
                .clipShape(plusShape)
                .contentShape(plusShape)
        }
        .buttonStyle(.plain)
        .shadow(color: plusShadow, radius: theme.glowRadius > 0 ? 9 : 5, y: theme.id == .soft ? 4 : 0)
    }

    private var plusShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 16, style: .continuous)
    }

    private var plusShadow: Color {
        switch theme.id {
        case .soft: theme.accent.opacity(0.32)
        case .control: theme.accent.opacity(0.35)
        case .ink: .clear
        }
    }

    // MARK: - Offline banner

    private var offlineBanner: some View {
        Group {
            switch theme.id {
            case .soft:
                Text(copy.offline)
                    .font(theme.body(12, weight: .semibold))
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.danger.opacity(0.25), lineWidth: 1))
            case .control:
                Text(copy.offline)
                    .font(theme.mono(10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.danger.opacity(0.35), lineWidth: 1))
            case .ink:
                Text(copy.offline)
                    .font(theme.mono(9))
                    .tracking(1.5)
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(theme.danger.opacity(0.5), lineWidth: 1))
            }
        }
    }

    // MARK: - Rows

    private func row(for bot: Bot, index: Int) -> some View {
        Button {
            // openChat, never a raw openBotID write: it is what resumes the
            // bot's canonical forever-chat and hydrates the transcript. A bare
            // navigation write opens an empty chat whose first send forks a
            // brand-new session away from the bot's real history.
            model.openChat(botID: bot.id)
        } label: {
            HStack(alignment: .center, spacing: 13) {
                avatar(for: bot)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        nameText(for: bot)
                        jobText(for: bot)
                    }
                    statusLine(for: bot, index: index)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(bot.previewTime.isEmpty ? "new" : bot.previewTime)
                        .font(timeFont)
                        .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.38) : theme.faint)
                    badge(for: bot)
                }
            }
            .padding(rowPadding)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                if theme.rowStyle == .ledger {
                    Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func avatar(for bot: Bot) -> some View {
        ZStack {
            if bot.status == .working {
                WorkingPulse(color: theme.id == .ink ? theme.ink.opacity(0.55)
                                : theme.color(for: bot.hue),
                             lineWidth: theme.id == .soft ? 2 : 1.5)
                    .frame(width: 54, height: 54)
            }
            AvatarView(bot: bot, size: 46, theme: theme)
        }
        .frame(width: 46, height: 46)
        // Bot Mode's petMode: the profile's mascot keeps a working bot
        // company. Pinned to the avatar's corner like the prototype's marker —
        // an overlay, so a pet appearing never reflows the row, and it renders
        // nothing at all on a gateway without pets.
        .overlay(alignment: .bottomTrailing) {
            if bot.status == .working {
                PetCompanionView(model: model, bot: bot)
                    .offset(x: 4, y: 2)
            }
        }
    }

    /// Title + @handle, from the one identity path
    /// (Components/BotIdentity.swift) — the same pair the profile sheet
    /// renders, so a bot never reads two different names in two places.
    private func nameText(for bot: Bot) -> some View {
        BotIdentityLabel(bot: bot, theme: theme, scale: .row)
    }

    private func jobText(for bot: Bot) -> some View {
        Group {
            switch theme.id {
            case .soft:
                Text(bot.job).font(theme.body(11, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.38))
            case .control:
                Text(bot.job.uppercased()).font(theme.mono(9, weight: .semibold))
                    .tracking(1.2).foregroundStyle(theme.ink.opacity(0.35))
            case .ink:
                Text(bot.job.uppercased()).font(theme.mono(8.5))
                    .tracking(1.5).foregroundStyle(theme.ink.opacity(0.45))
            }
        }
        .lineLimit(1)
    }

    /// The live line: working = task + ticking elapsed, approval/mention/idle
    /// = preview, tinted and weighted per state. Control appends a blinking
    /// block cursor while working.
    private func statusLine(for bot: Bot, index: Int) -> some View {
        // Per-row second offset so timers don't tick in lockstep (prototype:
        // `(secs + i * 17) % 60`).
        let rowSeconds = (seconds + index * 17) % 60
        let line = TalariaVoice.rosterLine(for: bot, seconds: rowSeconds, theme.id)
        let working = bot.status == .working
        let hot = bot.mentionsYou || bot.status == .approval || working

        return HStack(spacing: 6) {
            Text(line)
                .font(previewFont(hot: hot))
                .italic(theme.id == .ink && (working || bot.mentionsYou))
                .foregroundStyle(previewColor(for: bot))
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
            if working && theme.id == .control {
                BlinkingCursor(color: theme.color(for: bot.hue))
            }
        }
    }

    private func previewFont(hot: Bool) -> Font {
        switch theme.id {
        case .soft: theme.body(13, weight: hot ? .semibold : .regular)
        case .control: theme.mono(11, weight: hot ? .semibold : .regular)
        case .ink: theme.body(14.5, weight: hot ? .semibold : .regular)
        }
    }

    private func previewColor(for bot: Bot) -> Color {
        if bot.mentionsYou {
            return theme.id == .control ? theme.color(for: .pink) : theme.accent
        }
        if bot.status == .approval {
            return theme.id == .control ? theme.warn : theme.danger
        }
        if bot.status == .working {
            return theme.id == .soft ? theme.color(for: bot.hue) : theme.ink
        }
        return theme.sub
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    @ViewBuilder private func badge(for bot: Bot) -> some View {
        if bot.unread > 0 || bot.status == .approval {
            let isHold = bot.status == .approval
            let text = isHold ? "!" : String(bot.unread)
            let bg: Color = theme.id == .ink ? theme.danger
                : isHold ? (theme.id == .control ? theme.warn : theme.danger)
                : theme.accent
            let fg: Color = theme.id == .control ? theme.bg
                : theme.id == .ink ? theme.bg : theme.accentFg

            Group {
                switch theme.id {
                case .soft:
                    Text(text).font(theme.body(11, weight: .bold))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(bg, in: RoundedRectangle(cornerRadius: 9))
                case .control:
                    Text(text).font(theme.mono(10, weight: .bold))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(bg, in: RoundedRectangle(cornerRadius: 3))
                case .ink:
                    Text(text).font(theme.mono(9.5, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(bg, in: Circle())
                        .shadow(color: theme.ink.opacity(0.3), radius: 1.5, y: 1)
                }
            }
            .foregroundStyle(fg)
        }
    }

    private var rowPadding: EdgeInsets {
        switch theme.rowStyle {
        case .card: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        case .terminal: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13)
        case .ledger: EdgeInsets(top: 14, leading: 2, bottom: 14, trailing: 2)
        }
    }

    @ViewBuilder private var rowBackground: some View {
        switch theme.rowStyle {
        case .card:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1.5, y: 1)
        case .terminal:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            Color.clear
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text(TalariaVoice.rosterFooter(botCount: model.bots.count,
                                       gatewayCount: max(model.connections.count, 1),
                                       theme.id))
            .font(footFont)
            .tracking(theme.id == .soft ? 0 : theme.id == .control ? 1 : 2)
            .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.35)
                : theme.id == .control ? theme.ink.opacity(0.3) : theme.ink.opacity(0.4))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.mono(8.5)
        }
    }
}

// MARK: - Local effects

/// The prototype's `cursorU`: a hard step blink, on for half the second.
private struct BlinkingCursor: View {
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 6, height: 11)
                .opacity(on ? 1 : 0)
        }
    }
}

/// rowU — staggered fade + rise entrance.
private struct RosterEntrance: ViewModifier {
    var delay: Double
    @State private var shown = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            // Damped, the row still fades in — but it does not travel, and the
            // stagger collapses so the whole roster is legible at once.
            .offset(y: shown || reducedMotion ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                if reducedMotion {
                    withAnimation(.easeOut(duration: 0.2)) { shown = true }
                } else {
                    withAnimation(.easeOut(duration: 0.45).delay(delay)) { shown = true }
                }
            }
    }
}

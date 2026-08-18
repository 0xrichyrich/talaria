import SwiftUI
import TalariaKit
import TalariaTheme

// Reusable screen chrome: the kicker+title header every top-level screen uses,
// plus the small themed atoms (icon buttons, chip shells) and the themed
// strings that live *outside* CopyPack in the design prototype (bot display
// names, elapsed formats, state lines, net-chip labels, done-words).
// Ported from Talaria.dc.html: T.kickerCss/titleCss/ornDisplay + renderVals().

// MARK: - ScreenHeader

/// Kicker + title header, per theme:
/// - soft: no kicker, 31pt heavy title
/// - control: phosphor mono kicker + 27pt heavy title
/// - ink: ornament rule, mono kicker, 28pt Cormorant small-caps title
public struct ScreenHeader<Trailing: View>: View {
    public var theme: ThemePack
    public var kicker: String?
    public var title: String
    @ViewBuilder public var trailing: () -> Trailing

    public init(theme: ThemePack, kicker: String? = nil, title: String,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.theme = theme
        self.kicker = kicker
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if theme.id == .ink {
                ornament
            }
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: theme.id == .control ? 3 : 1) {
                    if theme.showsKicker, let kicker, !kicker.isEmpty {
                        Text(kicker)
                            .font(theme.mono(9.5, weight: .semibold))
                            .tracking(theme.id == .control ? 2.5 : 2)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                            .lineLimit(1)
                    }
                    titleText
                }
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var titleText: some View {
        switch theme.id {
        case .soft:
            Text(title)
                .font(theme.body(31, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        case .control:
            Text(title)
                .font(theme.body(27, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        case .ink:
            Text(title)
                .font(theme.display(28).smallCaps())
                .tracking(0.5)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
    }

    /// Ink's line — ◆ — line rule above the header.
    private var ornament: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.lineStrong).frame(height: 1)
            Rectangle()
                .fill(theme.ink)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
            Rectangle().fill(theme.lineStrong).frame(height: 1)
        }
    }
}

// MARK: - Icon button

/// The 32pt round/rounded icon button used across headers (search glyph,
/// theme cycler, back chevron, sheet closers). Silhouette follows
/// `iconCornerFraction`; chrome follows the theme's iconBtnCss.
public struct HeaderIconButton<Glyph: View>: View {
    public var theme: ThemePack
    public var size: CGFloat
    public var action: () -> Void
    @ViewBuilder public var glyph: () -> Glyph

    public init(theme: ThemePack, size: CGFloat = 32, action: @escaping () -> Void,
                @ViewBuilder glyph: @escaping () -> Glyph) {
        self.theme = theme
        self.size = size
        self.action = action
        self.glyph = glyph
    }

    public var body: some View {
        Button(action: action) {
            glyph()
                .frame(width: size, height: size)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * theme.iconCornerFraction, style: .continuous)
    }

    private var borderColor: Color {
        theme.id == .soft ? theme.line : theme.lineStrong
    }
}

// MARK: - Chip shell

/// The pill/panel chrome behind small chips (net chip, model strip, routines
/// button): capsule card in soft, bordered panel in control, hairline square
/// in ink.
public struct ChipShell: ViewModifier {
    public var theme: ThemePack

    public init(theme: ThemePack) { self.theme = theme }

    public func body(content: Content) -> some View {
        let radius = theme.id == .ink ? theme.inputRadius : theme.buttonRadius
        if theme.chipIsCapsule {
            content
                .background(theme.panel)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        } else {
            content
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.lineStrong.opacity(0.8),
                                  lineWidth: 1))
        }
    }
}

public extension View {
    func chipShell(_ theme: ThemePack) -> some View {
        modifier(ChipShell(theme: theme))
    }
}

// MARK: - Themed action buttons

/// The btnPriCss treatment: violet capsule-ish card in soft, phosphor block in
/// control, ink-black seal button in ink. Used by approval cards, push
/// banners and onboarding CTAs.
public struct ThemedPrimaryButton: View {
    public var theme: ThemePack
    public var title: String
    public var compact: Bool
    public var action: () -> Void

    public init(theme: ThemePack, title: String, compact: Bool = false,
                action: @escaping () -> Void) {
        self.theme = theme; self.title = title; self.compact = compact; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 7 : 10)
                .background(theme.id == .ink ? theme.ink : theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
        }
        .buttonStyle(.plain)
        .shadow(color: theme.glowRadius > 0 ? theme.accent.opacity(0.22)
                    : theme.id == .soft ? theme.accent.opacity(0.28) : .clear,
                radius: theme.glowRadius > 0 ? 8 : 5, y: theme.id == .soft ? 4 : 0)
    }

    @ViewBuilder private var label: some View {
        switch theme.id {
        case .soft:
            Text(title).font(theme.body(13.5, weight: .bold)).foregroundStyle(theme.accentFg)
        case .control:
            Text(title).font(theme.mono(11, weight: .bold)).tracking(1.5)
                .foregroundStyle(theme.accentFg)
        case .ink:
            Text(title).font(theme.body(15, weight: .bold).smallCaps()).tracking(1.5)
                .foregroundStyle(theme.bg)
        }
    }
}

/// The btnSecCss treatment: quiet gray in soft, red-bordered ABORT in
/// control, vermilion-ruled refuse in ink.
public struct ThemedSecondaryButton: View {
    public var theme: ThemePack
    public var title: String
    public var compact: Bool
    public var fillsWidth: Bool
    public var action: () -> Void

    public init(theme: ThemePack, title: String, compact: Bool = false,
                fillsWidth: Bool = false, action: @escaping () -> Void) {
        self.theme = theme; self.title = title; self.compact = compact
        self.fillsWidth = fillsWidth; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .padding(.vertical, compact ? 7 : 10)
                .padding(.horizontal, fillsWidth ? 0 : 16)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(theme.id == .soft ? theme.ink.opacity(0.05) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .strokeBorder(borderColor, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
        }
        .buttonStyle(.plain)
    }

    private var borderColor: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.danger.opacity(0.4)
        case .ink: theme.accent.opacity(0.6)
        }
    }

    @ViewBuilder private var label: some View {
        switch theme.id {
        case .soft:
            Text(title).font(theme.body(13.5, weight: .bold)).foregroundStyle(theme.ink)
        case .control:
            Text(title).font(theme.mono(11, weight: .bold)).tracking(1.5)
                .foregroundStyle(theme.danger)
        case .ink:
            Text(title).font(theme.body(15, weight: .bold).smallCaps()).tracking(1)
                .foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Glow pulse

/// The prototype's `glowU` keyframe: opacity breathing .45 → 1, used on
/// status dots and pending-approval markers.
public struct GlowPulse: ViewModifier {
    public var period: Double
    @State private var dim = false

    public init(period: Double = 2.2) { self.period = period }

    public func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

public extension View {
    /// Apply the glowU opacity pulse.
    func glowPulse(period: Double = 2.2) -> some View {
        modifier(GlowPulse(period: period))
    }
}

// MARK: - Themed voice (strings outside CopyPack)

/// Themed logic the prototype computes outside `copy()` — display names,
/// elapsed-time formats, roster/chat status lines, net-chip labels, roster
/// footer and approval done-words. Kept here so Roster/Chat/banner and any
/// other screen agree on the voice.
public enum TalariaVoice {

    public static func capitalized(_ id: String) -> String {
        guard let first = id.first else { return id }
        return String(first).uppercased() + id.dropFirst()
    }

    // The bare-id overloads that used to live here (`displayName(_ id:)` and
    // `plainUpper(_ id:)`) are gone. Both re-derived a name from the profile
    // id — `plainUpper` printed it verbatim, so the primary profile shouted
    // DEFAULT where every other surface says HERMES — which is the split
    // identity Phase 0 removed. A call site holding only an id now goes
    // through `AppModel.identity(_:)`; one holding an optional Bot uses the
    // `displayName(_:id:_:)` overload in Components/BotIdentity.swift.

    /// Desktop Bot Mode's title (plugin.js `displayName`): a user-set title,
    /// "Hermes" for the primary "default" profile, else the de-slugged
    /// profile name. Ink renders it small-caps, so it stays unprefixed there;
    /// the other packs keep the prototype's @-prefix only when the bot has no
    /// distinct title, so a titled bot reads "skynet" rather than "@skynet".
    public static func displayName(for bot: Bot, _ theme: ThemeID) -> String {
        bot.showsHandle || theme == .ink ? bot.displayTitle : "@" + bot.handle
    }

    /// The @handle you tag a bot with (plugin.js `botHandle`): the profile
    /// name, except "default" → @hermes. Shown beside the title only when the
    /// two differ, matching desktop's `showsHandle`.
    public static func handle(for bot: Bot) -> String {
        "@" + bot.handle
    }

    /// Elapsed-time readout: soft "4m 12s" · control "04:12" · ink "4 minutes gone".
    public static func elapsed(minutes: Int, seconds: Int, _ theme: ThemeID) -> String {
        switch theme {
        case .control: String(format: "%02d:%02d", minutes, seconds)
        case .ink: "\(minutes) minutes gone"
        case .soft: "\(minutes)m \(seconds)s"
        }
    }

    /// The roster row's live line: working = task + ticking elapsed
    /// (control prefixes "▸ "), otherwise the last-message preview.
    public static func rosterLine(for bot: Bot, seconds: Int, _ theme: ThemeID) -> String {
        guard bot.status == .working, let task = bot.task else { return bot.preview }
        let el = elapsed(minutes: bot.minutesElapsed, seconds: seconds, theme)
        let sep = theme == .ink ? " — " : " · "
        return (theme == .control ? "▸ " : "") + task + sep + el
    }

    /// The chat header's state line under the bot name.
    public static func chatStateLine(for bot: Bot, _ theme: ThemeID) -> String {
        switch bot.status {
        case .working:
            return bot.task ?? bot.preview
        case .approval:
            switch theme {
            case .ink: return "held — awaiting your seal"
            case .control: return "HOLD — waiting on you"
            case .soft: return "blocked — waiting on you"
            }
        case .idle:
            return theme == .ink ? "at rest · memory warm" : "idle · memory warm"
        }
    }

    /// Approval card outcome line: "Approved — sent" / "RELEASED — RAN CLEAN"
    /// / "sealed — done cleanly", and the denial forms.
    public static func doneWord(kind: ApprovalKind, approved: Bool, _ theme: ThemeID) -> String {
        guard approved else {
            switch theme {
            case .ink: return "refused — the familiar knows"
            case .control: return "ABORTED — AGENT NOTIFIED"
            case .soft: return "Denied — bot notified"
            }
        }
        let act: String
        switch kind {
        case .email: act = theme == .control ? "SENT" : "sent"
        case .command: act = theme == .control ? "RAN CLEAN" : theme == .ink ? "done cleanly" : "ran clean"
        case .post, .other: act = "scheduled"
        }
        switch theme {
        case .ink: return "sealed — " + act
        case .control: return "RELEASED — " + act
        case .soft: return "Approved — " + act
        }
    }

    /// Roster footer: "6 bots · 3 gateways · profiles are the bots" in each voice.
    public static func rosterFooter(botCount: Int, gatewayCount: Int, _ theme: ThemeID) -> String {
        switch theme {
        case .ink: "\(botCount) FAMILIARS · \(gatewayCount) WAYS · THE PROFILES ARE THE BOTS"
        case .control: "\(botCount) AGENTS · \(gatewayCount) UPLINKS · PROFILES ARE THE BOTS"
        case .soft: "\(botCount) bots · \(gatewayCount) gateways · profiles are the bots"
        }
    }

    public enum NetTone: Sendable { case up, cloud, down }

    /// Header net chip: label + tone, from live connection state.
    public static func netChip(offline: Bool, connections: [GatewayConnection],
                               _ theme: ThemeID) -> (label: String, tone: NetTone) {
        if offline {
            switch theme {
            case .ink: return ("SEVERED", .down)
            case .control: return ("NO LINK", .down)
            case .soft: return ("offline", .down)
            }
        }
        let primary = connections.first { $0.state == .connected } ?? connections.first
        if let primary, primary.kind == .cloud {
            switch theme {
            case .ink: return ("BY CLOUD", .cloud)
            case .control, .soft: return ("cloud", .cloud)
            }
        }
        let name = primary?.name ?? "homelab"
        return (theme == .ink ? name.uppercased() : name, .up)
    }

    /// Dot/label color for a net tone.
    public static func netColor(_ tone: NetTone, theme: ThemePack) -> Color {
        switch tone {
        case .up: theme.id == .control ? theme.accent : theme.ok
        case .cloud: theme.color(for: .blue)
        case .down: theme.danger
        }
    }
}

import SwiftUI
import TalariaKit
import TalariaTheme

// The chrome every Settings section is built from, in one place so the four
// sections cannot drift apart. Nothing here knows what a setting *is* — it is
// the themed vocabulary: section heading, grouped rows, value row, switch row,
// segmented picker, action row, footnote.
//
// The treatments follow `ThemePack.rowStyle`, the same split the roster and
// Connections use: soft = one floating card with hairline separators, control =
// a bordered terminal panel, ink = chrome-free ruled ledger lines.
//
// Reuse rather than duplication where a component already exists elsewhere:
// section headings and footnotes are `GatewaySectionLabel` / `GatewayFootnote`
// from OnboardingView, and the theme swatches are its `ThemeSwatchCard`.

// MARK: - Section

/// A titled block: uppercase heading, grouped content, optional footnote.
struct SettingsSection<Content: View>: View {
    var theme: ThemePack
    var title: String
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GatewaySectionLabel(theme: theme, text: title)
                .padding(.horizontal, 2)
            content()
            if let footnote, !footnote.isEmpty {
                GatewayFootnote(theme: theme, text: footnote)
                    .padding(.horizontal, 2)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Group chrome

/// The container behind a run of rows. Ink deliberately has none: its rows are
/// ruled, so a box around them would be a second frame.
struct SettingsGroup<Content: View>: View {
    var theme: ThemePack
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SettingsGroupChrome(theme: theme))
    }
}

struct SettingsGroupChrome: ViewModifier {
    var theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .background(theme.panel)
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .background(theme.panel)
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .overlay(alignment: .top) { theme.lineStrong.frame(height: 1) }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 10 : 18, style: .continuous)
    }
}

/// Row padding + the separator between rows. `isLast` suppresses the rule at
/// the bottom of a card; ink keeps it, because its list *is* the rules.
struct SettingsRowChrome: ViewModifier {
    var theme: ThemePack
    var isLast: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 14)
            .padding(.vertical, theme.rowStyle == .ledger ? 13 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if !isLast || theme.rowStyle == .ledger {
                    theme.line.frame(height: 1)
                }
            }
    }
}

// MARK: - Rows

/// Title (+ optional subtitle) on the left, a value and/or chevron on the
/// right. Tappable when `action` is set.
struct SettingsRow: View {
    var theme: ThemePack
    var title: String
    var subtitle: String?
    var value: String?
    var valueTone: Color?
    var showsChevron: Bool = false
    var isLast: Bool = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsType.rowSubtitle(theme))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let value, !value.isEmpty {
                Text(value)
                    .font(SettingsType.rowValue(theme))
                    .foregroundStyle(valueTone ?? theme.faint)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if showsChevron {
                Text(verbatim: "›")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.45) : theme.accent)
            }
        }
    }
}

/// A row whose right side is the themed switch.
struct SettingsToggleRow: View {
    var theme: ThemePack
    var title: String
    var subtitle: String?
    var isOn: Bool
    var isLast: Bool = false
    var toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SettingsType.rowSubtitle(theme))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsSwitch(theme: theme, isOn: isOn, action: toggle)
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A whole-row button. `isDestructive` borrows the danger token rather than a
/// second button style, so the three packs stay in charge of the color.
struct SettingsActionRow: View {
    var theme: ThemePack
    var title: String
    var subtitle: String?
    var isDestructive: Bool = false
    var isBusy: Bool = false
    var isLast: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsType.rowTitle(theme))
                        .foregroundStyle(isDestructive ? theme.danger
                                                       : (theme.id == .ink ? theme.ink : theme.accent))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsType.rowSubtitle(theme))
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }
}

/// A row that leaves the app. Kept separate from `SettingsRow` so the outward
/// arrow (and the accessibility link trait) is never accidental.
struct SettingsLinkRow: View {
    var theme: ThemePack
    var title: String
    var subtitle: String?
    var url: URL
    var isLast: Bool = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsType.rowTitle(theme))
                        .foregroundStyle(theme.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsType.rowSubtitle(theme))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "↗")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.45) : theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Segmented picker

/// The themed segmented control used by Appearance. Generic over the choice so
/// the text-size and motion pickers share one implementation and one look.
struct SettingsSegmented<Value: Hashable>: View {
    var theme: ThemePack
    var options: [(value: Value, label: String)]
    var selection: Value
    var pick: (Value) -> Void

    var body: some View {
        HStack(spacing: theme.id == .ink ? 0 : 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { pick(option.value) } label: {
                    Text(option.label)
                        .font(font)
                        .tracking(theme.id == .soft ? 0 : 0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(foreground(isOn: option.value == selection))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(background(isOn: option.value == selection))
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(border(isOn: option.value == selection),
                                                    lineWidth: 1))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(option.value == selection ? [.isSelected] : [])
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : theme.buttonRadius, style: .continuous)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .bold)
        case .control: theme.mono(9.5, weight: .bold)
        case .ink: theme.body(13, weight: .semibold).smallCaps()
        }
    }

    private func foreground(isOn: Bool) -> Color {
        guard isOn else { return theme.id == .ink ? theme.ink.opacity(0.5) : theme.sub }
        switch theme.id {
        case .soft: return theme.accentFg
        case .control: return theme.accent
        case .ink: return theme.bg
        }
    }

    private func background(isOn: Bool) -> Color {
        guard isOn else { return theme.id == .soft ? theme.ink.opacity(0.05) : .clear }
        switch theme.id {
        case .soft: return theme.accent
        case .control: return theme.accent.opacity(0.12)
        case .ink: return theme.ink
        }
    }

    private func border(isOn: Bool) -> Color {
        switch theme.id {
        case .soft: return .clear
        case .control: return isOn ? theme.accent.opacity(0.6) : theme.line
        case .ink: return theme.lineStrong
        }
    }
}

// MARK: - Switch

/// The design's 46×27 switch (trackOn / trackOff / knobCss). File-scoped to the
/// Settings feature, matching the copies Connections and Routines keep.
struct SettingsSwitch: View {
    var theme: ThemePack
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.strokeBorder(trackBorder, lineWidth: 1))
                knobShape
                    .fill(knobFill)
                    .frame(width: 21, height: 21)
                    .shadow(color: theme.id == .soft ? Color.black.opacity(0.2) : .clear,
                            radius: 1.5, y: 1)
                    .offset(x: isOn ? 21 : 2.5)
            }
            .frame(width: 46, height: 27)
            .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var knobShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 10.5, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackBorder: Color {
        theme.id == .soft ? .clear : theme.lineStrong
    }

    private var knobFill: Color {
        switch theme.id {
        case .soft: theme.panel
        case .control: theme.ink
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.35)
        }
    }
}

// MARK: - Type scale

/// One place for the row type ramp, so a value row in Gateways and one in
/// Privacy are the same size in the same theme.
enum SettingsType {
    static func rowTitle(_ theme: ThemePack) -> Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .semibold)
        case .control: theme.body(13.5, weight: .semibold)
        case .ink: theme.body(16, weight: .semibold)
        }
    }

    static func rowSubtitle(_ theme: ThemePack) -> Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }

    static func rowValue(_ theme: ThemePack) -> Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }
}

// MARK: - Motion

/// The staggered entrance every Settings section uses, damped to a plain fade
/// when reduce-motion is in effect (system setting, or the app override in
/// Appearance).
struct SettingsEntrance: ViewModifier {
    var delay: Double
    var reduced: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduced {
                    withAnimation(.easeOut(duration: 0.2)) { shown = true }
                } else {
                    withAnimation(.easeOut(duration: 0.36).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func settingsEntrance(delay: Double, reduced: Bool) -> some View {
        modifier(SettingsEntrance(delay: delay, reduced: reduced))
    }
}

// Models / Voice / Notifications live in sibling files in this same module, so
// `SettingsView` names them directly. An earlier draft routed them through a
// mutable registry that something had to install at start-up; nothing ever did,
// and three of the seven sections silently vanished. A registry cannot be
// type-checked into existence — a direct reference can.

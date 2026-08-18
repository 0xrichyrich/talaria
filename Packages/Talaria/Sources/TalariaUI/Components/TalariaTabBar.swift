import SwiftUI
import TalariaKit
import TalariaTheme

// The five-tab bar in its three theme treatments, ported from the prototype's
// tabBarCss/itemActive/tabMark/tabNum tokens:
// - soft:    floating glass capsule with a dark active pill,
// - control: full-width mono terminal bar, glowing tick above the active tab,
// - ink:     parchment ledger footer, double top rule, roman numerals i–v.
// Labels come from CopyPack.tabs; any tab can carry a count badge. Two tones:
// alerts (blocked approvals) burn in danger/warn, unread counts sit in the
// accent so a waiting seal never reads as "three new messages".

public struct TalariaTabBar: View {
    public var theme: ThemePack
    public var copy: CopyPack
    public var selected: CopyPack.Tab
    /// Count per tab; absent or non-positive entries render no badge.
    public var badges: [CopyPack.Tab: Int]
    public var onSelect: (CopyPack.Tab) -> Void

    public init(theme: ThemePack, copy: CopyPack, selected: CopyPack.Tab,
                badges: [CopyPack.Tab: Int], onSelect: @escaping (CopyPack.Tab) -> Void) {
        self.theme = theme; self.copy = copy; self.selected = selected
        self.badges = badges; self.onSelect = onSelect
    }

    /// Approvals-only convenience, kept for callers that predate per-tab badges.
    public init(theme: ThemePack, copy: CopyPack, selected: CopyPack.Tab,
                badgeCount: Int, onSelect: @escaping (CopyPack.Tab) -> Void) {
        self.init(theme: theme, copy: copy, selected: selected,
                  badges: badgeCount > 0 ? [.approvals: badgeCount] : [:],
                  onSelect: onSelect)
    }

    /// The prototype's ROM array — lowercase numerals set in mono.
    private static let numerals = ["i", "ii", "iii", "iv", "v"]

    public var body: some View {
        switch theme.tabBarStyle {
        case .floatingPill: floatingPill
        case .terminal: terminal
        case .doubleRule: doubleRule
        }
    }

    // MARK: - Soft · floating glass pill

    private var floatingPill: some View {
        HStack(spacing: 0) {
            ForEach(Array(copy.tabs.enumerated()), id: \.offset) { index, item in
                pillItem(item.label, tab: item.tab, index: index)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(theme.panel.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        .shadow(color: theme.ink.opacity(0.12), radius: 15, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func pillItem(_ label: String, tab: CopyPack.Tab, index: Int) -> some View {
        let on = tab == selected
        return Button {
            onSelect(tab)
        } label: {
            Text(label)
                .font(theme.body(11, weight: .bold))
                .foregroundStyle(on ? theme.panel : theme.ink.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(on ? theme.ink : Color.clear, in: Capsule())
                .overlay(alignment: .topTrailing) { badge(for: tab).offset(x: 4, y: -5) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Control · terminal bar

    private var terminal: some View {
        HStack(spacing: 0) {
            ForEach(Array(copy.tabs.enumerated()), id: \.offset) { index, item in
                terminalItem(item.label, tab: item.tab, index: index)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .bottom)
        }
        .background {
            theme.bg.opacity(0.92).ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(theme.lineStrong.opacity(0.7)).frame(height: 1)
        }
    }

    private func terminalItem(_ label: String, tab: CopyPack.Tab, index: Int) -> some View {
        let on = tab == selected
        return Button {
            onSelect(tab)
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? theme.accent : theme.ink.opacity(0.12))
                    .frame(width: 22, height: 3)
                    .shadow(color: on ? theme.accent.opacity(0.6) : .clear, radius: 5)
                Text(label)
                    .font(theme.mono(9.5, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(on ? theme.ink : theme.ink.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .overlay(alignment: .topTrailing) { badge(for: tab).offset(x: 4, y: -5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Ink · double-rule ledger

    private var doubleRule: some View {
        HStack(spacing: 0) {
            ForEach(Array(copy.tabs.enumerated()), id: \.offset) { index, item in
                ledgerItem(item.label, tab: item.tab, index: index)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            theme.bg.opacity(0.96).ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 1) {
                Rectangle().fill(theme.ink.opacity(0.5)).frame(height: 1)
                Rectangle().fill(theme.ink.opacity(0.5)).frame(height: 1)
            }
        }
    }

    private func ledgerItem(_ label: String, tab: CopyPack.Tab, index: Int) -> some View {
        let on = tab == selected
        return Button {
            onSelect(tab)
        } label: {
            VStack(spacing: 1) {
                Text(Self.numerals[min(index, Self.numerals.count - 1)])
                    .font(theme.mono(8))
                    .tracking(1)
                    .foregroundStyle(on ? theme.accent : theme.faint)
                Text(label)
                    .font(theme.body(13, weight: .bold).smallCaps())
                    .tracking(0.5)
                    .foregroundStyle(on ? theme.accent : theme.ink.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .overlay(alignment: .topTrailing) { badge(for: tab).offset(x: 4, y: -5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Badge

    /// Blocked work reads hotter than unread traffic.
    private enum BadgeTone { case alert, unread }

    private func tone(for tab: CopyPack.Tab) -> BadgeTone {
        tab == .approvals ? .alert : .unread
    }

    /// Counts past two digits stop being readable at 16pt.
    private func badgeText(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func fill(_ tone: BadgeTone) -> Color {
        switch tone {
        case .alert:
            // Vermilion in soft/ink, amber on the phosphor bar.
            return theme.id == .control ? theme.warn : theme.danger
        case .unread:
            // Ink's danger and accent are the same vermilion, so unread there
            // is a plain ledger dot instead — the seal must stay unique.
            return theme.id == .ink ? theme.ink : theme.accent
        }
    }

    @ViewBuilder private func badge(for tab: CopyPack.Tab) -> some View {
        let count = badges[tab] ?? 0
        if count > 0 {
            let text = Text(badgeText(count))
            let color = fill(tone(for: tab))
            switch theme.id {
            case .soft:
                text.font(theme.body(10, weight: .heavy))
                    .foregroundStyle(theme.panel)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(color, in: RoundedRectangle(cornerRadius: 8))
            case .control:
                text.font(theme.mono(9, weight: .bold))
                    .foregroundStyle(theme.bg)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(color, in: RoundedRectangle(cornerRadius: 3))
                    .shadow(color: color.opacity(0.5), radius: theme.glowRadius / 2)
            case .ink:
                // Wax-seal badge: disc with an inner parchment ring.
                text.font(theme.mono(8.5, weight: .semibold))
                    .foregroundStyle(theme.bg)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, count > 9 ? 3 : 0)
                    .background(color, in: Capsule())
                    .overlay(Capsule().inset(by: 1.5).strokeBorder(theme.bg, lineWidth: 1))
            }
        }
    }
}

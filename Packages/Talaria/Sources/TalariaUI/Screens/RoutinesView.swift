import SwiftUI
import TalariaKit
import TalariaTheme

// Routines — pushed from a bot's chat. This bot's routines (with themed
// toggles), a dashed "+ new routine" row, an "Other bots" ledger, and the
// Hermes-cron footnote. Ported from Talaria.dc.html
// `data-screen-label="Routines"`.

public struct RoutinesView: View {
    private let model: AppModel
    private let botID: String
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(model: AppModel, botID: String, onBack: (() -> Void)? = nil) {
        self.model = model
        self.botID = botID
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var mine: [Routine] { model.routines.filter { $0.botID == botID } }
    private var others: [Routine] { model.routines.filter { $0.botID != botID } }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
                    ForEach(Array(mine.enumerated()), id: \.element.id) { index, routine in
                        RoutineRow(routine: routine, theme: theme, copy: copy) {
                            model.toggleRoutine(routine)
                        }
                        .modifier(RowEntrance(delay: Double(index) * 0.055))
                    }

                    newRoutineRow

                    Text(copy.otherBots)
                        .font(theme.mono(theme.id == .soft ? 11 : 9, weight: .heavy))
                        .tracking(theme.id == .soft ? 1 : 2)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                        .padding(.top, 12)
                        .padding(.horizontal, 2)

                    ForEach(others) { routine in
                        otherBotRow(routine)
                    }

                    Text(copy.cronNote)
                        .font(footnoteFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(iconButtonShape)
                    .overlay(iconButtonShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.kickerRoutines)
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(verbatim: "\(copy.titleRoutines) \(themedBotName(botID, theme: theme))")
                    .font(subtitleFont)
                    .foregroundStyle(theme.ink)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var iconButtonShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    private var footnoteFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }

    // MARK: Rows

    private var newRoutineRow: some View {
        Text(copy.newRoutine)
            .font(newRoutineFont)
            .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: theme.rowRadius > 0 ? theme.cardRadius : 0,
                                 style: .continuous)
                    .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.dashColor,
                                  style: StrokeStyle(lineWidth: theme.id == .soft ? 1.5 : 1,
                                                     dash: [5, 4]))
            )
            .contentShape(Rectangle())
    }

    private var newRoutineFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private func otherBotRow(_ routine: Routine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(themedBotName(routine.botID, theme: theme))
                .font(otherNameFont)
                .foregroundStyle(theme.color(for: model.bot(routine.botID)?.hue ?? .teal))
            Text(routine.name)
                .font(theme.body(theme.id == .ink ? 14.5 : (theme.id == .control ? 12.5 : 13)))
                .foregroundStyle(theme.sub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(routine.schedule)
                .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                .foregroundStyle(theme.faint)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var otherNameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }
}

// MARK: - One routine row with themed toggle

private struct RoutineRow: View {
    let routine: Routine
    let theme: ThemePack
    let copy: CopyPack
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name)
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                Text(verbatim: "\(routine.schedule) · \(copy.next) \(routine.next)")
                    .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                    .foregroundStyle(theme.sub)
                Text(routine.last)
                    .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(routine.isOn ? theme.ok : theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ThemedToggle(isOn: routine.isOn, theme: theme, action: toggle)
        }
        .modifier(RoutineRowChrome(theme: theme))
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(14, weight: .bold)
        case .ink: theme.body(17.5, weight: .bold)
        }
    }
}

/// Row chrome per rowStyle: soft = floating card, control = terminal panel,
/// ink = ruled ledger line.
private struct RoutineRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

/// The design's 46×27 custom switch (trackOn/trackOff/knobCss tokens).
private struct ThemedToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let action: () -> Void

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
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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
        switch theme.id {
        case .soft: .clear
        case .control: theme.lineStrong
        case .ink: theme.lineStrong
        }
    }

    private var knobFill: Color {
        switch theme.id {
        case .soft: theme.panel
        case .control: theme.ink
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.35)
        }
    }
}

// MARK: - Shared row helpers (file-scoped copies; each screen file keeps its own)

private extension ThemePack {
    var dashColor: Color {
        switch id {
        case .soft: ink.opacity(0.15)
        case .control: accent.opacity(0.25)
        case .ink: lineStrong
        }
    }
}

private func themedBotName(_ id: String, theme: ThemePack) -> String {
    theme.id == .ink ? id.prefix(1).uppercased() + id.dropFirst() : "@" + id
}

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.38).delay(delay)) { shown = true }
            }
    }
}

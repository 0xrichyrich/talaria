import SwiftUI
import TalariaKit
import TalariaTheme

// The search palette — scrim + input over everything, opened from the
// magnifier on the roster. Empty query shows "Live now" (working bots) plus
// the actions; a query filters bots, sessions across all bots, artifacts, and
// actions. Every row routes on tap and dismisses the palette.
// Ported from Talaria.dc.html `sc-if searchOpen`.

/// Palette actions the palette cannot route through `AppModel` alone; the
/// host wires these to its create-bot sheet / connections push.
public enum SearchPaletteAction: Sendable {
    case newBot
    case addGateway
}

public struct SearchPalette: View {
    private let model: AppModel
    @Binding private var isPresented: Bool
    private let onAction: ((SearchPaletteAction) -> Void)?

    @State private var query = ""
    @FocusState private var focused: Bool

    public init(model: AppModel, isPresented: Binding<Bool>,
                onAction: ((SearchPaletteAction) -> Void)? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.onAction = onAction
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    // MARK: Result sets (mirrors the prototype's sr* pipelines)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func matches(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.lowercased().contains(trimmedQuery)
    }

    private var resultBots: [Bot] {
        if trimmedQuery.isEmpty { return model.workingBots }
        return model.bots.filter { matches($0.id) || matches($0.job) || matches($0.preview) }
    }

    private var resultSessions: [(botID: String, session: SessionSummary)] {
        guard !trimmedQuery.isEmpty else { return [] }
        return model.sessions
            .filter { $0.key != "default" }
            .sorted { $0.key < $1.key }
            .flatMap { botID, list in
                list.filter { matches($0.title) }.map { (botID, $0) }
            }
    }

    private var resultArtifacts: [Artifact] {
        guard !trimmedQuery.isEmpty else { return [] }
        return model.artifacts.filter { matches($0.title) || matches($0.meta) }
    }

    // The prototype keeps these four action names identical across all three
    // theme voices (they are not CopyPack keys).
    private var resultActions: [(label: String, run: () -> Void)] {
        let all: [(String, () -> Void)] = [
            ("New bot", { onAction?(.newBot) }),
            ("Add gateway", { onAction?(.addGateway) }),
            ("Approvals", { model.selectedTab = .approvals }),
            ("Cycle theme", { model.theme.cycle() }),
        ]
        return all.filter { trimmedQuery.isEmpty || $0.0.lowercased().contains(trimmedQuery) }
    }

    private var sectionHead: String {
        trimmedQuery.isEmpty ? "Live now · Actions" : "Results"
    }

    // MARK: Body

    public var body: some View {
        ZStack(alignment: .top) {
            // Scrim
            theme.scrimColor
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 10) {
                inputRow
                results
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .transition(.opacity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(copy.searchPh, text: $query)
                .font(inputFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .textFieldStyle(.plain)
                .padding(.horizontal, 15)
                .frame(height: 44)
                .background(theme.panel)
                .clipShape(inputShape)
                .overlay(inputShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

            Button(action: close) {
                Text(verbatim: "✕")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(iconShape)
                    .overlay(iconShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 22), style: .continuous)
    }

    private var iconShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 19 : 38 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var inputFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5)
        case .control: theme.mono(13)
        case .ink: theme.body(15)
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(sectionHead)
                    .font(theme.mono(theme.id == .soft ? 10 : 9.5, weight: .bold))
                    .tracking(theme.id == .soft ? 1 : 1.8)
                    .foregroundStyle(theme.accentFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.accent)

                ForEach(resultBots) { bot in
                    botRow(bot)
                }
                ForEach(resultSessions, id: \.session.id) { hit in
                    metaRow(title: hit.session.title,
                            trail: "\(themedBotName(hit.botID, theme: theme)) · \(hit.session.when)") {
                        openBot(hit.botID)
                    }
                }
                ForEach(resultArtifacts) { artifact in
                    metaRow(title: artifact.title,
                            trail: "\(themedBotName(artifact.botID, theme: theme)) · \(artifact.when)") {
                        openBot(artifact.botID)
                    }
                }

                WrapLayout(spacing: 7) {
                    ForEach(Array(resultActions.enumerated()), id: \.offset) { _, action in
                        actionChip(action.label) {
                            close()
                            action.run()
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Rows

    private func botRow(_ bot: Bot) -> some View {
        Button { openBot(bot.id) } label: {
            HStack(spacing: 10) {
                AvatarView(bot: bot, size: 26, theme: theme)
                Text(themedBotName(bot.id, theme: theme))
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                Text(liveLine(for: bot))
                    .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .modifier(PaletteCard(theme: theme))
    }

    private func metaRow(title: String, trail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(theme.body(theme.id == .ink ? 15.5 : 13.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trail)
                    .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .modifier(PaletteCard(theme: theme))
    }

    private func actionChip(_ label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(chipLabel(label))
                .font(chipFont)
                .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background((theme.id == .ink ? theme.ink : theme.accent).opacity(theme.id == .ink ? 0.03 : 0.06))
                .clipShape(chipShape)
                .overlay(chipShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.accent.opacity(theme.id == .soft ? 0.35 : 0.3),
                    lineWidth: theme.id == .soft ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ label: String) -> String {
        theme.id == .control ? label.uppercased() : label
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 22 : (theme.id == .control ? 6 : 0),
                         style: .continuous)
    }

    private var chipFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    /// Roster-style status line: task + elapsed while working, else preview.
    private func liveLine(for bot: Bot) -> String {
        guard bot.status == .working, let task = bot.task else { return bot.preview }
        switch theme.id {
        case .soft: return "\(task) · \(bot.minutesElapsed)m"
        case .control: return "▸ \(task) · \(String(format: "%02d", bot.minutesElapsed))m"
        case .ink: return "\(task) — \(bot.minutesElapsed) minutes gone"
        }
    }

    // MARK: Routing

    private func close() {
        query = ""
        isPresented = false
    }

    private func openBot(_ id: String) {
        close()
        model.selectedTab = .home
        model.openBotID = id
    }
}

// MARK: - Result card chrome

private struct PaletteCard: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        content
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .shadow(color: theme.rowStyle == .card ? theme.ink.opacity(0.04) : .clear,
                    radius: 2, y: 1)
    }
}

// MARK: - Wrapping chip layout

private struct WrapLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Shared helpers (file-scoped copies; each screen file keeps its own)

private extension ThemePack {
    /// The design's `scrim` token, derived from pack colors.
    var scrimColor: Color {
        id == .control ? Color.black.opacity(0.62) : ink.opacity(0.4)
    }
}

private func themedBotName(_ id: String, theme: ThemePack) -> String {
    theme.id == .ink ? id.prefix(1).uppercased() + id.dropFirst() : "@" + id
}

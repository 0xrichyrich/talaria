import SwiftUI
import TalariaKit
import TalariaTheme

// Bot Profile sheet — design-map.md §4 "Bot Profile" (prototype screen `detail`).
//
// Large avatar + description, stat cards (sessions / memories / skills),
// recent sessions, the context-window meter, the per-bot YOLO toggle, model
// pin chips, the animated memory "star map", Duplicate / Edit actions and the
// CLI-only deletion footnote. Demo mode mutates AppModel directly; live mode
// additionally drives config.set (yolo), profiles.configure (model pin) and
// profiles.create clone_from (duplicate).

@MainActor
public struct BotSheetView: View {
    private let model: AppModel
    private let botID: String

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
    }

    public init(model: AppModel, bot: Bot) {
        self.init(model: model, botID: bot.id)
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var style: DetailStyle { DetailStyle(t: theme) }

    private var bot: Bot {
        model.bot(botID) ?? Bot(id: botID, job: "", shape: .circle, hue: .teal)
    }

    /// Ink names its familiars ("Researcher"); the others use handles ("@researcher").
    private var displayName: String {
        theme.id == .ink ? botID.prefix(1).uppercased() + botID.dropFirst() : "@" + botID
    }

    private var sessions: [SessionSummary] {
        model.sessions[botID] ?? model.sessions["default"] ?? []
    }

    private var memory: BotMemory {
        model.memory[botID] ?? model.memory["default"]
            ?? BotMemory(skillCount: 0, memoryCount: 0, recent: [])
    }

    private var yoloOn: Bool { model.chats[botID]?.yolo ?? false }

    private var contextTotal: Int {
        min(100, model.contextMeter.reduce(0) { $0 + $1.percent })
    }

    // Star map: positions/sizes/delays ported from the prototype's `stars`.
    private static let stars: [(x: CGFloat, y: CGFloat)] = [
        (0.16, 0.26), (0.34, 0.12), (0.55, 0.20), (0.78, 0.30),
        (0.86, 0.62), (0.64, 0.74), (0.38, 0.64), (0.22, 0.48),
    ]

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    identityRow
                    statCards
                    sectionLabel(copy.sessionsSec)
                    sessionsGroup
                    sectionLabel("\(copy.contextSec) · \(contextTotal)%")
                    contextCard
                    yoloCard
                    sectionLabel(copy.modelSec)
                    modelChips
                    sectionLabel(copy.memorySec)
                    memoryCard
                    actionRow(copy.duplicate) { duplicateBot() }
                    actionRow(copy.editLook) { showEditor = true }
                    Text(copy.deleteNote)
                        .font(style.footNoteFont)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .sheet(isPresented: $showEditor) {
            CreateBotView(model: model, editing: model.bot(botID))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(style.backFg)
                    .frame(width: 31, height: 31)
                    .background(iconButtonChrome)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(displayName)
                .font(style.subTitleFont)
                .foregroundStyle(theme.ink)

            Spacer(minLength: 8)

            Text(theme.id == .soft ? bot.job : bot.job.uppercased())
                .font(style.jobFont)
                .tracking(style.jobTracking)
                .foregroundStyle(theme.faint)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var iconButtonChrome: some View {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : theme.iconCornerFraction * 44
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme.id == .ink {
            shape.stroke(theme.lineStrong, lineWidth: 1)
        } else {
            shape.fill(theme.panel).overlay(shape.stroke(theme.line, lineWidth: 1))
        }
    }

    // MARK: - Identity + stats

    private var identityRow: some View {
        HStack(spacing: 13) {
            AvatarView(shape: bot.shape, hue: bot.hue, size: 58,
                       isWorking: bot.status == .working, theme: theme)
            // Fallback copy ported from the prototype (not part of CopyPack).
            Text(bot.description ?? "A fresh profile. Its story is unwritten.")
                .font(style.aSubPlainFont)
                .foregroundStyle(theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statCards: some View {
        HStack(spacing: 8) {
            statCard(String(sessions.count), "sessions")
            statCard(String(memory.memoryCount), "memories")
            statCard(String(memory.skillCount), "skills")
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(style.apTitleFont)
                .foregroundStyle(theme.ink)
            Text(label)
                .font(style.timeFont)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .modifier(DetailCardChrome(theme: theme))
    }

    // MARK: - Recent sessions

    private var sessionsGroup: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                Button {
                    openSession(session)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(style.aTextFont)
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            Text("\(session.when) · \(session.messageCount) msgs")
                                .font(style.timeFont)
                                .foregroundStyle(theme.faint)
                        }
                        Spacer(minLength: 8)
                        Text("›")
                            .font(style.timeFont)
                            .foregroundStyle(theme.faint)
                    }
                    .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if theme.rowStyle == .ledger || session.id != sessions.last?.id {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
        .modifier(DetailGroupChrome(theme: theme))
    }

    private func openSession(_ session: SessionSummary) {
        model.openBotID = botID
        model.selectedTab = .home
        dismiss()
    }

    // MARK: - Context window

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(model.contextMeter.enumerated()), id: \.element.id) { index, segment in
                        Rectangle()
                            .fill(segmentColor(index))
                            .frame(width: geo.size.width * CGFloat(segment.percent) / 100)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(theme.line)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            ForEach(Array(model.contextMeter.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: 7) {
                    Circle()
                        .fill(segmentColor(index))
                        .frame(width: 7, height: 7)
                    Text(segment.label)
                        .font(style.aSubFont)
                        .foregroundStyle(theme.sub)
                    Spacer(minLength: 8)
                    Text("\(segment.percent)%")
                        .font(style.timeFont)
                        .foregroundStyle(theme.faint)
                }
                .padding(.top, 7)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
        .modifier(DetailCardChrome(theme: theme))
    }

    /// Meter segments cycle through the avatar palette, same order everywhere.
    private func segmentColor(_ index: Int) -> Color {
        let hues: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]
        return theme.color(for: hues[index % hues.count])
    }

    // MARK: - YOLO

    private var yoloCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.yoloName)
                    .font(style.prefNameFont)
                    .foregroundStyle(yoloOn ? theme.warn : theme.faint)
                Text(copy.yoloSub)
                    .font(style.aSubFont)
                    .foregroundStyle(theme.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DetailToggle(isOn: yoloOn, theme: theme) {
                setYolo(!yoloOn)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .modifier(DetailCardChrome(theme: theme))
    }

    private func setYolo(_ enabled: Bool) {
        let chat = model.chat(for: botID)
        chat.yolo = enabled
        if case .live = model.mode, let client = model.client, let sid = chat.sessionID {
            Task { try? await client.setYolo(sessionID: sid, enabled: enabled) }
        }
    }

    // MARK: - Model pin

    private var modelChips: some View {
        DetailChipFlow(spacing: 7) {
            ForEach(model.models, id: \.self) { name in
                DetailChip(text: name,
                           selected: (bot.pinnedModel ?? model.models.first) == name,
                           theme: theme) {
                    pinModel(name)
                }
            }
        }
    }

    private func pinModel(_ modelName: String) {
        guard let index = model.bots.firstIndex(where: { $0.id == botID }) else { return }
        model.bots[index].pinnedModel = modelName
        if case .live = model.mode, let client = model.client {
            Task { try? await client.configureProfile(name: botID, model: modelName) }
        }
    }

    // MARK: - Memory (star map)

    private var memoryCard: some View {
        VStack(spacing: 0) {
            starMap
                .frame(height: 96)
            Rectangle().fill(theme.line).frame(height: 1)
            ForEach(Array(memory.recent.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(style.aSubPlainFont)
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
                if index < memory.recent.count - 1 {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
        .modifier(DetailCardChrome(theme: theme))
    }

    private var starMap: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                constellationLine(geo, x: 0.18, y: 0.30, width: 0.44, degrees: 9)
                constellationLine(geo, x: 0.56, y: 0.24, width: 0.32, degrees: 38)
                constellationLine(geo, x: 0.24, y: 0.52, width: 0.38, degrees: -14)
                ForEach(Array(Self.stars.enumerated()), id: \.offset) { index, star in
                    TwinkleStar(color: theme.color(for: bot.hue),
                                size: index.isMultiple(of: 3) ? 5 : 3.5,
                                delay: Double(index) * 0.4)
                        .position(x: geo.size.width * star.x, y: geo.size.height * star.y)
                }
            }
        }
        .background(theme.inset)
    }

    private func constellationLine(_ geo: GeometryProxy, x: CGFloat, y: CGFloat,
                                   width: CGFloat, degrees: Double) -> some View {
        Rectangle()
            .fill(theme.line)
            .frame(width: geo.size.width * width, height: 1)
            .rotationEffect(.degrees(degrees), anchor: .leading)
            .offset(x: geo.size.width * x, y: geo.size.height * y)
    }

    // MARK: - Actions

    private func actionRow(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(style.aTextFont)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DetailCardChrome(theme: theme))
    }

    /// Desktop "Duplicate" semantics: clone config, skills and memory into a
    /// sibling profile named `<id>-2` (first free suffix).
    private func duplicateBot() {
        guard let source = model.bot(botID) else { return }
        let newID = cloneID(for: source.id)
        // Preview copy ported from the prototype (not part of CopyPack).
        let clone = Bot(id: newID, job: source.job, shape: source.shape, hue: source.hue,
                        status: .idle, preview: "Cloned — config, skills, memory copied.",
                        previewTime: "new", unread: 0, description: source.description,
                        pinnedModel: source.pinnedModel)
        model.bots.append(clone)
        if case .live = model.mode, let client = model.client {
            Task { try? await client.createProfile(name: newID, cloneFrom: source.id) }
        }
        model.openBotID = nil
        model.selectedTab = .home
        dismiss()
    }

    private func cloneID(for base: String) -> String {
        var suffix = 2
        while model.bots.contains(where: { $0.id == "\(base)-\(suffix)" }) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: - Section labels

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(style.secLabelFont)
            .tracking(style.secLabelTracking)
            .foregroundStyle(theme.faint)
            .padding(.top, 2)
    }
}

// MARK: - Per-theme styles (ported from the prototype's detail-screen CSS)

fileprivate struct DetailStyle {
    let t: ThemePack

    var backFg: Color { t.id == .ink ? t.ink : t.accent }

    var subTitleFont: Font {
        switch t.id {
        case .soft: t.body(20, weight: .heavy)
        case .control: t.body(18, weight: .heavy)
        case .ink: t.display(22, weight: .bold).smallCaps()
        }
    }

    var jobFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .semibold)
        case .control: t.mono(9, weight: .semibold)
        case .ink: t.mono(8.5)
        }
    }

    var jobTracking: CGFloat { t.id == .soft ? 0 : 1.4 }

    var secLabelFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .heavy)
        case .control: t.mono(9, weight: .bold)
        case .ink: t.mono(8.5)
        }
    }

    var secLabelTracking: CGFloat { t.id == .soft ? 1 : 2 }

    var timeFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .medium)
        case .control: t.mono(10)
        case .ink: t.mono(9)
        }
    }

    var aTextFont: Font {
        switch t.id {
        case .soft: t.body(13.5, weight: .semibold)
        case .control: t.body(13, weight: .semibold)
        case .ink: t.body(15.5, weight: .semibold)
        }
    }

    var aSubFont: Font {
        switch t.id {
        case .soft: t.body(12)
        case .control: t.mono(10)
        case .ink: t.body(13).italic()
        }
    }

    var aSubPlainFont: Font {
        switch t.id {
        case .soft: t.body(13)
        case .control: t.body(12.5)
        case .ink: t.body(14.5)
        }
    }

    var apTitleFont: Font {
        switch t.id {
        case .soft: t.body(14.5, weight: .bold)
        case .control: t.body(14, weight: .bold)
        case .ink: t.body(17, weight: .bold)
        }
    }

    var prefNameFont: Font {
        switch t.id {
        case .soft: t.body(14, weight: .semibold)
        case .control: t.body(13.5, weight: .semibold)
        case .ink: t.body(16, weight: .semibold)
        }
    }

    var footNoteFont: Font {
        switch t.id {
        case .soft: t.body(11.5)
        case .control: t.mono(9.5)
        case .ink: t.body(13).italic()
        }
    }
}

// MARK: - Chrome

fileprivate struct DetailCardChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        content
            .background(shape.fill(theme.panel))
            .clipShape(shape)
            .overlay(shape.stroke(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 1.5, y: 1)
    }
}

fileprivate struct DetailGroupChrome: ViewModifier {
    let theme: ThemePack

    @ViewBuilder func body(content: Content) -> some View {
        if theme.rowStyle == .ledger {
            content // Ink: bare ruled ledger, no card chrome.
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
            content
                .background(shape.fill(theme.panel))
                .clipShape(shape)
                .overlay(shape.stroke(theme.line, lineWidth: 1))
                .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 1.5, y: 1)
        }
    }
}

// MARK: - Themed toggle (46×27, knob 21, per-theme track/knob)

fileprivate struct DetailToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.stroke(trackStroke, lineWidth: 1))
                knob
                    .frame(width: 21, height: 21)
                    .offset(x: isOn ? 22.5 : 2.5, y: 3)
            }
            .frame(width: 46, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackStroke: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.lineStrong
        case .ink: theme.ink.opacity(0.5)
        }
    }

    @ViewBuilder private var knob: some View {
        switch theme.id {
        case .soft:
            Circle().fill(theme.panel)
                .shadow(color: theme.ink.opacity(0.2), radius: 1.5, y: 1)
        case .control:
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.ink)
        case .ink:
            Circle().fill(isOn ? theme.ink : theme.ink.opacity(0.35))
        }
    }
}

// MARK: - Selectable chip (prototype `chipSel`)
// Internal: shared with CreateBotView's Advanced section, which renders the
// same chip language.

struct DetailChip: View {
    let text: String
    let selected: Bool
    var struck: Bool = false
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font)
                .strikethrough(struck)
                .foregroundStyle(foreground)
                .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                .background(shape.fill(background))
                .overlay(shape.stroke(border, lineWidth: theme.id == .soft ? 1.5 : 1))
                .opacity(struck ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        let radius: CGFloat = switch theme.id {
        case .soft: 999
        case .control: 5
        case .ink: 0
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9.5)
        }
    }

    private var foreground: Color {
        if selected {
            return theme.id == .ink ? theme.bg : theme.accent
        }
        return theme.sub
    }

    private var background: Color {
        guard selected else { return .clear }
        switch theme.id {
        case .soft: return theme.accent.opacity(0.07)
        case .control: return theme.accent.opacity(0.06)
        case .ink: return theme.ink
        }
    }

    private var border: Color {
        if selected {
            switch theme.id {
            case .soft: return theme.accent
            case .control: return theme.accent.opacity(0.5)
            case .ink: return theme.ink
            }
        }
        switch theme.id {
        case .soft: return theme.ink.opacity(0.12)
        case .control: return theme.line
        case .ink: return theme.ink.opacity(0.3)
        }
    }
}

// MARK: - Flow layout for wrapping chip rows (shared with CreateBotView)

struct DetailChipFlow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
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
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Twinkling star (prototype `glowU` 2.8s, staggered)

fileprivate struct TwinkleStar: View {
    let color: Color
    let size: CGFloat
    let delay: Double

    @State private var lit = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(lit ? 1 : 0.45)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(delay),
                       value: lit)
            .onAppear { lit = true }
    }
}

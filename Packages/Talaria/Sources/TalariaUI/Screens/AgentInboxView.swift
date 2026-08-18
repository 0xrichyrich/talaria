import SwiftUI
import TalariaKit
import TalariaTheme

// Agent Inbox — Agent Inbox / Comms / The Parley. The cross-bot traffic feed:
// each row is a from-avatar, "from → to" names (copy.a2aSep — "unto" in ink;
// "all" renders as a broadcast), the message body (italic and quoted in ink),
// and a footer attribution note. Ported from Talaria.dc.html
// `data-screen-label="Agent Inbox"`.
//
// Live source (AppModelLive+Feeds.swift): handoffs upstream are per-invocation
// —`hermes -p <bot> chat -c "Agent Inbox" -q "Message from 🤖 …"` — so there is
// no inbox object to fetch. The feed is each profile's own "Agent Inbox"
// session, read over the transcript REST and split back into from → to rows by
// that attribution prefix. Compose does the same thing from the phone:
// resume-or-create the target bot's Agent Inbox session and prompt.submit an
// attributed message into it.

public struct AgentInboxView: View {
    private let model: AppModel

    @State private var showCompose = false

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var feeds: FeedsRuntime { FeedsRuntime.shared }

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
                    ForEach(Array(model.agentInbox.enumerated()), id: \.element.id) { index, message in
                        A2ARow(message: message,
                               fromBot: model.bot(message.fromBotID),
                               toBot: model.bot(message.toBotID),
                               theme: theme, copy: copy) {
                            model.openInboxMessage(message)
                        }
                        .modifier(RowEntrance(delay: Double(min(index, 12)) * 0.055))
                    }

                    if model.agentInbox.isEmpty { emptyState }
                    if model.mode == .live { composeRow }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            model.attachActivityRouter()
            await model.refreshAgentInbox()
        }
        .sheet(isPresented: $showCompose) {
            HandoffSheet(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if theme.showsKicker {
                        Text(copy.kickerA2A)
                            .font(theme.mono(theme.id == .ink ? 9 : 9.5, weight: .semibold))
                            .tracking(theme.id == .control ? 2.5 : 2)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                            .padding(.bottom, theme.id == .control ? 3 : 1)
                    }
                    Text(copy.titleA2A)
                        .font(titleFont)
                        .tracking(theme.smallCapsTitles ? 0.5 : -0.5)
                        .foregroundStyle(theme.ink)
                }
                Spacer(minLength: 6)
                if model.mode == .live {
                    HeaderIconButton(theme: theme, size: 32) {
                        Task { await model.refreshAgentInbox(force: true) }
                    } glyph: {
                        Text(verbatim: "↻")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                            .opacity(feeds.inboxScanning ? 0.4 : 1)
                    }
                    .disabled(feeds.inboxScanning)
                }
            }
            Text(copy.a2aLead)
                .font(theme.body(theme.id == .ink ? 14 : 12.5))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.display(31)
        case .control: theme.display(27)
        case .ink: theme.display(28).smallCaps()
        }
    }

    // MARK: Compose + empty state

    private var composeRow: some View {
        Button {
            showCompose = true
        } label: {
            Text(copy.composeHandoff(theme.id))
                .font(composeFont)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
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
        .buttonStyle(.plain)
        .padding(.top, 8)
        .disabled(model.bots.count < 2)
    }

    private var composeFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(feeds.inboxScanning ? copy.scanningLabel(theme.id) : copy.inboxEmptyTitle(theme.id))
                .font(theme.id == .control ? theme.mono(12, weight: .bold)
                                           : theme.body(15, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(copy.inboxEmptyBody(theme.id))
                .font(footFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.faint)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
    }

    // MARK: Footer

    /// The attribution note — handoffs are real cross-profile messages — plus
    /// the live provenance line once a sweep has run.
    private var footer: some View {
        VStack(spacing: 4) {
            Text(copy.a2aFoot)
                .font(footFont)
                .tracking(theme.id == .soft ? 0 : (theme.id == .ink ? 2 : 1))
                .textCase(theme.id == .ink ? .uppercase : nil)
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
            if model.mode == .live, !feeds.inboxNote.isEmpty {
                Text(feeds.inboxNote)
                    .font(footFont)
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.mono(8.5)
        }
    }
}

// MARK: - Row

private struct A2ARow: View {
    let message: A2AMessage
    let fromBot: Bot?
    let toBot: Bot?
    let theme: ThemePack
    let copy: CopyPack
    let open: () -> Void

    private var isBroadcast: Bool { message.toBotID == "all" }

    private var fromColor: Color { theme.color(for: fromBot?.hue ?? .teal) }

    /// Broadcasts render muted; direct messages take the recipient's hue.
    private var toColor: Color {
        isBroadcast ? theme.sub : theme.color(for: toBot?.hue ?? .teal)
    }

    /// "all bots" / "ALL" / "All" for broadcasts, else the themed bot name.
    private var toName: String {
        guard isBroadcast else {
            return TalariaVoice.displayName(toBot, id: message.toBotID, theme.id)
        }
        switch theme.id {
        case .soft: return "all bots"
        case .control: return "ALL"
        case .ink: return "All"
        }
    }

    /// Ink wraps the parley in quotation marks.
    private var bodyText: String {
        theme.id == .ink ? "“\(message.text)”" : message.text
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(shape: fromBot?.shape ?? .circle,
                           hue: fromBot?.hue ?? .teal,
                           size: 26, theme: theme)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TalariaVoice.displayName(fromBot, id: message.fromBotID, theme.id))
                            .font(nameFont)
                            .foregroundStyle(fromColor)
                            .lineLimit(1)
                        Text(copy.a2aSep)
                            .font(sepFont)
                            .italic(theme.id == .ink)
                            .foregroundStyle(sepColor)
                            .lineLimit(1)
                        Text(toName)
                            .font(nameFont)
                            .foregroundStyle(toColor)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(message.time)
                            .font(timeFont)
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                    Text(bodyText)
                        .font(bodyFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(bodyColor)
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(A2ARowChrome(theme: theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    private var sepFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10.5)
        case .ink: theme.body(13)
        }
    }

    private var sepColor: Color {
        theme.id == .ink ? theme.faint : theme.ink.opacity(theme.id == .control ? 0.3 : 0.35)
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    private var bodyFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5)
        case .control: theme.body(13)
        case .ink: theme.body(15.5)
        }
    }

    private var bodyColor: Color {
        theme.id == .ink ? theme.ink.opacity(0.85) : theme.ink.opacity(0.92)
    }
}

// MARK: - Handoff composer

/// From-bot → to-bot → message. The send resumes (or creates) the target's own
/// "Agent Inbox" session and submits the message with the sender attribution
/// the roster convention expects, so the target reads it exactly like a CLI
/// handoff.
private struct HandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    @State private var from: String = ""
    @State private var to: String = ""
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var canSend: Bool {
        !from.isEmpty && !to.isEmpty && from != to
            && !text.trimmingCharacters(in: .whitespaces).isEmpty && !sending
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    picker(copy.handoffFrom(theme.id), selection: $from, exclude: to)
                    picker(copy.handoffTo(theme.id), selection: $to, exclude: from)
                    TextField(copy.handoffPlaceholder(theme.id), text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(4...12)
                        .font(fieldFont)
                        .foregroundStyle(theme.ink)
                        .tint(theme.accent)
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        .background(theme.id == .ink ? Color.clear : theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous)
                            .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
                    if let error {
                        Text(error)
                            .font(footFont)
                            .foregroundStyle(theme.danger)
                    }
                    Text(copy.a2aFoot)
                        .font(footFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .onAppear {
            if from.isEmpty { from = model.openBotID ?? model.bots.first?.id ?? "" }
            if to.isEmpty { to = model.bots.first(where: { $0.id != from })?.id ?? "" }
        }
    }

    private var header: some View {
        HStack {
            Button(copy.cancel) { dismiss() }
                .buttonStyle(.plain)
                .font(headerButtonFont)
                .foregroundStyle(theme.id == .soft ? theme.accent : theme.sub)
            Spacer()
            Text(copy.composeHandoff(theme.id))
                .font(titleFont)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Button(copy.send(theme.id)) { send() }
                .buttonStyle(.plain)
                .font(headerButtonFont)
                .foregroundStyle(canSend ? theme.accent : theme.faint)
                .disabled(!canSend)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private func picker(_ label: String, selection: Binding<String>, exclude: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(theme.id == .control ? theme.mono(9.5, weight: .bold) : theme.body(11, weight: .bold))
                .tracking(theme.id == .soft ? 0.5 : 1.5)
                .textCase(theme.id == .ink ? nil : .uppercase)
                .foregroundStyle(theme.faint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.bots.filter { $0.id != exclude }) { bot in
                        Button {
                            selection.wrappedValue = bot.id
                        } label: {
                            HStack(spacing: 6) {
                                AvatarView(shape: bot.shape, hue: bot.hue, size: 16, theme: theme)
                                Text(TalariaVoice.displayName(for: bot, theme.id))
                                    .font(theme.id == .control ? theme.mono(10.5, weight: .semibold)
                                                               : theme.body(12.5, weight: .semibold))
                                    .foregroundStyle(selection.wrappedValue == bot.id
                                                     ? theme.color(for: bot.hue) : theme.sub)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .chipShell(theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func send() {
        sending = true
        error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await model.sendHandoff(from: from, to: to, text: text)
                dismiss()
            } catch {
                self.error = (error as? GatewayError)?.message ?? error.localizedDescription
            }
        }
    }

    private var fieldRadius: CGFloat { theme.inputRadius > 100 ? 14 : theme.inputRadius }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(17, weight: .heavy)
        case .control: theme.mono(13, weight: .bold)
        case .ink: theme.display(20, weight: .bold).smallCaps()
        }
    }

    private var headerButtonFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.mono(11, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var fieldFont: Font {
        switch theme.id {
        case .soft: theme.body(14)
        case .control: theme.mono(12)
        case .ink: theme.body(15.5)
        }
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

// MARK: - Row chrome (file-scoped copy; each screen file keeps its own)

/// Row chrome per rowStyle: soft = floating card, control = terminal panel,
/// ink = ruled ledger line.
private struct A2ARowChrome: ViewModifier {
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

private extension ThemePack {
    var dashColor: Color {
        switch id {
        case .soft: ink.opacity(0.15)
        case .control: accent.opacity(0.25)
        case .ink: lineStrong
        }
    }
}

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.42).delay(delay)) { shown = true }
            }
    }
}

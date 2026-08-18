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
// no inbox object to fetch. The feed is each profile's own Bot Chat, read over
// the transcript REST and split back into from → to rows by that attribution
// prefix. `AppModelLive+A2A.swift` keeps it LIVE (the gateway's
// `sessions.changed` fires on any state.db write, including the ones the CLI
// and cron make) and owns the compose path: resolve @handles against the
// roster, deliver into each recipient's canonical Bot Chat, and relay the
// reply back into this feed, attributed.

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
                               fromBot: model.bot(model.resolvedBotID(message.fromBotID)),
                               toBot: model.bot(message.toBotID),
                               delivery: model.delivery(for: message),
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
            // Sweeps now, then follows sessions.changed with a slow poll behind
            // it. Paired with endInboxLive so a screen nobody is looking at
            // stops costing radio.
            model.beginInboxLive()
        }
        .onDisappear { model.endInboxLive() }
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
                        model.sweepInbox(after: 0)
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
    let delivery: A2ADelivery?
    let theme: ThemePack
    let copy: CopyPack
    let open: () -> Void

    /// Progressive disclosure, ported from desktop's group transcript
    /// (plugin.js:7316-7332): the line stays quiet by default and expands to
    /// carry the @handles on demand. Desktop hovers; touch taps the names.
    @State private var revealed = false

    private var isBroadcast: Bool { message.toBotID == "all" }

    private var fromColor: Color { theme.color(for: fromBot?.hue ?? .teal) }

    /// Broadcasts render muted; direct messages take the recipient's hue.
    private var toColor: Color {
        isBroadcast ? theme.sub : theme.color(for: toBot?.hue ?? .teal)
    }

    /// Only offer the reveal when a handle would actually add something —
    /// desktop's `showsHandle` rule (plugin.js:2721). An untitled bot's name IS
    /// its handle, so tapping it would be a gesture with nothing to say; the
    /// tap falls through to opening the conversation instead.
    private var canReveal: Bool {
        (fromBot?.showsHandle ?? false) || (!isBroadcast && (toBot?.showsHandle ?? false))
    }

    private var fromName: String {
        let name = TalariaVoice.displayName(fromBot, id: message.fromBotID, theme.id)
        guard revealed, let fromBot, fromBot.showsHandle else { return name }
        return "\(name) (@\(fromBot.handle))"
    }

    /// "all bots" / "ALL" / "All" for broadcasts, else the themed bot name.
    private var toName: String {
        guard !isBroadcast else {
            switch theme.id {
            case .soft: return "all bots"
            case .control: return "ALL"
            case .ink: return "All"
            }
        }
        let name = TalariaVoice.displayName(toBot, id: message.toBotID, theme.id)
        guard revealed, let toBot, toBot.showsHandle else { return name }
        return "\(name) (@\(toBot.handle))"
    }

    /// Ink wraps the parley in quotation marks.
    private var bodyText: String {
        theme.id == .ink ? "“\(message.text)”" : message.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(shape: fromBot?.shape ?? .circle,
                       hue: fromBot?.hue ?? .teal,
                       size: 26, theme: theme)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Tapping the names reveals the handles; tapping anywhere
                    // else opens the conversation the message lives in. The
                    // inner gesture wins because SwiftUI delivers a tap to the
                    // innermost view that handles it.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fromName)
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
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard canReveal else { return open() }
                        withAnimation(.easeOut(duration: 0.16)) { revealed.toggle() }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text(canReveal ? copy.a2aRevealHint(theme.id)
                                                      : copy.a2aOpenHint(theme.id)))

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
                if let note = deliveryNote { deliveryLine(note) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(A2ARowChrome(theme: theme))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Delivery state

    /// What became of a handoff this app sent. Honest about the one limit that
    /// matters: a recipient mid-run finishes first (see `submitHandoff`).
    private var deliveryNote: (text: String, tone: Color)? {
        guard let delivery else { return nil }
        switch delivery.state {
        case .waiting:
            return delivery.queuedBehindRun
                ? (copy.a2aQueuedNote(theme.id), theme.warn)
                : (copy.a2aWaitingNote(theme.id), theme.faint)
        case .replied:
            return (copy.a2aRepliedNote(theme.id), theme.ok)
        case .quiet:
            return (copy.a2aQuietNote(theme.id), theme.faint)
        case .failed(let reason):
            return (copy.a2aFailedNote(theme.id, reason: reason), theme.danger)
        }
    }

    private func deliveryLine(_ note: (text: String, tone: Color)) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: theme.id == .control ? "▸" : "·")
                .font(noteFont)
                .foregroundStyle(note.tone)
            Text(note.text)
                .font(noteFont)
                .italic(theme.id == .ink)
                .foregroundStyle(note.tone)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private var noteFont: Font {
        switch theme.id {
        case .soft: theme.body(11)
        case .control: theme.mono(9)
        case .ink: theme.mono(9)
        }
    }

    private var bodyColor: Color {
        theme.id == .ink ? theme.ink.opacity(0.85) : theme.ink.opacity(0.92)
    }
}

// MARK: - Handoff composer

/// Speaker → @mentions → message. The send resolves each @handle against the
/// live roster, opens that bot's canonical Bot Chat and submits the message
/// with the sender attribution the roster convention expects, so the target
/// reads it exactly like a CLI handoff — then watches for the reply.
private struct HandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    @State private var from: String = ""
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var resolution: MentionResolution {
        var resolved = model.resolveMentions(in: text, speaking: from)
        // A handle half-typed is not a mistake yet. While the completion strip
        // is still offering candidates for the token under the caret, that
        // token gets no "no such handle" line — the strip is the answer.
        if let active = BotMention.activeToken(in: text),
           !model.mentionSuggestions(for: active.token, speaking: from).isEmpty {
            resolved.unknown.removeAll { $0 == active.token }
            resolved.ambiguous.removeAll { $0 == active.token }
        }
        return resolved
    }

    /// The message has to say something beyond the handles that route it.
    private var hasBody: Bool {
        var rest = text
        for bot in resolution.bots { rest = BotMention.remove(bot.handle, from: rest) }
        return !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !from.isEmpty && !resolution.bots.isEmpty && hasBody && !sending
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    speakerPicker
                    MentionField(model: model, text: $text, speaking: from,
                                 placeholder: copy.mentionPlaceholder(theme.id))
                    MentionRecipients(model: model, resolution: resolution) { bot in
                        text = BotMention.remove(bot.handle, from: text)
                    }
                    rosterStrip
                    if let error {
                        Text(error)
                            .font(footFont)
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The limit, said plainly and once.
                    Text(copy.a2aLimitNote(theme.id))
                        .font(footFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// Who is speaking. The attribution prefix carries this bot's title and
    /// @handle, so the recipient's messaging protocol knows an agent — not its
    /// human — is talking (plugin.js:2635).
    private var speakerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(copy.handoffFrom(theme.id))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.bots) { bot in
                        Button { select(speaker: bot) } label: {
                            chip(bot, selected: from == bot.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// The mobile way in to a grammar the phone cannot teach by hovering: tap
    /// a bot and its @handle lands in the draft. Same mechanism as typing it —
    /// the mentions in the text are the single source of routing.
    private var rosterStrip: some View {
        let addressable = model.bots.filter { bot in
            bot.id != from && !resolution.bots.contains(where: { $0.id == bot.id })
        }
        return Group {
            if !addressable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    label(copy.mentionRosterLabel(theme.id))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(addressable) { bot in
                                Button {
                                    text = BotMention.append(bot.handle, to: text)
                                } label: {
                                    chip(bot, selected: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    if resolution.bots.isEmpty {
                        Text(copy.mentionNoRecipients(theme.id))
                            .font(footFont)
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.faint)
                    }
                }
            }
        }
    }

    private func chip(_ bot: Bot, selected: Bool) -> some View {
        HStack(spacing: 6) {
            AvatarView(shape: bot.shape, hue: bot.hue, size: 16, theme: theme)
            Text(TalariaVoice.displayName(for: bot, theme.id))
                .font(theme.id == .control ? theme.mono(10.5, weight: .semibold)
                                           : theme.body(12.5, weight: .semibold))
                .foregroundStyle(selected ? theme.color(for: bot.hue) : theme.sub)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .chipShell(theme)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(theme.id == .control ? theme.mono(9.5, weight: .bold) : theme.body(11, weight: .bold))
            .tracking(theme.id == .soft ? 0.5 : 1.5)
            .textCase(theme.id == .ink ? nil : .uppercase)
            .foregroundStyle(theme.faint)
    }

    /// Changing the speaker un-addresses it: a bot never @s itself
    /// (plugin.js:2414), so a handle already in the draft has to come out.
    private func select(speaker bot: Bot) {
        from = bot.id
        text = BotMention.remove(bot.handle, from: text)
    }

    private func send() {
        let recipients = resolution.bots.map(\.id)
        sending = true
        error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await model.deliverHandoff(from: from, to: recipients, text: text)
                dismiss()
            } catch {
                self.error = (error as? GatewayError)?.message ?? error.localizedDescription
            }
        }
    }

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

extension CopyPack {
    func a2aRevealHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Show handles"
        case .control: "SHOW HANDLES"
        case .ink: "show their true names"
        }
    }

    func a2aOpenHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open the conversation"
        case .control: "OPEN SESSION"
        case .ink: "open the audience"
        }
    }
}

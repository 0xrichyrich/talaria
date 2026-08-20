import SwiftUI
import TalariaKit
import TalariaTheme

// Per-bot chat, pushed from the roster. Header with back / avatar / themed
// state line / routines button (header tap opens the bot sheet); the message
// list (sys rows, bot bubbles with block markdown, tool chips, papers-digest
// and inline-approval cards, user bubbles with offline queued notes, typing
// dots); quick replies; the model/context/YOLO strip; and the composer with
// mic → voice, attachments, slash commands, and a send button that becomes a
// stop control while a turn runs.
// Ported from Talaria.dc.html `data-screen-label="Chat"`.
//
// The inline approval card is wired to the same state as the Approvals tab:
// pending == the ref is still in model.approvals; deciding here removes it
// there (and vice versa), with the outcome word remembered in ApprovalOutcomes.

// MARK: - Approval outcome ledger

/// AppModel removes an approval on resolve, but decided cards keep rendering
/// with their themed done-word ("Approved — sent" / "RELEASED — RAN CLEAN" /
/// "sealed — done cleanly"). This ledger keeps the card data + outcome for
/// every approval this process has seen, shared by the inline chat card and
/// the push banner.
@MainActor
@Observable
public final class ApprovalOutcomes {
    public static let shared = ApprovalOutcomes()

    public private(set) var snapshots: [String: Approval] = [:]
    public private(set) var outcomes: [String: Bool] = [:]

    public init() {}

    /// Cache the card data while the approval is still pending.
    public func remember(_ approval: Approval) {
        if snapshots[approval.id] == nil { snapshots[approval.id] = approval }
    }

    /// Record a decision made anywhere in the app.
    public func record(_ approval: Approval, approved: Bool) {
        snapshots[approval.id] = approval
        outcomes[approval.id] = approved
    }

    /// A response that did not reach its owning gateway is not an outcome.
    /// Reopen the card so the user can retry and a pending sweep can merge it.
    func reopen(_ approvalID: String) {
        outcomes.removeValue(forKey: approvalID)
        ApprovalBridges.shared.decided.removeValue(forKey: approvalID)
    }

    /// Record + resolve in one step — the path every approve/deny control
    /// in this module should take.
    public func resolve(_ approval: Approval, approve: Bool, in model: AppModel) {
        record(approval, approved: approve)
        model.resolveApproval(approval, approve: approve)
    }
}

// MARK: - ChatView

public struct ChatView: View {
    private let model: AppModel
    private let botID: String
    private let onOpenProfile: () -> Void
    private let onRoutines: () -> Void
    private let onVoice: () -> Void

    @State private var draft = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @ScaledMetric(relativeTo: .body) private var softComposerSize = 14.5
    @ScaledMetric(relativeTo: .body) private var controlComposerSize = 13
    @ScaledMetric(relativeTo: .body) private var inkComposerSize = 15
    @State private var showModelSheet = false
    @State private var showCommands = false
    @State private var transcriptAnchoredBotID: String?
    @FocusState private var composerFocused: Bool

    /// Tapback set, matching desktop's reaction picker.
    private static let reactionEmojis = ["👍", "❤️", "🎉", "🙏", "🤔", "👎"]

    public init(model: AppModel, botID: String,
                onOpenProfile: @escaping () -> Void = {},
                onRoutines: @escaping () -> Void = {},
                onVoice: @escaping () -> Void = {}) {
        self.model = model
        self.botID = botID
        self.onOpenProfile = onOpenProfile
        self.onRoutines = onRoutines
        self.onVoice = onVoice
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// The one identity path (Components/BotIdentity.swift).
    private var bot: Bot { model.identity(botID) }

    private var botColor: Color { theme.color(for: bot.hue) }
    private var chat: ChatState? { model.chats[botID] }
    private var messages: [ChatMessage] { chat?.messages ?? [] }

    /// A turn is in flight: the send button is a stop control and typed text
    /// steers instead of submitting.
    private var turnRunning: Bool {
        (chat?.isRunning ?? false) || (chat?.isTyping ?? false)
    }

    private var attachmentCount: Int { chat?.attachments.count ?? 0 }
    private var transcriptPolicy: TranscriptPresentationPolicy {
        TranscriptPresentationPolicy(detail: model.settings.transcriptDetail)
    }

    private var hasLiveTranscriptDetail: Bool {
        messages.contains { message in
            (message.isStreaming && !(message.reasoning ?? "").isEmpty)
                || message.toolCalls.contains { $0.state == .running }
        }
    }

    private var quickReplies: [String] {
        model.mode == .demo ? (DemoData.quickReplies[botID] ?? []) : []
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            modelStrip
            if !quickReplies.isEmpty {
                quickReplyRow
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .onAppear {
            seedChatIfNeeded()
            // Idempotent: RootView attaches the router at connect time so
            // background bots keep their chips; this is the safety net for a
            // chat opened before that ran.
            model.attachChatEventRouter()
        }
    }

    /// Demo bots without history open on their roster preview, like the
    /// prototype's `[{ from:'bot', text: preview }]` fallback.
    ///
    /// Demo only. In live mode `openChat` hydrates the real transcript, and
    /// seeding here painted the roster preview as a message the bot never sent
    /// — an empty forever-chat has to look empty, not fake.
    private func seedChatIfNeeded() {
        guard model.mode == .demo else { return }
        guard model.chats[botID] == nil else { return }
        let chat = model.chat(for: botID)
        if chat.messages.isEmpty, !bot.preview.isEmpty {
            chat.messages.append(ChatMessage(author: .bot, time: bot.previewTime,
                                             text: bot.preview))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HeaderIconButton(theme: theme, size: 31, action: { model.openBotID = nil }) {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .padding(.bottom, 2)
            }
            AvatarView(bot: bot, size: 36, theme: theme)
            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 1) {
                    nameLine
                    stateLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            routinesButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private var nameLine: some View {
        let name = TalariaVoice.displayName(for: bot, theme.id)
        return Group {
            switch theme.id {
            case .soft: Text(verbatim: "\(name) ›").font(theme.body(16, weight: .bold))
            case .control: Text(verbatim: "\(name) ›").font(theme.body(15, weight: .bold))
            case .ink: Text(verbatim: "\(name) ›").font(theme.body(19, weight: .bold).smallCaps()).tracking(0.5)
            }
        }
        .foregroundStyle(theme.ink)
        .lineLimit(1)
    }

    private var stateLine: some View {
        let line = TalariaVoice.chatStateLine(for: bot, theme.id)
        let color: Color = switch bot.status {
        case .working: theme.ok
        case .approval: theme.id == .control ? theme.warn : theme.danger
        case .idle: theme.faint
        }
        return Group {
            switch theme.id {
            case .soft: Text(line).font(theme.body(11.5, weight: .medium))
            case .control: Text(line.uppercased()).font(theme.mono(9.5)).tracking(0.8)
            case .ink: Text(line.uppercased()).font(theme.mono(8.5)).tracking(1.5)
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private var routinesButton: some View {
        Button(action: onRoutines) {
            Group {
                switch theme.id {
                case .soft:
                    Text(copy.routinesBtn).font(theme.body(12, weight: .semibold))
                        .foregroundStyle(theme.ink)
                case .control:
                    Text(copy.routinesBtn).font(theme.mono(10, weight: .semibold))
                        .tracking(1).foregroundStyle(theme.ink)
                case .ink:
                    Text(copy.routinesBtn).font(theme.body(13, weight: .semibold).smallCaps())
                        .tracking(1).foregroundStyle(theme.ink)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .chipShell(theme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                    if transcriptPolicy.showsWorkingAvatar(
                        isTurnRunning: turnRunning,
                        hasLiveDetail: hasLiveTranscriptDetail
                    ) {
                        TranscriptWorkingAvatar(model: model, bot: bot, theme: theme,
                                                label: copy.workingLabel(theme.id))
                            .modifier(ChatEntrance())
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                // Tapping the transcript puts the keyboard away. A bot's
                // answer is usually longer than the third of the screen left
                // above an open keyboard, so reading is the common intent and
                // it deserves the cheapest possible gesture.
                //
                // `.contentShape` first: a VStack of bubbles only receives
                // taps where a bubble actually is, and the gaps between them
                // are exactly where a thumb lands when it means "dismiss".
                .contentShape(Rectangle())
                .onTapGesture { composerFocused = false }
            }
            // Drag the transcript down and the keyboard follows the finger,
            // rather than vanishing at some threshold.
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .task(id: initialTranscriptAnchorKey) {
                guard transcriptAnchoredBotID != botID, !messages.isEmpty else { return }
                // A long LazyVStack does not have its final bottom geometry on
                // the first paint. Anchor once after the initial layout, then
                // again after the first lazy measurement pass. Subsequent
                // transcript updates keep the normal animated behavior below
                // and never fight a person's manual scroll position.
                await Task.yield()
                proxy.scrollTo("chat-bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
                transcriptAnchoredBotID = botID
            }
            .onChange(of: messages.count) {
                guard transcriptAnchoredBotID == botID else { return }
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat?.isTyping ?? false) {
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var initialTranscriptAnchorKey: String {
        "\(botID)\u{1f}\(messages.count)\u{1f}\(String(describing: messages.last?.id))"
    }

    @ViewBuilder private func messageRow(_ message: ChatMessage) -> some View {
        switch message.author {
        case .system: systemRow(message)
        case .bot: botRow(message)
        case .user: userRow(message)
        }
    }

    // MARK: System rows

    private func systemRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
            sysPill(message.text)
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func sysPill(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text)
                .font(theme.body(11, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.4))
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(theme.ink.opacity(0.05), in: Capsule())
                .lineLimit(1)
        case .control:
            Text(text.uppercased())
                .font(theme.mono(9.5))
                .tracking(1)
                .foregroundStyle(theme.ink.opacity(0.4))
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.lineStrong.opacity(0.6), lineWidth: 1))
                .lineLimit(1)
        case .ink:
            Text(text.uppercased())
                .font(theme.mono(8))
                .tracking(1.5)
                .foregroundStyle(theme.ink.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Bot rows

    private func botRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if theme.id == .ink {
                    Text(verbatim: "\(TalariaVoice.plainUpper(for: bot)) · \(message.time ?? "now")")
                        .font(theme.mono(8))
                        .tracking(1.5)
                        .foregroundStyle(theme.ink.opacity(0.45))
                        .padding(.bottom, 4)
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty,
                   transcriptPolicy.showsReasoning(isLive: message.isStreaming) {
                    ThoughtBlock(reasoning: reasoning, theme: theme,
                                 isLive: message.isStreaming && message.text.isEmpty)
                        .padding(.bottom, message.text.isEmpty ? 0 : 5)
                }
                if !message.text.isEmpty {
                    botBubble(message.text)
                        .contextMenu { messageMenu(message) }
                }
                let visibleToolCalls = transcriptPolicy.visibleToolCalls(message.toolCalls)
                if !visibleToolCalls.isEmpty {
                    ToolCallList(calls: visibleToolCalls, theme: theme, copy: copy, accent: botColor)
                        .padding(.top, message.text.isEmpty ? 0 : 7)
                        .padding(.leading, theme.id == .ink ? 12 : 0)
                }
                if let card = message.card {
                    cardView(card)
                        .padding(.top, 8)
                        .padding(.leading, theme.id == .ink ? 14 : 0)
                }
                if let emoji = model.reaction(for: message) {
                    reactionBadge(emoji)
                        .padding(.top, 4)
                        .padding(.leading, theme.id == .ink ? 12 : 10)
                }
            }
            Spacer(minLength: 44) // ≈ the prototype's 86% max width
        }
        .modifier(ChatEntrance())
    }

    @ViewBuilder private func botBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5,
                         color: theme.ink.opacity(0.94), lineSpacing: 3)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                       bottomTrailingRadius: 20, topTrailingRadius: 20))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                bottomTrailingRadius: 20, topTrailingRadius: 20)
                    .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        case .control:
            MarkdownText(text, theme: theme, size: 14,
                         color: theme.ink.opacity(0.88), lineSpacing: 3.5)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                       bottomTrailingRadius: 10, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                bottomTrailingRadius: 10, topTrailingRadius: 10)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            // Flat manuscript text with a colored left rule — no bubble.
            MarkdownText(text, theme: theme, size: 16.5, color: theme.ink, lineSpacing: 4)
                .padding(.vertical, 2)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(botColor).frame(width: 2)
                }
        }
    }

    // MARK: Message actions (long press)

    @ViewBuilder private func messageMenu(_ message: ChatMessage) -> some View {
        Button {
            copyToPasteboard(message.text)
        } label: {
            Label(copy.copyMessage(theme.id), systemImage: "doc.on.doc")
        }
        if model.canReact(to: message, in: botID) {
            Menu {
                ForEach(Self.reactionEmojis, id: \.self) { emoji in
                    Button(emoji) { model.react(to: message, in: botID, emoji: emoji) }
                }
            } label: {
                Label(copy.reactMessage(theme.id), systemImage: "face.smiling")
            }
        }
    }

    private func reactionBadge(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: 12))
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(theme.id == .ink ? Color.clear : theme.panel,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
    }

    @ViewBuilder private func cardView(_ card: MessageCard) -> some View {
        switch card {
        case .papers(let papers): papersCard(papers)
        case .approvalRef(let ref): approvalCard(ref: ref)
        }
    }

    // MARK: Papers digest card

    private static let inkFigures = ["fig. i", "fig. ii", "fig. iii"]

    private func papersCard(_ papers: [MessageCard.Paper]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.digestHead)
                .font(theme.mono(theme.id == .ink ? 8 : 9, weight: .bold))
                .tracking(theme.id == .ink ? 2 : 1.5)
                .foregroundStyle(theme.id == .control ? theme.accent
                    : theme.ink.opacity(theme.id == .ink ? 0.55 : 0.45))
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            ForEach(Array(papers.enumerated()), id: \.offset) { index, paper in
                paperRow(paper, index: index)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
            }
            Button {
                // Full digest lives with the artifact — jump to the vault.
                model.selectedTab = .artifacts
                model.openBotID = nil
            } label: {
                Group {
                    switch theme.id {
                    case .soft:
                        Text(copy.digestLink).font(theme.body(12.5, weight: .bold))
                    case .control:
                        Text(copy.digestLink).font(theme.mono(10, weight: .bold)).tracking(1)
                    case .ink:
                        Text(copy.digestLink).font(theme.body(14, weight: .bold).smallCaps()).tracking(1)
                    }
                }
                .foregroundStyle(theme.accent)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(cardChrome)
    }

    private func paperRow(_ paper: MessageCard.Paper, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(theme.id == .ink
                 ? (index < Self.inkFigures.count ? Self.inkFigures[index] : "fig.")
                 : "▪")
                .font(theme.mono(9))
                .foregroundStyle(botColor)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(paper.title)
                    .font(theme.body(theme.id == .ink ? 15.5 : 13.5,
                                     weight: theme.id == .control ? .semibold : .bold))
                    .foregroundStyle(theme.ink)
                Text(paper.meta)
                    .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                    .tracking(theme.id == .ink ? 0.5 : 0)
                    .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.45)
                        : theme.id == .control ? theme.ink.opacity(0.42) : theme.ink.opacity(0.5))
                    .padding(.top, 2)
                Text(paper.summary)
                    .font(theme.body(theme.id == .ink ? 14 : 12.5))
                    .italic(theme.id == .ink)
                    .lineSpacing(2.5)
                    .foregroundStyle(theme.ink.opacity(theme.id == .ink ? 0.75 : 0.65))
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var cardChrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        case .control:
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.lineStrong.opacity(0.7), lineWidth: 1))
        case .ink:
            Rectangle()
                .fill(theme.panel)
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Inline approval card

    /// The card itself (choices, done-word, hazard chrome) belongs to the
    /// approvals surface — Components/InlineApprovalCard.swift — and binds to
    /// the same ApprovalOutcomes ledger this file defines.
    private func approvalCard(ref: String) -> some View {
        InlineApprovalCard(model: model, approvalID: ref, botID: botID)
    }

    // MARK: User rows

    private func userRow(_ message: ChatMessage) -> some View {
        let queued = model.composeQueue.contains {
            $0.botID == botID && $0.text == message.text
        }
        return HStack(spacing: 0) {
            Spacer(minLength: 70) // ≈ the prototype's 78% max width
            VStack(alignment: .trailing, spacing: 3) {
                userBubble(message.text)
                    .contextMenu { messageMenu(message) }
                if queued {
                    Text(copy.queued)
                        .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(9))
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .modifier(ChatEntrance())
    }

    @ViewBuilder private func userBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5, color: theme.accentFg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(LinearGradient(colors: [theme.color(for: .violet), theme.accent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                       bottomTrailingRadius: 6, topTrailingRadius: 20))
                .shadow(color: theme.accent.opacity(0.24), radius: 6, y: 4)
        case .control:
            MarkdownText(text, theme: theme, size: 14, color: theme.ink, lineSpacing: 3.5)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.12),
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                bottomTrailingRadius: 3, topTrailingRadius: 10)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1))
        case .ink:
            MarkdownText(text, theme: theme, size: 15.5, color: theme.bg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11)
                .padding(.horizontal, 15)
                .background(theme.ink,
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 16))
        }
    }

    // MARK: - Model / context / YOLO strip

    private var contextPercent: Int {
        if let live = chat?.usage?.contextPercent { return live }
        let seeded = DemoData.chats[botID]?.count ?? (bot.preview.isEmpty ? 0 : 1)
        let extra = max(0, messages.count - seeded)
        return min(92, 34 + extra * 3)
    }

    private var modelShort: String {
        let pinned = bot.pinnedModel ?? model.models.first ?? ""
        return pinned.components(separatedBy: " ").first ?? pinned
    }

    private var yoloOn: Bool { chat?.yolo ?? false }

    private var modelStrip: some View {
        HStack(spacing: 8) {
            Button {
                showModelSheet = true
            } label: {
                Text(verbatim: "⌘ \(modelShort)")
                    .font(chipStripFont)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.6) : theme.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showModelSheet) {
                ModelEffortSheet(model: model, botID: botID)
            }
            Spacer(minLength: 8)
            Capsule()
                .fill(theme.line)
                .frame(width: 52, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.accent)
                        .frame(width: 52 * CGFloat(contextPercent) / 100)
                }
            Text(verbatim: "\(contextPercent)%")
                .font(chipStripFont)
                .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.4) : theme.faint)
                .monospacedDigit()
            Button {
                model.setYolo(botID: botID, enabled: !yoloOn)
            } label: {
                Text(verbatim: "YOLO")
                    .font(chipStripFont)
                    .foregroundStyle(yoloOn ? theme.warn : theme.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
        .chipShell(theme)
        .padding(.horizontal, 16)
        .padding(.bottom, 7)
    }

    private var chipStripFont: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    // MARK: - Quick replies

    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        model.sendOrSteer(text: reply, to: botID)
                    } label: {
                        quickChip(reply)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func quickChip(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text)
                .font(theme.body(13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1.5))
        case .control:
            Text(text)
                .font(theme.mono(10.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
        case .ink:
            Text(text)
                .font(theme.body(14, weight: .semibold).smallCaps())
                .tracking(0.5)
                .foregroundStyle(theme.ink)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.ink.opacity(0.03))
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.4), lineWidth: 1))
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Staged attachments (attachments agent owns the tray + picker).
            AttachmentTray(model: model, botID: botID)
            if turnRunning, model.mode == .live {
                steerHint
            }
            // The @-completion rows, above the field because the keyboard owns
            // everything below it. Kept out of the stack entirely when there
            // is nothing to offer, so no gap opens over the composer.
            let handles = mentionSuggestions
            if !handles.isEmpty {
                MentionSuggestionStrip(theme: theme, items: handles, pick: complete(with:))
            }
            // The editor owns the full container width. Controls live on a
            // fixed toolbar below it, so a 320 pt phone never turns prose into
            // the narrow vertical column produced by three inline buttons.
            TextField("", text: $draft,
                      prompt: Text(copy.composer(bot)).foregroundStyle(theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...ChatComposerLayoutPolicy.maxEditorLines(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ))
                .font(composerFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($composerFocused)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(composerFieldChrome)

            HStack(alignment: .center, spacing: 8) {
                HeaderIconButton(theme: theme, size: 40, action: onVoice) {
                    HStack(spacing: 3) {
                        micBar(height: 14, color: theme.accent)
                        micBar(height: 8, color: theme.accentFaint)
                    }
                }
                .frame(minWidth: ChatComposerLayoutPolicy.controlHitTarget,
                       minHeight: ChatComposerLayoutPolicy.controlHitTarget)
                .accessibilityLabel(copy.voiceLabel(theme.id))
                attachButton
                Spacer(minLength: 8)
                sendOrStopButton
            }
            .frame(minHeight: ChatComposerLayoutPolicy.controlHitTarget)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // The strip appears and disappears per keystroke; without a transition
        // the field jumps under the thumb mid-word.
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.18),
                   value: mentionSuggestions.map(\.botID))
        // "/" as the first character opens the command palette; Cancel just
        // dismisses it and leaves the draft (and the keyboard) where they were.
        .onChange(of: draft) { _, new in
            if new == "/" { showCommands = true }
        }
        .sheet(isPresented: $showCommands, onDismiss: {
            // Cancel (or a zero-argument command that ran from the palette)
            // leaves the lone "/" behind — clear it and hand the keyboard back.
            if draft == "/" { draft = "" }
            composerFocused = true
        }) {
            CommandPaletteSheet(model: model, botID: botID) { picked in
                draft = picked
                showCommands = false
            }
        }
    }

    // MARK: - @-mention completion (plugin.js:7996-8043)

    /// The handles worth offering for the token being typed.
    ///
    /// Desktop registers its provider into EVERY composer (plugin.js:7996-7997
    /// — "active in ANY composer", issue #88060), and this is the composer
    /// that matters on a phone: the handoff sheet is a deliberate act, a chat
    /// message is where an @handle actually gets typed. Everything about the
    /// rows is the shared provider (`bots.mentionSuggestions`), which is
    /// synchronous by contract because it answers per keystroke.
    ///
    /// The guards are Talaria's, and each names a path where picking a handle
    /// would insert a token that does NOT route:
    ///
    ///  * demo mode and offline — `routeMentions` bails on both
    ///    (AppModelLive+A2A.swift:444) and an offline draft is queued as
    ///    written, so the mention would reach the model as literal text;
    ///  * mid-turn — a send while a turn runs STEERS, and steering is
    ///    deliberately mention-free (`sendOrSteer`, AppModelLive+Chat.swift:253);
    ///  * a slash draft — `send()` hands anything starting with "/" to
    ///    `runSlash`, which never reaches the middleware. This also keeps the
    ///    strip out of the lone-"/" palette gesture's way.
    ///
    /// Upstream has no equivalent because it has no steer path, no offline
    /// queue and no demo world; the honest reading is that a completion is an
    /// offer to route, so it is only made where routing happens.
    private var mentionSuggestions: [MentionSuggestion] {
        guard model.mode == .live, !model.isOffline, !turnRunning,
              !draft.hasPrefix("/"),
              let active = BotMention.activeToken(in: draft) else { return [] }
        return model.mentionSuggestions(for: active.token, speaking: botID)
    }

    /// Swap the half-typed token for the chosen handle and keep the keyboard.
    private func complete(with item: MentionSuggestion) {
        guard let active = BotMention.activeToken(in: draft) else { return }
        draft = BotMention.complete(draft, range: active.range, with: item.handle)
        composerFocused = true
    }

    /// Paperclip → the attachments agent's picker, badged with what is staged.
    private var attachButton: some View {
        HeaderIconButton(theme: theme, size: 40,
                         action: { model.presentAttachmentPicker(botID: botID) }) {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: theme.id == .ink ? .regular : .medium))
                .foregroundStyle(attachmentCount > 0 ? theme.accent : theme.ink.opacity(0.55))
        }
        .frame(minWidth: ChatComposerLayoutPolicy.controlHitTarget,
               minHeight: ChatComposerLayoutPolicy.controlHitTarget)
        .overlay(alignment: .topTrailing) {
            if attachmentCount > 0 {
                Text(verbatim: "\(attachmentCount)")
                    .font(theme.mono(8, weight: .bold))
                    .foregroundStyle(theme.accentFg)
                    .frame(width: 14, height: 14)
                    .background(theme.accent, in: Circle())
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityLabel(copy.attachLabel(theme.id))
    }

    /// Mid-turn sends steer the running turn instead of interrupting it —
    /// desktop's behavior, and worth saying out loud on a phone.
    private var steerHint: some View {
        HStack(spacing: 6) {
            Text(verbatim: "↳")
                .font(theme.mono(10))
                .foregroundStyle(theme.accent)
            Text(copy.steerHint(theme.id))
                .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(9))
                .tracking(theme.id == .ink ? 1 : 0)
                .foregroundStyle(theme.faint)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private func micBar(height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: theme.id == .soft ? 2.25 : theme.id == .control ? 1 : 2)
            .fill(color)
            .frame(width: 4.5, height: height)
    }

    private var composerFont: Font {
        switch theme.id {
        case .soft: theme.body(softComposerSize)
        case .control: theme.mono(controlComposerSize)
        case .ink: theme.body(inkComposerSize)
        }
    }

    @ViewBuilder private var composerFieldChrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.09), lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 8).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.lineStrong.opacity(0.8), lineWidth: 1))
        case .ink:
            RoundedRectangle(cornerRadius: 2).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(theme.ink.opacity(0.4), lineWidth: 1))
        }
    }

    private var sendShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 8 : 20, style: .continuous)
    }

    private var sendBackground: Color {
        if turnRunning {
            return switch theme.id {
            case .soft: theme.danger
            case .control: theme.danger.opacity(0.14)
            case .ink: theme.ink
            }
        }
        if !canSend {
            return switch theme.id {
            case .soft: theme.ink.opacity(0.18)
            case .control: theme.ink.opacity(0.14)
            case .ink: theme.ink.opacity(0.3)
            }
        }
        return theme.accent
    }

    /// Attachments alone are a valid turn — the gateway supplies the implicit
    /// "what is this?" prompt for an image sent without words.
    private var canSend: Bool {
        switch composerAction {
        case .disabled, .stop: false
        default: true
        }
    }

    private var composerAction: ChatComposerAction {
        ChatComposerActionPolicy.action(draft: draft, attachmentCount: attachmentCount,
                                        isTurnRunning: turnRunning)
    }

    private var stopGlyphColor: Color {
        switch theme.id {
        case .soft: theme.accentFg
        case .control: theme.danger
        case .ink: theme.bg
        }
    }

    /// The single highest-value control on this screen: while a turn runs the
    /// send button becomes stop (session.interrupt), so a runaway bot can be
    /// halted from the phone.
    /// Stop is what the button means only when there is nothing to send.
    /// With a draft in hand it is a send button even mid-turn — that send
    /// steers or queues (the hint above the field says which), which is what
    /// you wanted when you typed. Reaching for the return key to get past a
    /// permanent stop button was the old behaviour.
    private var showsStop: Bool { composerAction == .stop }

    private var sendOrStopButton: some View {
        Button {
            if showsStop {
                model.stopTurn(botID: botID)
            } else {
                send()
            }
        } label: {
            Group {
                if showsStop {
                    RoundedRectangle(cornerRadius: theme.id == .soft ? 3
                                        : theme.id == .control ? 1 : 2)
                        .fill(stopGlyphColor)
                        .frame(width: 12, height: 12)
                } else {
                    Text(verbatim: "↑")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(theme.accentFg)
                }
            }
            .frame(width: ChatComposerLayoutPolicy.controlHitTarget,
                   height: ChatComposerLayoutPolicy.controlHitTarget)
            .background(sendBackground, in: sendShape)
            .overlay {
                if showsStop, theme.id != .soft {
                    sendShape.strokeBorder(theme.danger.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(sendShape)
        }
        .buttonStyle(.plain)
        .shadow(color: showsStop && theme.glowRadius > 0 ? theme.danger.opacity(0.45) : .clear,
                radius: 8)
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.2),
                   value: canSend)
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.2),
                   value: turnRunning)
        .animation(ChatComposerLayoutPolicy.animation(reducedMotion: reducedMotion, duration: 0.2),
                   value: showsStop)
        .accessibilityLabel(showsStop ? copy.stopLabel(theme.id) : copy.sendLabel(theme.id))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard canSend else { return }
        // A lone "/" is a request for the palette, not a command to run.
        if text == "/" {
            showCommands = true
            return
        }
        draft = ""
        // Slash commands are not prompts: they go to slash.exec, which appends
        // its own user echo and leaves anything staged in the tray alone for
        // the next real turn.
        if text.hasPrefix("/") {
            Task { await model.runSlash(text, botID: botID) }
            return
        }
        model.sendOrSteer(text: text, to: botID)
    }
}

// MARK: - Chat copy (per-theme voice for the surfaces added here)

extension CopyPack {

    /// Stop button label (accessibility + control-theme readout).
    func stopLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Stop"
        case .control: "ABORT TURN"
        case .ink: "stay its hand"
        }
    }

    func sendLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Send"
        case .control: "TRANSMIT"
        case .ink: "send"
        }
    }

    func voiceLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Start voice conversation"
        case .control: "OPEN VOICE CHANNEL"
        case .ink: "speak with it"
        }
    }

    func workingLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Working"
        case .control: "WORKING"
        case .ink: "at work"
        }
    }

    /// System row appended when the user stops a running turn.
    func stopNote(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Stopped by you"
        case .control: "TURN INTERRUPTED BY OPERATOR"
        case .ink: "you stayed its hand"
        }
    }

    /// Composer hint while a turn is in flight.
    func steerHint(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Working — what you send now steers this turn instead of interrupting it."
        case .control: "TURN LIVE — INPUT INJECTS AS STEER, NO INTERRUPT"
        case .ink: "it works — a word now is whispered into the task, not over it"
        }
    }

    func attachLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Attach a file"
        case .control: "ATTACH PAYLOAD"
        case .ink: "enclose something"
        }
    }

    func copyMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Copy text"
        case .control: "COPY"
        case .ink: "take a copy"
        }
    }

    func reactMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "React"
        case .control: "MARK"
        case .ink: "leave a mark"
        }
    }

    /// Tool chip: running with no argument preview yet.
    func toolRunning(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "running…"
        case .control: "RUNNING"
        case .ink: "at work"
        }
    }

    func toolFailed(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "failed"
        case .control: "FAULT"
        case .ink: "it faltered"
        }
    }

    /// Header above an expanded tool result.
    func toolResultHead(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "RESULT"
        case .control: "RETURN"
        case .ink: "WHAT CAME BACK"
        }
    }
}

// MARK: - Entrance

/// rowU for chat messages — quick fade + rise.
private struct ChatEntrance: ViewModifier {
    @State private var shown = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.35
                )) { shown = true }
            }
    }
}

// MARK: - Thought block (desktop reasoning parity)

/// The collapsible reasoning block above a bot message — desktop's "Thought ›"
/// row. While reasoning is streaming ahead of the first visible token it shows
/// a live tail instead of a chevron.
struct ThoughtBlock: View {
    var reasoning: String
    var theme: ThemePack
    var isLive: Bool

    @State private var expanded = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isLive ? "thinking" : "Thought")
                        .font(theme.mono(10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                    if isLive {
                        Circle().fill(theme.accent)
                            .frame(width: 5, height: 5)
                            .shadow(color: theme.accent.opacity(0.6), radius: 3)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.faint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded || isLive {
                Text(isLive ? String(reasoning.suffix(280)) : reasoning)
                    .font(theme.mono(11))
                    .lineSpacing(3)
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(theme.inset.opacity(theme.id == .ink ? 0 : 1),
                                in: RoundedRectangle(cornerRadius: theme.cardRadius == 0 ? 0 : 10))
                    .overlay(alignment: .leading) {
                        if theme.id == .ink {
                            Rectangle().fill(theme.line).frame(width: 2)
                        }
                    }
            }
        }
    }
}

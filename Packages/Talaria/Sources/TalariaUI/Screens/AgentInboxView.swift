import SwiftUI
import TalariaKit
import TalariaTheme

// Agent Inbox — Agent Inbox / Comms / The Parley. The cross-bot traffic feed:
// each row is a from-avatar, "from → to" names (copy.a2aSep — "unto" in ink;
// "all" renders as a broadcast), the message body (italic and quoted in ink),
// and a footer attribution note. You watch; @mention in a bot's chat to steer.
// Ported from Talaria.dc.html `data-screen-label="Agent Inbox"`.

public struct AgentInboxView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

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
                               theme: theme, copy: copy)
                            .modifier(RowEntrance(delay: Double(index) * 0.055))
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
    }

    // MARK: Header

    private var header: some View {
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

    // MARK: Footer

    /// The attribution note — handoffs are real cross-profile messages.
    private var footer: some View {
        Text(copy.a2aFoot)
            .font(footFont)
            .tracking(theme.id == .soft ? 0 : (theme.id == .ink ? 2 : 1))
            .textCase(theme.id == .ink ? .uppercase : nil)
            .foregroundStyle(theme.faint)
            .multilineTextAlignment(.center)
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

    private var isBroadcast: Bool { message.toBotID == "all" }

    private var fromColor: Color { theme.color(for: fromBot?.hue ?? .teal) }

    /// Broadcasts render muted; direct messages take the recipient's hue.
    private var toColor: Color {
        isBroadcast ? theme.sub : theme.color(for: toBot?.hue ?? .teal)
    }

    /// "all bots" / "ALL" / "All" for broadcasts, else the themed bot name.
    private var toName: String {
        guard isBroadcast else {
            return TalariaVoice.displayName(message.toBotID, theme.id)
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
        HStack(alignment: .top, spacing: 10) {
            AvatarView(shape: fromBot?.shape ?? .circle,
                       hue: fromBot?.hue ?? .teal,
                       size: 26, theme: theme)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TalariaVoice.displayName(message.fromBotID, theme.id))
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(A2ARowChrome(theme: theme))
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

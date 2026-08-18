import SwiftUI
import TalariaKit
import TalariaTheme

// The approval surfaces that live outside the Approvals tab:
//
// - `InlineApprovalCard` — the same seal card rendered inside a chat
//   transcript, bound to a `.approvalRef` message. It shares state with the
//   Approvals tab: pending means the id is still in `model.approvals`, and
//   deciding here resolves it everywhere through the ApprovalOutcomes ledger.
// - `BlockingPromptOverlay` — the clarify / sudo / secret bridges
//   (ws-protocol.md §8). These park a real tool thread for 120–300 s and had no
//   UI at all, so an agent that asked a question simply hung until timeout.
// - The themed voice both of them and ApprovalsView share.

// MARK: - Themed voice

public extension CopyPack {

    /// Button label for one gateway choice. The pack's own `approve` is used
    /// when the server offers nothing but once/deny — there is no scope to
    /// disambiguate, and "Approve" reads better than "Approve once".
    func approvalChoice(_ choice: ApprovalChoice, _ t: ThemeID) -> String {
        switch choice {
        case .once:
            switch t {
            case .soft: return "Approve once"
            case .control: return "RELEASE ONCE"
            case .ink: return "grant this once"
            }
        case .session:
            switch t {
            case .soft: return "Allow this session"
            case .control: return "RELEASE · SESSION"
            case .ink: return "grant for this audience"
            }
        case .always:
            switch t {
            case .soft: return "Always allow"
            case .control: return "RELEASE · ALWAYS"
            case .ink: return "grant evermore"
            }
        case .deny:
            return deny
        }
    }

    /// A decided card's line: the themed done-word plus the scope that was
    /// granted, so "always" stays visible after the card dims.
    func approvalDone(kind: ApprovalKind, choice: ApprovalChoice, _ t: ThemeID) -> String {
        TalariaVoice.doneWord(kind: kind, approved: choice != .deny, t)
            + approvalScopeNote(choice, t)
    }

    /// Trailing qualifier on a decided card's done-word, so "always" and "this
    /// session" stay visible after the decision.
    func approvalScopeNote(_ choice: ApprovalChoice, _ t: ThemeID) -> String {
        switch choice {
        case .once, .deny: return ""
        case .session:
            switch t {
            case .soft: return " · this session"
            case .control: return " · SESSION"
            case .ink: return " · for this audience"
            }
        case .always:
            switch t {
            case .soft: return " · always"
            case .control: return " · ALWAYS"
            case .ink: return " · evermore"
            }
        }
    }

    /// Shown when the gateway reduced the choice set because this pattern was
    /// refused before (`smart_denied`).
    func approvalSmartDenied(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Refused before — only once-or-deny is offered."
        case .control: return "PREVIOUSLY REFUSED — REDUCED CHOICE SET"
        case .ink: return "once refused — this once only, or not at all"
        }
    }

    /// The Approvals-tab lead's second sentence.
    func approvalsSwipeHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Swipe → approve, ← deny."
        case .control: return "SWIPE → RELEASE, ← ABORT."
        case .ink: return "Draw right to seal, left to refuse."
        }
    }

    /// Age readout. Empty age means a request recovered by the reconnect
    /// replay, which has been waiting an unknown while.
    func approvalAge(_ age: String, _ t: ThemeID) -> String {
        if age.isEmpty {
            switch t {
            case .soft: return "waiting"
            case .control: return "HELD"
            case .ink: return "still waiting"
            }
        }
        if age == "now" {
            switch t {
            case .soft: return "just now"
            case .control: return "NOW"
            case .ink: return "a moment past"
            }
        }
        switch t {
        case .soft: return "\(age) ago"
        case .control: return "\(age.uppercased()) AGO"
        case .ink: return "\(age) past"
        }
    }

    /// `approval.respond` resolved nothing: it timed out, an interrupt denied
    /// it, or another client answered first.
    func approvalGone(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "That approval was already resolved — it timed out or was answered elsewhere."
        case .control: return "HOLD ALREADY CLEARED — TIMED OUT OR ANSWERED ELSEWHERE."
        case .ink: return "The seal was given elsewhere, or the hour passed."
        }
    }

    func approvalSendFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Couldn't reach the gateway — the bot is still waiting. Try again."
        case .control: return "LINK FAILED — AGENT STILL HELD. RETRY."
        case .ink: return "The word did not carry. The familiar waits still."
        }
    }

    func promptSendFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Couldn't send that answer — the bot is still waiting."
        case .control: return "ANSWER NOT DELIVERED — AGENT STILL HELD."
        case .ink: return "Your answer did not carry. The familiar waits."
        }
    }

    // MARK: Blocking prompts

    func promptTag(_ kind: BlockingPrompt.Kind, _ t: ThemeID) -> String {
        switch kind {
        case .clarify:
            switch t {
            case .soft: return "NEEDS AN ANSWER"
            case .control: return "QUERY — INPUT REQUIRED"
            case .ink: return "A QUESTION IS PUT TO YOU"
            }
        case .sudo:
            switch t {
            case .soft: return "NEEDS YOUR PASSWORD"
            case .control: return "SUDO — CREDENTIAL REQUIRED"
            case .ink: return "THE KEY IS ASKED OF YOU"
            }
        case .secret:
            switch t {
            case .soft: return "NEEDS A SECRET"
            case .control: return "SECRET — CREDENTIAL REQUIRED"
            case .ink: return "A SECRET IS ASKED OF YOU"
            }
        }
    }

    /// Fallback question text. `sudo.request` carries no payload at all and
    /// `secret.request` can arrive with an empty prompt.
    func promptQuestion(_ kind: BlockingPrompt.Kind, envVar: String?, _ t: ThemeID) -> String {
        switch kind {
        case .clarify:
            switch t {
            case .soft: return "The bot needs an answer to continue."
            case .control: return "AGENT AWAITS INPUT TO CONTINUE."
            case .ink: return "The familiar waits upon your word."
            }
        case .sudo:
            switch t {
            case .soft: return "Enter the sudo password for this command."
            case .control: return "ENTER SUDO PASSWORD FOR THIS COMMAND."
            case .ink: return "Give the sudo word for this deed."
            }
        case .secret:
            let name = envVar ?? ""
            if name.isEmpty {
                switch t {
                case .soft: return "Enter the secret this skill needs."
                case .control: return "ENTER SECRET REQUIRED BY SKILL."
                case .ink: return "Give the secret this gift requires."
                }
            }
            switch t {
            case .soft: return "Enter the value to store as \(name)."
            case .control: return "ENTER VALUE FOR \(name)."
            case .ink: return "Give the value to be kept as \(name)."
            }
        }
    }

    /// Reassurance under a secure field. Talaria never persists these values.
    func promptSecureNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Sent straight to your gateway — never stored on this phone."
        case .control: return "TRANSMITTED TO GATEWAY ONLY — NOT PERSISTED ON DEVICE."
        case .ink: return "Carried to the gateway alone; nothing is kept here."
        }
    }

    func promptSubmit(_ kind: BlockingPrompt.Kind, _ t: ThemeID) -> String {
        if kind == .clarify {
            switch t {
            case .soft: return "Answer"
            case .control: return "SEND"
            case .ink: return "answer"
            }
        }
        switch t {
        case .soft: return "Send securely"
        case .control: return "TRANSMIT"
        case .ink: return "entrust it"
        }
    }

    /// Empty value = refusal, a first-class protocol outcome.
    func promptRefuse(_ kind: BlockingPrompt.Kind, _ t: ThemeID) -> String {
        if kind == .clarify {
            switch t {
            case .soft: return "Skip"
            case .control: return "SKIP"
            case .ink: return "say nothing"
            }
        }
        switch t {
        case .soft: return "Refuse"
        case .control: return "REFUSE"
        case .ink: return "withhold it"
        }
    }

    func promptMultiNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: return "Pick as many as apply."
        case .control: return "MULTI-SELECT — PICK ANY."
        case .ink: return "Choose as many as apply."
        }
    }

    func promptPlaceholder(_ kind: BlockingPrompt.Kind, _ t: ThemeID) -> String {
        switch kind {
        case .clarify:
            switch t {
            case .soft: return "Type your answer…"
            case .control: return "ANSWER…"
            case .ink: return "write your answer…"
            }
        case .sudo:
            switch t {
            case .soft: return "Password"
            case .control: return "PASSWORD"
            case .ink: return "the sudo word"
            }
        case .secret:
            switch t {
            case .soft: return "Secret value"
            case .control: return "VALUE"
            case .ink: return "the secret"
            }
        }
    }

    /// More prompts parked behind this one.
    func promptQueued(_ count: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft: return count == 1 ? "1 more waiting" : "\(count) more waiting"
        case .control: return "+\(count) QUEUED"
        case .ink: return count == 1 ? "one more awaits" : "\(count) more await"
        }
    }
}

// MARK: - Choice buttons (shared by the tab card and the inline card)

/// The gateway's derived choice set as controls: once + deny on the primary
/// row, the broader grants (session / always) as quieter chips beneath. The
/// server decides which of the four exist — smart-denied requests get only
/// once/deny, and patterns that cannot be permanently allowed lose "always".
struct ApprovalChoiceButtons: View {
    let theme: ThemePack
    let copy: CopyPack
    let choices: [ApprovalChoice]
    var compact: Bool = false
    let decide: (ApprovalChoice) -> Void

    /// Grants beyond "this one time", in the gateway's order.
    private var scopeChoices: [ApprovalChoice] {
        choices.filter { $0 == .session || $0 == .always }
    }

    /// With no scope grants on offer there is nothing to disambiguate, so the
    /// pack's plain Approve/RELEASE/grant-the-seal reads better.
    private var approveTitle: String {
        scopeChoices.isEmpty ? copy.approve : copy.approvalChoice(.once, theme.id)
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                if choices.contains(.once) {
                    ThemedPrimaryButton(theme: theme, title: approveTitle, compact: compact) {
                        decide(.once)
                    }
                }
                if choices.contains(.deny) {
                    ThemedSecondaryButton(theme: theme, title: copy.deny,
                                          compact: compact, fillsWidth: true) {
                        decide(.deny)
                    }
                }
            }
            if !scopeChoices.isEmpty {
                HStack(spacing: 7) {
                    ForEach(scopeChoices, id: \.rawValue) { choice in
                        ApprovalScopeChip(theme: theme,
                                          title: copy.approvalChoice(choice, theme.id)) {
                            decide(choice)
                        }
                    }
                }
            }
        }
    }
}

/// A broader grant ("this session" / "always"). Deliberately quieter than the
/// primary button — approving forever should take a deliberate tap, not be the
/// thing your thumb lands on.
struct ApprovalScopeChip: View {
    let theme: ThemePack
    let title: String
    let action: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(9.5, weight: .bold)
        case .ink: theme.body(13.5, weight: .semibold).smallCaps()
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .tracking(theme.id == .soft ? 0 : 1.2)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(theme.id == .soft ? theme.accent.opacity(0.09) : Color.clear)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    theme.accent.opacity(theme.id == .soft ? 0 : 0.45), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .shadow(color: theme.glowRadius > 0 ? theme.accent.opacity(0.16) : .clear, radius: 6)
    }
}

// MARK: - Inline approval card

/// The seal card inside a chat transcript, bound to a `.approvalRef` message.
///
/// State is shared with the Approvals tab, not copied: "pending" means the id
/// is still in `model.approvals`, and every decision routes through
/// ApprovalOutcomes so the tab, the banner and this card agree. A decided card
/// keeps rendering (dimmed, with the done-word) from the ledger's snapshot.
public struct InlineApprovalCard: View {
    private let model: AppModel
    private let approvalID: String
    private let botID: String

    public init(model: AppModel, approvalID: String, botID: String) {
        self.model = model
        self.approvalID = approvalID
        self.botID = botID
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var live: Approval? { model.approvals.first { $0.id == approvalID } }
    private var approval: Approval? { live ?? ApprovalOutcomes.shared.snapshots[approvalID] }
    private var pending: Bool { live != nil }

    /// The choice a decided card was answered with. Prefers the ledger; falls
    /// back to the system row AppModel appends on resolve, for a card decided
    /// before this process learned about it.
    private var decidedChoice: ApprovalChoice {
        if let choice = ApprovalOutcomes.shared.choice(for: approvalID) { return choice }
        guard let approval else { return .once }
        let denied = model.chats[botID]?.messages.contains {
            $0.author == .system && $0.text.hasPrefix("Denied") && $0.text.contains(approval.title)
        } ?? false
        return denied ? .deny : .once
    }

    public var body: some View {
        Group {
            if let approval {
                card(approval)
                    .onAppear { if let live { ApprovalOutcomes.shared.remember(live) } }
            }
        }
    }

    private func card(_ approval: Approval) -> some View {
        let detail = model.approvalDetail(approvalID)
        return VStack(alignment: .leading, spacing: 0) {
            if theme.id == .control && pending {
                InlineHazardStripes(color: theme.warn, background: theme.panel)
                    .frame(height: 5)
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                subjectLine(approval)
                    .padding(.top, 7)
                Text(verbatim: "\(copy.unto) \(approval.target)")
                    .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                    .foregroundStyle(theme.ink.opacity(theme.id == .ink ? 0.5 : 0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
                quote(approval)
                    .padding(.top, 8)
                if pending, detail?.smartDenied == true {
                    Text(copy.approvalSmartDenied(theme.id))
                        .font(theme.mono(theme.id == .ink ? 8 : 9))
                        .tracking(theme.id == .soft ? 0.5 : 1.2)
                        .foregroundStyle(theme.danger.opacity(0.85))
                        .padding(.top, 7)
                }
                if pending {
                    ApprovalChoiceButtons(theme: theme, copy: copy,
                                          choices: model.approvalChoices(for: approvalID),
                                          compact: true) { choice in
                        ApprovalOutcomes.shared.resolve(approval, choice: choice, in: model)
                    }
                    .padding(.top, 11)
                } else {
                    doneRow(approval)
                        .padding(.top, 11)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .background(sealChrome)
        .padding(theme.id == .ink ? 4 : 0) // room for the ink double rule
        .opacity(pending ? 1 : 0.68)
    }

    private var accentState: Color {
        pending ? (theme.id == .control ? theme.warn : theme.danger) : theme.faint
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(accentState)
                .frame(width: 8, height: 8)
                .glowPulse(period: 1.7)
            Text(copy.tag)
                .font(theme.mono(theme.id == .ink ? 8.5 : 9.5,
                                 weight: theme.id == .ink ? .semibold : .bold))
                .tracking(theme.id == .control ? 1.8 : theme.id == .ink ? 2 : 1)
                .foregroundStyle(accentState)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func subjectLine(_ approval: Approval) -> some View {
        Group {
            if approval.kind == .command {
                Text(approval.subject)
                    .font(theme.mono(theme.id == .soft ? 12.5 : 12, weight: .semibold))
            } else {
                Text(approval.subject)
                    .font(theme.body(theme.id == .ink ? 17 : theme.id == .control ? 13 : 14,
                                     weight: theme.id == .soft ? .bold : .semibold))
            }
        }
        .foregroundStyle(theme.id == .control ? theme.warn : theme.ink)
    }

    @ViewBuilder private func quote(_ approval: Approval) -> some View {
        switch theme.id {
        case .soft:
            Text(approval.body)
                .font(theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(theme.ink.opacity(0.7))
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.inset, in: RoundedRectangle(cornerRadius: 12))
        case .control:
            Text(approval.body)
                .font(theme.body(12.5))
                .lineSpacing(3.5)
                .foregroundStyle(theme.ink.opacity(0.7))
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.inset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            Text(approval.body)
                .font(theme.body(14.5))
                .italic()
                .lineSpacing(3.5)
                .foregroundStyle(theme.ink.opacity(0.8))
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.ink.opacity(0.25)).frame(width: 2)
                }
        }
    }

    private func doneRow(_ approval: Approval) -> some View {
        let choice = decidedChoice
        let color = choice == .deny ? theme.danger : theme.ok
        return HStack(spacing: 9) {
            if theme.id == .ink {
                Circle()
                    .fill(color)
                    .overlay(Circle().inset(by: 2).stroke(theme.panel, lineWidth: 1.4))
                    .frame(width: 14, height: 14)
            }
            Text(copy.approvalDone(kind: approval.kind, choice: choice, theme.id))
                .tracking(theme.id == .soft ? 0 : 1)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(doneFont)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(doneBackground(denied: choice == .deny))
        .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous))
        .overlay {
            if theme.id == .ink {
                RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
                    .strokeBorder(color, lineWidth: 1)
            }
        }
    }

    private var doneFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(14.5, weight: .bold).smallCaps()
        }
    }

    private func doneBackground(denied: Bool) -> Color {
        switch theme.id {
        case .soft: denied ? theme.danger.opacity(0.08) : theme.ok.opacity(0.1)
        case .control: denied ? theme.danger.opacity(0.08) : theme.ok.opacity(0.08)
        case .ink: .clear
        }
    }

    @ViewBuilder private var sealChrome: some View {
        let border = pending
            ? (theme.id == .control ? theme.warn.opacity(0.35)
               : theme.id == .ink ? theme.accent.opacity(0.65) : theme.danger.opacity(0.35))
            : (theme.id == .control ? theme.line
               : theme.id == .ink ? theme.ink.opacity(0.3) : theme.ink.opacity(0.08))
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(border, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.05), radius: 6, y: 3)
        case .control:
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1))
                .shadow(color: pending ? theme.warn.opacity(0.14) : .clear, radius: 10)
        case .ink:
            Rectangle()
                .fill(theme.panel)
                .overlay(Rectangle().strokeBorder(border, lineWidth: 1))
                // The seal's double rule: a hairline floating 4pt outside.
                .overlay(Rectangle().inset(by: -4).stroke(theme.ink.opacity(0.45), lineWidth: 1))
        }
    }
}

// MARK: - Blocking prompt overlay

/// The clarify / sudo / secret bridges (ws-protocol.md §8). Each one has a real
/// tool thread parked on it — 120 s for sudo, 300 s for the others (clarify can
/// be configured to wait forever) — so this overlay is modal by design: the
/// only ways out are answering or refusing, both of which unblock the run.
///
/// Refusal is not a cancel. An empty value is what the protocol calls a
/// refusal: sudo reports no password available, secret returns `skipped:true`,
/// clarify hands the agent an empty answer. All three let the turn continue.
public struct BlockingPromptOverlay: View {
    private let model: AppModel

    @State private var text = ""
    @State private var selections: [String] = []
    @FocusState private var fieldFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// One at a time: the gateway can park several tools, and answering the
    /// front one reveals the next.
    private var prompt: BlockingPrompt? { ApprovalBridges.shared.prompts.first }
    private var queued: Int { max(0, ApprovalBridges.shared.prompts.count - 1) }

    public var body: some View {
        ZStack {
            if let prompt {
                Rectangle()
                    .fill(.black.opacity(theme.id == .ink ? 0.3 : 0.5))
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    card(prompt)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: prompt?.id)
        .onChange(of: prompt?.id) {
            text = ""
            selections = []
            fieldFocused = prompt?.isSecret == true
        }
        // This overlay is mounted for the life of the app, which makes it the
        // one place guaranteed to see every link transition. Arming the bridges
        // from here means a bot that asks a question is never left parked
        // because a connect happened somewhere the integrator did not hook.
        // Every call is an identity check plus an integer compare.
        .task { model.attachApprovalBridges() }
        .onChange(of: model.mode) { model.attachApprovalBridges() }
        .onChange(of: model.isOffline) { model.attachApprovalBridges() }
        .onChange(of: model.bots) { model.attachApprovalBridges() }
    }

    // MARK: Card

    private func card(_ prompt: BlockingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if theme.id == .control {
                InlineHazardStripes(color: prompt.isSecret ? theme.danger : theme.accent,
                                    background: theme.panel)
                    .frame(height: 5)
            }
            VStack(alignment: .leading, spacing: 0) {
                tagRow(prompt)
                if let botID = prompt.botID {
                    Text(model.botName(botID, theme.id))
                        .font(botFont)
                        .foregroundStyle(theme.color(for: model.bot(botID)?.hue ?? .teal))
                        .padding(.top, 6)
                }
                Text(questionText(prompt))
                    .font(questionFont)
                    .italic(theme.id == .ink)
                    .lineSpacing(3)
                    .foregroundStyle(theme.ink)
                    // An essay-length question must not push the answer
                    // controls off a phone screen with the keyboard up.
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                if prompt.kind == .clarify && !prompt.choices.isEmpty {
                    if prompt.multiSelect {
                        Text(copy.promptMultiNote(theme.id))
                            .font(theme.mono(theme.id == .ink ? 8 : 9))
                            .tracking(1.2)
                            .foregroundStyle(theme.faint)
                            .padding(.top, 8)
                    }
                    if prompt.choices.count > 5 {
                        // Long option lists scroll inside the card rather than
                        // growing it past the screen.
                        ScrollView { choiceList(prompt) }
                            .frame(height: 300)
                            .padding(.top, 9)
                    } else {
                        choiceList(prompt)
                            .padding(.top, 9)
                    }
                } else {
                    entryField(prompt)
                        .padding(.top, 11)
                    if prompt.isSecret {
                        Text(copy.promptSecureNote(theme.id))
                            .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8 : 9))
                            .tracking(theme.id == .soft ? 0 : 1)
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                }

                actions(prompt)
                    .padding(.top, 12)

                if queued > 0 {
                    Text(copy.promptQueued(queued, theme.id))
                        .font(theme.mono(theme.id == .ink ? 8 : 9))
                        .tracking(1.2)
                        .foregroundStyle(theme.faint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 9)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .background(promptChrome(prompt))
        .padding(theme.id == .ink ? 4 : 0)
    }

    private func tagRow(_ prompt: BlockingPrompt) -> some View {
        let tint = prompt.isSecret ? theme.danger : (theme.id == .control ? theme.accent : theme.warn)
        return HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .glowPulse(period: 1.7)
            Text(copy.promptTag(prompt.kind, theme.id))
                .font(theme.mono(theme.id == .ink ? 8.5 : 9.5,
                                 weight: theme.id == .ink ? .semibold : .bold))
                .tracking(theme.id == .control ? 1.8 : theme.id == .ink ? 2 : 1)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func questionText(_ prompt: BlockingPrompt) -> String {
        prompt.question.isEmpty
            ? copy.promptQuestion(prompt.kind, envVar: prompt.envVar, theme.id)
            : prompt.question
    }

    // MARK: Choices

    private func choiceList(_ prompt: BlockingPrompt) -> some View {
        VStack(spacing: 6) {
            ForEach(prompt.choices, id: \.self) { choice in
                Button {
                    if prompt.multiSelect {
                        toggle(choice)
                    } else {
                        model.answerBlockingPrompt(prompt, answer: choice)
                    }
                } label: {
                    choiceRow(choice, selected: selections.contains(choice),
                              multi: prompt.multiSelect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choiceRow(_ choice: String, selected: Bool, multi: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.inputRadius == 999 ? 14 : theme.inputRadius,
                                     style: .continuous)
        return HStack(spacing: 10) {
            if multi {
                // A square mark for multi-select — this is a checkbox, and the
                // agent accepts any number of them.
                RoundedRectangle(cornerRadius: theme.id == .soft ? 5 : 2)
                    .fill(selected ? theme.accent : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: theme.id == .soft ? 5 : 2)
                        .strokeBorder(selected ? theme.accent : theme.lineStrong, lineWidth: 1.5))
                    .frame(width: 18, height: 18)
            }
            Text(choice)
                .font(theme.id == .soft ? theme.body(14) : theme.id == .control
                      ? theme.body(13.5) : theme.body(16))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !multi {
                Text(verbatim: theme.id == .ink ? "→" : "›")
                    .font(theme.mono(theme.id == .ink ? 11 : 13))
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(selected && multi ? theme.accent.opacity(0.1) : theme.inset)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected && multi ? theme.accent.opacity(0.6) : theme.line,
                                    lineWidth: 1))
        .contentShape(shape)
    }

    private func toggle(_ choice: String) {
        if let index = selections.firstIndex(of: choice) {
            selections.remove(at: index)
        } else {
            selections.append(choice)
        }
    }

    // MARK: Entry

    @ViewBuilder private func entryField(_ prompt: BlockingPrompt) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.inputRadius == 999 ? 14 : theme.inputRadius,
                                     style: .continuous)
        Group {
            if prompt.isSecret {
                SecureField(copy.promptPlaceholder(prompt.kind, theme.id), text: $text)
            } else {
                TextField(copy.promptPlaceholder(prompt.kind, theme.id), text: $text, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .font(theme.id == .control ? theme.mono(13) : theme.body(theme.id == .ink ? 16 : 14.5))
        .foregroundStyle(theme.ink)
        .focused($fieldFocused)
        .textFieldStyle(.plain)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(theme.inset)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.line, lineWidth: 1))
        .modifier(SecureEntryTraits(secret: prompt.isSecret))
    }

    // MARK: Actions

    private func actions(_ prompt: BlockingPrompt) -> some View {
        HStack(spacing: 8) {
            // On a single-select question the choices *are* the answer, so
            // there is nothing for a submit button to do.
            if !isSingleChoice(prompt) {
                ThemedPrimaryButton(theme: theme, title: copy.promptSubmit(prompt.kind, theme.id)) {
                    submit(prompt)
                }
                .opacity(canSubmit(prompt) ? 1 : 0.45)
                .disabled(!canSubmit(prompt))
            }
            ThemedSecondaryButton(theme: theme, title: copy.promptRefuse(prompt.kind, theme.id),
                                  fillsWidth: true) {
                // Empty answer — the protocol's refusal. The run continues.
                model.answerBlockingPrompt(prompt, answer: "")
            }
        }
    }

    private func isSingleChoice(_ prompt: BlockingPrompt) -> Bool {
        prompt.kind == .clarify && !prompt.choices.isEmpty && !prompt.multiSelect
    }

    private func canSubmit(_ prompt: BlockingPrompt) -> Bool {
        if prompt.kind == .clarify && !prompt.choices.isEmpty {
            return prompt.multiSelect && !selections.isEmpty
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(_ prompt: BlockingPrompt) {
        if prompt.kind == .clarify && !prompt.choices.isEmpty {
            guard prompt.multiSelect, !selections.isEmpty else { return }
            model.answerBlockingPrompt(prompt, selections: selections)
            return
        }
        // Passwords keep their surrounding whitespace; free text does not.
        let answer = prompt.isSecret ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        model.answerBlockingPrompt(prompt, answer: answer)
    }

    // MARK: Chrome

    @ViewBuilder private func promptChrome(_ prompt: BlockingPrompt) -> some View {
        let tint = prompt.isSecret ? theme.danger : theme.accent
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.16), radius: 22, y: 10)
        case .control:
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1))
                .shadow(color: tint.opacity(0.22), radius: 16)
        case .ink:
            Rectangle()
                .fill(theme.panel)
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.5), lineWidth: 1))
                .overlay(Rectangle().inset(by: -4).stroke(theme.ink.opacity(0.4), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.2), radius: 18, y: 8)
        }
    }

    private var botFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    private var questionFont: Font {
        switch theme.id {
        case .soft: theme.body(15.5, weight: .semibold)
        case .control: theme.body(14.5, weight: .semibold)
        case .ink: theme.body(18)
        }
    }
}

/// Credential fields must never be autocorrected, capitalized, or offered to
/// QuickType. iOS-only traits; macOS gets the plain secure field.
private struct SecureEntryTraits: ViewModifier {
    let secret: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .textContentType(secret ? .password : nil)
            .submitLabel(.send)
        #else
        content.autocorrectionDisabled(true)
        #endif
    }
}

// MARK: - Shared chrome

/// 45° hazard bands across the top of a control-theme card (the design's
/// repeating-linear-gradient stripe). File-scoped to this component pair.
struct InlineHazardStripes: View {
    let color: Color
    let background: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            let stripe: CGFloat = 8
            var x = -size.height - stripe * 2
            while x < size.width + stripe * 2 {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + stripe, y: size.height))
                path.addLine(to: CGPoint(x: x + stripe + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.closeSubpath()
                context.fill(path, with: .color(color))
                x += stripe * 2
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

import SwiftUI
import TalariaKit
import TalariaTheme

// Approvals — Approvals / Holds / The Seals. The kicker counts pending items
// in the theme's voice ("2 pending" / "2 HOLDS PENDING" / "TWO AWAIT YOUR
// HAND", empty "all clear" / "ALL CLEAR" / "ALL IS SEALED"). Cards swipe:
// drag right to approve once, left to deny — the card translates and slightly
// rotates, the matching affordance fades in past 24pt, and ≥90pt commits.
// Decided cards linger dimmed with the themed done-word ("Approved — sent" /
// "RELEASED — RAN CLEAN" / "sealed — done cleanly") before animating out.
// Ported from Talaria.dc.html `data-screen-label="Approvals"`.
//
// The buttons are driven by the request's own `choices` array
// (ws-protocol.md §8), not a hardcoded approve/deny: the gateway derives
// once / session / always / deny per request, drops "always" when the pattern
// cannot be permanently allowed, and reduces to once/deny for a pattern it has
// already refused (smart_denied). Swipe stays the fast path for the two
// choices that are always present; the broader grants are explicit taps.

public struct ApprovalsView: View {
    private let model: AppModel

    /// Local mirror of `model.approvals` that keeps just-decided cards on
    /// screen (dimmed, showing the done-word) before they animate out. The
    /// model itself resolves immediately so badges, chats and live RPCs stay
    /// in sync.
    @State private var rows: [Approval] = []
    /// id → the choice it was answered with. Present while a decided card is
    /// still lingering.
    @State private var decisions: [String: ApprovalChoice] = [:]

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private var pendingCount: Int {
        rows.filter { decisions[$0.id] == nil }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, approval in
                        ApprovalCard(approval: approval,
                                     bot: model.bot(approval.botID),
                                     choices: model.approvalChoices(for: approval.id),
                                     smartDenied: model.approvalDetail(approval.id)?.smartDenied ?? false,
                                     decision: decisions[approval.id],
                                     theme: theme, copy: copy,
                                     decide: { choice in decide(approval, choice: choice) })
                            // sealMargin — breathing room for ink's double rule.
                            .padding(theme.id == .ink ? 4 : 0)
                            .modifier(RowEntrance(delay: Double(index) * 0.06))
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .onAppear {
            syncRows()
            // Approvals raised while the app was backgrounded never re-emit
            // their event; approval.pending is the only way to see them. Opening
            // this tab is a direct request to be up to date.
            model.attachApprovalBridges()
            Task { await model.replayPendingApprovals(force: true) }
        }
        .onChange(of: model.approvals) { syncRows() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Unlike other kickers this one shows in every theme (soft
            // included) — it is the pending count, warn-colored.
            Text(pendingLabel)
                .font(theme.mono(theme.id == .ink ? 9 : 9.5, weight: .semibold))
                .tracking(theme.id == .control ? 2.5 : 2)
                .foregroundStyle(theme.warn)
                .padding(.bottom, theme.id == .control ? 3 : 1)
            Text(copy.titleApprovals)
                .font(titleFont)
                .tracking(theme.smallCapsTitles ? 0.5 : -0.5)
                .foregroundStyle(theme.ink)
            Text(verbatim: "\(copy.approvalsLead) \(copy.approvalsSwipeHint(theme.id))")
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

    /// "2 pending" / "2 HOLDS PENDING" / "TWO AWAIT YOUR HAND"; empty state
    /// "all clear" / "ALL CLEAR" / "ALL IS SEALED".
    private var pendingLabel: String {
        let n = pendingCount
        switch theme.id {
        case .soft:
            return n > 0 ? "\(n) pending" : "all clear"
        case .control:
            return n > 0 ? "\(n) HOLDS PENDING" : "ALL CLEAR"
        case .ink:
            guard n > 0 else { return "ALL IS SEALED" }
            let words = ["NONE", "ONE", "TWO", "THREE", "FOUR", "FIVE"]
            let word = n < words.count ? words[n] : String(n)
            return "\(word) AWAIT YOUR HAND"
        }
    }

    // MARK: Decide / sync

    private func decide(_ approval: Approval, choice: ApprovalChoice) {
        guard decisions[approval.id] == nil else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            decisions[approval.id] = choice
        }
        // Resolve in the model immediately (tab badge, chat follow-up, live
        // RPC); the local row lingers so the done-word can land first. Going
        // through ApprovalOutcomes shares the exact outcome with the inline
        // chat card and push banner.
        ApprovalOutcomes.shared.resolve(approval, choice: choice, in: model)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 0.35)) {
                rows.removeAll { $0.id == approval.id }
                decisions.removeValue(forKey: approval.id)
            }
            // A failed approval.respond puts the card back in the model — the
            // agent is still parked and the user must be able to retry. Resync
            // rather than trust the local removal.
            syncRows()
        }
    }

    private func syncRows() {
        var next = model.approvals
        // Keep locally-decided cards in place until their exit runs; rows
        // resolved elsewhere (push banner, inline chat card) just vanish.
        for (index, row) in rows.enumerated()
        where decisions[row.id] != nil && !next.contains(where: { $0.id == row.id }) {
            next.insert(row, at: min(index, next.count))
        }
        if next != rows { rows = next }
    }
}

// MARK: - Card

private struct ApprovalCard: View {
    let approval: Approval
    let bot: Bot?
    /// The gateway's derived choice set for this request.
    let choices: [ApprovalChoice]
    /// This pattern was refused before, so only once/deny is on offer.
    let smartDenied: Bool
    /// nil = pending; otherwise the choice it was answered with (lingering).
    let decision: ApprovalChoice?
    let theme: ThemePack
    let copy: CopyPack
    let decide: (ApprovalChoice) -> Void

    @State private var dragX: CGFloat = 0

    private var pending: Bool { decision == nil }
    private var approved: Bool { decision != nil && decision != .deny }
    private var botColor: Color { theme.color(for: bot?.hue ?? .teal) }

    private var tagColor: Color {
        pending ? (theme.id == .control ? theme.warn : theme.danger) : theme.faint
    }

    /// apBorderOn / apBorderOff, per theme.
    private var borderColor: Color {
        switch theme.id {
        case .soft: pending ? theme.danger.opacity(0.35) : theme.ink.opacity(0.08)
        case .control: pending ? theme.warn.opacity(0.35) : theme.line
        case .ink: pending ? theme.accent.opacity(0.65) : theme.ink.opacity(0.3)
        }
    }

    private var doneColor: Color { approved ? theme.ok : theme.danger }

    // Affordances fade in past 24pt of drag, saturating at 90pt.
    private var approveOpacity: Double {
        dragX > 24 ? min(1, (dragX - 24) / 66) : 0
    }
    private var denyOpacity: Double {
        dragX < -24 ? min(1, (-dragX - 24) / 66) : 0
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if theme.id == .control && pending {
                hazardStripe
            }
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(borderColor, lineWidth: 1))
        .overlay {
            if theme.id == .ink {
                // The seal's double rule: a hairline floating 4pt outside.
                Rectangle().inset(by: -4)
                    .stroke(theme.ink.opacity(0.45), lineWidth: 1)
            }
        }
        .shadow(color: theme.id == .soft ? theme.ink.opacity(0.06) : .clear, radius: 7, y: 4)
        .overlay(alignment: .topLeading) {
            affordance(copy.approve, primary: true)
                .opacity(approveOpacity)
                .padding(.top, 10).padding(.leading, 12)
        }
        .overlay(alignment: .topTrailing) {
            affordance(copy.deny, primary: false)
                .opacity(denyOpacity)
                .padding(.top, 10).padding(.trailing, 12)
        }
        .opacity(pending ? 1 : 0.68)
        .offset(x: dragX)
        .rotationEffect(.degrees(dragX * 0.02))
        .gesture(swipe)
    }

    // MARK: Anatomy

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            targetLine
                .padding(.top, 4)
            subject
                .padding(.top, 9)
            quote
                .padding(.top, 6)
            whyAndAge
                .padding(.top, 7)
            if pending && smartDenied {
                Text(copy.approvalSmartDenied(theme.id))
                    .font(theme.mono(theme.id == .ink ? 8 : 9))
                    .tracking(theme.id == .soft ? 0.5 : 1.2)
                    .foregroundStyle(theme.danger.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            if pending {
                ApprovalChoiceButtons(theme: theme, copy: copy, choices: choices,
                                      decide: decide)
                    .padding(.top, 11)
            } else {
                doneRow.padding(.top, 11)
            }
        }
    }

    /// Avatar + bot name, kind tag, title.
    private var head: some View {
        HStack(alignment: .center, spacing: 10) {
            AvatarView(shape: bot?.shape ?? .circle, hue: bot?.hue ?? .teal,
                       size: 34, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TalariaVoice.displayName(bot, id: approval.botID, theme.id))
                        .font(nameFont)
                        .foregroundStyle(botColor)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        if pending {
                            PulsingDot(color: tagColor, size: 7)
                        }
                        Text(copy.tag)
                            .font(tagFont)
                            .tracking(tagTracking)
                            .foregroundStyle(tagColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                Text(approval.title)
                    .font(apTitleFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
            }
        }
    }

    /// "to sarah.chen@…" / "→ …" / "unto …" (copy.unto separator).
    private var targetLine: some View {
        Text(verbatim: "\(copy.unto) \(approval.target)")
            .font(metaFont)
            .foregroundStyle(metaColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Subject line — mono for shell commands.
    private var subject: some View {
        Text(approval.subject)
            .font(approval.kind == .command ? subjectCmdFont : subjectFont)
            .foregroundStyle(subjectColor)
    }

    @ViewBuilder private var quote: some View {
        switch theme.id {
        case .soft:
            Text(approval.body)
                .font(theme.body(13))
                .foregroundStyle(theme.ink.opacity(0.7))
                .lineSpacing(2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .background(theme.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .control:
            Text(approval.body)
                .font(theme.body(12.5))
                .foregroundStyle(theme.ink.opacity(0.7))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .background(theme.inset)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            Text(approval.body)
                .font(theme.body(14.5))
                .italic()
                .foregroundStyle(theme.ink.opacity(0.8))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    theme.ink.opacity(0.25).frame(width: 2)
                }
        }
    }

    /// Why line, with the age trailing ("12m ago" / "12m past" in ink, or the
    /// themed "waiting" for a request recovered by the reconnect replay).
    private var whyAndAge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(theme.id == .soft ? approval.why : approval.why.uppercased())
                .font(whyFont)
                .tracking(theme.id == .soft ? 0 : (theme.id == .ink ? 1.5 : 0.5))
                .foregroundStyle(theme.faint)
            Spacer(minLength: 6)
            Text(copy.approvalAge(approval.age, theme.id))
                .font(timeFont)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
        }
    }

    // MARK: Done

    private var doneRow: some View {
        HStack(spacing: 9) {
            if theme.id == .ink {
                WaxSealDot(color: doneColor, ring: theme.panel, size: 14, pulsing: false)
            }
            Text(copy.approvalDone(kind: approval.kind, choice: decision ?? .once, theme.id))
                .tracking(theme.id == .soft ? 0 : 1)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(doneFont)
        .foregroundStyle(doneColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(doneBackground)
        .clipShape(buttonShape)
        .overlay {
            if theme.id == .ink {
                buttonShape.strokeBorder(doneColor, lineWidth: 1)
            }
        }
    }

    /// The ghost approve/deny chips that fade in while dragging.
    @ViewBuilder private func affordance(_ text: String, primary: Bool) -> some View {
        Group {
            if primary {
                primaryLabel(text)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(primaryBackground)
                    .clipShape(buttonShape)
            } else {
                secondaryLabel(text)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(secondaryBackground)
                    .clipShape(buttonShape)
                    .overlay(buttonShape.strokeBorder(secondaryBorder, lineWidth: 1))
            }
        }
        .allowsHitTesting(false)
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(buttonFont)
            .tracking(buttonTracking)
            .foregroundStyle(theme.id == .ink ? theme.bg : theme.accentFg)
            .lineLimit(1)
    }

    private func secondaryLabel(_ text: String) -> some View {
        Text(text)
            .font(buttonFont)
            .tracking(buttonTracking)
            .foregroundStyle(secondaryForeground)
            .lineLimit(1)
    }

    // MARK: Swipe

    /// The fast path covers the two choices every request offers. Session and
    /// always are deliberately tap-only — a gesture should not hand a bot a
    /// standing permission.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard pending else { return }
                // Horizontal intent only; vertical drags stay with the scroll.
                guard dragX != 0 ||
                        abs(value.translation.width) > abs(value.translation.height)
                else { return }
                dragX = value.translation.width
            }
            .onEnded { _ in
                guard pending else { return }
                if abs(dragX) >= 90 {
                    decide(dragX > 0 ? .once : .deny)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    dragX = 0
                }
            }
    }

    // MARK: Chrome bits

    /// Control's hazard stripe (stripeOn/stripeH): repeating 45° warn bands.
    private var hazardStripe: some View {
        DiagonalStripes(stripeWidth: 8)
            .fill(theme.warn)
            .background(theme.panel)
            .frame(height: 5)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
    }

    private var primaryBackground: Color {
        theme.id == .ink ? theme.ink : theme.accent
    }

    private var secondaryBackground: Color {
        theme.id == .soft ? theme.ink.opacity(0.05) : .clear
    }

    private var secondaryBorder: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.danger.opacity(0.4)
        case .ink: theme.accent.opacity(0.6)
        }
    }

    private var secondaryForeground: Color {
        switch theme.id {
        case .soft: theme.ink
        case .control: theme.danger
        case .ink: theme.accent
        }
    }

    // MARK: Fonts & colors

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    private var tagFont: Font {
        switch theme.id {
        case .soft: theme.mono(10, weight: .heavy)
        case .control: theme.mono(9.5, weight: .bold)
        case .ink: theme.mono(8.5, weight: .semibold)
        }
    }

    private var tagTracking: CGFloat {
        switch theme.id {
        case .soft: 1
        case .control: 1.8
        case .ink: 2
        }
    }

    private var apTitleFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(14, weight: .bold)
        case .ink: theme.body(17, weight: .bold)
        }
    }

    private var metaFont: Font {
        switch theme.id {
        case .soft: theme.body(11)
        case .control: theme.mono(9.5)
        case .ink: theme.mono(8.5)
        }
    }

    private var metaColor: Color {
        theme.id == .soft ? theme.ink.opacity(0.45) : theme.sub
    }

    private var subjectFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .bold)
        case .control: theme.body(13, weight: .semibold)
        case .ink: theme.body(17, weight: .semibold)
        }
    }

    private var subjectCmdFont: Font {
        theme.mono(theme.id == .soft ? 12.5 : 12, weight: .semibold)
    }

    private var subjectColor: Color {
        // Control renders subjects warn-tinted (the design's #FFD9A8 amber).
        theme.id == .control ? theme.warn : theme.ink
    }

    private var whyFont: Font {
        switch theme.id {
        case .soft: theme.body(11)
        case .control: theme.mono(9)
        case .ink: theme.mono(8)
        }
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    private var buttonFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5, weight: .bold)
        case .control: theme.mono(11, weight: .bold)
        case .ink: theme.body(15, weight: .bold).smallCaps()
        }
    }

    private var buttonTracking: CGFloat {
        switch theme.id {
        case .soft: 0
        case .control: 1.5
        case .ink: 1.5
        }
    }

    private var doneFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(14.5, weight: .bold).smallCaps()
        }
    }

    private var doneBackground: Color {
        switch theme.id {
        case .soft: approved ? theme.ok.opacity(0.1) : theme.danger.opacity(0.08)
        case .control: approved ? theme.ok.opacity(0.08) : theme.danger.opacity(0.08)
        case .ink: .clear
        }
    }
}

// MARK: - Shared row helpers (file-scoped copies; each screen file keeps its own)

/// The pulsing status dot beside the kind tag (the design's glowU animation).
private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Ink's wax-seal dot: a solid disc with an inset panel-colored ring.
private struct WaxSealDot: View {
    let color: Color
    let ring: Color
    let size: CGFloat
    var pulsing: Bool = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().inset(by: size * 0.16).stroke(ring, lineWidth: size * 0.1))
            .frame(width: size, height: size)
            .opacity(pulsing && dim ? 0.45 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { if pulsing { dim = true } }
    }
}

/// 45° hazard bands (the design's repeating-linear-gradient stripeOn).
private struct DiagonalStripes: Shape {
    var stripeWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period = stripeWidth * 2
        var x = rect.minX - rect.height - period
        while x < rect.maxX + period {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.closeSubpath()
            x += period
        }
        return path
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

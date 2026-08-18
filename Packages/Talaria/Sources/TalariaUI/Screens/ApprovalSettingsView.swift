import SwiftUI
import TalariaKit
import TalariaTheme

// Approvals → policy. Roadmap Phase 3.3: the rules behind the prompt, not the
// prompt itself.
//
// Talaria could always *answer* an approval. What it could not do was change
// what asks, how long it waits, or take back a grant — and "always" is granted
// from a phone, in a hurry, often from a lock screen. A client that can hand
// out a permanent permission and cannot take it back is not finished.
//
// Five sections, each of which disappears whole when the gateway cannot serve
// it (an older gateway has no `approvals.mode` RPC; one without the dashboard
// routes has no config REST):
//
//   Mode      — manual / smart / off, persisted gateway-wide.
//   Bypass    — what is currently skipping approvals, and how to stop it.
//               This is where the global-vs-session YOLO distinction gets said
//               out loud instead of being folded into one ambiguous switch.
//   Wait      — approvals.timeout: how long a parked agent waits for you.
//   Always    — the permanent allowlist, with revoke.
//   Pairing   — who may DM your bots (pushes PairingView).
//
// The model layer, the RPC shapes and the upstream citations are in
// AppModelLive+ApprovalPolicy.swift; this file is only the surface.

public struct ApprovalSettingsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @State private var showsPairing = false
    /// The allowlist entry a confirm dialog is currently asking about.
    @State private var revoking: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }
    private var store: ApprovalPolicyStore { model.approvalPolicy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    /// Every section is gated on a probe, so it is possible for a gateway to
    /// support none of them. Saying so once beats five silent absences.
    private var hasAnySurface: Bool {
        store.modeSupport == .supported || store.configSupport == .supported
            || store.pairingSupport == .supported
    }

    public var body: some View {
        ZStack {
            content
            if showsPairing {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    PairingView(model: model) {
                        withAnimation(pushAnimation) { showsPairing = false }
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            await model.loadApprovalPolicy()
            // The pairing probe decides whether the row below exists at all, so
            // it runs here rather than waiting for the screen it opens.
            await model.loadPairing()
        }
        .confirmationDialog(copy.policyRevokeTitle(themeID),
                            isPresented: Binding(get: { revoking != nil },
                                                 set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            if let pattern = revoking {
                Button(copy.policyRevoke(themeID), role: .destructive) {
                    revoking = nil
                    Task { await model.revokeAlwaysAllowed(pattern) }
                }
            }
            Button(copy.cancel, role: .cancel) { revoking = nil }
        } message: {
            Text(copy.policyRevokeConfirm(themeID, pattern: revoking ?? ""))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let notice = store.notice {
                        noticeCard(notice)
                    }
                    if store.hasLoaded, store.hasLoadedPairing, !hasAnySurface {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(copy.policyUnavailable(themeID))
                                .font(themeID == .control ? theme.mono(11) : theme.body(13))
                                .italic(themeID == .ink)
                                .foregroundStyle(theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            GatewayFootnote(theme: theme,
                                            text: copy.policyUnavailableNote(themeID))
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 10)
                    }

                    if store.modeSupport == .supported {
                        modeSection
                            .settingsEntrance(delay: 0, reduced: reducedMotion)
                    }
                    if showsBypassSection {
                        bypassSection
                            .settingsEntrance(delay: 0.04, reduced: reducedMotion)
                    }
                    if store.configSupport == .supported {
                        waitSection
                            .settingsEntrance(delay: 0.08, reduced: reducedMotion)
                        allowlistSection
                            .settingsEntrance(delay: 0.12, reduced: reducedMotion)
                    }
                    if store.pairingSupport == .supported {
                        pairingSection
                            .settingsEntrance(delay: 0.16, reduced: reducedMotion)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(themeID == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(themeID == .ink ? Color.clear : theme.panel)
                    .clipShape(backShape)
                    .overlay(backShape.strokeBorder(
                        themeID == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copy.settingsBack(themeID)))

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.policyKicker(themeID))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(themeID == .ink ? theme.sub : theme.accent)
                        .lineLimit(1)
                }
                Text(copy.policyTitle(themeID))
                    .font(titleFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else {
                HeaderIconButton(theme: theme, size: 31, action: {
                    Task {
                        await model.loadApprovalPolicy()
                        await model.loadPairing()
                    }
                }) {
                    Text(verbatim: "⟳")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(themeID == .ink ? theme.ink : theme.accent)
                }
                .accessibilityLabel(Text(copy.policyRefresh(themeID)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var backShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var titleFont: Font {
        switch themeID {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        SettingsSection(theme: theme,
                        title: copy.policyModeSec(themeID),
                        footnote: copy.policyModeNote(themeID)) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSegmented(theme: theme,
                                  options: ApprovalMode.allCases.map {
                                      (value: $0, label: copy.policyModeLabel($0, themeID))
                                  },
                                  selection: store.mode) { picked in
                    Task { await model.setApprovalMode(picked) }
                }
                .opacity(store.isBusy("mode") ? 0.55 : 1)
                .disabled(store.isBusy("mode"))

                Text(copy.policyModeExplain(store.mode, themeID))
                    .font(SettingsType.rowSubtitle(theme))
                    .italic(themeID == .ink)
                    .foregroundStyle(store.mode == .off ? theme.warn
                                     : (themeID == .control ? theme.faint : theme.sub))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Bypass

    /// Only worth a section when something is actually being skipped. In the
    /// ordinary case — manual or smart, no session flags — there is nothing to
    /// say and a permanently visible "nothing is bypassing" row would train the
    /// eye to ignore the one time it matters.
    private var showsBypassSection: Bool {
        model.globalApprovalBypass || !model.sessionBypassBots.isEmpty
    }

    private var bypassSection: some View {
        SettingsSection(theme: theme,
                        title: copy.policyBypassSec(themeID),
                        footnote: copy.policyBypassNote(themeID)) {
            SettingsGroup(theme: theme) {
                if model.globalApprovalBypass {
                    // The state is worth naming even on a gateway that cannot
                    // be told to stop — but the verb is only offered where the
                    // RPC exists, because a button that always fails is worse
                    // than no button on a screen about safety.
                    let canRestore = store.modeSupport == .supported
                    SettingsRow(theme: theme,
                                title: copy.policyGlobalBypass(themeID),
                                subtitle: copy.policyGlobalBypassNote(themeID),
                                value: copy.policyOnValue(themeID),
                                valueTone: theme.warn,
                                isLast: !canRestore)
                    if canRestore {
                        SettingsActionRow(theme: theme,
                                          title: copy.policyRestore(themeID),
                                          subtitle: copy.policyRestoreNote(themeID),
                                          isBusy: store.isBusy("mode"),
                                          isLast: true) {
                            Task { await model.setApprovalMode(.manual) }
                        }
                    }
                } else {
                    // Not destructive: clearing a bypass is the safe direction,
                    // and a red bot name would read as an accusation.
                    let rows = model.sessionBypassBots
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, bot in
                        SettingsActionRow(theme: theme,
                                          title: TalariaVoice.displayName(for: bot, themeID),
                                          subtitle: copy.policySessionBypassNote(themeID),
                                          isLast: index == rows.count - 1) {
                            model.clearSessionBypass(botID: bot.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: Wait

    /// Standard offers plus whatever the gateway actually has, so a config
    /// hand-edited to 45 s is shown as 45 s rather than silently rounded into
    /// one of ours the moment the picker renders.
    private var waitOptions: [Int] {
        let standard = [60, 300, 900, 3600]
        let current = store.config.timeoutSeconds
        return standard.contains(current) ? standard : (standard + [current]).sorted()
    }

    private var waitSection: some View {
        SettingsSection(theme: theme,
                        title: copy.policyWaitSec(themeID),
                        footnote: copy.policyWaitNote(themeID)) {
            SettingsSegmented(theme: theme,
                              options: waitOptions.map {
                                  (value: $0, label: copy.policyWaitLabel($0, themeID))
                              },
                              selection: store.config.timeoutSeconds) { picked in
                Task { await model.setApprovalTimeout(picked) }
            }
            .opacity(store.isBusy("timeout") ? 0.55 : 1)
            .disabled(store.isBusy("timeout"))
        }
    }

    // MARK: Always allowed

    private var allowlistSection: some View {
        SettingsSection(theme: theme,
                        title: copy.policyAllowSec(themeID),
                        footnote: store.config.allowlist.isEmpty ? nil
                                                                 : copy.policyAllowNote(themeID)) {
            SettingsGroup(theme: theme) {
                if store.config.allowlist.isEmpty {
                    SettingsRow(theme: theme,
                                title: copy.policyAllowEmpty(themeID),
                                subtitle: copy.policyAllowEmptyNote(themeID),
                                isLast: true)
                } else {
                    let rows = store.config.allowlist.sorted {
                        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    }
                    ForEach(Array(rows.enumerated()), id: \.element) { index, pattern in
                        AllowlistRow(theme: theme,
                                     pattern: pattern,
                                     revokeLabel: copy.policyRevoke(themeID),
                                     isBusy: store.isBusy("allow:" + pattern),
                                     isLast: index == rows.count - 1) {
                            revoking = pattern
                        }
                    }
                }
            }
        }
    }

    // MARK: Pairing

    private var pairingSection: some View {
        SettingsSection(theme: theme,
                        title: copy.policyPairSec(themeID),
                        footnote: copy.policyPairNote(themeID)) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme,
                            title: copy.policyPairRow(themeID),
                            subtitle: copy.policyPairRowNote(themeID),
                            value: pendingBadge,
                            valueTone: pendingBadge == nil ? nil : theme.warn,
                            showsChevron: true,
                            isLast: true) {
                    withAnimation(pushAnimation) { showsPairing = true }
                }
            }
        }
    }

    /// The one pre-open signal that a stranger is blocked at the door.
    private var pendingBadge: String? {
        let waiting = store.pairing.pending.count
        guard waiting > 0 else { return nil }
        return copy.policyPairWaiting(waiting, themeID)
    }

    // MARK: Chrome

    private func noticeCard(_ text: String) -> some View {
        Text(text)
            .font(themeID == .control ? theme.mono(10.5) : theme.body(12.5))
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(theme.danger.opacity(0.45), lineWidth: 1))
    }

    private var pushAnimation: Animation {
        reducedMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }
}

// MARK: - Allowlist row

/// One permanent grant: the pattern in mono (it is command text and must be
/// read exactly, wrapping rather than truncating), and the verb that takes it
/// back.
private struct AllowlistRow: View {
    let theme: ThemePack
    let pattern: String
    let revokeLabel: String
    let isBusy: Bool
    let isLast: Bool
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(pattern)
                .font(theme.mono(theme.id == .ink ? 11 : 11.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else {
                Button(action: revoke) {
                    Text(revokeLabel)
                        .font(theme.id == .control ? theme.mono(9.5, weight: .bold)
                                                   : theme.body(12, weight: .semibold))
                        .tracking(theme.id == .soft ? 0 : 1)
                        .foregroundStyle(theme.danger)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presentation

/// Hosts the approval-policy screen for whoever owns the screen graph. Mount it
/// beside the Settings presenter:
///
///     TalariaRootView(model: model)
///         .talariaSettings(model: model)
///         .talariaApprovalPolicy(model: model)
///
/// It listens for `AppModel.requestApprovalPolicy()`, so the Approvals tab, the
/// bot sheet and the command palette only have to call that.
public struct TalariaApprovalPolicyPresenter: ViewModifier {
    private let model: AppModel

    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel) { self.model = model }

    private var pushAnimation: Animation {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
            ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        model.theme.pack.bg.ignoresSafeArea()
                        ApprovalSettingsView(model: model) {
                            withAnimation(pushAnimation) { isPresented = false }
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(14)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenApprovalPolicy)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onChange(of: isPresented) { _, presented in
                // The pairing watch is a live subscription; it exists only while
                // somebody is looking at it.
                if presented { model.attachPairingWatch() } else { model.detachPairingWatch() }
            }
            .onChange(of: model.showOnboarding) { _, showing in
                if showing, isPresented { isPresented = false }
            }
    }
}

public extension View {
    /// Mount the approval-policy screen on this view tree.
    func talariaApprovalPolicy(model: AppModel) -> some View {
        modifier(TalariaApprovalPolicyPresenter(model: model))
    }
}

// MARK: - Copy

extension CopyPack {

    func policyKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TALARIA // POLICY"
        case .control: "APPROVAL POLICY"
        case .ink: "THE LAW OF SEALS"
        }
    }

    func policyTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approval rules"
        case .control: "HOLD POLICY"
        case .ink: "The Standing Order"
        }
    }

    func policyRefresh(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Refresh"
        case .control: "RE-READ"
        case .ink: "read again"
        }
    }

    /// Lead for a gateway error on this screen; the message follows it.
    func policyNoticeLead(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused that"
        case .control: "GATEWAY REFUSED"
        case .ink: "The gateway would not have it"
        }
    }

    func policyUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway has no approval settings"
        case .control: "NO POLICY SURFACE ON THIS GATEWAY"
        case .ink: "this gateway keeps no standing order"
        }
    }

    func policyUnavailableNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approvals still work — you just cannot change the rules from here. Upgrade the gateway, or edit config.yaml where it runs."
        case .control: "APPROVALS STILL FUNCTION. RULE EDITING REQUIRES A NEWER GATEWAY OR HOST-SIDE CONFIG.YAML."
        case .ink: "The seals are still asked of you; only the law is written elsewhere — in config.yaml, where the gateway itself runs."
        }
    }

    // MARK: Mode

    func policyModeSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What asks you"
        case .control: "APPROVAL MODE"
        case .ink: "WHAT IS BROUGHT BEFORE YOU"
        }
    }

    func policyModeLabel(_ mode: ApprovalMode, _ t: ThemeID) -> String {
        switch (mode, t) {
        case (.manual, .soft): "Ask me"
        case (.manual, .control): "MANUAL"
        case (.manual, .ink): "ask"
        case (.smart, .soft): "Smart"
        case (.smart, .control): "SMART"
        case (.smart, .ink): "judged"
        case (.off, .soft): "Never ask"
        case (.off, .control): "OFF"
        case (.off, .ink): "unchained"
        }
    }

    func policyModeExplain(_ mode: ApprovalMode, _ t: ThemeID) -> String {
        switch (mode, t) {
        case (.manual, .soft):
            "Every dangerous command waits for you. Safest, and the noisiest."
        case (.manual, .control):
            "ALL FLAGGED COMMANDS BLOCK PENDING OPERATOR RELEASE."
        case (.manual, .ink):
            "Every perilous deed is brought to your hand and waits there."
        case (.smart, .soft):
            "A second model triages first: obviously safe runs, genuinely dangerous is blocked outright, anything it is unsure about still comes to you."
        case (.smart, .control):
            "AUX MODEL TRIAGES: SAFE → RUN · DANGEROUS → BLOCKED · UNCERTAIN → OPERATOR."
        case (.smart, .ink):
            "A second mind reads first — the harmless it lets pass, the truly perilous it refuses outright, and what it cannot judge it brings to you."
        case (.off, .soft):
            "Nothing asks. Every bot, the CLI and every scheduled run act without you until you turn this back on."
        case (.off, .control):
            "NO PROMPTS. APPLIES TO EVERY SESSION, THE CLI AND CRON UNTIL REVERTED."
        case (.off, .ink):
            "Nothing is brought before you. Every familiar, and every rite kept by the clock, acts unbidden."
        }
    }

    func policyModeNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved on the gateway, so it survives restarts and applies to every bot, the CLI and scheduled runs alike. The YOLO switch in a chat is a different thing: it lasts only for that one session."
        case .control: "PERSISTED GATEWAY-SIDE (APPROVALS.MODE). SCOPE: ALL SESSIONS + CLI + CRON. THE PER-CHAT YOLO TOGGLE IS SESSION-SCOPED AND DOES NOT PERSIST."
        case .ink: "Written at the gateway and kept through its sleeping, binding every familiar, the plain command line and the rites of the clock. The unchaining you set within a single audience is another matter, and dies with it."
        }
    }

    // MARK: Bypass

    func policyBypassSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Skipping approvals right now"
        case .control: "ACTIVE BYPASS"
        case .ink: "WHAT GOES UNSEALED"
        }
    }

    func policyBypassNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Covers the gateway-wide switch and the chats this phone has open. A bypass that will not switch off here was set with the gateway's own --yolo flag, which only the machine running it can clear."
        case .control: "SCOPE: THE GATEWAY-WIDE SWITCH + SESSIONS BOUND ON THIS DEVICE. A BYPASS THAT WILL NOT CLEAR HERE WAS SET VIA THE PROCESS --YOLO FLAG — HOST-SIDE ONLY."
        case .ink: "This counts the gateway's own standing order and the audiences this device holds open. An unchaining that refuses your hand was granted at the gateway's starting, and only there can it be undone."
        }
    }

    func policyGlobalBypass(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approvals are off everywhere"
        case .control: "GLOBAL BYPASS"
        case .ink: "every familiar goes unchained"
        }
    }

    func policyGlobalBypassNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Every bot, the CLI and every scheduled run act without asking."
        case .control: "ALL SESSIONS + CLI + CRON ACT WITHOUT PROMPTING."
        case .ink: "Every familiar, the plain command and the rites alike act unbidden."
        }
    }

    func policyOnValue(_ t: ThemeID) -> String {
        switch t {
        case .soft: "ON"
        case .control: "ACTIVE"
        case .ink: "in force"
        }
    }

    func policyRestore(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Turn approvals back on"
        case .control: "RESTORE MANUAL GATE"
        case .ink: "bind them again"
        }
    }

    func policyRestoreNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sets the mode back to “Ask me”."
        case .control: "SETS APPROVALS.MODE = MANUAL."
        case .ink: "Returns the standing order to asking."
        }
    }

    func policySessionBypassNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "YOLO is on for this chat — tap to switch it off"
        case .control: "SESSION YOLO ACTIVE — TAP TO CLEAR"
        case .ink: "unchained for this audience — touch to bind"
        }
    }

    // MARK: Wait

    func policyWaitSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "How long it waits for you"
        case .control: "HOLD TIMEOUT"
        case .ink: "HOW LONG IT WAITS"
        }
    }

    func policyWaitLabel(_ seconds: Int, _ t: ThemeID) -> String {
        let minutes = seconds / 60
        switch t {
        case .soft:
            if seconds < 60 { return "\(seconds)s" }
            return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes) min"
        case .control:
            if seconds < 60 { return "\(seconds)S" }
            return minutes >= 60 ? "\(minutes / 60)H" : "\(minutes)M"
        case .ink:
            if seconds < 60 { return "\(seconds) sec" }
            return minutes >= 60 ? "an hour" : "\(minutes) min"
        }
    }

    func policyWaitNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A bot that asks and hears nothing back treats the silence as a refusal and gives up. Longer means a push you see an hour later still counts."
        case .control: "SILENCE IS NOT CONSENT: AN UNANSWERED HOLD EXPIRES AS A DENIAL. LONGER WINDOW = A LATE NOTIFICATION STILL LANDS."
        case .ink: "A familiar that asks and hears nothing takes the silence for refusal. A longer patience lets a late-read tiding still be answered."
        }
    }

    // MARK: Always allowed

    func policyAllowSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Always allowed"
        case .control: "PERMANENT ALLOWLIST"
        case .ink: "GRANTED IN PERPETUITY"
        }
    }

    func policyAllowNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Every time you tapped “Always”, plus anything set in config.yaml. Revoking rewrites the gateway's config; the running gateway keeps its loaded copy until it next restarts."
        case .control: "SOURCED FROM 'ALWAYS' GRANTS + COMMAND_ALLOWLIST IN CONFIG.YAML. REVOKE REWRITES CONFIG; THE LIVE PROCESS HOLDS ITS LOADED SET UNTIL RESTART."
        case .ink: "Each seal you granted for all time, and whatever the config names besides. To revoke is to rewrite that book — though the gateway keeps the page it already read until it wakes anew."
        }
    }

    func policyAllowEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing is permanently allowed"
        case .control: "ALLOWLIST EMPTY"
        case .ink: "nothing is granted in perpetuity"
        }
    }

    func policyAllowEmptyNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Choosing “Always” on an approval adds its pattern here."
        case .control: "SELECTING 'ALWAYS' ON A HOLD ADDS ITS PATTERN KEY HERE."
        case .ink: "Granting a seal for all time inscribes its pattern here."
        }
    }

    func policyRevoke(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Revoke"
        case .control: "REVOKE"
        case .ink: "break it"
        }
    }

    func policyRevokeTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Revoke this permission?"
        case .control: "REVOKE ALLOWLIST ENTRY?"
        case .ink: "Break this seal?"
        }
    }

    func policyRevokeConfirm(_ t: ThemeID, pattern: String) -> String {
        switch t {
        case .soft: "“\(pattern)” will need your approval again. Takes effect for the running gateway once it restarts."
        case .control: "'\(pattern)' WILL PROMPT AGAIN. EFFECTIVE FOR THE LIVE PROCESS AFTER ITS NEXT RESTART."
        case .ink: "“\(pattern)” shall be brought before you once more. The gateway honours it anew when next it wakes."
        }
    }

    // MARK: Pairing entry

    func policyPairSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Who can message your bots"
        case .control: "DM ACCESS"
        case .ink: "WHO MAY SPEAK TO THEM"
        }
    }

    func policyPairRow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pairing requests"
        case .control: "PAIRING QUEUE"
        case .ink: "those at the door"
        }
    }

    func policyPairRowNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approve or revoke people on Telegram, Discord, WhatsApp and the rest"
        case .control: "APPROVE / REVOKE PER MESSAGING PLATFORM"
        case .ink: "admit or turn away, on each of the messaging ways"
        }
    }

    func policyPairWaiting(_ count: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft: count == 1 ? "1 waiting" : "\(count) waiting"
        case .control: "\(count) WAITING"
        case .ink: count == 1 ? "one waits" : "\(count) wait"
        }
    }

    func policyPairNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "An unknown person who DMs a bot is blocked until someone lets them in. Until now that someone had to be at a desktop."
        case .control: "UNKNOWN DM SENDERS ARE BLOCKED PENDING APPROVAL. PREVIOUSLY DESKTOP/CLI ONLY."
        case .ink: "A stranger who writes to a familiar waits at the door until admitted — a thing that until now could only be done from the desk."
        }
    }
}

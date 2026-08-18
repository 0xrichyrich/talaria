import SwiftUI
import TalariaKit
import TalariaTheme

// Pairing — who may DM your bots. Roadmap Phase 3.5 / PARITY.md #19, #20.
//
// When a stranger messages a bot on Telegram, Discord, WhatsApp or Signal, the
// bot replies with a one-time code and the sender is blocked until an admin
// approves them. Until this screen the only admins were a desktop app and a
// terminal, which means the answer to "can you let me in?" was "wait until I'm
// at my laptop". It is the clearest the-phone-is-enough story in the audit.
//
// The security posture, and why it is what it is:
//
//   * A grant is issued on the row's `request_id`, never on the pairing code.
//     The code belongs to the person who received the DM — it is their proof
//     that the channel is theirs — and no endpoint returns it. THE CODE IS
//     NEVER DISPLAYED, TYPED, LOGGED OR STORED HERE. There is no field for it.
//   * Both verbs confirm. On a phone the list scrolls under your thumb, and
//     both letting a stranger in and locking a colleague out are consequential
//     enough to be worth one sentence naming exactly who is affected.
//   * Approval is optimistic with rollback: the row leaves at once, and comes
//     back with the reason if the gateway refuses.
//   * A row whose request has aged out answers 404, which reads as "expired",
//     not as an error — the list was stale, and pulling again fixes it.
//
// Transport, wire shapes and upstream citations: GatewayClient+Pairing.swift.
// State and the verbs: AppModelLive+ApprovalPolicy.swift.

struct PairingView: View {
    let model: AppModel
    var onBack: (() -> Void)?

    /// The row a confirmation dialog is currently asking about.
    @State private var confirming: PairingConfirmation?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }
    private var store: ApprovalPolicyStore { model.approvalPolicy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    /// Which verb a dialog is asking to confirm. One value rather than two
    /// flags, so two dialogs can never be armed at once.
    private enum PairingConfirmation: Identifiable {
        case admit(PairingRequest)
        case revoke(PairedUser)

        var id: String {
            switch self {
            case .admit(let request): "admit:" + request.id
            case .revoke(let user): "revoke:" + user.id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let notice = store.pairingNotice {
                        noticeCard(notice)
                    }
                    pendingSection
                        .settingsEntrance(delay: 0, reduced: reducedMotion)
                    approvedSection
                        .settingsEntrance(delay: 0.06, reduced: reducedMotion)
                    GatewayFootnote(theme: theme, text: copy.pairCodeNote(themeID))
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task { await model.loadPairing() }
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            confirmActions
        } message: {
            Text(confirmMessage)
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
                    Text(copy.pairKicker(themeID))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(themeID == .ink ? theme.sub : theme.accent)
                        .lineLimit(1)
                }
                Text(copy.pairTitle(themeID))
                    .font(titleFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if store.isLoadingPairing {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else {
                HeaderIconButton(theme: theme, size: 31,
                                 action: { Task { await model.loadPairing() } }) {
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

    // MARK: Waiting

    private var pendingSection: some View {
        SettingsSection(theme: theme,
                        title: copy.pairPendingSec(themeID),
                        footnote: store.pairing.pending.isEmpty ? nil
                                                                : copy.pairPendingNote(themeID)) {
            SettingsGroup(theme: theme) {
                if store.pairing.pending.isEmpty {
                    SettingsRow(theme: theme,
                                title: store.hasLoadedPairing ? copy.pairPendingEmpty(themeID)
                                                              : copy.pairLoading(themeID),
                                isLast: true)
                } else {
                    let rows = store.pairing.pending
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, request in
                        PairingPendingRow(
                            theme: theme,
                            title: PairingNames.display(request.userName, request.userID),
                            detail: detailLine(platform: request.platform,
                                               userID: request.userID,
                                               age: copy.pairAge(request.ageMinutes, themeID)),
                            actionLabel: copy.pairAdmit(themeID),
                            blockedReason: request.isApprovable ? nil
                                                                : copy.pairNoRequestID(themeID),
                            isBusy: store.isBusy("pair:" + request.id),
                            isLast: index == rows.count - 1) {
                            confirming = .admit(request)
                        }
                    }
                }
            }
        }
    }

    // MARK: Admitted

    private var approvedSection: some View {
        SettingsSection(theme: theme,
                        title: copy.pairApprovedSec(themeID),
                        footnote: store.pairing.approved.isEmpty ? nil
                                                                 : copy.pairApprovedNote(themeID)) {
            SettingsGroup(theme: theme) {
                if store.pairing.approved.isEmpty {
                    SettingsRow(theme: theme,
                                title: store.hasLoadedPairing ? copy.pairApprovedEmpty(themeID)
                                                              : copy.pairLoading(themeID),
                                isLast: true)
                } else {
                    let rows = store.pairing.approved
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, user in
                        PairingPendingRow(
                            theme: theme,
                            title: PairingNames.display(user.userName, user.userID),
                            detail: detailLine(platform: user.platform,
                                               userID: user.userID,
                                               age: PairingNames.since(user.approvedAt)),
                            actionLabel: copy.pairRevoke(themeID),
                            isDestructive: true,
                            isBusy: store.isBusy("revoke:" + user.id),
                            isLast: index == rows.count - 1) {
                            confirming = .revoke(user)
                        }
                    }
                }
            }
        }
    }

    /// "Telegram · 48812207 · 12m ago" — the three facts an operator judges on:
    /// where they are writing from, which account, and how long they have been
    /// standing at the door.
    private func detailLine(platform: String, userID: String, age: String?) -> String {
        var parts = [PairingNames.platform(platform)]
        if !userID.isEmpty, userID != PairingNames.platform(platform) { parts.append(userID) }
        if let age, !age.isEmpty { parts.append(age) }
        return parts.joined(separator: themeID == .ink ? " — " : " · ")
    }

    // MARK: Confirmation

    @ViewBuilder private var confirmActions: some View {
        switch confirming {
        case .admit(let request):
            Button(copy.pairAdmit(themeID)) {
                confirming = nil
                Task { await model.approvePairing(request) }
            }
            Button(copy.cancel, role: .cancel) { confirming = nil }
        case .revoke(let user):
            Button(copy.pairRevoke(themeID), role: .destructive) {
                confirming = nil
                Task { await model.revokePairing(user) }
            }
            Button(copy.cancel, role: .cancel) { confirming = nil }
        case .none:
            EmptyView()
        }
    }

    private var confirmTitle: String {
        switch confirming {
        case .admit: copy.pairAdmitTitle(themeID)
        case .revoke: copy.pairRevokeTitle(themeID)
        case .none: ""
        }
    }

    private var confirmMessage: String {
        switch confirming {
        case .admit(let request):
            copy.pairAdmitConfirm(themeID,
                                  who: PairingNames.display(request.userName, request.userID),
                                  platform: PairingNames.platform(request.platform))
        case .revoke(let user):
            copy.pairRevokeConfirm(themeID,
                                   who: PairingNames.display(user.userName, user.userID),
                                   platform: PairingNames.platform(user.platform))
        case .none:
            ""
        }
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
                .stroke(theme.warn.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Row

/// One person: who they are, where from, how long, and the single verb that
/// applies to them. `blockedReason` replaces the verb for a row no admin
/// surface can grant — the legacy pre-hash entries that carry no request id and
/// simply age out (gateway/pairing.py:770-802).
private struct PairingPendingRow: View {
    let theme: ThemePack
    let title: String
    let detail: String
    let actionLabel: String
    var isDestructive: Bool = false
    var blockedReason: String?
    let isBusy: Bool
    let isLast: Bool
    let act: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                if let blockedReason {
                    Text(blockedReason)
                        .font(SettingsType.rowSubtitle(theme))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else if blockedReason == nil {
                Button(action: act) {
                    Text(actionLabel)
                        .font(theme.id == .control ? theme.mono(9.5, weight: .bold)
                                                   : theme.body(12, weight: .semibold))
                        .tracking(theme.id == .soft ? 0 : 1)
                        .foregroundStyle(isDestructive ? theme.danger
                                         : (theme.id == .ink ? theme.ink : theme.accent))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 11)
                        .background(actionBackground)
                        .clipShape(actionShape)
                        .overlay(actionShape.strokeBorder(actionBorder, lineWidth: 1))
                        .contentShape(actionShape)
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .accessibilityElement(children: .combine)
    }

    private var actionShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .ink ? theme.inputRadius : theme.buttonRadius,
                         style: .continuous)
    }

    private var actionBackground: Color {
        guard theme.id == .soft else { return .clear }
        return (isDestructive ? theme.danger : theme.accent).opacity(0.1)
    }

    private var actionBorder: Color {
        switch theme.id {
        case .soft: return .clear
        case .control: return (isDestructive ? theme.danger : theme.accent).opacity(0.5)
        case .ink: return theme.lineStrong
        }
    }
}

// MARK: - Names

/// Display transforms for pairing data. Not CopyPack's business: a platform's
/// product name and a person's handle read the same in all three voices.
enum PairingNames {
    /// The platform ids upstream registers (`gateway/pairing.py:66-88`) as the
    /// names their users know them by. Anything else — a plugin platform — is
    /// de-slugged rather than guessed at.
    private static let labels: [String: String] = [
        "telegram": "Telegram", "discord": "Discord", "slack": "Slack",
        "signal": "Signal", "email": "Email", "sms": "SMS",
        "whatsapp": "WhatsApp", "whatsapp_cloud": "WhatsApp Cloud",
        "mattermost": "Mattermost", "matrix": "Matrix", "dingtalk": "DingTalk",
        "feishu": "Feishu", "wecom": "WeCom", "wecom_callback": "WeCom Callback",
        "weixin": "Weixin", "bluebubbles": "BlueBubbles", "qqbot": "QQ",
        "yuanbao": "Yuanbao",
    ]

    static func platform(_ id: String) -> String {
        let key = id.lowercased().trimmingCharacters(in: .whitespaces)
        if let known = labels[key] { return known }
        guard !key.isEmpty else { return "—" }
        return key.split(separator: "_")
            .map { TalariaVoice.capitalized(String($0)) }
            .joined(separator: " ")
    }

    /// A name when the platform gave one, otherwise the account id — never an
    /// invented placeholder, because this string is what an approval is judged
    /// on.
    static func display(_ name: String, _ userID: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return userID.isEmpty ? "—" : userID
    }

    private static let sinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// "since 12 Aug 2026" — nil when the store recorded no grant time, which
    /// is the case for users mirrored in from a platform allowlist.
    static func since(_ approvedAt: Double?) -> String? {
        guard let approvedAt, approvedAt > 0 else { return nil }
        return sinceFormatter.string(from: Date(timeIntervalSince1970: approvedAt))
    }
}

// MARK: - Copy

extension CopyPack {

    func pairKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TALARIA // ACCESS"
        case .control: "DM ACCESS CONTROL"
        case .ink: "WHO IS ADMITTED"
        }
    }

    func pairTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pairing"
        case .control: "PAIRING"
        case .ink: "The Doorway"
        }
    }

    func pairLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading the pairing store…"
        case .control: "READING PAIRING STORE…"
        case .ink: "reading the doorbook…"
        }
    }

    // MARK: Waiting

    func pairPendingSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Waiting to be let in"
        case .control: "PENDING REQUESTS"
        case .ink: "AT THE DOOR"
        }
    }

    func pairPendingEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nobody is waiting"
        case .control: "QUEUE EMPTY"
        case .ink: "no one waits"
        }
    }

    func pairPendingNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Each of these people messaged one of your bots and is blocked until you let them in. Requests expire on their own after an hour."
        case .control: "EACH SENDER IS BLOCKED PENDING APPROVAL. REQUESTS EXPIRE AFTER 1 H."
        case .ink: "Each of these wrote to a familiar and waits, unanswered, until you admit them. An hour unattended and the request lapses of itself."
        }
    }

    func pairAdmit(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Let in"
        case .control: "ADMIT"
        case .ink: "admit"
        }
    }

    func pairAdmitTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Let this person in?"
        case .control: "GRANT DM ACCESS?"
        case .ink: "Admit this stranger?"
        }
    }

    func pairAdmitConfirm(_ t: ThemeID, who: String, platform: String) -> String {
        switch t {
        case .soft: "\(who) will be able to message your bots on \(platform) from now on. You can revoke it here at any time."
        case .control: "\(who.uppercased()) GAINS PERSISTENT DM ACCESS VIA \(platform.uppercased()). REVOCABLE HERE."
        case .ink: "\(who) may speak with your familiars by way of \(platform) henceforth. The leave may be withdrawn here at any hour."
        }
    }

    /// A pre-hash pending entry from an older gateway. There is no id to grant
    /// on, and this app will not take a code, so it is left to lapse.
    func pairNoRequestID(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Written by an older gateway — it can't be approved from here and expires on its own."
        case .control: "LEGACY ENTRY — NO REQUEST ID. NOT APPROVABLE; EXPIRES AT TTL."
        case .ink: "An older hand wrote this one; it bears no mark to grant, and will lapse in its own time."
        }
    }

    // MARK: Admitted

    func pairApprovedSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Allowed in"
        case .control: "APPROVED USERS"
        case .ink: "ADMITTED"
        }
    }

    func pairApprovedEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nobody has been let in yet"
        case .control: "NO APPROVED USERS"
        case .ink: "none have been admitted"
        }
    }

    func pairApprovedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Everyone who can currently DM your bots. Revoking also removes them from the platform's own allowed-users list."
        case .control: "CURRENT DM ROSTER. REVOKE ALSO PRUNES THE PLATFORM'S *_ALLOWED_USERS ENTRY."
        case .ink: "All who may presently speak to your familiars. To withdraw the leave also strikes them from the platform's own roll."
        }
    }

    func pairRevoke(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove"
        case .control: "REVOKE"
        case .ink: "turn away"
        }
    }

    func pairRevokeTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove this person's access?"
        case .control: "REVOKE DM ACCESS?"
        case .ink: "Withdraw this leave?"
        }
    }

    func pairRevokeConfirm(_ t: ThemeID, who: String, platform: String) -> String {
        switch t {
        case .soft: "\(who) will no longer be able to message your bots on \(platform). They can ask again and wait for a new approval."
        case .control: "\(who.uppercased()) LOSES DM ACCESS VIA \(platform.uppercased()). MAY RE-REQUEST AND RE-QUEUE."
        case .ink: "\(who) shall no longer speak with your familiars by way of \(platform). They may knock again and wait anew."
        }
    }

    // MARK: Ages and outcomes

    func pairAge(_ minutes: Int, _ t: ThemeID) -> String {
        if minutes < 1 {
            switch t {
            case .soft: return "just now"
            case .control: return "NOW"
            case .ink: return "this moment"
            }
        }
        if minutes < 60 {
            switch t {
            case .soft: return "\(minutes)m ago"
            case .control: return "\(minutes)M"
            case .ink: return minutes == 1 ? "a minute waiting" : "\(minutes) minutes waiting"
            }
        }
        let hours = minutes / 60
        switch t {
        case .soft: return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
        case .control: return hours < 24 ? "\(hours)H" : "\(hours / 24)D"
        case .ink:
            if hours < 24 { return hours == 1 ? "an hour waiting" : "\(hours) hours waiting" }
            let days = hours / 24
            return days == 1 ? "a day waiting" : "\(days) days waiting"
        }
    }

    /// The row was granted, cleared or timed out somewhere else while we held a
    /// stale list. Not an error — a refresh.
    func pairExpired(_ t: ThemeID) -> String {
        switch t {
        case .soft: "That request is gone — approved elsewhere, or it timed out. Pull the list again."
        case .control: "REQUEST NO LONGER PENDING — RESOLVED ELSEWHERE OR EXPIRED. RE-READ THE QUEUE."
        case .ink: "That one is no longer at the door — admitted elsewhere, or lapsed. Read the book again."
        }
    }

    /// 429. Only the code path can trigger the lockout upstream, so reaching
    /// this from a request-id grant means something in front of the gateway is
    /// rate-limiting us — still worth naming precisely.
    func pairLockedOut(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This platform is locked out after too many failed approvals. It clears itself within the hour."
        case .control: "PLATFORM LOCKED OUT — REPEATED FAILED APPROVALS. AUTO-CLEARS WITHIN 1 H."
        case .ink: "This way is barred a while, for too many failed attempts. It opens again within the hour."
        }
    }

    func pairGone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "They were already removed."
        case .control: "USER NOT IN APPROVED LIST."
        case .ink: "They had already been turned away."
        }
    }

    /// The line that says the quiet part: this screen never shows the code.
    func pairCodeNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approvals are granted on the request itself, never on the pairing code. The code is the requester's own proof of their account — your gateway only keeps a hash of it, and it is never shown here or anywhere else."
        case .control: "GRANTS ARE ISSUED ON REQUEST_ID, NEVER ON THE PAIRING CODE. THE CODE IS THE REQUESTER'S PROOF-OF-CHANNEL; THE GATEWAY STORES ONLY A SALTED HASH AND NO SURFACE EVER RENDERS IT."
        case .ink: "The seal is granted upon the request itself and never upon the word sent to the stranger. That word is their own proof and theirs alone — the gateway keeps but a hash of it, and it is shown here never."
        }
    }
}

import SwiftUI
import TalariaKit
import TalariaTheme

// The in-app push banner, ported from the prototype's bannerCss block: a
// floating card at the top of the screen carrying the sending bot's avatar,
// title, "now · TALARIA" meta and a one-line body. Approval pushes grow
// inline Approve / Later buttons. RootView owns the ~14s demo cycle and the
// 4.8s auto-hide; this view is purely presentational.

/// One banner's payload — the DB.PUSHES shape (`bot` may be "gateway").
/// Mirrors PushCoordinator.DemoPush but compiles on every platform.
public struct BannerPush: Identifiable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var title: String
    public var body: String
    public var kind: PushKind
    /// Pending approval this push can decide inline (kind == .approval).
    public var approvalID: String?

    public init(id: String = UUID().uuidString, botID: String, title: String,
                body: String, kind: PushKind, approvalID: String? = nil) {
        self.id = id; self.botID = botID; self.title = title
        self.body = body; self.kind = kind; self.approvalID = approvalID
    }

    /// The demo cycle, verbatim from the design DB (`DB.PUSHES`).
    public static let demoCycle: [BannerPush] = [
        BannerPush(id: "push-approval", botID: "inbox", title: "inbox needs approval",
                   body: "Reply to Sarah Chen is ready to send.",
                   kind: .approval, approvalID: "ap1"),
        BannerPush(id: "push-response", botID: "inbox", title: "Agent reply ready",
                   body: "The draft reply to Sarah Chen is ready to review.",
                   kind: .response),
        BannerPush(id: "push-routine", botID: "researcher", title: "Morning digest finished",
                   body: "6 papers · 2 flagged must-read.", kind: .routine),
        BannerPush(id: "push-mention", botID: "comms", title: "comms mentioned you",
                   body: "“which screenshot for the launch post?”", kind: .mention),
        BannerPush(id: "push-task", botID: "ops", title: "Backup verified",
                   body: "42 GB · 18m · checksums clean.", kind: .task),
        BannerPush(id: "push-gateway", botID: "gateway", title: "homelab reconnected",
                   body: "Offline 6m — tailscale route recovered.", kind: .gateway),
    ]
}

public struct PushBanner: View {
    public var theme: ThemePack
    public var copy: CopyPack
    public var push: BannerPush
    /// Roster bot behind the push; nil renders the gateway avatar.
    public var bot: Bot?
    /// True while the referenced approval is still pending — shows the
    /// inline Approve / Later row.
    public var showsApprovalActions: Bool
    public var onTap: () -> Void
    public var onApprove: () -> Void
    public var onLater: () -> Void

    public init(theme: ThemePack, copy: CopyPack, push: BannerPush, bot: Bot?,
                showsApprovalActions: Bool,
                onTap: @escaping () -> Void,
                onApprove: @escaping () -> Void,
                onLater: @escaping () -> Void) {
        self.theme = theme; self.copy = copy; self.push = push; self.bot = bot
        self.showsApprovalActions = showsApprovalActions
        self.onTap = onTap; self.onApprove = onApprove; self.onLater = onLater
    }

    public var body: some View {
        HStack(alignment: showsApprovalActions ? .top : .center, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    meta
                }
                bodyLine
                if showsApprovalActions {
                    HStack(spacing: 7) {
                        ThemedPrimaryButton(theme: theme, title: copy.approve,
                                            compact: true, action: onApprove)
                        ThemedSecondaryButton(theme: theme, title: copy.later,
                                              compact: true, fillsWidth: true,
                                              action: onLater)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(chrome)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Pieces

    @ViewBuilder private var avatar: some View {
        if let bot {
            AvatarView(bot: bot, size: 33, theme: theme)
        } else {
            AvatarView(shape: .circle, hue: .gateway, size: 33, theme: theme)
        }
    }

    private var title: some View {
        Group {
            switch theme.id {
            case .soft:
                Text(push.title).font(theme.body(13, weight: .heavy))
            case .control:
                Text(push.title).font(theme.mono(11, weight: .bold)).tracking(0.5)
            case .ink:
                Text(push.title).font(theme.body(15.5, weight: .bold))
            }
        }
        .foregroundStyle(theme.ink)
        .lineLimit(1)
    }

    private var meta: some View {
        Group {
            switch theme.id {
            case .soft:
                Text(copy.bnMeta).font(theme.body(10.5))
            case .control:
                Text(copy.bnMeta).font(theme.mono(8.5))
            case .ink:
                Text(copy.bnMeta).font(theme.mono(7.5)).tracking(1)
            }
        }
        .foregroundStyle(theme.id == .ink ? theme.faint : theme.ink.opacity(0.4))
        .lineLimit(1)
    }

    private var bodyLine: some View {
        Group {
            switch theme.id {
            case .soft:
                Text(push.body).font(theme.body(12.5))
            case .control:
                Text(push.body).font(theme.body(12))
            case .ink:
                Text(push.body).font(theme.body(13.5)).italic()
            }
        }
        .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.65) : theme.sub)
        .lineLimit(1)
    }

    // MARK: - Chrome

    @ViewBuilder private var chrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18).fill(theme.panel.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.18), radius: 17, y: 14)
        case .control:
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).fill(theme.panel.opacity(0.96)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.6), radius: 20, y: 14)
                .shadow(color: theme.accent.opacity(0.08), radius: 10)
        case .ink:
            // The wax-seal double rule: card border, a 3pt parchment margin,
            // then a second hairline — box-shadow rings in the prototype.
            Rectangle()
                .fill(theme.panel)
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.5), lineWidth: 1))
                .background(Rectangle().fill(theme.panel).padding(-3))
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.5), lineWidth: 1).padding(-4))
                .shadow(color: theme.ink.opacity(0.25), radius: 17, y: 16)
        }
    }
}

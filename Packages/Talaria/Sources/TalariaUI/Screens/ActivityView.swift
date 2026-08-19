import SwiftUI
import TalariaKit
import TalariaTheme

// Activity — Activity / Feed / The Ledger. A day-grouped ledger of everything
// the roster did: approvals (with a pending chip — a wax seal in ink),
// mentions, routine runs, finished tasks and gateway events (gateway-hue
// avatar). Tapping routes: approval → Approvals tab, gateway → Connections,
// anything else → that bot's chat.
// Ported from Talaria.dc.html `data-screen-label="Activity"`.
//
// Live source (AppModelLive+Feeds.swift): there is no activity endpoint. The
// rows are an in-process journal fed by the event stream (finished turns,
// cron.changed runs, inbound A2A mentions), the approvals array (raised and
// cleared) and the connection monitor (link lost / restored) — persisted to
// UserDefaults, newest 200, so the tab is never empty on relaunch.
//
// Since the toast bus (AppModelLive+Toasts.swift) the journal also carries the
// half of the story that used to leave no trace: what YOU did. A pin, a
// duplicate, a look save, a delete, a model switch — each posts its optimistic
// toast and its confirmation under one key, so the ledger keeps ONE row per act
// that goes from pending to settled rather than two rows arguing.
//
// What that means for this screen:
//
//  · Live mode renders the persisted journal, never DemoData. `publishActivity`
//    is guarded on `mode == .live`, and every toast-mirrored row goes through
//    `toast()`, which carries the same guard — `recordActivity` itself has none,
//    so a demo pin stays out of the persisted journal because the bus keeps it
//    out, not because the journal refuses it.
//  · A pending row is an act whose answer had not landed yet. Answers arrive in
//    memory, so a row left pending by a killed app is swept on appear
//    (`settleStalePendingToasts`) instead of pulsing forever at a question that
//    stopped being open hours ago.
//  · The footer says where these rows come from, because "Activity" on a tab bar
//    reads like a server-side feed and this one is emphatically local.

public struct ActivityView: View {
    private let model: AppModel
    /// Connections is pushed a level deep off the roster; the host wires this
    /// to its connections push (same pattern as SearchPalette's onAction).
    private let onOpenConnections: (() -> Void)?

    @State private var confirmingClear = false

    public init(model: AppModel, onOpenConnections: (() -> Void)? = nil) {
        self.model = model
        self.onOpenConnections = onOpenConnections
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.kickerActivity, title: copy.titleActivity) {
                if model.mode == .live, !model.activity.isEmpty {
                    HeaderIconButton(theme: theme, size: 32) {
                        confirmingClear = true
                    } glyph: {
                        Text(verbatim: "⌫")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(model.activity) { day in
                        dayGroup(day)
                    }
                    if model.activity.isEmpty { emptyState } else { provenanceNote }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            model.attachActivityRouter()
            // Answers live in memory; the ledger lives on disk. Anything still
            // marked pending from a previous launch is settled before the first
            // paint, so a wax seal only ever pulses at something real.
            model.settleStalePendingToasts()
        }
        .confirmationDialog(copy.clearLedger(theme.id), isPresented: $confirmingClear) {
            Button(copy.clearLedger(theme.id), role: .destructive) {
                model.clearActivityJournal()
            }
            Button(copy.cancel, role: .cancel) {}
        }
    }

    // MARK: Day group

    private func dayGroup(_ day: ActivityDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dayLabel(day.day)
            VStack(spacing: 0) {
                ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                    ActivityRow(item: item,
                                bot: model.bot(item.botID),
                                isLast: index == day.items.count - 1,
                                theme: theme, copy: copy) {
                        route(item)
                    }
                    .modifier(RowEntrance(delay: Double(min(index, 10)) * 0.05))
                }
            }
            .modifier(GroupChrome(theme: theme))
        }
    }

    @ViewBuilder private func dayLabel(_ day: String) -> some View {
        switch theme.id {
        case .soft:
            Text(day)
                .font(theme.body(12, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(theme.faint)
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
        case .control:
            Text(day)
                .font(theme.mono(9.5, weight: .bold))
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(theme.faint)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
        case .ink:
            // Ledger heading: small-caps over a heavy rule.
            Text(day)
                .font(theme.body(16, weight: .bold).smallCaps())
                .tracking(1)
                .foregroundStyle(theme.ink)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    theme.ink.opacity(0.5).frame(height: 2)
                }
        }
    }

    /// Where these rows came from. The other derived screens carry the same kind
    /// of footnote (`artifactsDerivationNote`, the routines note) for the same
    /// reason: this app makes a point of never letting a derived surface pass
    /// itself off as a server-side feed. Demo mode is not annotated — there is
    /// nothing honest to say about a canned ledger.
    @ViewBuilder private var provenanceNote: some View {
        if model.mode == .live {
            Text(copy.ledgerScopeNote(theme.id, count: model.activityRowCount,
                                      cap: model.activityRowLimit))
                .font(theme.id == .control ? theme.mono(9) : theme.body(11))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.activityEmptyTitle(theme.id))
                .font(theme.id == .control ? theme.mono(12, weight: .bold)
                                           : theme.body(15, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(copy.activityEmptyBody(theme.id))
                .font(theme.id == .control ? theme.mono(9.5) : theme.body(theme.id == .ink ? 13 : 11.5))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.faint)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 24)
    }

    // MARK: Routing

    /// approval → Approvals tab; gateway events → Connections; else the bot's
    /// chat. Mirrors the prototype's `a.go`.
    private func route(_ item: ActivityItem) {
        if item.kind == .approval {
            model.selectedTab = .approvals
        } else if item.botID == "gateway" {
            if let onOpenConnections {
                onOpenConnections()
            } else {
                // Connections is one tap deep off the roster.
                model.selectedTab = .home
            }
        } else {
            model.selectedTab = .home
            model.openChat(botID: item.botID)
        }
    }
}

// MARK: - Row

private struct ActivityRow: View {
    let item: ActivityItem
    let bot: Bot?
    let isLast: Bool
    let theme: ThemePack
    let copy: CopyPack
    let open: () -> Void

    private var isGateway: Bool { item.botID == "gateway" || bot == nil }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 11) {
                Text(item.time)
                    .font(timeFont)
                    .foregroundStyle(theme.faint)
                    .frame(width: 34, alignment: .leading)
                    .padding(.top, 3)
                    .lineLimit(1)
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(textFont)
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if !item.subtext.isEmpty {
                        Text(item.subtext)
                            .font(subFont)
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.sub)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.pending {
                    pendChip
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                // Every ledger row rules off in ink; cards/panels divide
                // between rows only.
                if theme.id == .ink || !isLast {
                    theme.line.frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Mini avatar — gateway events get the reserved gateway hue.
    private var avatar: some View {
        AvatarView(shape: isGateway ? .circle : (bot?.shape ?? .circle),
                   hue: isGateway ? .gateway : (bot?.hue ?? .teal),
                   size: 29, theme: theme)
    }

    /// PENDING / HOLD chip; ink replaces the chip with a pulsing wax seal.
    @ViewBuilder private var pendChip: some View {
        switch theme.id {
        case .soft:
            Text(copy.pendChip)
                .font(theme.body(10, weight: .heavy))
                .foregroundStyle(theme.danger)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(theme.danger.opacity(0.1))
                .clipShape(Capsule())
        case .control:
            Text(copy.pendChip)
                .font(theme.mono(8.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.warn)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(theme.warn.opacity(0.4), lineWidth: 1))
        case .ink:
            WaxSealDot(color: theme.danger, ring: theme.bg, size: 16, pulsing: true)
        }
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    private var textFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5, weight: .semibold)
        case .control: theme.body(13, weight: .semibold)
        case .ink: theme.body(15.5, weight: .semibold)
        }
    }

    private var subFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.body(13)
        }
    }
}

// MARK: - Group chrome

/// The day-group container: floating card in soft, terminal panel in control,
/// bare ledger in ink.
private struct GroupChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
        }
    }
}

// MARK: - Shared row helpers (file-scoped copies; each screen file keeps its own)

/// Ink's wax-seal dot: a solid disc with an inset ring in the page color.
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

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4).delay(delay)) { shown = true }
            }
    }
}

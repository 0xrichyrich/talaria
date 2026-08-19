import SwiftUI
import TalariaKit
import TalariaTheme

// The union roster's second-class citizens, and the chip that marks them.
//
// Desktop annotates every row that came from another Connection with a bare
// connection-label chip and makes it visibly lesser: no context menu, no
// unread, no local metadata — "two 'default' agents must never borrow each
// other's title, color or pin" — and tapping it explains rather than
// navigating (plugin.js:3896-3910, BOT-MODE-PARITY §Multi-source rosters).
//
// Talaria keeps the second-class treatment and changes only the promise at the
// end of the tap. Desktop says "Gateway stays on this device" because its main
// process holds every connection open; Talaria holds exactly one, so the tap
// says what it will actually do — switch this phone to that gateway — and then
// does it through `openForeignBot`.

// MARK: - The chip

/// A gateway's label, worn by a roster row that does not belong to the live
/// connection. Quiet by construction: this is an annotation, not a status.
public struct ConnectionBadge: View {
    public enum State: Sendable {
        /// Listed from that gateway during this launch.
        case live
        /// Last-known list; the gateway did not answer the last attempt.
        case stale
        /// Saved gateway with no credential on this device.
        case needsSignIn
    }

    private let label: String
    private let kind: ConnectionKind
    private let state: State
    private let theme: ThemePack

    public init(label: String, kind: ConnectionKind, state: State = .live, theme: ThemePack) {
        self.label = label; self.kind = kind; self.state = state; self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(text)
                .font(font)
                .tracking(theme.id == .soft ? 0 : theme.id == .control ? 1 : 1.4)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(background)
        .overlay(border)
    }

    private var text: String {
        switch theme.id {
        case .soft: label
        case .control, .ink: label.uppercased()
        }
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(10.5, weight: .semibold)
        case .control: theme.mono(9, weight: .semibold)
        case .ink: theme.mono(8, weight: .semibold)
        }
    }

    /// Kind reads through the dot (the same vocabulary the Connections rows
    /// use), reachability through its brightness.
    private var dotColor: Color {
        let base: Color = switch kind {
        case .cloud: theme.color(for: .blue)
        case .tailscale: theme.color(for: .violet)
        case .lan: theme.color(for: .teal)
        }
        return switch state {
        case .live: base
        case .stale: base.opacity(0.4)
        case .needsSignIn: theme.warn
        }
    }

    private var textColor: Color {
        state == .live ? theme.sub : theme.faint
    }

    @ViewBuilder private var background: some View {
        switch theme.id {
        case .soft:
            Capsule().fill(theme.ink.opacity(0.045))
        case .control:
            RoundedRectangle(cornerRadius: 3).fill(theme.ink.opacity(0.05))
        case .ink:
            Color.clear
        }
    }

    @ViewBuilder private var border: some View {
        switch theme.id {
        case .soft:
            Capsule().strokeBorder(theme.line, lineWidth: 1)
        case .control:
            RoundedRectangle(cornerRadius: 3).strokeBorder(theme.line, lineWidth: 1)
        case .ink:
            Rectangle().strokeBorder(theme.lineStrong.opacity(0.55), lineWidth: 1)
        }
    }
}

// MARK: - The section

/// The rest of the fleet: every bot on a saved gateway that is not the live
/// one, under one divider, each row wearing its gateway's badge.
///
/// Drop it into the roster list under the local rows — desktop appends foreign
/// rows to the same array for exactly this reason (plugin.js:2345-2357), and
/// keeping them in one labelled block is what makes them read as second-class
/// on a screen too narrow for a per-row context menu.
public struct MultiGatewayRosterSection: View {
    private let model: AppModel
    /// The roster search needle (already trimmed, lowercased and '@'-stripped
    /// by `RosterSearch.needle`). Foreign rows are part of the same array
    /// desktop filters (plugin.js:2345-2357, 7668), so one query narrows this
    /// block too — and the device label is a match field, which is what makes
    /// typing a machine's name list everything on it (plugin.js:2974-2976).
    private let needle: String
    private let includeEntries: Bool

    public init(model: AppModel, needle: String = "", includeEntries: Bool = true) {
        self.model = model
        self.needle = needle
        self.includeEntries = includeEntries
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        // With no second gateway this has no children and therefore no height:
        // a phone with one gateway must never grow a "no other gateways"
        // shelf, which is why the header is inside the guard and not around
        // it. The refresh that FEEDS these rows deliberately does not live
        // here — this view sits in a lazy list and may never be built on a
        // long roster; the roster screen owns the task instead.
        let entries = includeEntries ? model.foreignRosterEntries(matching: needle) : []
        // Gateways that listed NOTHING are a footnote about the fleet, not
        // roster rows, so a live query has nothing of theirs to narrow —
        // answering "homelab" with a machine that has no bots on it would be
        // the search inventing a result. They come back when the field clears.
        let problems = needle.isEmpty ? model.foreignRosterProblems : []
        VStack(alignment: .leading, spacing: rowGap) {
            if !entries.isEmpty || !problems.isEmpty {
                header
                    .padding(.top, 18)
                ForEach(entries) { entry in
                    row(for: entry)
                }
                ForEach(problems) { problem in
                    problemRow(problem.gateway, problem.freshness)
                }
            }
        }
    }

    private var rowGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    // MARK: Header

    /// Names the gateway you are on, because the rows underneath are an
    /// invitation to leave it — "switch" only means something against a
    /// stated here.
    private var header: some View {
        HStack(spacing: 8) {
            Text(copy.otherGateways(model.activeConnectionLabel, theme.id))
                .font(headerFont)
                .tracking(theme.id == .soft ? 0.4 : theme.id == .control ? 1.4 : 2)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle()
                .fill(theme.line)
                .frame(height: 1)
        }
        .padding(.bottom, 2)
    }

    private var headerFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .semibold)
        case .control: theme.mono(9, weight: .semibold)
        case .ink: theme.mono(8.5, weight: .semibold)
        }
    }

    // MARK: Rows

    private func row(for entry: ForeignRosterEntry) -> some View {
        let bot = model.rosterBot(for: entry)
        return Button {
            Task { @MainActor in await model.openForeignBot(entry) }
        } label: {
            HStack(alignment: .center, spacing: 13) {
                AvatarView(bot: bot, size: 38, theme: theme)
                    // Dim stale/sign-in-required rows; a healthy remote bot is
                    // fully present because opening it no longer switches the
                    // app away from the current gateway.
                    .opacity(entry.isStale || entry.needsSignIn ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        BotIdentityLabel(bot: bot, theme: theme, scale: .row)
                        ConnectionBadge(label: entry.connectionLabel,
                                        kind: entry.connectionKind,
                                        state: badgeState(for: entry),
                                        theme: theme)
                    }
                    Text(statusLine(for: entry))
                        .font(previewFont)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chevron
            }
            .padding(rowPadding)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                if theme.rowStyle == .ledger {
                    Rectangle().fill(theme.ink.opacity(0.1)).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badgeState(for entry: ForeignRosterEntry) -> ConnectionBadge.State {
        if entry.needsSignIn { return .needsSignIn }
        return entry.isStale ? .stale : .live
    }

    /// What that machine last said, or — when we only have a cached list —
    /// how old the picture is. Never a bare "offline".
    private func statusLine(for entry: ForeignRosterEntry) -> String {
        // The credential is gone, so the row is a memory. Tapping still leads
        // somewhere useful: `switchGateway` raises the sign-in banner.
        if entry.needsSignIn { return copy.gatewayNeedsSignIn(theme.id) }
        if entry.isStale {
            // The age of the PICTURE, not of the bot's last message: what the
            // user needs to know is how much to trust the row in front of them.
            return copy.gatewayLastSeen(Self.relative(since: entry.fetchedAt), theme.id)
        }
        let preview = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? copy.remoteBotReady(entry.connectionLabel, theme.id) : preview
    }

    /// A gateway that listed nothing: it needs a sign-in, or it is not
    /// answering. Both are things the user can do something about, which is
    /// the only reason this row exists.
    private func problemRow(_ gateway: SavedGateway,
                            _ freshness: SecondaryRoster.Freshness) -> some View {
        Button {
            Task { @MainActor in await model.becomeGateway(gateway) }
        } label: {
            HStack(spacing: 10) {
                ConnectionBadge(label: gateway.name,
                                kind: gateway.kind,
                                state: freshness == .needsSignIn ? .needsSignIn : .stale,
                                theme: theme)
                Text(freshness == .needsSignIn
                     ? copy.gatewayNeedsSignIn(theme.id)
                     : copy.gatewayUnreachable(theme.id))
                    .font(previewFont)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSwitchingGateway)
    }

    private var previewFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.body(13)
        }
    }

    /// The affordance that says "this leads somewhere else" — the one visual
    /// difference from a local row, because the destination is a whole gateway.
    private var chevron: some View {
        Text(verbatim: theme.id == .ink ? "→" : "›")
            .font(theme.id == .ink ? theme.body(13) : theme.body(15, weight: .medium))
            .foregroundStyle(theme.faint)
    }

    private var rowPadding: EdgeInsets {
        switch theme.rowStyle {
        case .card: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        case .terminal: EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13)
        case .ledger: EdgeInsets(top: 12, leading: 2, bottom: 12, trailing: 2)
        }
    }

    @ViewBuilder private var rowBackground: some View {
        switch theme.rowStyle {
        case .card:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .terminal:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.line.opacity(0.7), lineWidth: 1))
        case .ledger:
            Color.clear
        }
    }

    /// Coarse age of a cached row. Deliberately vague past a day: the point is
    /// "this is old", not a timestamp nobody asked for.
    static func relative(since date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        guard seconds.isFinite, seconds < 3_600 * 24 * 365 else { return "a while" }
        if seconds < 90 { return "a moment" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// MARK: - Copy

public extension CopyPack {

    /// Section header over the rows that belong to other gateways. Names the
    /// live gateway when there is one, so the boundary has two sides.
    func otherGateways(_ activeLabel: String?, _ theme: ThemeID) -> String {
        guard let activeLabel, !activeLabel.isEmpty else {
            switch theme {
            case .soft: return "On your other gateways"
            case .control: return "OTHER UPLINKS"
            case .ink: return "FAMILIARS OF OTHER HOUSES"
            }
        }
        switch theme {
        case .soft: return "Elsewhere — you’re on \(activeLabel)"
        case .control: return "OTHER UPLINKS · BOUND TO \(activeLabel.uppercased())"
        case .ink: return "OTHER HOUSES · YOU ATTEND \(activeLabel.uppercased())"
        }
    }

    /// Empty-preview fallback for a healthy remote row. Tapping routes through
    /// that bot's retained connection without moving the primary app gateway.
    func remoteBotReady(_ label: String, _ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Ready on \(label)"
        case .control: "REMOTE UPLINK READY · \(label.uppercased())"
        case .ink: "attending from \(label)"
        }
    }

    /// A cached row: we are showing the last picture we took.
    func gatewayLastSeen(_ age: String, _ theme: ThemeID) -> String {
        switch theme {
        case .soft: "last seen \(age) ago · showing last known"
        case .control: "LAST CONTACT \(age.uppercased()) · CACHED"
        case .ink: "last seen \(age) ago — as it was"
        }
    }

    func gatewayNeedsSignIn(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Sign in to see its bots"
        case .control: "AUTH REQUIRED — NO ROSTER"
        case .ink: "unopened — sign in to see its familiars"
        }
    }

    func gatewayUnreachable(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Not answering — nothing listed yet"
        case .control: "NO ANSWER — ROSTER UNKNOWN"
        case .ink: "silent — no roll has been taken"
        }
    }
}

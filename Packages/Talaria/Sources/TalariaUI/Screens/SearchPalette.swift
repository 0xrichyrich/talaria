import SwiftUI
import TalariaKit
import TalariaTheme

// The search palette — scrim + input over everything, opened from the
// magnifier on the roster. Empty query shows "Live now" (working bots) plus
// the action registry; a query searches bots, sessions, artifacts and actions,
// grouped by kind with one header per group.
//
// Sessions are the only server-backed group: live mode runs a 250 ms-debounced
// GET /api/sessions/search through `model.searchSessions`, demo mode filters
// the canned index. Bots, artifacts and actions stay client-side — they are
// already fully in memory, so making them async would only add latency.
//
// Every row routes on tap and dismisses the palette. Ported from
// Talaria.dc.html `sc-if searchOpen`, extended for live search.

/// Palette actions the palette cannot route through `AppModel` alone; the
/// host wires these to its sheets and pushes.
public enum SearchPaletteAction: Sendable {
    case newBot
    case addGateway
    /// Jump to a tab. Routed through the host because reaching a tab means
    /// popping whatever is stacked over it, which is the host's state.
    case tab(CopyPack.Tab)
    /// Skills / toolsets / MCP — hosted as a sheet so it never crowds the
    /// five prototype tabs.
    case capabilities
    /// Browse stored sessions for a bot (the palette resolves which one).
    case sessions(botID: String)
    /// A cross-session search hit: open this bot on this stored session.
    case openSession(botID: String, sessionID: String)
}

public struct SearchPalette: View {
    private let model: AppModel
    @Binding private var isPresented: Bool
    private let onAction: ((SearchPaletteAction) -> Void)?

    @State private var query = ""
    @FocusState private var focused: Bool

    // Live session search (see `runSessionSearch`).
    @State private var sessionHits: [PaletteSession] = []
    @State private var searchState: SessionSearchState = .idle
    @State private var searchTask: Task<Void, Never>?

    public init(model: AppModel, isPresented: Binding<Bool>,
                onAction: ((SearchPaletteAction) -> Void)? = nil) {
        self.model = model
        self._isPresented = isPresented
        self.onAction = onAction
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Where the server-backed session group stands for the current query.
    private enum SessionSearchState: Equatable {
        /// Nothing to run: demo mode, or a query shorter than the floor.
        case idle
        case searching
        case done
        /// Live mode with no reachable gateway — degrade, don't spin.
        case unreachable
    }

    /// Below this, an FTS query matches most of the transcript store; desktop
    /// applies the same floor before hitting /api/sessions/search.
    private static let minimumLiveQuery = 2

    // MARK: Result sets (mirrors the prototype's sr* pipelines)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func matches(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.lowercased().contains(trimmedQuery)
    }

    private var resultBots: [Bot] {
        if trimmedQuery.isEmpty { return model.workingBots }
        return model.bots.filter { matches($0.id) || matches($0.job) || matches($0.preview) }
    }

    /// Demo mode has no search endpoint — filter the canned per-bot index so
    /// the palette behaves identically without a gateway.
    private var demoSessions: [PaletteSession] {
        guard !trimmedQuery.isEmpty else { return [] }
        return model.sessions
            .filter { $0.key != "default" }
            .sorted { $0.key < $1.key }
            .flatMap { botID, list in
                list.filter { matches($0.title) }.map {
                    PaletteSession(sessionID: $0.id, botID: botID, title: $0.title,
                                   snippet: "", when: $0.when)
                }
            }
    }

    private var resultSessions: [PaletteSession] {
        model.mode == .live ? sessionHits : demoSessions
    }

    private var resultArtifacts: [Artifact] {
        guard !trimmedQuery.isEmpty else { return [] }
        return model.artifacts.filter { matches($0.title) || matches($0.meta) }
    }

    // MARK: Action registry

    private struct PaletteAction: Identifiable {
        let id: String
        let label: String
        let run: () -> Void
    }

    /// "Sessions…" needs a subject: the open chat, else the first bot on the
    /// roster. With an empty roster the row is simply not offered.
    private var sessionsActionBot: String? {
        model.openBotID ?? model.bots.first?.id
    }

    private var resultActions: [PaletteAction] {
        var all: [PaletteAction] = [
            PaletteAction(id: "new-bot", label: copy.createTitle) { onAction?(.newBot) },
            PaletteAction(id: "add-gateway", label: copy.paletteAddGateway(theme.id)) { onAction?(.addGateway) },
            PaletteAction(id: "capabilities", label: copy.paletteCapabilities(theme.id)) { onAction?(.capabilities) },
        ]
        if let botID = sessionsActionBot {
            all.append(PaletteAction(id: "sessions", label: copy.paletteSessionsAction(theme.id)) {
                onAction?(.sessions(botID: botID))
            })
        }
        // Destinations, in tab-bar order and tab-bar voice. Home is omitted —
        // the palette is opened from it.
        for entry in copy.tabs where entry.tab != .home {
            all.append(PaletteAction(id: "tab-\(entry.tab.rawValue)", label: entry.label) {
                onAction?(.tab(entry.tab))
            })
        }
        all.append(PaletteAction(id: "cycle-theme", label: copy.paletteCycleTheme(theme.id)) {
            model.theme.cycle()
        })
        return all.filter { trimmedQuery.isEmpty || $0.label.lowercased().contains(trimmedQuery) }
    }

    /// True once every group has reported empty and nothing is still in flight.
    private var showsEmptyState: Bool {
        !trimmedQuery.isEmpty && searchState != .searching
            && resultBots.isEmpty && resultSessions.isEmpty
            && resultArtifacts.isEmpty && resultActions.isEmpty
    }

    // MARK: Body

    public var body: some View {
        ZStack(alignment: .top) {
            // Scrim
            theme.scrimColor
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 10) {
                inputRow
                results
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .transition(.opacity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: query) { scheduleSessionSearch() }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(copy.searchPh, text: $query)
                .font(inputFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onSubmit { runSessionSearchNow() }
                .textFieldStyle(.plain)
                .padding(.horizontal, 15)
                .frame(height: 44)
                .background(theme.panel)
                .clipShape(inputShape)
                .overlay(inputShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

            Button(action: close) {
                Text(verbatim: "✕")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.ink)
                    .frame(width: 38, height: 38)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(iconShape)
                    .overlay(iconShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 22), style: .continuous)
    }

    private var iconShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 19 : 38 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var inputFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5)
        case .control: theme.mono(13)
        case .ink: theme.body(15)
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if !resultBots.isEmpty {
                    sectionHeader(trimmedQuery.isEmpty
                                  ? copy.paletteLiveNow(theme.id) : copy.titleHome)
                    ForEach(resultBots) { bot in
                        botRow(bot)
                    }
                }

                if !trimmedQuery.isEmpty {
                    sessionSection
                }

                if !resultArtifacts.isEmpty {
                    sectionHeader(copy.titleArtifacts)
                    ForEach(resultArtifacts) { artifact in
                        metaRow(title: artifact.title,
                                trail: "\(model.botName(artifact.botID, theme.id)) · \(artifact.when)") {
                            openBot(artifact.botID)
                        }
                    }
                }

                if !resultActions.isEmpty {
                    sectionHeader(copy.paletteActions(theme.id))
                    WrapLayout(spacing: 7) {
                        ForEach(resultActions) { action in
                            actionChip(action.label) {
                                close()
                                action.run()
                            }
                        }
                    }
                    .padding(.top, 1)
                }

                if showsEmptyState {
                    noteRow(copy.paletteNoMatches(theme.id))
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The sessions group carries its own status: a spinner while the REST
    /// search is in flight, and a themed note when the gateway is out of reach
    /// rather than a spinner that never resolves.
    @ViewBuilder private var sessionSection: some View {
        if searchState == .searching || searchState == .unreachable || !resultSessions.isEmpty {
            HStack(spacing: 8) {
                sectionHeader(copy.paletteSessionsHead(theme.id))
                if searchState == .searching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(theme.accent)
                    Text(copy.paletteSearching(theme.id))
                        .font(theme.mono(theme.id == .soft ? 10 : 9.5))
                        .tracking(theme.id == .soft ? 0.6 : 1.2)
                        .foregroundStyle(theme.faint)
                }
                Spacer(minLength: 0)
            }

            if searchState == .unreachable {
                noteRow(copy.paletteSearchUnreachable(theme.id))
            }
            ForEach(resultSessions) { hit in
                sessionRow(hit)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(theme.mono(theme.id == .soft ? 10 : 9.5, weight: .bold))
            .tracking(theme.id == .soft ? 1 : 1.8)
            .foregroundStyle(theme.accentFg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.accent)
    }

    // MARK: Rows

    private func botRow(_ bot: Bot) -> some View {
        Button { openBot(bot.id) } label: {
            HStack(spacing: 10) {
                AvatarView(bot: bot, size: 26, theme: theme)
                Text(TalariaVoice.displayName(for: bot, theme.id))
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                Text(liveLine(for: bot))
                    .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .modifier(PaletteCard(theme: theme))
    }

    /// A cross-session hit: title, the FTS snippet that matched, then the
    /// owning bot and age.
    private func sessionRow(_ hit: PaletteSession) -> some View {
        Button { openSession(hit) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(hit.title)
                        .font(theme.body(theme.id == .ink ? 15.5 : 13.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(model.botName(hit.botID, theme.id)) · \(hit.when)")
                        .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.sub)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .modifier(PaletteCard(theme: theme))
    }

    private func metaRow(title: String, trail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(theme.body(theme.id == .ink ? 15.5 : 13.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trail)
                    .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .modifier(PaletteCard(theme: theme))
    }

    /// Non-interactive status line in the result stack (empty / degraded).
    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(theme.id == .control ? theme.mono(10.5) : theme.body(theme.id == .ink ? 14 : 12.5))
            .italic(theme.id == .ink)
            .foregroundStyle(theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .modifier(PaletteCard(theme: theme))
    }

    private func actionChip(_ label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(chipLabel(label))
                .font(chipFont)
                .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background((theme.id == .ink ? theme.ink : theme.accent).opacity(theme.id == .ink ? 0.03 : 0.06))
                .clipShape(chipShape)
                .overlay(chipShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.accent.opacity(theme.id == .soft ? 0.35 : 0.3),
                    lineWidth: theme.id == .soft ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ label: String) -> String {
        theme.id == .control ? label.uppercased() : label
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 22 : (theme.id == .control ? 6 : 0),
                         style: .continuous)
    }

    private var chipFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    /// Roster-style status line: task + elapsed while working, else preview.
    private func liveLine(for bot: Bot) -> String {
        guard bot.status == .working, let task = bot.task else { return bot.preview }
        switch theme.id {
        case .soft: return "\(task) · \(bot.minutesElapsed)m"
        case .control: return "▸ \(task) · \(String(format: "%02d", bot.minutesElapsed))m"
        case .ink: return "\(task) — \(bot.minutesElapsed) minutes gone"
        }
    }

    // MARK: Live session search

    /// Debounce the server search: every keystroke cancels the pending task
    /// and restarts the 250 ms timer, so a fast typist issues one request.
    private func scheduleSessionSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard model.mode == .live, q.count >= Self.minimumLiveQuery else {
            sessionHits = []
            searchState = .idle
            return
        }
        guard model.client != nil, !model.isOffline else {
            sessionHits = []
            searchState = .unreachable
            return
        }
        searchState = .searching
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await performSessionSearch(q)
        }
    }

    /// Return key — skip the debounce and search on what is typed now.
    private func runSessionSearchNow() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard model.mode == .live, q.count >= Self.minimumLiveQuery,
              model.client != nil, !model.isOffline else { return }
        searchState = .searching
        searchTask = Task { @MainActor in
            await performSessionSearch(q)
        }
    }

    private func performSessionSearch(_ q: String) async {
        let hits = await model.searchSessions(q)
        // A slow response must not overwrite results for a newer query.
        guard !Task.isCancelled, q == trimmedQuery else { return }
        sessionHits = hits.map {
            PaletteSession(sessionID: $0.sessionID, botID: $0.botID, title: $0.title,
                           snippet: $0.snippet, when: $0.when)
        }
        searchState = .done
    }

    // MARK: Routing

    private func close() {
        searchTask?.cancel()
        query = ""
        sessionHits = []
        searchState = .idle
        isPresented = false
    }

    private func openBot(_ id: String) {
        close()
        model.selectedTab = .home
        // openChat (not a raw openBotID write) clears unread and resumes the
        // live session with deferred history.
        model.openChat(botID: id)
    }

    private func openSession(_ hit: PaletteSession) {
        close()
        model.selectedTab = .home
        onAction?(.openSession(botID: hit.botID, sessionID: hit.sessionID))
    }
}

// MARK: - Result view models

/// One session result, from either the live search endpoint or the demo index.
private struct PaletteSession: Identifiable, Equatable {
    /// Session ids are only unique within a profile, so rows key on bot+session.
    let id: String
    let sessionID: String
    let botID: String
    let title: String
    let snippet: String
    let when: String

    init(sessionID: String, botID: String, title: String, snippet: String, when: String) {
        self.id = botID + "/" + sessionID
        self.sessionID = sessionID
        self.botID = botID
        self.title = title
        self.snippet = snippet
        self.when = when
    }
}

// MARK: - Palette copy (three voices, same as CopyPack proper)

extension CopyPack {
    func paletteLiveNow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Live now"
        case .control: "LIVE NOW"
        case .ink: "AT WORK NOW"
        }
    }

    func paletteActions(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Actions"
        case .control: "ACTIONS"
        case .ink: "DEEDS"
        }
    }

    func paletteSessionsHead(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions"
        case .control: "SESSIONS"
        case .ink: "AUDIENCES"
        }
    }

    func paletteSearching(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Searching…"
        case .control: "QUERYING…"
        case .ink: "SEEKING…"
        }
    }

    func paletteNoMatches(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing matches that."
        case .control: "NO MATCHES."
        case .ink: "Nothing of that name is written here."
        }
    }

    func paletteSearchUnreachable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions live on the gateway — reconnect to search them."
        case .control: "LINK DOWN — SESSION INDEX UNREACHABLE."
        case .ink: "The way is severed; the past audiences cannot be read."
        }
    }

    func paletteCapabilities(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Capabilities"
        case .control: "CAPABILITIES"
        case .ink: "gifts & arts"
        }
    }

    func paletteSessionsAction(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions…"
        case .control: "SESSIONS…"
        case .ink: "past audiences…"
        }
    }

    func paletteCycleTheme(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Cycle theme"
        case .control: "CYCLE THEME"
        case .ink: "change the guise"
        }
    }

    func paletteAddGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add gateway"
        case .control: "ADD UPLINK"
        case .ink: "open a way"
        }
    }
}

// MARK: - Result card chrome

private struct PaletteCard: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        content
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .shadow(color: theme.rowStyle == .card ? theme.ink.opacity(0.04) : .clear,
                    radius: 2, y: 1)
    }
}

// MARK: - Wrapping chip layout

private struct WrapLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Shared helpers (file-scoped copies; each screen file keeps its own)

private extension ThemePack {
    /// The design's `scrim` token, derived from pack colors.
    var scrimColor: Color {
        id == .control ? Color.black.opacity(0.62) : ink.opacity(0.4)
    }
}

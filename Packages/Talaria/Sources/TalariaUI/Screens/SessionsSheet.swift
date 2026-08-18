import SwiftUI
import TalariaKit
import TalariaTheme

// The bot's stored sessions — desktop's sidebar session list, folded into one
// phone sheet (PARITY.md §4 "Sessions & history").
//
// Rows come from session.list {limit:200, profile}; tapping one resumes it by
// durable key and rebinds the chat. Swiping a row renames (session.title /
// PATCH) or deletes it (session.delete, which refuses a live session with
// 4023). The overflow carries the turn controls that act on the bot's current
// session: branch, compress and export. Typing filters the loaded rows and,
// past two characters, also runs the gateway's full-text index so a phrase
// from inside a conversation finds it.

@MainActor
public struct SessionsSheet: View {
    private let model: AppModel
    private let botID: String
    private let onOpen: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var loading = true
    @State private var loadError: String?
    /// Full-text hits that are not already in the loaded page.
    @State private var hits: [SessionSearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var outcome: SessionActionOutcome?
    @State private var working = false
    @State private var renameTarget: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    /// `onOpen` fires after the chat has been rebound onto the tapped
    /// session, so the host can bring the chat forward.
    public init(model: AppModel, botID: String, onOpen: ((String) -> Void)? = nil) {
        self.model = model
        self.botID = botID
        self.onOpen = onOpen
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Ink names its familiars; the others use handles.
    private var displayName: String {
        theme.id == .ink ? botID.prefix(1).uppercased() + botID.dropFirst() : "@" + botID
    }

    // MARK: - Rows

    /// One list row, from either the loaded page or the full-text index.
    private struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let when: String
        let messageCount: Int
        let preview: String
        /// A full-text hit outside the loaded page — no local counts for it.
        let remote: Bool
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var storedRows: [Row] {
        let stored = model.chats[botID]?.storedSessions ?? []
        let needle = trimmedQuery
        return stored.compactMap { session in
            let preview = model.sessionPreview(session.id) ?? ""
            guard needle.isEmpty
                    || session.title.lowercased().contains(needle)
                    || preview.lowercased().contains(needle) else { return nil }
            return Row(id: session.id, title: session.title, when: session.when,
                       messageCount: session.messageCount, preview: preview, remote: false)
        }
    }

    private var remoteRows: [Row] {
        let known = Set(storedRows.map(\.id))
        return hits.compactMap { hit in
            guard !known.contains(hit.sessionID) else { return nil }
            return Row(id: hit.sessionID, title: hit.title, when: hit.when,
                       messageCount: 0, preview: hit.snippet, remote: true)
        }
    }

    private var isEmpty: Bool { storedRows.isEmpty && remoteRows.isEmpty }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.sessKicker(theme.id),
                         title: copy.sessionsSec) {
                HStack(spacing: 8) {
                    if model.mode == .live { overflow }
                    HeaderIconButton(theme: theme, action: { dismiss() }) {
                        Text(verbatim: "✕")
                            .font(theme.body(13, weight: .bold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.sub)
                    }
                }
            }

            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            if working || outcome != nil {
                statusCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            list
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .presentationDetents([.large])
        .overlay { if renameTarget != nil { renameOverlay } }
        .task(id: botID) { await load() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Header pieces

    private var overflow: some View {
        Menu {
            Button(copy.sessBranch(theme.id)) { run { await model.branchSession(botID: botID) } }
            Button(copy.sessCompress(theme.id)) { run { await model.compressSession(botID: botID) } }
            Button(copy.sessExport(theme.id)) { run { await model.exportSession(botID: botID) } }
        } label: {
            Text(verbatim: "···")
                .font(theme.body(15, weight: .black))
                .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                .frame(width: 32, height: 32)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(iconShape)
                .overlay(iconShape.strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong,
                                                lineWidth: 1))
                .contentShape(iconShape)
        }
        .menuStyle(.borderlessButton)
        .disabled(working)
        .opacity(working ? 0.5 : 1)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32 * theme.iconCornerFraction, style: .continuous)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text(verbatim: "⌕")
                .font(theme.mono(15, weight: .semibold))
                .foregroundStyle(theme.faint)
            TextField(copy.sessSearchPlaceholder(theme.id), text: $query)
                .textFieldStyle(.plain)
                .font(theme.id == .control ? theme.mono(12) : theme.body(13.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                } label: {
                    Text(verbatim: "✕")
                        .font(theme.body(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.inset,
                    in: RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    /// One slot for both "an action is running" and "here is what it did".
    private var statusCard: some View {
        HStack(alignment: .top, spacing: 9) {
            if working {
                ProgressView().controlSize(.small).tint(theme.accent)
            } else if let outcome {
                Text(verbatim: outcome.ok ? "✓" : "!")
                    .font(theme.mono(12, weight: .bold))
                    .foregroundStyle(outcome.ok ? theme.ok : theme.danger)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(working ? copy.sessWorking(theme.id) : (outcome?.headline ?? ""))
                    .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                               : theme.body(12.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                if let detail = outcome?.detail, !detail.isEmpty, !working {
                    Text(detail)
                        .font(theme.id == .control ? theme.mono(9.5) : theme.body(11.5))
                        .foregroundStyle(theme.sub)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !working, outcome != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { outcome = nil }
                } label: {
                    Text(verbatim: "✕")
                        .font(theme.body(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(outcome?.ok == false ? theme.danger.opacity(0.5) : theme.line,
                          lineWidth: 1))
    }

    // MARK: - List

    private var list: some View {
        List {
            if loading {
                loadingRow
            } else if let loadError {
                noteRow(loadError, tone: theme.danger)
            } else if isEmpty {
                noteRow(trimmedQuery.isEmpty ? copy.sessEmpty(theme.id)
                                             : copy.sessNoMatches(theme.id),
                        tone: theme.sub)
            }

            ForEach(storedRows) { row in sessionRow(row) }

            if !remoteRows.isEmpty {
                sectionLabel(copy.sessFullText(theme.id))
                ForEach(remoteRows) { row in sessionRow(row) }
            }

            if !loading, !isEmpty {
                noteRow(copy.sessFootnote(theme.id), tone: theme.faint)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .refreshable { await load() }
    }

    private func sessionRow(_ row: Row) -> some View {
        Button {
            open(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(theme.id == .ink ? theme.body(15.5, weight: .semibold)
                                               : theme.body(13.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(metaLine(row))
                        .font(theme.id == .soft ? theme.body(11, weight: .medium)
                                                : theme.mono(theme.id == .ink ? 9 : 10))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                    if !row.preview.isEmpty {
                        Text(row.preview)
                            .font(theme.id == .control ? theme.mono(10)
                                                       : theme.body(theme.id == .ink ? 13 : 12))
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.sub)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "›")
                    .font(theme.body(13, weight: .semibold))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 1)
            }
            .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SessionRowChrome(theme: theme))
        .listRowInsets(EdgeInsets(top: theme.rowStyle == .ledger ? 0 : 3, leading: 20,
                                  bottom: theme.rowStyle == .ledger ? 0 : 3, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { delete(row) } label: {
                Text(copy.sessDelete(theme.id))
            }
            Button { startRename(row) } label: {
                Text(copy.sessRename(theme.id))
            }
            .tint(theme.accent)
        }
        .contextMenu {
            Button(copy.sessRename(theme.id)) { startRename(row) }
            Button(copy.sessDelete(theme.id), role: .destructive) { delete(row) }
        }
    }

    private func metaLine(_ row: Row) -> String {
        guard !row.remote, row.messageCount > 0 else { return row.when }
        return "\(row.when) · \(row.messageCount) \(copy.sessMessages(theme.id))"
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(theme.accent)
            Text(verbatim: "session.list…")
                .font(theme.mono(11))
                .foregroundStyle(theme.faint)
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)
    }

    private func noteRow(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(theme.id == .control ? theme.mono(10) : theme.body(12))
            .italic(theme.id == .ink)
            .foregroundStyle(tone)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.bg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.id == .soft ? theme.body(11, weight: .heavy) : theme.mono(9, weight: .bold))
            .tracking(theme.id == .soft ? 1 : 2)
            .foregroundStyle(theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.bg)
    }

    // MARK: - Rename (themed; a system alert would break all three looks)

    private var renameOverlay: some View {
        ZStack {
            theme.bg.opacity(theme.id == .control ? 0.86 : 0.72)
                .ignoresSafeArea()
                .onTapGesture { cancelRename() }

            VStack(alignment: .leading, spacing: 12) {
                Text(copy.sessRenameTitle(theme.id))
                    .font(theme.id == .ink ? theme.display(20, weight: .bold).smallCaps()
                                           : theme.body(16, weight: .heavy))
                    .foregroundStyle(theme.ink)

                TextField(copy.sessRenamePlaceholder(theme.id), text: $renameText)
                    .textFieldStyle(.plain)
                    .font(theme.id == .control ? theme.mono(13) : theme.body(14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                    .background(theme.inset,
                                in: RoundedRectangle(cornerRadius: theme.inputRadius,
                                                     style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))

                // The secondary button style is the deny/abort treatment
                // (red-bordered in control) — wrong voice for a cancel, so
                // this uses the sheets' quiet text-button affordance.
                HStack(spacing: 12) {
                    Button(copy.cancel) { cancelRename() }
                        .font(theme.body(13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    ThemedPrimaryButton(theme: theme, title: copy.sessRenameOK(theme.id),
                                        compact: true) {
                        commitRename()
                    }
                    .frame(maxWidth: 150)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: 340)
            .background(theme.panel,
                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func load() async {
        await model.refreshSessions(botID: botID)
        loadError = model.sessionsLoadError(for: botID)
        loading = false
    }

    private func open(_ row: Row) {
        model.openStoredSession(row.id, botID: botID)
        onOpen?(row.id)
        dismiss()
    }

    private func delete(_ row: Row) {
        Task { @MainActor in
            working = true
            let failure = await model.deleteStoredSession(row.id, botID: botID)
            working = false
            hits.removeAll { $0.sessionID == row.id }
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            }
        }
    }

    private func startRename(_ row: Row) {
        renameText = row.title
        withAnimation(.easeOut(duration: 0.2)) { renameTarget = row.id }
        renameFocused = true
    }

    private func cancelRename() {
        renameFocused = false
        withAnimation(.easeOut(duration: 0.2)) { renameTarget = nil }
    }

    private func commitRename() {
        guard let id = renameTarget else { return }
        let title = renameText
        cancelRename()
        Task { @MainActor in
            working = true
            let failure = await model.renameStoredSession(id, botID: botID, to: title)
            working = false
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            } else {
                // A renamed row can also be a full-text hit; keep both in step.
                hits = hits.map { hit in
                    guard hit.sessionID == id else { return hit }
                    var renamed = hit
                    renamed.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return renamed
                }
            }
        }
    }

    /// Run one overflow action, showing the spinner while it is in flight.
    private func run(_ action: @escaping () async -> SessionActionOutcome) {
        guard !working else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                outcome = nil
                working = true
            }
            let result = await action()
            withAnimation(.easeOut(duration: 0.2)) {
                working = false
                outcome = result
            }
        }
    }

    /// Local filtering is instant; the gateway's FTS index is a round trip, so
    /// it is debounced and only runs once the query is worth an index lookup.
    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.mode == .live, !model.isOffline, q.count >= 2 else {
            hits = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await model.searchSessions(q, botID: botID)
            guard !Task.isCancelled,
                  q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            hits = found
        }
    }
}

// MARK: - Row chrome (card / terminal panel / ruled ledger)

private struct SessionRowChrome: ViewModifier {
    let theme: ThemePack

    @ViewBuilder func body(content: Content) -> some View {
        if theme.rowStyle == .ledger {
            // Ink: bare ledger lines, no card chrome.
            content.overlay(alignment: .bottom) {
                Rectangle().fill(theme.line).frame(height: 1)
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
            content
                .background(shape.fill(theme.panel))
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.rowStyle == .card ? theme.ink.opacity(0.04) : .clear,
                        radius: 2, y: 1)
        }
    }
}

// MARK: - Sessions copy (three voices, same shape as CopyPack proper)

extension CopyPack {
    func sessKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "KEPT ON THE GATEWAY"
        case .control: "SESSION STORE"
        case .ink: "WRITTEN IN THE HOUSE"
        }
    }

    func sessSearchPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search titles and transcripts…"
        case .control: "QUERY TITLES / TRANSCRIPTS…"
        case .ink: "seek among the audiences…"
        }
    }

    func sessEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No stored sessions yet. Say something and this bot's first conversation lands here."
        case .control: "NO STORED SESSIONS. FIRST TRANSMISSION CREATES ONE."
        case .ink: "Nothing is written here yet. Speak, and the first audience is recorded."
        }
    }

    func sessNoMatches(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing matches that."
        case .control: "NO MATCHES."
        case .ink: "Nothing of that name is written here."
        }
    }

    func sessFullText(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Found in transcripts"
        case .control: "TRANSCRIPT MATCHES"
        case .ink: "FOUND WITHIN THE TEXT"
        }
    }

    func sessMessages(_ t: ThemeID) -> String {
        switch t {
        case .soft: "msgs"
        case .control: "MSG"
        case .ink: "exchanges"
        }
    }

    func sessFootnote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Swipe a session to rename or delete it. Tap to pick up where it left off."
        case .control: "SWIPE A ROW: RENAME / DELETE. TAP TO REATTACH."
        case .ink: "Draw a row aside to rename or strike it out. Touch one to resume that audience."
        }
    }

    func sessWorking(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Working…"
        case .control: "EXECUTING…"
        case .ink: "the work is under way…"
        }
    }

    func sessRename(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "RENAME"
        case .ink: "rename"
        }
    }

    func sessDelete(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "DELETE"
        case .ink: "strike out"
        }
    }

    func sessRenameTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename session"
        case .control: "RENAME SESSION"
        case .ink: "Rename this audience"
        }
    }

    func sessRenamePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Session title"
        case .control: "TITLE"
        case .ink: "its title"
        }
    }

    func sessRenameOK(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "SET"
        case .ink: "inscribe"
        }
    }

    func sessRenameEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A session needs a title."
        case .control: "TITLE REQUIRED."
        case .ink: "It must be given a name."
        }
    }

    func sessBranch(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Branch this session"
        case .control: "BRANCH"
        case .ink: "fork this audience"
        }
    }

    func sessCompress(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Compress context"
        case .control: "COMPRESS CONTEXT"
        case .ink: "distil the vessel"
        }
    }

    func sessExport(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Export snapshot"
        case .control: "EXPORT SNAPSHOT"
        case .ink: "seal a copy"
        }
    }

    func sessBranched(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Branched — the fork is in the list below."
        case .control: "BRANCHED — FORK ADDED TO STORE."
        case .ink: "Forked; the new audience is written below."
        }
    }

    func sessExported(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Snapshot written on the gateway"
        case .control: "SNAPSHOT WRITTEN ON GATEWAY HOST"
        case .ink: "A copy is sealed in the house"
        }
    }

    func sessNoLiveSession(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open this bot's chat first — these act on a live session."
        case .control: "NO LIVE SESSION — ATTACH BEFORE ISSUING CONTROLS."
        case .ink: "No audience is in progress; open one first."
        }
    }

    func sessDeleteLive(_ t: ThemeID) -> String {
        switch t {
        case .soft: "That session is still running. Stop the turn, then delete it."
        case .control: "SESSION LIVE — INTERRUPT BEFORE DELETE."
        case .ink: "It is still at work; you cannot strike it out yet."
        }
    }

    func sessUnreachable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions live on the gateway — reconnect to read them."
        case .control: "LINK DOWN — SESSION STORE UNREACHABLE."
        case .ink: "The way is severed; the past audiences cannot be read."
        }
    }

    func sessFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused that."
        case .control: "GATEWAY REFUSED."
        case .ink: "The house would not have it."
        }
    }
}

import SwiftUI
import TalariaKit
import TalariaTheme

// The slash-command surface. Desktop has a composer popover plus a completion
// drawer; on a phone the same job is a sheet you open by typing "/" (or from
// the composer) — search on top, the catalog grouped by category underneath,
// skill commands in their own section at the bottom.
//
// Filtering is two-layer: the cached catalog filters instantly on every
// keystroke, and a debounced complete.slash re-orders the result with the
// gateway's own ranking (usage-weighted, and it matches descriptions, which no
// local prefix filter can do). When a typed token matches nothing, one
// command.resolve call surfaces the canonical spelling of an alias.
//
// Also here: MCPSetupPrompt, the card that answers a parked mcp.setup.request.

public struct CommandPaletteSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let model: AppModel
    private let botID: String
    private let onPick: (String) -> Void

    @State private var query = ""
    @State private var catalog: [SlashCommand] = []
    @State private var completions: [SlashCommand] = []
    /// command.resolve fallback when nothing local or remote matched.
    @State private var resolved: SlashCommand?
    @State private var loading = true
    @State private var completionTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// - Parameter onPick: receives the text to place in the composer, with a
    ///   trailing space when the command expects an argument. Zero-argument
    ///   commands never reach it — those run immediately.
    public init(model: AppModel, botID: String, onPick: @escaping (String) -> Void) {
        self.model = model
        self.botID = botID
        self.onPick = onPick
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    // MARK: - Result pipeline

    /// The query as the gateway wants it: trimmed and slash-prefixed.
    private func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// Lowercased, slash-stripped command token for local matching. Only the
    /// leading token counts: once the user types "/undo 2" the argument is not
    /// part of the name they are searching for.
    private var needle: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return bare.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    private var rows: [SlashCommand] {
        guard !needle.isEmpty else { return catalog }
        var byName: [String: SlashCommand] = [:]
        for command in catalog { byName[command.name.lowercased()] = command }

        // Gateway order first (it ranks), then local-only description matches.
        var ordered: [SlashCommand] = []
        var seen = Set<String>()
        for item in completions where seen.insert(item.name.lowercased()).inserted {
            ordered.append(byName[item.name.lowercased()] ?? item)
        }
        for command in catalog
        where !seen.contains(command.name.lowercased()) && command.matches(needle) {
            seen.insert(command.name.lowercased())
            ordered.append(command)
        }
        if ordered.isEmpty, let resolved, !seen.contains(resolved.name.lowercased()) {
            ordered.append(resolved)
        }
        return ordered
    }

    private struct CommandSection: Identifiable {
        var id: String
        var title: String
        var rows: [SlashCommand]
        var isSkills: Bool
    }

    private var sections: [CommandSection] {
        var order: [String] = []
        var buckets: [String: [SlashCommand]] = [:]
        var skills: [SlashCommand] = []
        for row in rows {
            if row.kind == .skill { skills.append(row); continue }
            // Completion-only rows (the gateway's /density, /details, /logs
            // extras) carry no category and fall into the catch-all bucket.
            let key = row.category
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }
        var out = order.map { key in
            CommandSection(id: "cat:" + key,
                           title: key.isEmpty ? copy.commandsOtherSection(theme.id) : sectionLabel(key),
                           rows: buckets[key] ?? [], isSkills: false)
        }
        if !skills.isEmpty {
            out.append(CommandSection(id: "skills",
                                      title: copy.commandsSkillsSection(theme.id),
                                      rows: skills, isSkills: true))
        }
        return out
    }

    /// Category names arrive as data ("Session", "User commands"); only their
    /// casing is ours to theme.
    private func sectionLabel(_ raw: String) -> String {
        theme.id == .soft ? raw : raw.uppercased()
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            content
        }
        .background(theme.bg)
        .presentationDetents([.large])
        .presentationBackground(theme.bg)
        .task {
            catalog = await model.slashCatalog()
            loading = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onChange(of: query) { _, updated in
            refreshCompletions(for: updated)
        }
        .onDisappear { completionTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: theme.id == .control ? 3 : 1) {
                if theme.showsKicker {
                    Text(copy.commandsKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(theme.id == .control ? 2.5 : 2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                titleText
            }
            Spacer(minLength: 8)
            Button(copy.cancel) { dismiss() }
                .font(theme.id == .control ? theme.mono(11, weight: .bold)
                                           : theme.body(13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var titleText: some View {
        switch theme.id {
        case .soft:
            Text(copy.commandsTitle(.soft))
                .font(theme.body(26, weight: .heavy)).tracking(-0.5)
                .foregroundStyle(theme.ink)
        case .control:
            Text(copy.commandsTitle(.control))
                .font(theme.body(23, weight: .heavy)).tracking(-0.3)
                .foregroundStyle(theme.ink)
        case .ink:
            Text(copy.commandsTitle(.ink))
                .font(theme.display(25).smallCaps()).tracking(0.5)
                .foregroundStyle(theme.ink)
        }
    }

    private var searchField: some View {
        TextField("", text: $query,
                  prompt: Text(copy.commandsSearchPlaceholder(theme.id))
                    .foregroundStyle(theme.faint))
            .textFieldStyle(.plain)
            .font(inputFont)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .focused($focused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .submitLabel(.go)
            .onSubmit { submitTypedCommand() }
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(inputShape.fill(theme.panel))
            .overlay(inputShape.strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line,
                                             lineWidth: 1))
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 21), style: .continuous)
    }

    private var inputFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5)
        case .control: theme.mono(13)
        case .ink: theme.body(15)
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            statusBlock {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(copy.commandsLoading(theme.id))
                        .font(theme.mono(11))
                        .foregroundStyle(theme.faint)
                }
            }
        } else if model.slashCatalogFailed {
            statusBlock {
                VStack(spacing: 12) {
                    Text(copy.commandsCatalogFailed(theme.id))
                        .font(theme.body(theme.id == .ink ? 15 : 13.5))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.sub)
                        .multilineTextAlignment(.center)
                    if !model.slashCatalogWarning.isEmpty {
                        Text(model.slashCatalogWarning)
                            .font(theme.mono(10))
                            .foregroundStyle(theme.faint)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    ThemedPrimaryButton(theme: theme, title: copy.commandsRetry(theme.id),
                                        compact: true) {
                        loading = true
                        Task { @MainActor in
                            catalog = await model.reloadSlashCatalog()
                            loading = false
                        }
                    }
                    .frame(maxWidth: 220)
                }
            }
        } else if rows.isEmpty {
            statusBlock {
                Text(copy.commandsEmpty(theme.id))
                    .font(theme.body(theme.id == .ink ? 15 : 13.5))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.faint)
            }
        } else {
            results
        }
    }

    private func statusBlock<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack {
            Spacer(minLength: 24)
            inner()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, 60)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.rowStyle == .ledger ? 0 : 7) {
                if !model.slashCatalogWarning.isEmpty {
                    warningBanner
                }
                ForEach(sections) { section in
                    sectionHeader(section)
                    ForEach(section.rows) { row in
                        commandRow(row)
                    }
                    if theme.rowStyle != .ledger {
                        Color.clear.frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Skill/quick-command discovery failed server-side but the rest of the
    /// catalog is good — a banner, never an error screen.
    private var warningBanner: some View {
        Text(model.slashCatalogWarning)
            .font(theme.mono(10))
            .foregroundStyle(theme.warn)
            .lineLimit(2)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.warn.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 8))
            .padding(.bottom, 4)
    }

    private func sectionHeader(_ section: CommandSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(theme.mono(theme.id == .soft ? 10 : 9.5, weight: .bold))
                .tracking(theme.id == .soft ? 1.2 : 2)
                .foregroundStyle(theme.id == .control ? theme.accent : theme.faint)
            if section.isSkills, model.slashSkillCount > 0 {
                Text(verbatim: "\(model.slashSkillCount)")
                    .font(theme.mono(9.5))
                    .foregroundStyle(theme.faint)
                    .monospacedDigit()
            }
            if theme.id == .ink {
                Rectangle().fill(theme.lineStrong).frame(height: 1)
            }
        }
        .padding(.top, theme.rowStyle == .ledger ? 16 : 10)
        .padding(.bottom, theme.rowStyle == .ledger ? 6 : 2)
    }

    private func commandRow(_ row: SlashCommand) -> some View {
        Button { pick(row) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.name)
                            .font(nameFont)
                            .foregroundStyle(row.kind == .skill ? theme.accent : theme.ink)
                        if !row.usage.isEmpty {
                            Text(row.usage)
                                .font(theme.mono(theme.id == .ink ? 9 : 10))
                                .foregroundStyle(theme.faint)
                                .lineLimit(1)
                        }
                    }
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(descriptionFont)
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.sub)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    if !row.aliases.isEmpty {
                        Text(row.aliases.joined(separator: " · "))
                            .font(theme.mono(theme.id == .ink ? 8.5 : 9.5))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(runsImmediately(row) ? copy.commandsRunHint(theme.id)
                                          : copy.commandsArgHint(theme.id))
                    .font(theme.mono(theme.id == .ink ? 8.5 : 9))
                    .tracking(theme.id == .control ? 1.2 : 0.4)
                    .foregroundStyle(runsImmediately(row) ? theme.accent : theme.faint)
            }
            .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CommandRowChrome(theme: theme))
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .bold)
        case .control: theme.mono(12.5, weight: .bold)
        case .ink: theme.mono(12, weight: .semibold)
        }
    }

    private var descriptionFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10.5)
        case .ink: theme.body(13.5)
        }
    }

    // MARK: - Actions

    /// Zero-argument *commands* fire straight from the list. Skills always read
    /// a prompt, so they land in the composer even when the catalog carries no
    /// usage hint for them.
    private func runsImmediately(_ row: SlashCommand) -> Bool {
        row.kind == .command && !row.takesArguments
    }

    private func pick(_ row: SlashCommand) {
        if runsImmediately(row) {
            Task { @MainActor in await model.runSlash(row.name, botID: botID) }
        } else {
            onPick(row.name + " ")
        }
        dismiss()
    }

    /// Return in the search field: a typed command with an argument runs as
    /// typed ("/undo 2"), otherwise the top hit is picked.
    private func submitTypedCommand() {
        let typed = normalized(query)
        guard !typed.isEmpty else { return }
        if typed.contains(" ") {
            Task { @MainActor in await model.runSlash(typed, botID: botID) }
            dismiss()
            return
        }
        if let first = rows.first { pick(first) }
    }

    /// Debounced complete.slash, with one command.resolve fallback when
    /// nothing matched — the gateway knows spellings the catalog omits.
    private func refreshCompletions(for raw: String) {
        completionTask?.cancel()
        completions = []
        resolved = nil
        let text = normalized(raw)
        // Only while a command token is under the cursor: past the first space
        // complete.slash switches to argument completions ("/details c"), which
        // are not commands and have no place in a command list.
        guard model.mode == .live, text.count > 1, !text.contains(" ") else { return }
        completionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = await model.slashCompletions(for: text)
            guard !Task.isCancelled, normalized(query) == text else { return }
            completions = result.items
            guard result.items.isEmpty else { return }
            let hit = await model.resolveSlashCommand(text)
            guard !Task.isCancelled, normalized(query) == text else { return }
            resolved = hit
        }
    }
}

// MARK: - Row chrome

/// Floating card in soft, bordered terminal panel in control, ruled ledger line
/// in ink — the same three-way split every list in the app uses.
private struct CommandRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 2, y: 1)
        case .terminal:
            content
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .strokeBorder(theme.lineStrong.opacity(0.8), lineWidth: 1))
        case .ledger:
            content
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
        }
    }
}

// MARK: - MCP setup prompt

/// Answers a parked `mcp.setup.request`. The agent's tool thread is blocked for
/// up to 600 s waiting on `mcp.setup.respond`, so this card exists to end that
/// wait in seconds. Drop it into the root ZStack unconditionally — it renders
/// nothing until a request arrives.
public struct MCPSetupPrompt: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        if let request = model.mcpSetupPrompt {
            ZStack {
                // No tap-to-dismiss: the agent is parked until this is answered,
                // and a stray tap must not look like a decision.
                (theme.id == .control ? Color.black.opacity(0.66) : theme.ink.opacity(0.42))
                    .ignoresSafeArea()
                card(request)
                    .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    private func card(_ request: MCPSetupRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.mcpSetupKicker(theme.id))
                .font(theme.mono(9.5, weight: .bold))
                .tracking(theme.id == .soft ? 1.4 : 2.2)
                .foregroundStyle(theme.id == .control ? theme.warn : theme.accent)

            Text(copy.mcpSetupTitle(theme.id))
                .font(titleFont)
                .foregroundStyle(theme.ink)

            Text(copy.mcpSetupAsk(theme.id, server: request.server, action: request.action))
                .font(theme.id == .control ? theme.mono(11.5) : theme.body(theme.id == .ink ? 15 : 13.5))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            if !request.reason.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.mcpSetupReasonLabel(theme.id))
                        .font(theme.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(theme.faint)
                    Text(request.reason)
                        .font(theme.id == .control ? theme.mono(11) : theme.body(13))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 8))
            }

            Text(copy.mcpSetupNote(theme.id))
                .font(theme.id == .control ? theme.mono(9.5) : theme.body(11.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ThemedPrimaryButton(theme: theme, title: copy.mcpSetupDefer(theme.id)) {
                    model.answerMCPSetup(request, .deferToDesktop)
                }
                ThemedSecondaryButton(theme: theme, title: copy.mcpSetupDecline(theme.id),
                                      fillsWidth: true) {
                    model.answerMCPSetup(request, .decline)
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.id == .control ? theme.warn.opacity(0.4) : theme.lineStrong,
                          lineWidth: 1))
        .shadow(color: theme.glowRadius > 0 ? theme.warn.opacity(0.18) : theme.ink.opacity(0.18),
                radius: theme.glowRadius > 0 ? 14 : 18, y: 6)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(19, weight: .heavy)
        case .control: theme.body(17, weight: .heavy)
        case .ink: theme.display(21).smallCaps()
        }
    }
}

// MARK: - Themed copy

/// Voice for the command palette and the MCP setup card. Detail strings the
/// *agent* reads (the mcp.setup.respond payload) stay plain English in
/// AppModelLive+Commands — only what a person sees is themed.
public extension CopyPack {

    func commandsKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "COMMAND PALETTE"
        case .control: "COMMAND BUS"
        case .ink: "THE INVOCATIONS"
        }
    }

    func commandsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Commands"
        case .control: "Commands"
        case .ink: "Invocations"
        }
    }

    func commandsSearchPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search commands & skills…"
        case .control: "FILTER — /status, /compress…"
        case .ink: "seek an invocation…"
        }
    }

    func commandsSkillsSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Skills"
        case .control: "SKILLS"
        case .ink: "GIFTS"
        }
    }

    func commandsOtherSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Other"
        case .control: "MISC"
        case .ink: "SUNDRY"
        }
    }

    func commandsLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Loading commands…"
        case .control: "commands.catalog…"
        case .ink: "reading the catalogue…"
        }
    }

    func commandsEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No command matches."
        case .control: "NO MATCH."
        case .ink: "No invocation answers to that name."
        }
    }

    func commandsCatalogFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway didn’t return a command catalog."
        case .control: "CATALOG UNAVAILABLE — commands.catalog REFUSED."
        case .ink: "This gateway keeps no catalogue of invocations."
        }
    }

    func commandsRetry(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Try again"
        case .control: "RETRY"
        case .ink: "ask again"
        }
    }

    /// Trailing hint on a row that fires on tap.
    func commandsRunHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "run"
        case .control: "RUN"
        case .ink: "at once"
        }
    }

    /// Trailing hint on a row that lands in the composer for an argument.
    func commandsArgHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "needs input"
        case .control: "ARG"
        case .ink: "needs words"
        }
    }

    /// Slash execution attempted without a live gateway.
    func commandsUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Slash commands run on your gateway — connect one to use them."
        case .control: "NO LINK — slash.exec UNAVAILABLE."
        case .ink: "An invocation needs an open way to the gateway."
        }
    }

    func commandsNoOutput(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Done — no output."
        case .control: "(NO OUTPUT)"
        case .ink: "It is done; nothing was said."
        }
    }

    func commandsFailed(_ t: ThemeID, command: String, detail: String) -> String {
        switch t {
        case .soft: "\(command) failed — \(detail)"
        case .control: "\(command) — ERROR: \(detail)"
        case .ink: "\(command) was refused — \(detail)"
        }
    }

    // MARK: MCP setup card

    func mcpSetupKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TOOL SERVER"
        case .control: "MCP SETUP — AGENT BLOCKED"
        case .ink: "A PETITION FOR AN INSTRUMENT"
        }
    }

    func mcpSetupTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Set up a tool server?"
        case .control: "MCP SETUP REQUEST"
        case .ink: "An instrument is asked for"
        }
    }

    func mcpSetupAsk(_ t: ThemeID, server: String, action: MCPSetupRequest.Action) -> String {
        switch (t, action) {
        case (.soft, .install): "This bot wants to install the \(server) tool server."
        case (.soft, .enable): "This bot wants to re-enable the \(server) tool server."
        case (.soft, .authorize): "This bot wants to sign in to the \(server) tool server."
        case (.control, .install): "AGENT REQUESTS: INSTALL \(server.uppercased())"
        case (.control, .enable): "AGENT REQUESTS: ENABLE \(server.uppercased())"
        case (.control, .authorize): "AGENT REQUESTS: AUTHORIZE \(server.uppercased())"
        case (.ink, .install): "The familiar petitions to install the \(server) instrument."
        case (.ink, .enable): "The familiar petitions to restore the \(server) instrument."
        case (.ink, .authorize): "The familiar petitions for leave to enter \(server)."
        }
    }

    func mcpSetupReasonLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Why"
        case .control: "REASON"
        case .ink: "THE REASON GIVEN"
        }
    }

    func mcpSetupNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Talaria can’t run MCP setup on the phone — installs, enables and sign-ins live in the desktop app or `hermes mcp` in a terminal. Either answer unblocks the bot immediately."
        case .control: "TALARIA CANNOT RUN MCP SETUP — DESKTOP OR `hermes mcp` ONLY. EITHER ANSWER RELEASES THE AGENT NOW."
        case .ink: "This cannot be done from the pocket; it belongs to the desktop, or to `hermes mcp` at a terminal. Either answer frees the familiar at once."
        }
    }

    func mcpSetupDefer(_ t: ThemeID) -> String {
        switch t {
        case .soft: "I’ll do it on desktop"
        case .control: "DEFER TO DESKTOP"
        case .ink: "attend to it later"
        }
    }

    func mcpSetupDecline(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Not this one"
        case .control: "DECLINE"
        case .ink: "refuse"
        }
    }

    func mcpSetupDeferredLine(_ t: ThemeID, server: String) -> String {
        switch t {
        case .soft: "MCP setup for \(server) deferred to desktop — the bot was told to carry on."
        case .control: "MCP \(server.uppercased()) — DEFERRED. AGENT RELEASED."
        case .ink: "The petition for \(server) is set aside for the desktop; the familiar works on."
        }
    }

    func mcpSetupDeclinedLine(_ t: ThemeID, server: String) -> String {
        switch t {
        case .soft: "Declined MCP setup for \(server)."
        case .control: "MCP \(server.uppercased()) — DECLINED. AGENT RELEASED."
        case .ink: "The petition for \(server) is refused."
        }
    }
}

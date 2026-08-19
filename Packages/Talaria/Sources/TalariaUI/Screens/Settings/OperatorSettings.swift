import SwiftUI
import TalariaKit
import TalariaTheme

// Phone-relevant Hermes runtime controls that were explicitly left open by
// the original Settings pass. These are all ordinary authenticated config or
// log routes in the pinned gateway; no raw YAML/env editor is introduced.
//
// Pinned Hermes authority (b5455fdd):
//   GET /api/config[?profile=]          hermes_cli/web_server.py:6794
//   PUT /api/config {config, profile}   hermes_cli/web_server.py:7595
//   GET /api/logs                       hermes_cli/web_server.py:12298
//   agent.max_turns default             hermes_cli/config_defaults.py:46
//   agent.image_input_mode semantics    hermes_cli/config_defaults.py:309
//   persistent-memory switches          hermes_cli/config_defaults.py:1796

struct GatewayOperatorConfig: Equatable, Sendable {
    var maxTurns: Int
    var memoryEnabled: Bool
    var userProfileEnabled: Bool
    var memoryWriteApproval: Bool
    var imageInputMode: String

    init(_ value: JSONValue) {
        maxTurns = max(1, min(5_000, value["agent"]?["max_turns"]?.intValue ?? 500))
        memoryEnabled = value["memory"]?["memory_enabled"]?.boolValue ?? true
        userProfileEnabled = value["memory"]?["user_profile_enabled"]?.boolValue ?? true
        memoryWriteApproval = value["memory"]?["write_approval"]?.boolValue ?? false
        let mode = value["agent"]?["image_input_mode"]?.stringValue ?? "auto"
        imageInputMode = Self.imageModes.contains(mode) ? mode : "auto"
    }

    static let imageModes = ["auto", "native", "text"]
}

struct GatewayLogSnapshot: Equatable, Sendable {
    var file: String
    var lines: [String]

    init(_ value: JSONValue, fallbackFile: String) {
        file = value["file"]?.stringValue ?? fallbackFile
        lines = value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension GatewayClient {
    func operatorConfig(profile: String?) async throws -> GatewayOperatorConfig {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return GatewayOperatorConfig(try await restJSON(path: "api/config", query: query,
                                                        timeout: 30))
    }

    func gatewayLogs(file: String, level: String?, search: String,
                     lines: Int = 200) async throws -> GatewayLogSnapshot {
        var query = [URLQueryItem(name: "file", value: file),
                     URLQueryItem(name: "lines", value: String(max(1, min(500, lines))))]
        if let level, !level.isEmpty, level != "ALL" {
            query.append(URLQueryItem(name: "level", value: level))
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "search", value: trimmed)) }
        return GatewayLogSnapshot(
            try await restJSON(path: "api/logs", query: query, timeout: 30),
            fallbackFile: file)
    }
}

public struct OperatorSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateScopeKey: String?
    @State private var generation = 0
    @State private var config: GatewayOperatorConfig?
    @State private var draftMaxTurns = 500
    @State private var draftImageMode = "auto"
    @State private var isLoading = false
    @State private var busyField: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false

    @State private var logFile = "agent"
    @State private var logLevel = "ALL"
    @State private var logSearch = ""
    @State private var logs = GatewayLogSnapshot(.null, fallbackFile: "agent")
    @State private var logError: String?
    @State private var isLoadingLogs = false
    @State private var logGeneration = 0

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPickerSection }
            if !profileChoices.isEmpty { profilePickerSection }
            runtimeSection
            memorySection
            imageSection
            logsSection
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) {
            let key = scopeKey
            prepareForScope(key)
            await loadConfig(scopeKey: key)
            guard stateScopeKey == key else { return }
            await loadLogs(scopeKey: key)
        }
    }

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                           available: Set(gatewayChoices.map(\.id)),
                                           active: model.activeGatewayID,
                                           runtime: LiveRuntime.shared.gatewayID)
    }

    private var profileChoices: [Bot] {
        let target = targetGatewayID
        return model.unionRosterBots.filter { bot in
            if let route = model.profileRoute(for: bot.id) { return route.gatewayID == target }
            return target == model.activeGatewayID
        }
    }

    private var targetProfile: String? {
        let available = Set(profileChoices.compactMap { model.profileRoute(for: $0.id)?.profile ?? $0.id })
        return selectedProfile.flatMap { available.contains($0) ? $0 : nil }
    }

    private var scopeKey: String {
        "\(targetGatewayID ?? "demo")\u{1f}\(targetProfile ?? "__gateway__")"
    }

    private var gatewayPickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsOperatorGateway(theme.id),
                        footnote: copy.settingsOperatorGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsOperatorGateway(theme.id), selection: Binding(
                    get: { targetGatewayID }, set: { selectedGatewayID = $0; selectedProfile = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var profilePickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsOperatorProfile(theme.id),
                        footnote: copy.settingsOperatorProfileNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsOperatorProfile(theme.id), selection: $selectedProfile) {
                    Text(copy.settingsOperatorGatewayDefault(theme.id)).tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle).tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var runtimeSection: some View {
        SettingsSection(theme: theme, title: copy.settingsRuntimeSection(theme.id),
                        footnote: copy.settingsRuntimeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy.settingsMaxTurns(theme.id)).font(SettingsType.rowTitle(theme))
                        Text(copy.settingsMaxTurnsNote(theme.id))
                            .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    }
                    Spacer()
                    Stepper(value: $draftMaxTurns, in: 1...5_000, step: 25) {
                        Text("\(draftMaxTurns)").font(SettingsType.rowValue(theme))
                            .monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                    .fixedSize()
                }
                .modifier(SettingsRowChrome(theme: theme, isLast: false))
                SettingsActionRow(theme: theme, title: copy.settingsSaveMaxTurns(theme.id),
                                  isBusy: busyField == "agent.max_turns", isLast: true) {
                    Task { await saveMaxTurns() }
                }
                .disabled(config == nil || draftMaxTurns == config?.maxTurns)
            }
        }
    }

    private var memorySection: some View {
        SettingsSection(theme: theme, title: copy.settingsMemorySection(theme.id),
                        footnote: copy.settingsMemoryNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsToggleRow(theme: theme, title: copy.settingsMemoryEnabled(theme.id),
                                  subtitle: copy.settingsMemoryEnabledNote(theme.id),
                                  isOn: config?.memoryEnabled ?? false) {
                    Task { await saveBool(path: ["memory", "memory_enabled"],
                                          field: "memory.memory_enabled",
                                          value: !(config?.memoryEnabled ?? false),
                                          keyPath: \.memoryEnabled) }
                }
                SettingsToggleRow(theme: theme, title: copy.settingsUserProfileEnabled(theme.id),
                                  subtitle: copy.settingsUserProfileEnabledNote(theme.id),
                                  isOn: config?.userProfileEnabled ?? false) {
                    Task { await saveBool(path: ["memory", "user_profile_enabled"],
                                          field: "memory.user_profile_enabled",
                                          value: !(config?.userProfileEnabled ?? false),
                                          keyPath: \.userProfileEnabled) }
                }
                SettingsToggleRow(theme: theme, title: copy.settingsMemoryApproval(theme.id),
                                  subtitle: copy.settingsMemoryApprovalNote(theme.id),
                                  isOn: config?.memoryWriteApproval ?? false, isLast: true) {
                    Task { await saveBool(path: ["memory", "write_approval"],
                                          field: "memory.write_approval",
                                          value: !(config?.memoryWriteApproval ?? false),
                                          keyPath: \.memoryWriteApproval) }
                }
            }
            .disabled(config == nil || busyField != nil)
            .opacity(config == nil ? 0.55 : 1)
        }
    }

    private var imageSection: some View {
        SettingsSection(theme: theme, title: copy.settingsImageModeSection(theme.id),
                        footnote: copy.settingsImageModeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsImageModeSection(theme.id), selection: $draftImageMode) {
                    ForEach(GatewayOperatorConfig.imageModes, id: \.self) { mode in
                        Text(copy.settingsImageModeLabel(theme.id, mode: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                SettingsActionRow(theme: theme, title: copy.settingsSaveImageMode(theme.id),
                                  isBusy: busyField == "agent.image_input_mode", isLast: true) {
                    Task { await saveImageMode() }
                }
                .disabled(config == nil || draftImageMode == config?.imageInputMode)
            }
        }
    }

    private var logsSection: some View {
        SettingsSection(theme: theme, title: copy.settingsLogsSection(theme.id),
                        footnote: copy.settingsLogsNote(theme.id)) {
            SettingsGroup(theme: theme) {
                HStack(spacing: 8) {
                    Picker("", selection: $logFile) {
                        ForEach(["agent", "errors", "gateway", "gui", "desktop", "mcp"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("", selection: $logLevel) {
                        ForEach(["ALL", "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 10).padding(.vertical, 7)
                TextField(copy.settingsLogsSearch(theme.id), text: $logSearch)
                    .textFieldStyle(.plain).font(theme.mono(11))
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(theme.inset)
                    .modifier(SettingsRowChrome(theme: theme, isLast: false))
                SettingsActionRow(theme: theme, title: copy.settingsLogsRefresh(theme.id),
                                  isBusy: isLoadingLogs, isLast: true) {
                    Task { await loadLogs(scopeKey: scopeKey) }
                }
            }
            if let logError {
                Text(logError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            } else if logs.lines.isEmpty, !isLoadingLogs {
                Text(copy.settingsLogsEmpty(theme.id)).font(theme.mono(10)).foregroundStyle(theme.faint)
                    .padding(.horizontal, 2)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(logs.lines.joined(separator: "\n"))
                        .font(theme.mono(9.5)).foregroundStyle(theme.sub)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(theme.inset, in: RoundedRectangle(cornerRadius: theme.buttonRadius))
            }
        }
        .onChange(of: logFile) { _, _ in Task { await loadLogs(scopeKey: scopeKey) } }
        .onChange(of: logLevel) { _, _ in Task { await loadLogs(scopeKey: scopeKey) } }
    }

    private func prepareForScope(_ key: String) {
        guard stateScopeKey != key else { return }
        generation &+= 1
        stateScopeKey = key
        config = nil
        draftMaxTurns = 500
        draftImageMode = "auto"
        isLoading = false
        busyField = nil
        notice = nil
        logs = GatewayLogSnapshot(.null, fallbackFile: logFile)
        logError = nil
        isLoadingLogs = false
        logGeneration &+= 1
    }

    private func isCurrent(_ key: String, generation captured: Int) -> Bool {
        stateScopeKey == key && scopeKey == key && generation == captured
    }

    private func targetClient(gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func loadConfig(scopeKey key: String) async {
        guard stateScopeKey == key, !isLoading else { return }
        generation &+= 1
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        isLoading = true
        defer { if isCurrent(key, generation: captured) { isLoading = false } }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured) else { return }
            let loaded = try await client.operatorConfig(profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            config = loaded
            draftMaxTurns = loaded.maxTurns
            draftImageMode = loaded.imageInputMode
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func loadLogs(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        logGeneration &+= 1
        let capturedLogGeneration = logGeneration
        let captured = generation
        let gatewayID = targetGatewayID
        let file = logFile
        let level = logLevel
        let search = logSearch
        isLoadingLogs = true
        defer {
            if isCurrent(key, generation: captured), logGeneration == capturedLogGeneration {
                isLoadingLogs = false
            }
        }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            let loaded = try await client.gatewayLogs(file: file, level: level, search: search)
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            logs = loaded
            logError = nil
        } catch {
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            logError = error.localizedDescription
        }
    }

    private func saveMaxTurns() async {
        let value = max(1, min(5_000, draftMaxTurns))
        await save(path: ["agent", "max_turns"], field: "agent.max_turns",
                   value: .number(Double(value))) { $0.maxTurns = value }
    }

    private func saveImageMode() async {
        guard GatewayOperatorConfig.imageModes.contains(draftImageMode) else { return }
        let value = draftImageMode
        await save(path: ["agent", "image_input_mode"], field: "agent.image_input_mode",
                   value: .string(value)) { $0.imageInputMode = value }
    }

    private func saveBool(path: [String], field: String, value: Bool,
                          keyPath: WritableKeyPath<GatewayOperatorConfig, Bool>) async {
        await save(path: path, field: field, value: .bool(value)) { $0[keyPath: keyPath] = value }
    }

    private func save(path: [String], field: String, value: JSONValue,
                      apply: (inout GatewayOperatorConfig) -> Void) async {
        guard busyField == nil, var next = config else { return }
        let key = scopeKey
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        busyField = field
        setNotice(nil, warning: false)
        defer { if isCurrent(key, generation: captured) { busyField = nil } }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            // Client resolution may dial a secondary gateway. Revalidate before
            // issuing the mutation, and keep the target values captured above so
            // a picker change can never retarget an in-flight save.
            guard isCurrent(key, generation: captured) else { return }
            try await client.setGatewayConfigValue(path: path, value: value, profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            apply(&next)
            config = next
            setNotice(copy.settingsOperatorSaved(theme.id, field: field), warning: false)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func setNotice(_ text: String?, warning: Bool) {
        notice = text.flatMap { $0.isEmpty ? nil : $0 }
        noticeIsWarning = warning
    }
}

public extension CopyPack {
    func settingsOperatorGateway(_ t: ThemeID) -> String {
        switch t { case .soft: "Operator gateway"; case .control: "RUNTIME SOURCE"; case .ink: "the house being tended" }
    }
    func settingsOperatorGatewayNote(_ t: ThemeID) -> String {
        switch t { case .soft: "Runtime, memory and logs are owned by one gateway."; case .control: "RUNTIME CONFIG + LOGS ARE GATEWAY-LOCAL."; case .ink: "Choose the house whose workings you mean to tend." }
    }
    func settingsOperatorProfile(_ t: ThemeID) -> String {
        switch t { case .soft: "Applies to"; case .control: "PROFILE SCOPE"; case .ink: "whose rules these are" }
    }
    func settingsOperatorProfileNote(_ t: ThemeID) -> String {
        switch t { case .soft: "Runtime and memory can use a profile override. Logs remain gateway-wide."; case .control: "CONFIG MAY BE PROFILE-SCOPED. LOGS ARE ALWAYS GATEWAY-WIDE."; case .ink: "Name one resident for their rules; the house ledger below still belongs to everyone." }
    }
    func settingsOperatorGatewayDefault(_ t: ThemeID) -> String {
        switch t { case .soft: "Gateway default"; case .control: "GATEWAY DEFAULT"; case .ink: "the house rule" }
    }
    func settingsRuntimeSection(_ t: ThemeID) -> String {
        switch t { case .soft: "Agent runtime"; case .control: "AGENT RUNTIME"; case .ink: "how long the work may run" }
    }
    func settingsRuntimeNote(_ t: ThemeID) -> String {
        switch t { case .soft: "The tool-call ceiling for one turn. Lower values stop runaway work sooner."; case .control: "agent.max_turns — TOOL-CALL CEILING PER TURN."; case .ink: "A hard count beyond which one turn may travel no farther." }
    }
    func settingsMaxTurns(_ t: ThemeID) -> String { t == .control ? "MAX TURNS" : "Maximum turns" }
    func settingsMaxTurnsNote(_ t: ThemeID) -> String { t == .control ? "1–5000" : "1–5,000 tool-calling iterations" }
    func settingsSaveMaxTurns(_ t: ThemeID) -> String { t == .control ? "SAVE TURN CEILING" : "Save maximum turns" }
    func settingsMemorySection(_ t: ThemeID) -> String { t == .control ? "PERSISTENT MEMORY" : "Persistent memory" }
    func settingsMemoryNote(_ t: ThemeID) -> String { t == .control ? "BOUNDED MEMORY.md + USER.md INJECTION AND WRITE GATE." : "Controls the gateway’s bounded long-term memory and user profile." }
    func settingsMemoryEnabled(_ t: ThemeID) -> String { t == .control ? "MEMORY" : "Remember across chats" }
    func settingsMemoryEnabledNote(_ t: ThemeID) -> String { t == .control ? "memory.memory_enabled" : "Inject curated MEMORY.md context." }
    func settingsUserProfileEnabled(_ t: ThemeID) -> String { t == .control ? "USER PROFILE" : "Remember user profile" }
    func settingsUserProfileEnabledNote(_ t: ThemeID) -> String { t == .control ? "memory.user_profile_enabled" : "Inject curated USER.md context." }
    func settingsMemoryApproval(_ t: ThemeID) -> String { t == .control ? "APPROVE WRITES" : "Approve memory writes" }
    func settingsMemoryApprovalNote(_ t: ThemeID) -> String { t == .control ? "memory.write_approval" : "Review additions, replacements and removals before they persist." }
    func settingsImageModeSection(_ t: ThemeID) -> String { t == .control ? "IMAGE INPUT MODE" : "Image attachments" }
    func settingsImageModeNote(_ t: ThemeID) -> String { t == .control ? "auto | native | text — agent.image_input_mode" : "Choose whether images are sent natively or described as text first." }
    func settingsImageModeLabel(_ t: ThemeID, mode: String) -> String { t == .control ? mode.uppercased() : mode.capitalized }
    func settingsSaveImageMode(_ t: ThemeID) -> String { t == .control ? "SAVE IMAGE MODE" : "Save image mode" }
    func settingsLogsSection(_ t: ThemeID) -> String { t == .control ? "GATEWAY LOGS" : "Gateway logs" }
    func settingsLogsNote(_ t: ThemeID) -> String { t == .control ? "AUTHENTICATED GET /api/logs · READ-ONLY · LAST 200." : "Read-only tail from the selected gateway; nothing is uploaded." }
    func settingsLogsSearch(_ t: ThemeID) -> String { t == .control ? "SEARCH LOG TEXT" : "Search logs" }
    func settingsLogsRefresh(_ t: ThemeID) -> String { t == .control ? "REFRESH LOGS" : "Refresh logs" }
    func settingsLogsEmpty(_ t: ThemeID) -> String { t == .control ? "NO MATCHING LINES" : "No matching log lines." }
    func settingsOperatorSaved(_ t: ThemeID, field: String) -> String { t == .control ? "SAVED \(field)" : "Saved \(field)." }
}

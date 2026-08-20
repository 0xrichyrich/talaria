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
//   POST /api/gateway/restart           hermes_cli/web_server.py:4575
//   POST /api/hermes/update             hermes_cli/web_server.py:4665
//   GET /api/hermes/update/check        hermes_cli/web_server.py:4794
//   GET /api/actions/{name}/status      hermes_cli/web_server.py:5349
//   GET /api/analytics/usage            hermes_cli/web_server.py:15265
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

public struct GatewayCommandAction: Equatable, Sendable {
    var name: String
    var ok: Bool
    var running: Bool
    var alreadyRunning: Bool
    var pid: Int?
    var exitCode: Int?
    var message: String
    var lines: [String]
    var canApply: Bool
    var updateAvailable: Bool
    var behind: Int?
    var updateCommand: String
    var installMethod: String

    static let empty = GatewayCommandAction(
        name: "", ok: false, running: false, alreadyRunning: false,
        pid: nil, exitCode: nil, message: "", lines: [], canApply: false,
        updateAvailable: false, behind: nil, updateCommand: "", installMethod: "")

    init(name: String, ok: Bool, running: Bool, alreadyRunning: Bool,
         pid: Int?, exitCode: Int?, message: String, lines: [String],
         canApply: Bool, updateAvailable: Bool, behind: Int?,
         updateCommand: String, installMethod: String) {
        self.name = name; self.ok = ok; self.running = running
        self.alreadyRunning = alreadyRunning; self.pid = pid; self.exitCode = exitCode
        self.message = message; self.lines = lines; self.canApply = canApply
        self.updateAvailable = updateAvailable; self.behind = behind
        self.updateCommand = updateCommand; self.installMethod = installMethod
    }

    init(_ value: JSONValue, fallbackName: String = "") {
        name = value["name"]?.stringValue ?? fallbackName
        ok = value["ok"]?.boolValue ?? (value["running"]?.boolValue == true || value["exit_code"]?.intValue == 0)
        running = value["running"]?.boolValue ?? false
        alreadyRunning = value["already_running"]?.boolValue ?? false
        pid = value["pid"]?.intValue
        exitCode = value["exit_code"]?.intValue
        message = value["message"]?.stringValue
            ?? value["error"]?.stringValue
            ?? value["detail"]?.stringValue
            ?? ""
        lines = value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        canApply = value["can_apply"]?.boolValue ?? false
        updateAvailable = value["update_available"]?.boolValue ?? false
        behind = value["behind"]?.intValue
        updateCommand = value["update_command"]?.stringValue ?? ""
        installMethod = value["install_method"]?.stringValue ?? ""
    }

    var isFinished: Bool { !running && (exitCode != nil || !ok) }
}

public struct GatewayUsageModel: Equatable, Sendable {
    var name: String
    var tokens: Int
}

public struct GatewayUsageSnapshot: Equatable, Sendable {
    var days: Int
    var sessions: Int
    var apiCalls: Int
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCost: Double
    var topModels: [GatewayUsageModel]

    static let empty = GatewayUsageSnapshot(days: 30, sessions: 0, apiCalls: 0,
                                            inputTokens: 0, outputTokens: 0,
                                            estimatedCost: 0, topModels: [])
    static let periods = [7, 30, 90]

    init(days: Int, sessions: Int, apiCalls: Int, inputTokens: Int, outputTokens: Int,
         estimatedCost: Double, topModels: [GatewayUsageModel]) {
        self.days = days; self.sessions = sessions; self.apiCalls = apiCalls
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost; self.topModels = topModels
    }

    init(_ value: JSONValue, days: Int) {
        let totals = value["totals"]
        self.days = value["period_days"]?.intValue ?? days
        sessions = totals?["total_sessions"]?.intValue ?? 0
        apiCalls = totals?["total_api_calls"]?.intValue ?? 0
        inputTokens = totals?["total_input"]?.intValue ?? 0
        outputTokens = totals?["total_output"]?.intValue ?? 0
        estimatedCost = totals?["total_estimated_cost"]?.doubleValue ?? 0
        topModels = (value["by_model"]?.arrayValue ?? []).prefix(6).compactMap { row in
            guard let name = row["model"]?.stringValue, !name.isEmpty else { return nil }
            let tokens = (row["input_tokens"]?.intValue ?? 0) + (row["output_tokens"]?.intValue ?? 0)
            return GatewayUsageModel(name: name, tokens: tokens)
        }
    }
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

    func restartGateway(profile: String?) async throws -> GatewayCommandAction {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return GatewayCommandAction(
            try await restJSON(path: "api/gateway/restart", method: "POST", query: query, timeout: 30),
            fallbackName: "gateway-restart")
    }

    func hermesUpdateCheck() async throws -> GatewayCommandAction {
        GatewayCommandAction(
            try await restJSON(path: "api/hermes/update/check", timeout: 30),
            fallbackName: "hermes-update")
    }

    func startHermesUpdate() async throws -> GatewayCommandAction {
        GatewayCommandAction(
            try await restJSON(path: "api/hermes/update", method: "POST", timeout: 30),
            fallbackName: "hermes-update")
    }

    func actionStatus(name: String, lines: Int = 80) async throws -> GatewayCommandAction {
        GatewayCommandAction(
            try await restJSON(path: "api/actions/\(name)/status",
                               query: [URLQueryItem(name: "lines", value: String(lines))],
                               timeout: 20),
            fallbackName: name)
    }

    func usageAnalytics(days: Int, profile: String?) async throws -> GatewayUsageSnapshot {
        let clamped = GatewayUsageSnapshot.periods.contains(days) ? days : 30
        var query = [URLQueryItem(name: "days", value: String(clamped))]
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return GatewayUsageSnapshot(
            try await restJSON(path: "api/analytics/usage", query: query, timeout: 30),
            days: clamped)
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
    @State private var usageDays = 30
    @State private var usage = GatewayUsageSnapshot.empty
    @State private var usageError: String?
    @State private var isLoadingUsage = false
    @State private var usageGeneration = 0
    @State private var updateCheck = GatewayCommandAction.empty
    @State private var action = GatewayCommandAction.empty
    @State private var actionName: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPickerSection }
            if !profileChoices.isEmpty { profilePickerSection }
            systemSection
            usageSection
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
            await loadUsage(scopeKey: key)
            await loadUpdateCheck(scopeKey: key)
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

    private var systemSection: some View {
        let status = model.gatewayStatus
        return SettingsSection(theme: theme, title: copy.settingsCommandCenter(theme.id),
                               footnote: copy.settingsCommandCenterNote(theme.id)) {
            SettingsGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.settingsGatewayRunning(theme.id, running: status?.gatewayRunning == true))
                        .font(SettingsType.rowTitle(theme))
                    Text(copy.settingsGatewaySessions(theme.id,
                                                      version: status?.version ?? "—",
                                                      sessions: status?.activeSessions ?? 0,
                                                      agents: status?.activeAgents ?? 0))
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SettingsRowChrome(theme: theme, isLast: false))
                SettingsActionRow(theme: theme, title: copy.settingsRestartGateway(theme.id),
                                  isBusy: actionName == "gateway-restart" && action.running,
                                  isLast: false) {
                    Task { await runAction("gateway-restart") }
                }
                SettingsActionRow(theme: theme, title: copy.settingsUpdateHermes(theme.id),
                                  isBusy: actionName == "hermes-update" && action.running,
                                  isLast: true) {
                    Task { await runAction("hermes-update") }
                }
                .disabled(!updateCheck.canApply && updateCheck.installMethod.isEmpty == false && !updateCheck.updateAvailable)
            }
            if !updateCheck.message.isEmpty || updateCheck.updateAvailable || !updateCheck.updateCommand.isEmpty {
                Text(copy.settingsUpdateStatus(theme.id, check: updateCheck))
                    .font(theme.mono(10)).foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
            if let actionName, !action.message.isEmpty || !action.lines.isEmpty || action.running {
                Text(copy.settingsActionStatus(theme.id, action: action, name: actionName))
                    .font(theme.mono(10)).foregroundStyle(action.exitCode == nil || action.exitCode == 0 ? theme.sub : theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }

    private var usageSection: some View {
        SettingsSection(theme: theme, title: copy.settingsUsageSection(theme.id),
                        footnote: copy.settingsUsageNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsUsageSection(theme.id), selection: $usageDays) {
                    ForEach(GatewayUsageSnapshot.periods, id: \.self) { days in
                        Text(copy.settingsUsagePeriod(theme.id, days: days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.settingsUsageTotals(theme.id, usage: usage))
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    ForEach(usage.topModels, id: \.name) { row in
                        Text("\(row.name) · \(row.tokens)")
                            .font(theme.mono(10)).foregroundStyle(theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let usageError {
                Text(usageError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
        .onChange(of: usageDays) { _, _ in Task { await loadUsage(scopeKey: scopeKey) } }
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
        usage = GatewayUsageSnapshot.empty
        usageError = nil
        isLoadingUsage = false
        usageGeneration &+= 1
        updateCheck = GatewayCommandAction.empty
        action = GatewayCommandAction.empty
        actionName = nil
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

    private func loadUsage(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        usageGeneration &+= 1
        let capturedUsage = usageGeneration
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let days = usageDays
        isLoadingUsage = true
        defer {
            if isCurrent(key, generation: captured), usageGeneration == capturedUsage {
                isLoadingUsage = false
            }
        }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            let loaded = try await client.usageAnalytics(days: days, profile: profile)
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            usage = loaded
            usageError = nil
        } catch {
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            usageError = error.localizedDescription
        }
    }

    private func loadUpdateCheck(scopeKey key: String) async {
        guard stateScopeKey == key, model.mode == .live else { return }
        let captured = generation
        do {
            let client = try await targetClient(gatewayID: targetGatewayID)
            let loaded = try await client.hermesUpdateCheck()
            guard isCurrent(key, generation: captured) else { return }
            updateCheck = loaded
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            updateCheck.message = error.localizedDescription
        }
    }

    private func runAction(_ name: String) async {
        guard busyField == nil else { return }
        let key = scopeKey
        let captured = generation
        actionName = name
        action = GatewayCommandAction.empty
        do {
            let client = try await targetClient(gatewayID: targetGatewayID)
            let started: GatewayCommandAction
            if name == "gateway-restart" {
                started = try await client.restartGateway(profile: targetProfile)
            } else {
                started = try await client.startHermesUpdate()
            }
            guard isCurrent(key, generation: captured) else { return }
            action = started
            if started.ok || started.alreadyRunning || started.pid != nil {
                await pollAction(name, scopeKey: key, generation: captured)
            }
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            action.message = error.localizedDescription
            action.ok = false
        }
    }

    private func pollAction(_ name: String, scopeKey key: String, generation captured: Int) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(1200))
            guard isCurrent(key, generation: captured) else { return }
            do {
                let client = try await targetClient(gatewayID: targetGatewayID)
                let status = try await client.actionStatus(name: name)
                guard isCurrent(key, generation: captured) else { return }
                action = status
                if !status.running { return }
            } catch {
                guard isCurrent(key, generation: captured) else { return }
                action.message = error.localizedDescription
                return
            }
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
    func settingsCommandCenter(_ t: ThemeID) -> String { t == .control ? "GATEWAY SYSTEM" : "Gateway system" }
    func settingsCommandCenterNote(_ t: ThemeID) -> String { t == .control ? "POST /api/gateway/restart + /api/hermes/update · POLL /api/actions/*/status." : "Restart this gateway or apply a Hermes update, then watch the action log." }
    func settingsGatewayRunning(_ t: ThemeID, running: Bool) -> String {
        if t == .control { return running ? "GATEWAY RUNNING" : "GATEWAY STOPPED" }
        return running ? "Gateway running" : "Gateway stopped"
    }
    func settingsGatewaySessions(_ t: ThemeID, version: String, sessions: Int, agents: Int) -> String {
        t == .control ? "HERMES \(version) · \(sessions) SESSIONS · \(agents) AGENTS" : "Hermes \(version) · \(sessions) active sessions · \(agents) agents"
    }
    func settingsRestartGateway(_ t: ThemeID) -> String { t == .control ? "RESTART GATEWAY" : "Restart gateway" }
    func settingsUpdateHermes(_ t: ThemeID) -> String { t == .control ? "UPDATE HERMES" : "Update Hermes" }
    func settingsUpdateStatus(_ t: ThemeID, check: GatewayCommandAction) -> String {
        if !check.message.isEmpty { return check.message }
        if check.updateAvailable {
            let behind = check.behind.map(String.init) ?? "?"
            return t == .control ? "UPDATE AVAILABLE · \(behind) COMMITS BEHIND" : "Update available · \(behind) commits behind."
        }
        if !check.updateCommand.isEmpty {
            return t == .control ? check.updateCommand.uppercased() : check.updateCommand
        }
        return t == .control ? "UP TO DATE" : "Hermes is up to date."
    }
    func settingsActionStatus(_ t: ThemeID, action: GatewayCommandAction, name: String) -> String {
        let state: String
        if action.running { state = t == .control ? "RUNNING" : "running" }
        else if action.exitCode == 0 { state = t == .control ? "DONE" : "done" }
        else { state = t == .control ? "FAILED" : "failed" }
        let tail = action.lines.suffix(3).joined(separator: "\n")
        let body = action.message.isEmpty ? tail : action.message
        return body.isEmpty ? "\(name) · \(state)" : "\(name) · \(state)\n\(body)"
    }
    func settingsUsageSection(_ t: ThemeID) -> String { t == .control ? "USAGE" : "Usage" }
    func settingsUsageNote(_ t: ThemeID) -> String { t == .control ? "GET /api/analytics/usage · 7/30/90 DAYS." : "Account-level sessions, API calls and tokens for the selected gateway." }
    func settingsUsagePeriod(_ t: ThemeID, days: Int) -> String { t == .control ? "\(days)D" : "\(days) days" }
    func settingsUsageTotals(_ t: ThemeID, usage: GatewayUsageSnapshot) -> String {
        let cost = String(format: "%.2f", usage.estimatedCost)
        return t == .control
            ? "\(usage.sessions) SESSIONS · \(usage.apiCalls) CALLS · \(usage.inputTokens)+\(usage.outputTokens) TOKENS · $\(cost)"
            : "\(usage.sessions) sessions · \(usage.apiCalls) API calls · \(usage.inputTokens) in / \(usage.outputTokens) out · $\(cost)"
    }
}

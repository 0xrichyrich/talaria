import SwiftUI
import TalariaKit
import TalariaTheme
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct CustomInferenceEndpointEditorSeed: Equatable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var models: [String]
    var contextLength: String
    var discoversModels: Bool
    var makeDefault: Bool

    init(endpoint: CustomInferenceEndpoint) {
        id = endpoint.id
        name = endpoint.name
        baseURL = endpoint.baseURL
        model = endpoint.model
        models = endpoint.models
        contextLength = endpoint.contextLength.map(String.init) ?? ""
        discoversModels = endpoint.discoversModels
        // Saving an endpoint updates providers.<id>. An active endpoint must
        // also refresh model.{provider,default,base_url,key_env}; otherwise an
        // edited URL/model/key leaves Hermes' higher-priority active mirror
        // pointing at the old route.
        makeDefault = endpoint.isCurrent
    }
}

/// Mobile-first counterpart to Hermes Desktop Settings → Accounts and its
/// custom/local endpoint manager. OAuth happens on the gateway, while Talaria
/// opens the provider's system-browser page and renders only codes/status — it
/// never receives a provider access or refresh token.
public struct InferenceProviderSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    @Environment(\.openURL) private var openURL

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateScopeKey: String?
    @State private var generation = 0
    @State private var oauthGeneration = 0
    @State private var providers: [InferenceOAuthProvider] = []
    @State private var endpoints = CustomInferenceEndpointCatalog(.object([:]))
    @State private var isLoading = false
    @State private var busyID: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false

    @State private var oauthProvider: InferenceOAuthProvider?
    @State private var oauthStart: InferenceOAuthStart?
    @State private var oauthTarget: InferenceOAuthSessionTarget?
    @State private var oauthCode = ""
    @State private var oauthState: InferenceOAuthPollState?

    @State private var editingEndpointID: String?
    @State private var endpointName = ""
    @State private var endpointURL = ""
    @State private var endpointModel = ""
    @State private var endpointModels: [String] = []
    @State private var endpointAPIKey = ""
    @State private var endpointAPIKeyChanged = false
    @State private var endpointContext = ""
    @State private var endpointDiscoversModels = true
    @State private var endpointMakeDefault = false
    @State private var validation: CustomInferenceEndpointValidation?
    @State private var deleteCandidate: EndpointDeleteConfirmation?
    @State private var disconnectCandidate: DisconnectConfirmation?

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPickerSection }
            if !profileChoices.isEmpty { profilePickerSection }
            accountsSection
            endpointsSection
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
            prepareForScope(scopeKey)
            await load(scope: captureScope())
        }
        .onDisappear { retirePendingOAuthSession() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { disconnectCandidate != nil || deleteCandidate != nil },
            set: {
                if !$0 { disconnectCandidate = nil; deleteCandidate = nil }
            }),
            titleVisibility: .visible) {
                if let request = disconnectCandidate {
                    Button("Disconnect \(request.provider.name)", role: .destructive) {
                        disconnectCandidate = nil
                        Task { await confirmDisconnect(request) }
                    }
                } else if let request = deleteCandidate {
                    Button("Delete \(request.endpoint.name)", role: .destructive) {
                        deleteCandidate = nil
                        Task { await deleteEndpoint(request) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    disconnectCandidate = nil; deleteCandidate = nil
                }
            } message: {
                if let request = disconnectCandidate {
                    Text(request.message)
                } else if let request = deleteCandidate {
                    Text(request.message)
                } else {
                    Text("This removes its saved configuration and credential reference from this profile.")
                }
            }
    }

    // MARK: - Scope

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

    private var scopeKey: String { "\(targetGatewayID ?? "demo")\u{1f}\(targetProfile ?? "__gateway__")" }

    private struct Scope: Equatable {
        var gatewayID: String?
        var profile: String?
        var key: String
        var generation: Int
    }

    private struct DisconnectConfirmation: Identifiable {
        var id = UUID()
        var gatewayID: String
        var gatewayName: String
        var profile: String?
        var scope: Scope
        var provider: InferenceOAuthProvider

        var message: String {
            let owner = profile.map { "profile “\($0)” on \(gatewayName)" }
                ?? "the gateway-default profile on \(gatewayName)"
            return "This removes Hermes-managed credentials for \(provider.name) from \(owner). Other gateways and profiles are not changed."
        }
    }

    private struct EndpointDeleteConfirmation: Identifiable {
        var id = UUID()
        var target: InferenceEndpointMutationTarget
        var gatewayName: String
        var scope: Scope
        var endpoint: CustomInferenceEndpoint

        var message: String {
            let owner = target.profile.map { "profile “\($0)” on \(gatewayName)" }
                ?? "the gateway-default profile on \(gatewayName)"
            return "This removes \(endpoint.name) and its credential reference from \(owner). Other gateways and profiles are not changed."
        }
    }

    private var confirmationTitle: String {
        if let request = disconnectCandidate { return "Disconnect \(request.provider.name)?" }
        return "Delete custom endpoint?"
    }

    private func captureScope() -> Scope {
        Scope(gatewayID: targetGatewayID, profile: targetProfile,
              key: scopeKey, generation: generation)
    }

    private func isCurrent(_ scope: Scope) -> Bool {
        stateScopeKey == scope.key && scopeKey == scope.key && generation == scope.generation
    }

    @MainActor private func prepareForScope(_ key: String) {
        guard stateScopeKey != key else { return }
        retirePendingOAuthSession()
        stateScopeKey = key
        generation += 1
        oauthGeneration += 1
        providers = []
        endpoints = CustomInferenceEndpointCatalog(.object([:]))
        oauthProvider = nil; oauthStart = nil; oauthTarget = nil; oauthCode = ""; oauthState = nil
        resetEditor()
        notice = nil; isLoading = false; busyID = nil
    }

    private func targetClient(gatewayID: String?) async throws -> GatewayClient {
        guard model.mode == .live, let gatewayID else {
            throw GatewayError(code: -12, message: "Connect a gateway to manage providers.")
        }
        return try await model.routedClient(gatewayID: gatewayID)
    }

    // MARK: - Target pickers

    private var gatewayPickerSection: some View {
        SettingsSection(theme: theme, title: "PROVIDER GATEWAY",
                        footnote: "Accounts and local endpoints belong to one gateway. Switching here never changes the active chat.") {
            SettingsGroup(theme: theme) {
                Picker("Gateway", selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedProfile = nil })) {
                        ForEach(gatewayChoices) { gateway in
                            Text(gateway.name + (gateway.id == model.activeGatewayID ? " · active" : ""))
                                .tag(Optional(gateway.id))
                        }
                    }
                    .pickerStyle(.menu).tint(theme.accent).padding(10)
            }
        }
    }

    private var profilePickerSection: some View {
        SettingsSection(theme: theme, title: "PROVIDER PROFILE",
                        footnote: "Credentials and custom endpoints are isolated to the selected Hermes profile.") {
            SettingsGroup(theme: theme) {
                Picker("Profile", selection: $selectedProfile) {
                    Text("Gateway default").tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle).tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu).tint(theme.accent).padding(10)
            }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        SettingsSection(theme: theme, title: "INFERENCE ACCOUNTS",
                        footnote: "Connect subscription providers in the system browser. Tokens stay on the selected gateway and profile.") {
            SettingsGroup(theme: theme) {
                if providers.isEmpty {
                    SettingsRow(theme: theme, title: isLoading ? "Reading accounts…" : "No account providers reported",
                                subtitle: model.mode == .live ? nil : "Available after a gateway connects.", isLast: true)
                } else {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        providerRow(provider, isLast: index == providers.count - 1)
                    }
                }
            }

            if let provider = oauthProvider, let start = oauthStart {
                oauthPanel(provider: provider, start: start)
            }

            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme, title: "Refresh accounts",
                                  isBusy: isLoading, isLast: true) {
                    Task { await load(scope: captureScope()) }
                }
            }
        }
    }

    private func providerRow(_ provider: InferenceOAuthProvider, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                    Text(provider.status.loggedIn ? providerStatusLine(provider) : provider.flowLabel)
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                }
                Spacer(minLength: 8)
                Text(provider.status.loggedIn ? "CONNECTED" : "NOT CONNECTED")
                    .font(theme.mono(9.5)).foregroundStyle(provider.status.loggedIn ? theme.ok : theme.faint)
            }
            HStack(spacing: 8) {
                if provider.status.loggedIn, provider.disconnectable {
                    compactButton("Disconnect", destructive: true, busy: busyID == "disconnect:\(provider.id)") {
                        requestDisconnect(provider)
                    }
                } else if provider.status.loggedIn, let command = provider.disconnectCommand {
                    compactButton("Copy logout", destructive: true) {
                        copyText(command); showNotice("Logout command copied.")
                    }
                } else if !provider.status.loggedIn, provider.flow != .external {
                    compactButton("Connect", busy: busyID == "connect:\(provider.id)") {
                        Task { await startOAuth(provider) }
                    }
                }
                if provider.flow == .external || !provider.cliCommand.isEmpty {
                    compactButton("Copy CLI") { copyText(provider.cliCommand); showNotice("CLI command copied.") }
                }
                if let url = provider.docsURL {
                    compactButton("Docs") { openURL(url) }
                }
            }
            if let hint = provider.disconnectHint, provider.status.loggedIn {
                Text(hint).font(theme.mono(9.5)).foregroundStyle(theme.warn)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private func providerStatusLine(_ provider: InferenceOAuthProvider) -> String {
        [provider.status.sourceLabel, provider.status.tokenPreview].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func oauthPanel(provider: InferenceOAuthProvider,
                                          start: InferenceOAuthStart) -> some View {
        SettingsGroup(theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CONNECT \(provider.name.uppercased())")
                    .font(theme.mono(10)).foregroundStyle(theme.accent)
                if start.flow == .deviceCode {
                    Text(start.userCode).font(theme.mono(21)).foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        compactButton("Copy code") { copyText(start.userCode) }
                        if let url = start.verificationURL {
                            compactButton("Open browser") { openURL(url) }
                        }
                    }
                    Text(oauthState == .approved ? "Approved" : "Waiting for approval…")
                        .font(theme.mono(10)).foregroundStyle(oauthState == .approved ? theme.ok : theme.sub)
                } else {
                    Text("Authorize in your browser, then paste the returned code below.")
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    if let url = start.authorizationURL {
                        compactButton("Open browser") { openURL(url) }
                    }
                    TextField("Authorization code", text: $oauthCode)
                        .modifier(InferenceLiteralInput())
                        .font(theme.mono(11)).padding(10).background(theme.inset)
                    compactButton("Submit code", busy: busyID == "oauth-submit") {
                        Task { await submitOAuth(provider: provider, start: start) }
                    }
                    .disabled(oauthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                compactButton("Cancel", destructive: true) { Task { await cancelOAuth() } }
            }
            .modifier(SettingsRowChrome(theme: theme, isLast: true))
        }
        .task(id: start.sessionID) {
            guard start.flow == .deviceCode else { return }
            await pollOAuth(provider: provider, start: start, scope: captureScope(),
                            oauthGeneration: oauthGeneration)
        }
    }

    // MARK: - Custom/local endpoints

    private var endpointsSection: some View {
        SettingsSection(theme: theme, title: "CUSTOM & LOCAL INFERENCE",
                        footnote: "Manage OpenAI-compatible servers such as Ollama, llama.cpp, vLLM, or a private proxy. Validation calls the gateway, so localhost means that machine.") {
            SettingsGroup(theme: theme) {
                if endpoints.endpoints.isEmpty {
                    SettingsRow(theme: theme, title: "No custom endpoints", isLast: true)
                } else {
                    ForEach(Array(endpoints.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        endpointRow(endpoint, isLast: index == endpoints.endpoints.count - 1)
                    }
                }
            }

            if editingEndpointID != nil { endpointEditor }

            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme,
                                  title: editingEndpointID == nil ? "Add custom endpoint" : "Close editor",
                                  isLast: true) {
                    editingEndpointID == nil ? beginNewEndpoint() : resetEditor()
                }
            }
        }
    }

    private func endpointRow(_ endpoint: CustomInferenceEndpoint, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                    Text("\(endpoint.baseURL) · \(endpoint.model)")
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub).lineLimit(2)
                }
                Spacer(minLength: 8)
                if endpoint.isCurrent {
                    Text("ACTIVE").font(theme.mono(9.5)).foregroundStyle(theme.ok)
                }
            }
            HStack(spacing: 8) {
                if !endpoint.isCurrent {
                    compactButton("Use", busy: busyID == "activate:\(endpoint.id)") {
                        Task { await activateEndpoint(endpoint) }
                    }
                }
                compactButton("Edit") { beginEditing(endpoint) }
                compactButton("Delete", destructive: true) { requestDelete(endpoint) }
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private var endpointEditor: some View {
        SettingsGroup(theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                editorField("Name", text: $endpointName)
                editorField("Base URL", text: $endpointURL, keyboardURL: true)
                if endpointModels.count > 1 {
                    Picker("Model", selection: $endpointModel) {
                        ForEach(endpointModels, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu).tint(theme.accent)
                } else {
                    editorField("Model", text: $endpointModel)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key (optional)").font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    SecureField(editingEndpointHasKey ? "Leave unchanged to preserve saved key" : "Optional", text: Binding(
                        get: { endpointAPIKey },
                        set: { endpointAPIKey = $0; endpointAPIKeyChanged = true }))
                    .modifier(InferenceLiteralInput())
                    .font(theme.mono(11)).padding(10).background(theme.inset)
                }
                editorField("Context length (optional)", text: $endpointContext)
                Toggle("Discover models", isOn: $endpointDiscoversModels).tint(theme.accent)
                Toggle("Make active after save", isOn: $endpointMakeDefault).tint(theme.accent)
                if let validation {
                    Text(validation.ok ? "Connected · \(validation.models.count) models" : validation.message)
                        .font(theme.mono(10)).foregroundStyle(validation.ok ? theme.ok : theme.warn)
                }
                HStack(spacing: 8) {
                    compactButton("Test", busy: busyID == "validate") { Task { await validateEndpoint() } }
                    compactButton("Save", busy: busyID == "save-endpoint") { Task { await saveEndpoint() } }
                }
            }
            .modifier(SettingsRowChrome(theme: theme, isLast: true))
        }
    }

    private var editingEndpointHasKey: Bool {
        guard let id = editingEndpointID else { return false }
        return endpoints.endpoints.first(where: { $0.id == id })?.hasAPIKey ?? false
    }

    private func editorField(_ title: String, text: Binding<String>, keyboardURL: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
            TextField(title, text: text)
                .modifier(InferenceLiteralInput())
                #if os(iOS)
                .keyboardType(keyboardURL ? .URL : .default)
                #endif
                .font(theme.mono(11)).padding(10).background(theme.inset)
        }
    }

    // MARK: - Network actions

    @MainActor private func load(scope: Scope) async {
        guard !isLoading else { return }
        isLoading = true
        defer { if isCurrent(scope) { isLoading = false } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope) else { return }
            async let accountRows = client.inferenceOAuthProviders(profile: scope.profile)
            async let endpointRows = client.customInferenceEndpoints(profile: scope.profile)
            let (newProviders, newEndpoints) = try await (accountRows, endpointRows)
            guard isCurrent(scope) else { return }
            providers = newProviders; endpoints = newEndpoints
            notice = nil
        } catch {
            guard isCurrent(scope) else { return }
            showError(error)
        }
    }

    @MainActor private func startOAuth(_ provider: InferenceOAuthProvider) async {
        let scope = captureScope(); busyID = "connect:\(provider.id)"; oauthGeneration += 1
        let flowGeneration = oauthGeneration
        defer { if isCurrent(scope) { busyID = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
            let start = try await client.startInferenceOAuth(providerID: provider.id, profile: scope.profile)
            guard isCurrent(scope), oauthGeneration == flowGeneration else {
                try? await client.cancelInferenceOAuth(sessionID: start.sessionID, profile: scope.profile)
                return
            }
            guard let gatewayID = scope.gatewayID else { return }
            oauthProvider = provider; oauthStart = start
            oauthTarget = InferenceOAuthSessionTarget(gatewayID: gatewayID,
                profile: scope.profile, sessionID: start.sessionID)
            oauthState = .pending; oauthCode = ""
            if let url = start.authorizationURL ?? start.verificationURL { openURL(url) }
        } catch {
            guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
            showError(error)
        }
    }

    @MainActor private func submitOAuth(provider: InferenceOAuthProvider,
                                        start: InferenceOAuthStart) async {
        let scope = captureScope(), capturedCode = oauthCode
        let flowGeneration = oauthGeneration; busyID = "oauth-submit"
        defer { if isCurrent(scope) { busyID = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
            let result = try await client.submitInferenceOAuth(providerID: provider.id,
                sessionID: start.sessionID, code: capturedCode, profile: scope.profile)
            guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
            oauthState = result.state
            if result.state == .approved {
                await load(scope: scope)
                guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
                oauthProvider = nil; oauthStart = nil; oauthTarget = nil
            } else { showNotice(result.errorMessage ?? "Authorization was not approved.", warning: true) }
        } catch { if isCurrent(scope) { showError(error) } }
    }

    @MainActor private func pollOAuth(provider: InferenceOAuthProvider, start: InferenceOAuthStart,
                                      scope: Scope, oauthGeneration flowGeneration: Int) async {
        var sessionClient: GatewayClient?
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            sessionClient = client
            guard isCurrent(scope), oauthGeneration == flowGeneration else {
                try? await client.cancelInferenceOAuth(sessionID: start.sessionID, profile: scope.profile)
                return
            }
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(start.pollInterval))
                guard isCurrent(scope), oauthGeneration == flowGeneration else {
                    try? await client.cancelInferenceOAuth(sessionID: start.sessionID, profile: scope.profile)
                    return
                }
                let result = try await client.pollInferenceOAuth(providerID: provider.id,
                    sessionID: start.sessionID, profile: scope.profile)
                guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
                oauthState = result.state
                guard result.state == .pending else {
                    if result.state == .approved {
                        await load(scope: scope)
                        guard isCurrent(scope), oauthGeneration == flowGeneration else { return }
                        oauthProvider = nil; oauthStart = nil; oauthTarget = nil
                    } else { showNotice(result.errorMessage ?? "Authorization \(result.state.rawValue).", warning: true) }
                    return
                }
            }
        } catch is CancellationError {
            // The gateway's poller is independent of this view. Cancelling only
            // Talaria's Task would let a browser approval persist credentials
            // after the user changed profiles or closed Settings, so cancel the
            // server-side session as well.
            try? await sessionClient?.cancelInferenceOAuth(sessionID: start.sessionID,
                                                            profile: scope.profile)
        } catch { if isCurrent(scope), oauthGeneration == flowGeneration { showError(error) } }
    }

    @MainActor private func cancelOAuth() async {
        guard let target = oauthTarget else { return }
        let scope = captureScope(); oauthGeneration += 1
        oauthProvider = nil; oauthStart = nil; oauthTarget = nil; oauthState = nil; oauthCode = ""
        do {
            let client = try await targetClient(gatewayID: target.gatewayID)
            try await client.cancelInferenceOAuth(sessionID: target.sessionID, profile: target.profile)
        } catch { if isCurrent(scope) { showError(error) } }
    }

    @MainActor private func retirePendingOAuthSession() {
        guard let target = oauthTarget else { return }
        oauthGeneration += 1
        oauthTarget = nil
        Task {
            guard let client = try? await targetClient(gatewayID: target.gatewayID) else { return }
            try? await client.cancelInferenceOAuth(sessionID: target.sessionID, profile: target.profile)
        }
    }

    @MainActor private func requestDisconnect(_ provider: InferenceOAuthProvider) {
        let scope = captureScope()
        guard let gatewayID = scope.gatewayID else {
            showNotice("Connect a gateway to manage providers.", warning: true)
            return
        }
        let gatewayName = gatewayChoices.first(where: { $0.id == gatewayID })?.name ?? gatewayID
        disconnectCandidate = DisconnectConfirmation(gatewayID: gatewayID,
            gatewayName: gatewayName, profile: scope.profile, scope: scope, provider: provider)
    }

    @MainActor private func confirmDisconnect(_ request: DisconnectConfirmation) async {
        busyID = "disconnect:\(request.provider.id)"
        defer { if isCurrent(request.scope) { busyID = nil } }
        do {
            // Resolve and mutate only the immutable target the user reviewed in
            // the dialog. Do not consult targetGatewayID/targetProfile here: a
            // picker change while the sheet is up must not retarget deletion.
            let client = try await targetClient(gatewayID: request.gatewayID)
            try await client.disconnectInferenceOAuth(providerID: request.provider.id,
                                                       profile: request.profile)
            if isCurrent(request.scope) {
                await load(scope: request.scope)
            }
        } catch { if isCurrent(request.scope) { showError(error) } }
    }

    private func endpointDraft() -> CustomInferenceEndpointDraft {
        let context = Int(endpointContext.trimmingCharacters(in: .whitespaces))
        return CustomInferenceEndpointDraft(
            id: editingEndpointID == "__new__" ? "" : (editingEndpointID ?? ""),
            name: endpointName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: endpointModel.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: endpointAPIKeyChanged ? endpointAPIKey : nil,
            contextLength: context, discoversModels: endpointDiscoversModels,
            makeDefault: endpointMakeDefault, models: endpointModels)
    }

    @MainActor private func validateEndpoint() async {
        let scope = captureScope(), draft = endpointDraft(); busyID = "validate"
        defer { if isCurrent(scope) { busyID = nil } }
        guard !CustomInferenceEndpointValidationPolicy.requiresAPIKeyReentry(
            hasSavedKey: editingEndpointHasKey, apiKeyChanged: endpointAPIKeyChanged) else {
            showNotice("Re-enter the saved API key to test this endpoint. Hermes keeps saved keys write-only.",
                       warning: true)
            return
        }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope) else { return }
            let result = try await client.validateCustomInferenceEndpoint(draft)
            guard isCurrent(scope) else { return }
            validation = result
            if result.ok, !result.models.isEmpty {
                endpointModels = result.models
                if !result.models.contains(endpointModel) { endpointModel = result.models[0] }
            }
        } catch { if isCurrent(scope) { showError(error) } }
    }

    @MainActor private func saveEndpoint() async {
        let scope = captureScope(), draft = endpointDraft()
        guard !draft.name.isEmpty, !draft.baseURL.isEmpty, !draft.model.isEmpty else {
            showNotice("Name, base URL, and model are required.", warning: true); return
        }
        busyID = "save-endpoint"
        defer { if isCurrent(scope) { busyID = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope) else { return }
            let saved = try await client.saveCustomInferenceEndpoint(draft, profile: scope.profile)
            guard isCurrent(scope) else { return }
            endpoints = saved; resetEditor(); showNotice("Custom endpoint saved.")
        } catch { if isCurrent(scope) { showError(error) } }
    }

    @MainActor private func activateEndpoint(_ endpoint: CustomInferenceEndpoint) async {
        let scope = captureScope(); busyID = "activate:\(endpoint.id)"
        defer { if isCurrent(scope) { busyID = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard isCurrent(scope) else { return }
            try await client.activateCustomInferenceEndpoint(id: endpoint.id, profile: scope.profile)
            guard isCurrent(scope) else { return }
            await load(scope: scope)
        } catch { if isCurrent(scope) { showError(error) } }
    }

    @MainActor private func requestDelete(_ endpoint: CustomInferenceEndpoint) {
        let scope = captureScope()
        guard let gatewayID = scope.gatewayID else {
            showNotice("Connect a gateway to manage providers.", warning: true)
            return
        }
        let gatewayName = gatewayChoices.first(where: { $0.id == gatewayID })?.name ?? gatewayID
        deleteCandidate = EndpointDeleteConfirmation(
            target: InferenceEndpointMutationTarget(gatewayID: gatewayID,
                profile: scope.profile, endpointID: endpoint.id),
            gatewayName: gatewayName, scope: scope, endpoint: endpoint)
    }

    @MainActor private func deleteEndpoint(_ request: EndpointDeleteConfirmation) async {
        busyID = "delete:\(request.endpoint.id)"
        defer { if isCurrent(request.scope) { busyID = nil } }
        do {
            let client = try await targetClient(gatewayID: request.target.gatewayID)
            try await client.deleteCustomInferenceEndpoint(id: request.target.endpointID,
                                                           profile: request.target.profile)
            guard isCurrent(request.scope) else { return }
            await load(scope: request.scope)
        } catch { if isCurrent(request.scope) { showError(error) } }
    }

    // MARK: - Local state

    @MainActor private func beginNewEndpoint() {
        resetEditor(); editingEndpointID = "__new__"; endpointDiscoversModels = true
    }

    @MainActor private func beginEditing(_ endpoint: CustomInferenceEndpoint) {
        let seed = CustomInferenceEndpointEditorSeed(endpoint: endpoint)
        editingEndpointID = seed.id; endpointName = seed.name; endpointURL = seed.baseURL
        endpointModel = seed.model; endpointModels = seed.models
        endpointAPIKey = ""; endpointAPIKeyChanged = false
        endpointContext = seed.contextLength
        endpointDiscoversModels = seed.discoversModels; endpointMakeDefault = seed.makeDefault
        validation = nil
    }

    @MainActor private func resetEditor() {
        editingEndpointID = nil; endpointName = ""; endpointURL = ""; endpointModel = ""
        endpointModels = []; endpointAPIKey = ""; endpointAPIKeyChanged = false
        endpointContext = ""; endpointDiscoversModels = true; endpointMakeDefault = false
        validation = nil
    }

    private func compactButton(_ title: String, destructive: Bool = false, busy: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) }
                Text(title).font(theme.mono(10))
            }
            .foregroundStyle(destructive ? theme.warn : theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(theme.inset)
            .clipShape(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 7))
            .overlay(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 7)
                .strokeBorder(theme.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(busyID != nil)
    }

    @MainActor private func showNotice(_ message: String, warning: Bool = false) {
        notice = message; noticeIsWarning = warning
    }

    @MainActor private func showError(_ error: Error) {
        if let gateway = error as? GatewayError { showNotice(gateway.message, warning: true) }
        else { showNotice(error.localizedDescription, warning: true) }
    }

    private func copyText(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

private struct InferenceLiteralInput: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content
        #endif
    }
}

private extension InferenceOAuthProvider {
    var flowLabel: String {
        switch flow {
        case .pkce: "Browser authorization"
        case .deviceCode: "Device-code authorization"
        case .external: "Managed by an external CLI"
        }
    }
}

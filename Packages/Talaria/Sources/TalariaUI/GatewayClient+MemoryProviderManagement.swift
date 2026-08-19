import Foundation
import TalariaKit

// Typed projection of Hermes' dedicated memory-provider administration API.
//
// Pinned Hermes authority (b5455fdd):
//   GET  /api/memory                                           web_server.py:13926
//   GET  /api/memory/providers/{name}/config?surface=declared web_server.py:6706
//   PUT  /api/memory/providers/{name}/config?surface=declared web_server.py:6751
//   POST /api/memory/providers/{name}/setup                    web_server.py:6729
//   PUT  /api/memory/provider                                  web_server.py:13953
//   POST /api/memory/providers/{name}/oauth/start              memory_oauth.py:57
//   GET  /api/memory/providers/{name}/oauth/status             memory_oauth.py:73
//
// Discovery, dependency setup, and the default selection are gateway-owned.
// Declared config is profile-aware: Hermes evaluates it inside `_profile_scope`
// so a profile's provider credentials/config never leak into another profile.

struct MemoryProviderSetup: Equatable, Sendable {
    var pipDependencies: [String]
    var externalDependencies: [String]
    var requiredEnvironment: [String]
    var dependenciesInstalled: Bool

    init(_ value: JSONValue?) {
        pipDependencies = value?["pip_dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? []
        externalDependencies = value?["external_dependencies"]?.arrayValue?.compactMap {
            $0["name"]?.stringValue
        } ?? []
        requiredEnvironment = value?["required_env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        dependenciesInstalled = value?["dependencies_installed"]?.boolValue ?? true
    }

    var hasWork: Bool {
        !dependenciesInstalled && (!pipDependencies.isEmpty || !externalDependencies.isEmpty)
    }
}

struct MemoryProviderInventoryRow: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var available: Bool
    var configured: Bool
    var status: String
    var setup: MemoryProviderSetup

    init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        description = value["description"]?.stringValue ?? ""
        available = value["available"]?.boolValue ?? false
        configured = value["configured"]?.boolValue ?? false
        status = value["status"]?.stringValue ?? "unavailable"
        setup = MemoryProviderSetup(value["setup"])
    }
}

struct MemoryProviderInventory: Equatable, Sendable {
    var activeGatewayDefault: String
    var providers: [MemoryProviderInventoryRow]
    var memoryBytes: Int
    var userBytes: Int

    init(_ value: JSONValue) {
        activeGatewayDefault = value["active"]?.stringValue ?? ""
        providers = value["providers"]?.arrayValue?.compactMap(MemoryProviderInventoryRow.init) ?? []
        memoryBytes = value["builtin_files"]?["memory"]?.intValue ?? 0
        userBytes = value["builtin_files"]?["user"]?.intValue ?? 0
    }
}

enum MemoryProviderCatalog {
    static func merge(profileSchema: [String], gatewayInventory: [MemoryProviderInventoryRow],
                      active: String) -> [String] {
        var seen = Set<String>()
        return (profileSchema + gatewayInventory.map(\.name) + [active]).filter { name in
            !name.isEmpty && seen.insert(name).inserted
        }
    }
}

enum MemoryProviderSaveSemantics {
    /// Hermes' declared-config PUT does not select a provider.
    static func activeSelection(afterDeclaredSave current: String) -> String { current }
}

enum MemoryProviderDocumentationPolicy {
    static func externalURL(_ raw: String) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum MemoryProviderCopySemantics {
    static func saveAction(control: Bool) -> String {
        control ? "SAVE PROVIDER CONFIG" : "Save provider configuration"
    }

    static func savedNotice(control: Bool, provider: String) -> String {
        control ? "CONFIG SAVED: \(provider.uppercased())"
            : "Saved \(provider) configuration. Activate it separately to use it."
    }
}

struct MemoryProviderFieldOption: Identifiable, Equatable, Sendable {
    var id: String { value }
    var value: String
    var label: String
    var description: String

    init?(_ value: JSONValue) {
        guard let raw = value["value"]?.stringValue else { return nil }
        self.value = raw
        label = value["label"]?.stringValue ?? raw
        description = value["description"]?.stringValue ?? ""
    }
}

struct MemoryProviderField: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case text, secret, select, boolean, number

        init(upstream: String) {
            switch upstream {
            case "secret": self = .secret
            case "select": self = .select
            case "bool", "boolean": self = .boolean
            case "number", "integer": self = .number
            default: self = .text
            }
        }
    }

    var id: String { key }
    var key: String
    var label: String
    var kind: Kind
    var description: String
    var placeholder: String
    var isSet: Bool
    var value: String
    var options: [MemoryProviderFieldOption]

    init?(_ raw: JSONValue) {
        guard let key = raw["key"]?.stringValue, !key.isEmpty else { return nil }
        self.key = key
        label = raw["label"]?.stringValue ?? key
        kind = Kind(upstream: raw["kind"]?.stringValue ?? "text")
        description = raw["description"]?.stringValue ?? ""
        placeholder = raw["placeholder"]?.stringValue ?? ""
        isSet = raw["is_set"]?.boolValue ?? false
        value = raw["value"]?.stringValue
            ?? raw["value"]?.boolValue.map { $0 ? "true" : "false" }
            ?? raw["value"]?.doubleValue.map { String($0) }
            ?? ""
        options = raw["options"]?.arrayValue?.compactMap(MemoryProviderFieldOption.init) ?? []
    }
}

struct MemoryProviderDeclaredConfig: Equatable, Sendable {
    var name: String
    var label: String
    var documentationURL: String
    var fields: [MemoryProviderField]

    init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? ""
        label = value["label"]?.stringValue ?? name
        documentationURL = value["docs_url"]?.stringValue ?? ""
        fields = value["fields"]?.arrayValue?.compactMap(MemoryProviderField.init) ?? []
    }

    /// Hermes secrets are write-only. An empty secret means "keep the value
    /// already stored", so it must be omitted rather than submitted as a
    /// blank. Non-secret blanks remain meaningful (they clear an override).
    func submission(from drafts: [String: String]) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in fields {
            let draft = drafts[field.key] ?? field.value
            if field.kind == .secret && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            values[field.key] = .string(draft)
        }
        return values
    }
}

enum MemoryProviderOAuthState: String, Equatable, Sendable {
    case idle, pending, connected, error
}

struct MemoryProviderOAuthStatus: Equatable, Sendable {
    var state: MemoryProviderOAuthState
    var detail: String
    var connected: Bool
    /// `oauth`, `apikey`, or nil when no credential is stored.
    var authentication: String?

    init(_ value: JSONValue) {
        state = MemoryProviderOAuthState(rawValue: value["state"]?.stringValue ?? "") ?? .error
        detail = value["detail"]?.stringValue ?? ""
        connected = value["connected"]?.boolValue ?? false
        authentication = value["auth"]?.stringValue
    }
}

enum MemoryProviderOAuthPollDecision: Equatable {
    case keepWaiting
    case connected
    case failed(String)

    static func decide(status: MemoryProviderOAuthStatus, timedOut: Bool) -> Self {
        if status.state == .error {
            return .failed(status.detail.isEmpty ? "Connection failed." : status.detail)
        }
        // The flow state is process-global upstream, while credential detection
        // is evaluated inside the requested profile. Require BOTH on a terminal
        // connection so another profile's completed flow cannot be mistaken for
        // a credential in this one. During reconnect, pending+connected merely
        // describes the old credential and must keep waiting.
        if status.state == .connected {
            return status.connected
                ? .connected
                : .failed("Authorization did not connect the selected profile.")
        }
        if status.state == .idle && status.connected { return .connected }
        if timedOut {
            return .failed("Phone polling timed out; the gateway browser flow may still finish.")
        }
        return .keepWaiting
    }
}

extension GatewayClient {
    func memoryProviderInventory() async throws -> MemoryProviderInventory {
        MemoryProviderInventory(try await restJSON(path: "api/memory", timeout: 30))
    }

    func memoryProviderSelection(profile: String?) async throws -> String {
        let config = try await restJSON(path: "api/config", query: Self.memoryProfileQuery(profile),
                                        timeout: 30)
        return config["memory"]?["provider"]?.stringValue ?? ""
    }

    /// Profile-scoped discovery options from Hermes' dynamic config schema.
    /// Unlike `/api/memory`, this request runs inside the selected profile and
    /// therefore includes providers installed in that profile's plugin home,
    /// plus its configured current value even when discovery is temporarily
    /// unavailable.
    func memoryProviderCatalog(profile: String?) async throws -> [String] {
        let schema = try await restJSON(path: "api/config/schema",
                                        query: Self.memoryProfileQuery(profile), timeout: 30)
        return schema["fields"]?["memory.provider"]?["options"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
    }

    func memoryProviderConfig(_ provider: String, profile: String?) async throws
        -> MemoryProviderDeclaredConfig {
        let name = try Self.memoryProviderPathName(provider)
        var query = [URLQueryItem(name: "surface", value: "declared")]
        query.append(contentsOf: Self.memoryProfileQuery(profile))
        return MemoryProviderDeclaredConfig(
            try await restJSON(path: "api/memory/providers/\(name)/config",
                               query: query, timeout: 30))
    }

    func saveMemoryProviderConfig(_ config: MemoryProviderDeclaredConfig,
                                  drafts: [String: String], profile: String?) async throws {
        let name = try Self.memoryProviderPathName(config.name)
        var query = [URLQueryItem(name: "surface", value: "declared")]
        query.append(contentsOf: Self.memoryProfileQuery(profile))
        let body: JSONValue = .object(["values": .object(config.submission(from: drafts))])
        try await restJSON(path: "api/memory/providers/\(name)/config", method: "PUT",
                           query: query, body: body, timeout: 60)
    }

    /// Runs provider-declared dependency setup on the gateway host. This is
    /// intentionally NOT profile-scoped: dependencies belong to the gateway's
    /// Python/runtime installation, not to any bot profile.
    func setupMemoryProvider(_ provider: String) async throws {
        let name = try Self.memoryProviderPathName(provider)
        try await restJSON(path: "api/memory/providers/\(name)/setup", method: "POST",
                           body: ["values": .object([:])], timeout: 600)
    }

    /// Capability probe and current credential state. A 404 is intentional:
    /// providers without an `oauth_flow` module do not support this surface.
    func memoryProviderOAuthStatus(_ provider: String, profile: String?) async throws
        -> MemoryProviderOAuthStatus {
        let name = try Self.memoryProviderPathName(provider)
        return MemoryProviderOAuthStatus(
            try await restJSON(path: "api/memory/providers/\(name)/oauth/status",
                               query: Self.memoryProfileQuery(profile), timeout: 30))
    }

    /// Starts the provider's background loopback flow. The gateway opens the
    /// consent browser on its host; Talaria polls the profile-scoped status.
    func startMemoryProviderOAuth(_ provider: String, profile: String?) async throws
        -> MemoryProviderOAuthStatus {
        let name = try Self.memoryProviderPathName(provider)
        return MemoryProviderOAuthStatus(
            try await restJSON(path: "api/memory/providers/\(name)/oauth/start",
                               method: "POST", query: Self.memoryProfileQuery(profile),
                               body: .object([:]), timeout: 30))
    }

    /// Select a provider for a captured scope. Hermes' dedicated selection
    /// route owns the gateway default. A profile override uses the ordinary
    /// profile-scoped config route because `/api/memory/provider` deliberately
    /// has no profile parameter.
    func selectMemoryProvider(_ provider: String, profile: String?) async throws {
        if let profile, !profile.isEmpty {
            try await setGatewayConfigValue(path: ["memory", "provider"],
                                            value: .string(provider), profile: profile)
        } else {
            try await restJSON(path: "api/memory/provider", method: "PUT",
                               body: ["provider": .string(provider)], timeout: 30)
        }
    }

    private static func memoryProfileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    private static func memoryProviderPathName(_ name: String) throws -> String {
        let allowed = name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#,
                                 options: .regularExpression) != nil
        guard allowed else { throw GatewayError(code: -9, message: "invalid memory provider") }
        return name
    }
}

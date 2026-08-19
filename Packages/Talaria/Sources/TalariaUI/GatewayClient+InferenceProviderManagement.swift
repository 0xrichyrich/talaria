import Foundation
import TalariaKit

// Typed mobile client for Hermes Desktop's provider-account and custom-endpoint
// settings. Authority: pinned Hermes `hermes_cli/web_server.py` at b5455fdd,
// `/api/providers/oauth` (10722-11831) and
// `/api/providers/custom-endpoints` (8152-8275). Every call carries the
// addressed profile. Provider credentials never enter these response models.

private func inferenceWebURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          ["https", "http"].contains(scheme), url.host != nil else { return nil }
    return url
}

struct InferenceOAuthSessionTarget: Equatable, Sendable {
    var gatewayID: String
    var profile: String?
    var sessionID: String
}

struct InferenceEndpointMutationTarget: Equatable, Sendable {
    var gatewayID: String
    var profile: String?
    var endpointID: String
}

enum CustomInferenceEndpointValidationPolicy {
    static func requiresAPIKeyReentry(hasSavedKey: Bool, apiKeyChanged: Bool) -> Bool {
        hasSavedKey && !apiKeyChanged
    }
}

public enum InferenceOAuthFlow: String, Sendable {
    case pkce
    case deviceCode = "device_code"
    case external

    init(wire: String?) { self = Self(rawValue: wire ?? "") ?? .external }
}

public struct InferenceOAuthStatus: Sendable, Equatable {
    public var loggedIn: Bool
    public var source: String
    public var sourceLabel: String
    public var tokenPreview: String
    public var expiresAt: String?
    public var hasRefreshToken: Bool
    public var error: String?

    init(_ value: JSONValue) {
        loggedIn = value["logged_in"]?.boolValue ?? false
        source = value["source"]?.stringValue ?? ""
        sourceLabel = value["source_label"]?.stringValue ?? ""
        tokenPreview = value["token_preview"]?.stringValue ?? ""
        expiresAt = value["expires_at"]?.stringValue
        hasRefreshToken = value["has_refresh_token"]?.boolValue ?? false
        error = value["error"]?.stringValue
    }
}

public struct InferenceOAuthProvider: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var flow: InferenceOAuthFlow
    public var cliCommand: String
    public var docsURL: URL?
    public var disconnectHint: String?
    public var disconnectCommand: String?
    public var disconnectable: Bool
    public var status: InferenceOAuthStatus

    init(_ value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        name = value["name"]?.stringValue ?? id
        flow = InferenceOAuthFlow(wire: value["flow"]?.stringValue)
        cliCommand = value["cli_command"]?.stringValue ?? ""
        docsURL = inferenceWebURL(value["docs_url"]?.stringValue)
        disconnectHint = value["disconnect_hint"]?.stringValue
        disconnectCommand = value["disconnect_command"]?.stringValue
        disconnectable = value["disconnectable"]?.boolValue ?? false
        status = InferenceOAuthStatus(value["status"] ?? .object([:]))
    }
}

public struct InferenceOAuthStart: Sendable, Equatable {
    public var sessionID: String
    public var flow: InferenceOAuthFlow
    public var authorizationURL: URL?
    public var verificationURL: URL?
    public var userCode: String
    public var expiresIn: Int
    public var pollInterval: Int

    init(_ value: JSONValue) {
        sessionID = value["session_id"]?.stringValue ?? ""
        flow = InferenceOAuthFlow(wire: value["flow"]?.stringValue)
        authorizationURL = inferenceWebURL(value["auth_url"]?.stringValue)
        verificationURL = inferenceWebURL(value["verification_url"]?.stringValue)
        userCode = value["user_code"]?.stringValue ?? ""
        expiresIn = value["expires_in"]?.intValue ?? 900
        pollInterval = max(1, value["poll_interval"]?.intValue ?? 2)
    }
}

public enum InferenceOAuthPollState: String, Sendable {
    case pending, approved, denied, expired, error
}

public struct InferenceOAuthPoll: Sendable, Equatable {
    public var sessionID: String
    public var state: InferenceOAuthPollState
    public var errorMessage: String?
    public var expiresAt: Double?

    init(_ value: JSONValue) {
        sessionID = value["session_id"]?.stringValue ?? ""
        state = InferenceOAuthPollState(rawValue: value["status"]?.stringValue ?? "") ?? .error
        errorMessage = value["error_message"]?.stringValue
        expiresAt = value["expires_at"]?.doubleValue
    }
}

public struct CustomInferenceEndpoint: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var models: [String]
    public var contextLength: Int?
    public var discoversModels: Bool
    public var hasAPIKey: Bool
    public var apiKeyPreview: String?
    public var isCurrent: Bool
    public var source: String

    init(_ value: JSONValue) {
        id = value["id"]?.stringValue ?? ""
        name = value["name"]?.stringValue ?? id
        baseURL = value["base_url"]?.stringValue ?? ""
        model = value["model"]?.stringValue ?? ""
        models = value["models"]?.arrayValue?.compactMap(\.stringValue) ?? []
        contextLength = value["context_length"]?.intValue
        discoversModels = value["discover_models"]?.boolValue ?? true
        hasAPIKey = value["has_api_key"]?.boolValue ?? false
        apiKeyPreview = value["api_key_preview"]?.stringValue
        isCurrent = value["is_current"]?.boolValue ?? false
        source = value["source"]?.stringValue ?? ""
    }
}

public struct CustomInferenceEndpointCatalog: Sendable, Equatable {
    public var endpoints: [CustomInferenceEndpoint]
    public var currentProvider: String
    public var currentModel: String
    public var currentBaseURL: String

    init(_ value: JSONValue) {
        endpoints = value["endpoints"]?.arrayValue?.map(CustomInferenceEndpoint.init) ?? []
        currentProvider = value["current"]?["provider"]?.stringValue ?? ""
        currentModel = value["current"]?["model"]?.stringValue ?? ""
        currentBaseURL = value["current"]?["base_url"]?.stringValue ?? ""
    }
}

public struct CustomInferenceEndpointDraft: Sendable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    /// nil preserves the saved key, empty clears it, non-empty replaces it.
    public var apiKey: String?
    public var contextLength: Int?
    public var discoversModels: Bool
    public var makeDefault: Bool
    public var models: [String]

    public init(id: String = "", name: String, baseURL: String, model: String,
                apiKey: String? = nil, contextLength: Int? = nil,
                discoversModels: Bool = true, makeDefault: Bool = false,
                models: [String] = []) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model
        self.apiKey = apiKey; self.contextLength = contextLength
        self.discoversModels = discoversModels; self.makeDefault = makeDefault
        self.models = models
    }

    var wireValue: JSONValue {
        var body: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "base_url": .string(baseURL),
            "model": .string(model), "discover_models": .bool(discoversModels),
            "make_default": .bool(makeDefault),
            "models": .array(models.map(JSONValue.string)),
        ]
        if let apiKey { body["api_key"] = .string(apiKey) }
        if let contextLength { body["context_length"] = .number(Double(contextLength)) }
        return .object(body)
    }
}

public struct CustomInferenceEndpointValidation: Sendable, Equatable {
    public var ok: Bool
    public var reachable: Bool
    public var message: String
    public var models: [String]

    init(_ value: JSONValue) {
        ok = value["ok"]?.boolValue ?? false
        reachable = value["reachable"]?.boolValue ?? false
        message = value["message"]?.stringValue ?? ""
        models = value["models"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension GatewayClient {
    private func inferenceProfileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    func inferenceOAuthProviders(profile: String?) async throws -> [InferenceOAuthProvider] {
        let payload = try await restJSON(path: "api/providers/oauth",
                                         query: inferenceProfileQuery(profile), timeout: 30)
        return payload["providers"]?.arrayValue?.map(InferenceOAuthProvider.init) ?? []
    }

    func startInferenceOAuth(providerID: String, profile: String?) async throws -> InferenceOAuthStart {
        InferenceOAuthStart(try await restJSON(
            path: "api/providers/oauth/\(providerID)/start", method: "POST",
            query: inferenceProfileQuery(profile), body: .object([:]), timeout: 45))
    }

    func submitInferenceOAuth(providerID: String, sessionID: String, code: String,
                              profile: String?) async throws -> InferenceOAuthPoll {
        InferenceOAuthPoll(try await restJSON(
            path: "api/providers/oauth/\(providerID)/submit", method: "POST",
            query: inferenceProfileQuery(profile),
            body: .object(["session_id": .string(sessionID), "code": .string(code)]), timeout: 45))
    }

    func pollInferenceOAuth(providerID: String, sessionID: String,
                            profile: String?) async throws -> InferenceOAuthPoll {
        InferenceOAuthPoll(try await restJSON(
            path: "api/providers/oauth/\(providerID)/poll/\(sessionID)",
            query: inferenceProfileQuery(profile), timeout: 30))
    }

    func cancelInferenceOAuth(sessionID: String, profile: String?) async throws {
        try await restJSON(path: "api/providers/oauth/sessions/\(sessionID)", method: "DELETE",
                           query: inferenceProfileQuery(profile), timeout: 30)
    }

    func disconnectInferenceOAuth(providerID: String, profile: String?) async throws {
        try await restJSON(path: "api/providers/oauth/\(providerID)", method: "DELETE",
                           query: inferenceProfileQuery(profile), timeout: 30)
    }

    func customInferenceEndpoints(profile: String?) async throws -> CustomInferenceEndpointCatalog {
        CustomInferenceEndpointCatalog(try await restJSON(
            path: "api/providers/custom-endpoints", query: inferenceProfileQuery(profile), timeout: 30))
    }

    func validateCustomInferenceEndpoint(_ draft: CustomInferenceEndpointDraft) async throws
        -> CustomInferenceEndpointValidation {
        CustomInferenceEndpointValidation(try await restJSON(
            path: "api/providers/custom-endpoints/validate", method: "POST",
            body: draft.wireValue, timeout: 30))
    }

    func saveCustomInferenceEndpoint(_ draft: CustomInferenceEndpointDraft,
                                     profile: String?) async throws -> CustomInferenceEndpointCatalog {
        CustomInferenceEndpointCatalog(try await restJSON(
            path: "api/providers/custom-endpoints", method: "POST",
            query: inferenceProfileQuery(profile), body: draft.wireValue, timeout: 45))
    }

    func activateCustomInferenceEndpoint(id: String, profile: String?) async throws {
        try await restJSON(path: "api/providers/custom-endpoints/\(id)/activate", method: "POST",
                           query: inferenceProfileQuery(profile), body: .object([:]), timeout: 30)
    }

    func deleteCustomInferenceEndpoint(id: String, profile: String?) async throws {
        try await restJSON(path: "api/providers/custom-endpoints/\(id)", method: "DELETE",
                           query: inferenceProfileQuery(profile), timeout: 30)
    }
}

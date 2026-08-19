import Foundation
import TalariaKit

// Hermes profile directory lifecycle is REST-only. The socket `profiles.*`
// family can create/configure/list a profile, but current Hermes exposes
// rename and delete exclusively as:
//
//   PATCH  /api/profiles/{name} {"new_name": ...}
//   DELETE /api/profiles/{name}
//
// Pinned Hermes authority (b5455fdd):
//   hermes_cli/web_routers/profiles.py:1001-1048

public struct ProfileRenameResult: Sendable, Equatable {
    /// Canonical profile id after the operation. Renaming `default` is a
    /// presentation-only rename, so Hermes deliberately returns `default`.
    public var name: String
    public var displayName: String?

    init?(_ value: JSONValue) {
        guard let canonical = value["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !canonical.isEmpty else {
            return nil
        }
        name = canonical
        displayName = value["display_name"]?.stringValue
    }
}

enum ProfileNamePolicy {
    static let reserved: Set<String> = [
        "hermes", "default", "test", "tmp", "root", "sudo",
        "chat", "model", "gateway", "setup", "whatsapp", "login", "logout",
        "status", "cron", "doctor", "dump", "config", "pairing", "skills", "tools",
        "mcp", "sessions", "insights", "version", "update", "uninstall",
        "profile", "plugins", "honcho", "acp",
    ]

    static func validatesNamedProfile(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#,
                          options: .regularExpression) != nil else { return false }
        return !reserved.contains(clean)
    }
}

enum ProfileLifecycleCache {
    static func moveFirst<Value>(_ values: inout [String: Value],
                                 from sources: [String], to destination: String) {
        var sourceValue: Value?
        for source in sources where source != destination {
            if let value = values.removeValue(forKey: source), sourceValue == nil {
                sourceValue = value
            }
        }
        // The server accepted a rename of source → destination. Anything
        // already cached under destination predates that authoritative result.
        values.removeValue(forKey: destination)
        if let sourceValue { values[destination] = sourceValue }
    }
}

enum ProfileLifecycleQueue {
    static func reconcile(_ queue: inout [(botID: String, text: String)],
                          sources: Set<String>, destination: String?) {
        guard let destination else {
            queue.removeAll { sources.contains($0.botID) }
            return
        }
        queue = queue.map { sources.contains($0.botID)
            ? (botID: destination, text: $0.text) : $0 }
    }
}

extension GatewayREST {
    static func profileInventoryRequest(baseURL: URL,
                                        credential: GatewayCredential) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/profiles"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &request)
        return request
    }

    static func profileLifecycleRequest(baseURL: URL, credential: GatewayCredential,
                                        profile: String, method: String,
                                        newName: String? = nil) throws -> URLRequest {
        let cleanProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanProfile.isEmpty else {
            throw GatewayError(code: -9, message: "profile name is empty")
        }
        let url = baseURL.appending(path: "api/profiles").appending(path: cleanProfile)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &request)
        if let newName {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["new_name": newName])
        }
        return request
    }

    public static func renameProfile(baseURL: URL, credential: GatewayCredential,
                                     profile: String, newName: String) async throws
        -> ProfileRenameResult {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw GatewayError(code: 400, message: "Enter a profile name.")
        }
        let request = try profileLifecycleRequest(baseURL: baseURL, credential: credential,
                                                  profile: profile, method: "PATCH",
                                                  newName: cleanName)
        let value = try await profileLifecycleJSON(request, verb: "rename")
        guard let result = ProfileRenameResult(value) else {
            throw GatewayError(code: -9,
                               message: "Hermes confirmed the rename without a canonical name.")
        }
        return result
    }

    public static func deleteProfile(baseURL: URL, credential: GatewayCredential,
                                     profile: String) async throws {
        let request = try profileLifecycleRequest(baseURL: baseURL, credential: credential,
                                                  profile: profile, method: "DELETE")
        _ = try await profileLifecycleJSON(request, verb: "delete")
    }

    /// Authoritative filesystem-backed profile inventory used to resolve an
    /// ambiguous mutation response while the socket fence is still installed.
    /// Hermes' route falls back to a directory scan if rich enumeration fails,
    /// so absence here is stronger evidence than a stale WebSocket roster.
    public static func profileNames(baseURL: URL, credential: GatewayCredential) async throws
        -> Set<String> {
        let request = profileInventoryRequest(baseURL: baseURL, credential: credential)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(code) else {
            throw GatewayError(code: code,
                               message: value?["detail"]?.stringValue
                                   ?? "Profile inventory failed (HTTP \(code)).")
        }
        return try decodeProfileNames(value)
    }

    /// Mutation postconditions use absence as proof, so inventory decoding is
    /// deliberately all-or-nothing. Dropping one malformed or colliding row
    /// would turn an incomplete response into a false commit verdict.
    static func decodeProfileNames(_ value: JSONValue?) throws -> Set<String> {
        guard let rows = value?["profiles"]?.arrayValue else {
            throw GatewayError(code: -9, message: "Profile inventory was malformed.")
        }
        var names = Set<String>()
        var folded = Set<String>()
        for row in rows {
            guard let raw = row["name"]?.stringValue else {
                throw GatewayError(code: -9, message: "Profile inventory contained a malformed row.")
            }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == raw else {
                throw GatewayError(code: -9, message: "Profile inventory contained a blank or non-canonical name.")
            }
            guard names.insert(name).inserted,
                  folded.insert(name.lowercased()).inserted else {
                throw GatewayError(code: -9, message: "Profile inventory contained duplicate or conflicting names.")
            }
        }
        return names
    }

    private static func profileLifecycleJSON(_ request: URLRequest, verb: String) async throws
        -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(code) else {
            let detail = value["detail"]?.stringValue
            throw GatewayError(code: code,
                               message: detail ?? "Profile \(verb) failed (HTTP \(code)).")
        }
        guard value["ok"]?.boolValue == true else {
            throw GatewayError(code: code, message: "Hermes did not confirm the profile \(verb).")
        }
        return value
    }
}

/// Immutable authority captured before a destructive action begins. Keeping
/// the roster key and its parsed route together prevents `default` on one
/// gateway from becoming `default` on another while a confirmation is open.
public struct ProfileLifecycleTarget: Sendable, Equatable {
    public var rosterID: String
    public var route: GatewayBotRoute

    public init(rosterID: String, route: GatewayBotRoute) {
        self.rosterID = rosterID
        self.route = route
    }
}

/// Pure route-key plan used by the model and by collision tests. A gateway
/// switch during the REST await can move a formerly bare key into its
/// qualified form; this plan names only keys that still belong to the exact
/// captured gateway.
struct ProfileLifecycleStatePlan: Equatable {
    var sourceIDs: [String]
    var destinationID: String?
    var destinationIsPrimary: Bool

    init(target: ProfileLifecycleTarget, canonicalNewName: String?,
         currentPrimaryGatewayID: String?, restorePrimaryIfUnclaimed: Bool = false) {
        sourceIDs = [target.route.qualifiedID]
        destinationIsPrimary = currentPrimaryGatewayID == target.route.gatewayID
            || (currentPrimaryGatewayID == nil && restorePrimaryIfUnclaimed)
        if let canonicalNewName {
            destinationID = destinationIsPrimary
                ? canonicalNewName
                : GatewayBotRoute(gatewayID: target.route.gatewayID,
                                  profile: canonicalNewName).qualifiedID
        } else {
            destinationID = nil
            destinationIsPrimary = false
        }
    }
}

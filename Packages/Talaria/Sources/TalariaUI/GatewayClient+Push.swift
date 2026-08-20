import Foundation
import TalariaKit

enum PushRelayContract {
    static func configurationIssue(_ relay: JSONValue) -> String? {
        var issues: [String] = []
        if relay["relay_disabled"]?.boolValue == true {
            issues.append("the relay is disabled")
        }
        if relay["apns_configured"]?.boolValue == false {
            let missing = relay["apns_missing_env"]?.arrayValue?
                .compactMap(\.stringValue).filter { !$0.isEmpty } ?? []
            issues.append(missing.isEmpty
                ? "APNs credentials are incomplete"
                : "missing \(missing.joined(separator: ", "))")
        }
        return issues.isEmpty ? nil : issues.joined(separator: "; ")
    }

    static func validateTestResponse(_ response: JSONValue) throws {
        let results = response["results"]?.arrayValue ?? []
        guard !results.isEmpty else {
            throw GatewayError(code: 502, message: "The relay returned no APNs delivery result.")
        }
        let failures = results.filter { $0["ok"]?.boolValue != true }
        guard failures.isEmpty else {
            let detail = failures.map { row in
                let status = row["status"]?.intValue.map(String.init) ?? "unknown status"
                let reason = row["reason"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return reason.isEmpty ? status : "\(status) \(reason)"
            }.joined(separator: "; ")
            throw GatewayError(code: 502, message: "APNs rejected the test push (\(detail)).")
        }
    }
}

// Device-registry calls against the gateway-side talaria-push relay plugin
// (relay/). Routes are mounted at /api/plugins/talaria-push/ and use the
// same session auth as every other /api/* route — the plugin deliberately
// adds no second secret.

extension GatewayClient {

    /// Relay status: whether the plugin is installed and configured, and how
    /// many devices are registered. nil when the plugin isn't installed.
    public func pushRelayStatus() async -> JSONValue? {
        try? await restJSON(path: "api/plugins/talaria-push/status", timeout: 10)
    }

    /// Devices currently registered with this gateway's relay.
    public func pushRelayDevices() async -> [JSONValue] {
        guard let payload = try? await restJSON(path: "api/plugins/talaria-push/devices",
                                                timeout: 10) else { return [] }
        return payload["devices"]?.arrayValue ?? payload.arrayValue ?? []
    }

    /// Ask the relay to push this device a test notification — the end-to-end
    /// proof that APNs credentials, the token, and Focus settings all work.
    public func sendTestPush(tokenHex: String?, kind: String = "approval") async throws {
        var body: [String: JSONValue] = ["kind": .string(kind)]
        if let tokenHex { body["device_token"] = .string(tokenHex) }
        let response = try await restJSON(path: "api/plugins/talaria-push/test", method: "POST",
                                          body: .object(body), timeout: 20)
        try PushRelayContract.validateTestResponse(response)
    }

    /// Remove this device from the relay (notifications off).
    public func unregisterPushDevice(tokenHex: String) async throws {
        try await restJSON(path: "api/plugins/talaria-push/devices", method: "DELETE",
                           body: ["device_token": .string(tokenHex)], timeout: 15)
    }
}

import Foundation
import TalariaKit

// Device-registry calls against the gateway-side talaria-push relay plugin
// (app/relay). Routes are mounted at /api/plugins/talaria-push/ and use the
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
        try await restJSON(path: "api/plugins/talaria-push/test", method: "POST",
                           body: .object(body), timeout: 20)
    }

    /// Remove this device from the relay (notifications off).
    public func unregisterPushDevice(tokenHex: String) async throws {
        try await restJSON(path: "api/plugins/talaria-push/devices", method: "DELETE",
                           body: ["device_token": .string(tokenHex)], timeout: 15)
    }
}

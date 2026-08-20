import SwiftUI
import TalariaKit
import TalariaTheme
#if os(iOS)
import UserNotifications
import UIKit
#endif

/// Explicit notifications control for Connections: authorization state, the
/// enable toggle, this device's relay registration, and a test push.
///
/// Approvals are the reason push exists here — a bot blocked on you is
/// worthless if the phone stays silent — so the card is honest about every
/// link in the chain: iOS permission → APNs token → gateway relay plugin.
public struct NotificationsCard: View {
    private let model: AppModel
    private let gatewayID: String?

    public init(model: AppModel, gatewayID: String? = nil) {
        self.model = model
        self.gatewayID = gatewayID
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public enum Stage: Equatable {
        case unknown
        case denied
        case notEnabled
        /// Authorized on device, but the gateway relay has no registration.
        case unregistered
        /// iOS accepted authorization but APNs device registration failed.
        case registrationFailed(String)
        /// The gateway plugin exists, but its APNs credentials or relay state
        /// cannot currently deliver notifications.
        case relayMisconfigured(String)
        case ready(devices: Int)
        case noRelay
    }

    @State private var stage: Stage = .unknown
    @State private var busy = false
    @State private var message: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(theme.body(14, weight: .bold))
                    .foregroundStyle(theme.ink)
                Spacer()
            }

            Text(detail)
                .font(theme.body(12))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(theme.mono(11))
                    .foregroundStyle(theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                }
                switch stage {
                case .notEnabled, .unknown:
                    action("Enable notifications", primary: true) { await enable() }
                case .unregistered, .registrationFailed:
                    action("Register this device", primary: true) { await enable() }
                case .ready:
                    action("Send test push", primary: false) { await test() }
                case .denied:
                    action("Open Settings", primary: false) { openSystemSettings() }
                case .noRelay, .relayMisconfigured:
                    action("Recheck", primary: false) { await refresh() }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius)
            .stroke(stage.isProblem ? theme.warn.opacity(0.45) : theme.line, lineWidth: 1))
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .talariaPushRegistrationChanged)) {
            _ in Task { await refresh() }
        }
    }

    // MARK: - Pieces

    private var dotColor: Color {
        switch stage {
        case .ready: theme.ok
        case .denied, .noRelay, .registrationFailed, .relayMisconfigured: theme.danger
        case .unknown: theme.faint
        default: theme.warn
        }
    }

    private var title: String {
        switch stage {
        case .ready: "Notifications on"
        case .denied: "Notifications blocked"
        case .noRelay: "Relay not installed"
        case .relayMisconfigured: "Relay needs attention"
        case .unregistered: "Almost there"
        case .registrationFailed: "APNs registration failed"
        default: "Notifications off"
        }
    }

    private var detail: String {
        switch stage {
        case .ready(let devices):
            return "Approvals, agent replies, mentions, finished routines and long tasks push from your gateway. \(devices) device\(devices == 1 ? "" : "s") registered."
        case .denied:
            return "iOS is blocking Talaria's notifications. Turn them back on in Settings → Talaria → Notifications."
        case .noRelay:
            return "This gateway has no talaria-push relay plugin, so it can't send pushes. Install relay/talaria-push on the gateway host, then recheck."
        case .relayMisconfigured(let reason):
            return "This gateway registered the phone, but its APNs relay is not ready: \(reason)"
        case .unregistered:
            return "Notifications are allowed on this device but the gateway hasn't registered it yet."
        case .registrationFailed(let message):
            return "iOS could not register this device with APNs: \(message)"
        default:
            return copy.pushNote
        }
    }

    @ViewBuilder private func action(_ label: String, primary: Bool,
                                     _ run: @escaping () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            Text(label)
                .font(theme.mono(11, weight: .bold))
                .foregroundStyle(primary ? theme.accentFg : theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(primary ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.inset),
                            in: RoundedRectangle(cornerRadius: theme.buttonRadius))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: theme.buttonRadius)
                            .stroke(theme.lineStrong, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: - Actions

    private func targetClient() async -> GatewayClient? {
        if let gatewayID { return try? await model.routedClient(gatewayID: gatewayID) }
        return model.client
    }

    private func refresh() async {
        #if os(iOS)
        let status = await PushCoordinator.shared.authorizationStatus()
        switch status {
        case .denied:
            stage = .denied
            return
        case .notDetermined:
            stage = .notEnabled
            return
        default:
            break
        }
        if let failure = PushCoordinator.shared.registrationFailure {
            stage = .registrationFailed(failure.message)
            return
        }
        guard let client = await targetClient() else {
            stage = .unregistered
            return
        }
        guard let relay = await client.pushRelayStatus() else {
            stage = .noRelay
            return
        }
        if let issue = PushRelayContract.configurationIssue(relay) {
            stage = .relayMisconfigured(issue)
            return
        }
        let devices: Int
        if let reported = relay["devices"]?.intValue ?? relay["device_count"]?.intValue {
            devices = reported
        } else {
            // `await` cannot live in a `??` autoclosure, so the fallback is spelled out.
            devices = await client.pushRelayDevices().count
        }
        guard let token = PushCoordinator.shared.deviceTokenHex else {
            stage = .unregistered
            return
        }
        stage = await client.pushDevice(tokenHex: token) == nil
            ? .unregistered : .ready(devices: devices)
        #else
        stage = .noRelay
        #endif
    }

    private func enable() async {
        #if os(iOS)
        busy = true
        message = nil
        defer { busy = false }
        let status = await PushCoordinator.shared.authorizationStatus()
        if status == .notDetermined {
            guard await PushCoordinator.shared.requestAuthorization() else {
                stage = .denied
                return
            }
        } else if status == .denied {
            stage = .denied
            return
        } else {
            PushCoordinator.shared.registerForRemoteNotifications()
        }
        // The APNs round trip resolves the token, then the relay handshake.
        PushCoordinator.shared.registerWithRelay(gatewayID: gatewayID)
        try? await Task.sleep(for: .seconds(2))
        await refresh()
        if case .registrationFailed(let failure) = stage {
            message = "APNs failed: \(failure). Tap Register this device to retry."
        } else if case .unregistered = stage {
            message = "Waiting on APNs — pull down again in a moment."
        }
        #endif
    }

    private func test() async {
        #if os(iOS)
        busy = true
        defer { busy = false }
        guard let client = await targetClient() else { return }
        do {
            try await client.sendTestPush(tokenHex: PushCoordinator.shared.deviceTokenHex)
            message = "Test push sent — it should arrive in a second."
        } catch {
            let detail = (error as? GatewayError)?.message ?? error.localizedDescription
            message = "Test failed: \(detail)"
        }
        #endif
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

private extension NotificationsCard.Stage {
    var isProblem: Bool {
        switch self {
        case .ready, .unknown: false
        default: true
        }
    }
}

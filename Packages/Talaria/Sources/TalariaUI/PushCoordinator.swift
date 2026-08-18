import Foundation
import TalariaKit
import TalariaTheme

// Push pipeline glue for the app process:
// - notification authorization + UNUserNotificationCenter delegate,
// - the TALARIA_APPROVAL actionable category (approve from the lock screen),
// - APNs remote registration with the device token exposed async for the
//   gateway push-relay handshake,
// - action + deep-link routing into AppModel,
// - demo-mode local previews of the relay's payloads (DB.PUSHES shapes).
//
// The wire contract for a relay push mirrors the design DB:
//   { kind, bot, title, body, approval_request_id, session_id }
// with `kind` one of PushKind and `mutable-content: 1` so the
// TalariaNotificationService extension can decorate it.

/// userInfo keys shared with the gateway relay. The notification-service
/// extension duplicates these literals to stay dependency-free.
public enum PushPayloadKey {
    public static let kind = "kind"
    public static let bot = "bot"
    public static let title = "title"
    public static let body = "body"
    public static let approvalRequestID = "approval_request_id"
    public static let sessionID = "session_id"
}

/// Notification category / action identifiers, shared by PushCoordinator,
/// the service extension and the relay payloads.
public enum PushIdentifiers {
    public static let approvalCategory = "TALARIA_APPROVAL"
    public static let approveAction = "APPROVE_ACTION"
    public static let laterAction = "LATER_ACTION"
}

public extension Notification.Name {
    /// Posted when a talaria://connections deep link or gateway push arrives.
    /// Connections is a navigation push off the roster (not a tab), so the
    /// root view — which owns that push state — observes this and presents it.
    static let talariaOpenConnections = Notification.Name("bot.talaria.openConnections")
}

#if os(iOS)
import UserNotifications
import UIKit

@MainActor
public final class PushCoordinator: NSObject {

    public static let shared = PushCoordinator()

    private weak var model: AppModel?
    private var attached = false

    // MARK: - Wiring

    /// Install as the notification-center delegate, register the actionable
    /// categories in the current theme's voice, and keep them in that voice
    /// as the theme changes.
    public func configure(model: AppModel) {
        // Idempotent: the app target wires this at launch and the root view
        // re-wires on appear; re-arming for the same model would stack a
        // second observation chain.
        if attached, self.model === model { return }
        self.model = model
        attached = true
        UNUserNotificationCenter.current().delegate = self
        armCategoryObservation()
    }

    public func detach() {
        attached = false
        model = nil
    }

    /// Approve/Later become RELEASE/LATER become grant-the-seal/later —
    /// category titles follow the copy pack.
    public func registerCategories(copy: CopyPack) {
        // foreground:false — approving must not launch the app, and
        // authenticationRequired keeps a locked phone from releasing work.
        let approve = UNNotificationAction(
            identifier: PushIdentifiers.approveAction,
            title: copy.approve,
            options: [.authenticationRequired])
        let later = UNNotificationAction(
            identifier: PushIdentifiers.laterAction,
            title: copy.later,
            options: [])
        let category = UNNotificationCategory(
            identifier: PushIdentifiers.approvalCategory,
            actions: [approve, later],
            intentIdentifiers: [],
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func armCategoryObservation() {
        guard attached, let model else { return }
        withObservationTracking {
            self.registerCategories(copy: model.theme.copy)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.attached else { return }
                self.armCategoryObservation()
            }
        }
    }

    // MARK: - Authorization + APNs registration

    /// Onboarding's "Allow" card. Returns whether alerts were granted and,
    /// on success, kicks off APNs registration for the relay.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        // Critical alerts (approvals breaking through Focus) additionally
        // need the com.apple.developer.usernotifications.critical-alerts
        // entitlement; the standard set keeps this working without it.
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        if granted { registerForRemoteNotifications() }
        return granted
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Device token (relay registration)

    /// Lower-cased hex APNs token once registration succeeded.
    public private(set) var deviceTokenHex: String?
    private var tokenWaiters: [CheckedContinuation<String, Never>] = []

    /// Awaitable token for the gateway relay handshake: resolves immediately
    /// when registration already happened, otherwise suspends until the
    /// AppDelegate reports the token.
    public var deviceToken: String {
        get async {
            if let deviceTokenHex { return deviceTokenHex }
            return await withCheckedContinuation { continuation in
                tokenWaiters.append(continuation)
            }
        }
    }

    /// Forwarded from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceTokenHex = hex
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: hex) }
        registerWithRelayIfConnected()
    }

    /// Hand the token to the gateway's talaria-push relay plugin. Safe to call
    /// repeatedly (idempotent upsert server-side); silently skips when the
    /// gateway is absent or the plugin isn't installed.
    ///
    /// Connecting a gateway is the in-context moment to ask for notification
    /// permission — approvals are the whole point of the relay — so an
    /// undetermined status prompts once here rather than only in onboarding.
    public func registerWithRelayIfConnected() {
        guard let client = model?.client else { return }
        Task { @MainActor in
            if deviceTokenHex == nil {
                let status = await authorizationStatus()
                switch status {
                case .notDetermined:
                    guard await requestAuthorization() else { return }
                case .authorized, .provisional, .ephemeral:
                    registerForRemoteNotifications()
                default:
                    return  // denied — respect it
                }
            }
            // Wait for the APNs token (already resolved when registration
            // happened earlier in this launch).
            let hex = await deviceToken
            // The relay's upsert REPLACES the stored record wholesale
            // (talaria_push_relay/devices.py `upsert`), and an omitted
            // `profile_filter` normalizes to [] — "every bot". Re-sending the
            // existing filter is what stops this connect-time handshake from
            // silently undoing the per-bot choice made in Settings.
            // `environment` is deliberately NOT carried over: it describes this
            // build's aps-environment, not a user preference.
            let existing = await client.pushDevice(tokenHex: hex)
            try? await client.registerPushDevice(tokenHex: hex, environment: "dev",
                                                 profileFilter: existing?.profileFilter ?? [])
        }
    }

    /// Forwarded from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Waiters stay parked — the relay handshake simply never fires; the app
    /// remains fully usable over the live socket.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        deviceTokenHex = nil
    }

    // MARK: - Routing

    /// `talaria://bot/<id>` (island / widget tap) and `talaria://approvals`.
    @discardableResult
    public func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "talaria", let model else { return false }
        switch url.host {
        case "bot":
            let id = url.pathComponents.count > 1 ? url.pathComponents[1] : url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return false }
            // openChat, not a raw openBotID write: it resumes the bot's
            // canonical chat and hydrates it. A bare write lands in an empty
            // transcript whose first send forks a new session.
            model.openChat(botID: id)
            return true
        case "approvals":
            model.selectedTab = .approvals
            model.openBotID = nil
            return true
        case "connections":
            model.selectedTab = .home
            model.openBotID = nil
            NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
            return true
        default:
            return false
        }
    }

    /// Notification tap / action routing — same shape as the prototype's
    /// `bannerGo`: approval → approvals, gateway → roster (Connections is one
    /// tap deep), anything else → that bot's chat.
    private func handle(response: UNNotificationResponse) {
        guard let model else { return }
        let info = response.notification.request.content.userInfo
        // The relay's wire kind "long_task" is the app's PushKind.task.
        let kind = (info[PushPayloadKey.kind] as? String)
            .flatMap { PushKind(rawValue: $0 == "long_task" ? "task" : $0) }
        let botID = info[PushPayloadKey.bot] as? String

        switch response.actionIdentifier {
        case PushIdentifiers.approveAction:
            if let approval = approval(matching: info, in: model) {
                // Through the shared ledger so the inline chat card and the
                // Approvals tab see the exact outcome.
                ApprovalOutcomes.shared.resolve(approval, approve: true, in: model)
            }
        case PushIdentifiers.laterAction:
            break // Explicitly deferred; the approval stays pending.
        case UNNotificationDefaultActionIdentifier:
            switch kind {
            case .approval:
                model.selectedTab = .approvals
            case .gateway:
                model.selectedTab = .home
                model.openBotID = nil
                NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
            default:
                if let botID, botID != "gateway" {
                    // Same rule as every other route into a chat: openChat
                    // resumes the canonical conversation, a raw write does not.
                    model.openChat(botID: botID)
                } else {
                    model.selectedTab = .activity
                }
            }
        default:
            break
        }
    }

    private func approval(matching info: [AnyHashable: Any], in model: AppModel) -> Approval? {
        if let requestID = info[PushPayloadKey.approvalRequestID] as? String,
           let match = model.approvals.first(where: { $0.id == requestID }) {
            return match
        }
        // Fall back to the bot's oldest pending approval.
        if let botID = info[PushPayloadKey.bot] as? String {
            return model.approvals.first { $0.botID == botID }
        }
        return nil
    }

    // MARK: - Demo previews

    /// The relay payloads from the design DB (`DB.PUSHES`), used to preview
    /// real notification behavior in demo mode without a gateway.
    public struct DemoPush: Sendable {
        public var botID: String
        public var title: String
        public var body: String
        public var kind: PushKind
        public var approvalRequestID: String?

        public init(botID: String, title: String, body: String,
                    kind: PushKind, approvalRequestID: String? = nil) {
            self.botID = botID; self.title = title; self.body = body
            self.kind = kind; self.approvalRequestID = approvalRequestID
        }
    }

    /// Nonisolated so call sites (and the default argument below) can read it
    /// without hopping to the main actor — it's immutable Sendable data.
    public nonisolated static let demoPushes: [DemoPush] = [
        DemoPush(botID: "inbox", title: "inbox needs approval",
                 body: "Reply to Sarah Chen is ready to send.",
                 kind: .approval, approvalRequestID: "ap1"),
        DemoPush(botID: "researcher", title: "Morning digest finished",
                 body: "6 papers · 2 flagged must-read.", kind: .routine),
        DemoPush(botID: "comms", title: "comms mentioned you",
                 body: "“which screenshot for the launch post?”", kind: .mention),
        DemoPush(botID: "ops", title: "Backup verified",
                 body: "42 GB · 18m · checksums clean.", kind: .task),
        DemoPush(botID: "gateway", title: "homelab reconnected",
                 body: "Offline 6m — tailscale route recovered.", kind: .gateway),
    ]

    /// Schedule a sample local notification carrying the exact relay payload
    /// shape — background the app to see the banner, category actions and
    /// approve-from-notification flow.
    public func scheduleDemoPush(_ push: DemoPush = PushCoordinator.demoPushes[0],
                                 after seconds: TimeInterval = 4) {
        let content = UNMutableNotificationContent()
        content.title = push.title
        content.body = push.body
        content.sound = .default
        content.threadIdentifier = push.botID
        var info: [String: Any] = [
            PushPayloadKey.kind: push.kind.rawValue,
            PushPayloadKey.bot: push.botID,
            PushPayloadKey.title: push.title,
            PushPayloadKey.body: push.body,
        ]
        if push.kind == .approval {
            content.categoryIdentifier = PushIdentifiers.approvalCategory
            if let requestID = push.approvalRequestID {
                info[PushPayloadKey.approvalRequestID] = requestID
            }
        }
        content.userInfo = info

        let request = UNNotificationRequest(
            identifier: "talaria-demo-\(push.kind.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, seconds), repeats: false))
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushCoordinator: UNUserNotificationCenterDelegate {

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Foreground pushes still surface — the in-app banner mirrors the
        // system one in demo mode, but real relay pushes must never vanish.
        [.banner, .list, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        handle(response: response)
    }
}

#else

/// macOS compile-check shim: the package builds for macOS 14 without UIKit;
/// call sites keep a stable surface and do nothing.
@MainActor
public final class PushCoordinator {
    public static let shared = PushCoordinator()
    public private(set) var deviceTokenHex: String?
    public init() {}
    public func configure(model: AppModel) {}
    public func detach() {}
    @discardableResult
    public func requestAuthorization() async -> Bool { false }
    public func registerForRemoteNotifications() {}
    @discardableResult
    public func handleDeepLink(_ url: URL) -> Bool { false }
}

#endif

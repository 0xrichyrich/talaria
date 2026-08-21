import Foundation
import TalariaKit
import TalariaTheme

// Push pipeline glue for the app process:
// - notification authorization + UNUserNotificationCenter delegate,
// - the TALARIA_APPROVAL actionable category (approve from the lock screen),
// - the TALARIA_RESPONSE display-only category (agent reply ready),
// - APNs remote registration with the device token exposed async for the
//   gateway push-relay handshake,
// - action + deep-link routing into AppModel,
// - demo-mode local previews of the relay's payloads (DB.PUSHES shapes).
//
// The wire contract for a relay push mirrors the design DB:
//   { kind, gateway_id, bot, title, body, approval_request_id, session_id }
// with `kind` one of PushKind and `mutable-content: 1` so the
// TalariaNotificationService extension can decorate it.

/// userInfo keys shared with the gateway relay. The notification-service
/// extension duplicates these literals to stay dependency-free.
public enum PushPayloadKey {
    public static let kind = "kind"
    public static let bot = "bot"
    public static let botDisplayName = "bot_display_name"
    public static let botAvatar = "bot_avatar"
    public static let title = "title"
    public static let body = "body"
    public static let approvalRequestID = "approval_request_id"
    public static let sessionID = "session_id"
    public static let gatewayID = "gateway_id"
    public static let deeplink = "deeplink"
}

/// Resolve an untrusted relay payload into Talaria's collision-safe roster id.
/// Legacy payloads without gateway_id remain usable only when exactly one
/// source exists; multiple saved gateways make a bare profile ambiguous and
/// therefore non-actionable.
struct PushRouteResolver {
    static func sourceGatewayID(stamped sourceGatewayID: String?,
                                knownGatewayIDs: Set<String>,
                                activeGatewayID: String?) -> String? {
        if let sourceGatewayID {
            return knownGatewayIDs.contains(sourceGatewayID) ? sourceGatewayID : nil
        }
        if knownGatewayIDs.count == 1 { return knownGatewayIDs.first }
        if knownGatewayIDs.isEmpty { return activeGatewayID }
        return nil
    }

    static func botID(raw: String?, sourceGatewayID: String?,
                      knownGatewayIDs: Set<String>, activeGatewayID: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "gateway" else { return nil }
        // The source is a separate stamped field. A pre-qualified profile is
        // rejected rather than accepted under a second, possibly conflicting,
        // source identity.
        guard GatewayBotRoute(qualifiedID: raw) == nil else { return nil }
        guard let source = Self.sourceGatewayID(
            stamped: sourceGatewayID, knownGatewayIDs: knownGatewayIDs,
            activeGatewayID: activeGatewayID) else { return nil }
        return source == activeGatewayID
            ? raw : GatewayBotRoute(gatewayID: source, profile: raw).qualifiedID
    }

    /// Build the immutable route used by notification taps that carry a
    /// durable session. The stamped source is trusted only when it is saved;
    /// the legacy source-less shape remains usable only with one unambiguous
    /// saved gateway.
    static func exactStoredSessionRoute(for payload: PushNotificationPayload,
                                        knownGatewayIDs: Set<String>,
                                        activeGatewayID: String?) -> ExactStoredSessionRoute? {
        guard let profile = payload.bot, !profile.isEmpty, profile != "gateway",
              GatewayBotRoute(qualifiedID: profile) == nil,
              let storedSessionID = payload.sessionID, !storedSessionID.isEmpty,
              let gatewayID = sourceGatewayID(
                stamped: payload.gatewayID, knownGatewayIDs: knownGatewayIDs,
                activeGatewayID: activeGatewayID) else { return nil }
        return ExactStoredSessionRoute(
            gatewayID: gatewayID, profile: profile,
            storedSessionID: storedSessionID)
    }

    /// The destination a non-gateway push may safely open. The bot id is
    /// source-qualified whenever it belongs to a saved gateway other than the
    /// active one; the stored id is retained separately so a reply push can
    /// reopen the exact durable transcript rather than the canonical chat.
    static func destination(for payload: PushNotificationPayload,
                            knownGatewayIDs: Set<String>,
                            activeGatewayID: String?, demo: Bool = false)
        -> PushRouteDestination? {
        let botID = demo
            ? payload.bot
            : botID(raw: payload.bot, sourceGatewayID: payload.gatewayID,
                   knownGatewayIDs: knownGatewayIDs, activeGatewayID: activeGatewayID)
        guard let botID, !botID.isEmpty, botID != "gateway" else { return nil }
        if payload.kind == .response,
           payload.sessionID?.isEmpty != false { return nil }
        return PushRouteDestination(botID: botID, storedSessionID: payload.sessionID,
                                    gatewayID: payload.gatewayID)
    }
}

/// The decoded, untrusted envelope shared by notification routing and tests.
/// Display strings are optional because APNs may provide them only in `aps`,
/// while routing identity is carried by the relay's custom fields.
struct PushNotificationPayload: Sendable, Equatable {
    var wireKind: String
    var kind: PushKind
    var gatewayID: String?
    var bot: String?
    var title: String?
    var body: String?
    var approvalRequestID: String?
    var sessionID: String?
    var deeplink: URL?
}

/// Source-qualified destination for a notification tap.
struct PushRouteDestination: Sendable, Equatable {
    var botID: String
    var storedSessionID: String?
    var gatewayID: String?
}

/// Default-tap navigation shared by the iOS notification delegate and package
/// integration tests. `mode == .demo` is only Talaria's launch placeholder;
/// canned-session routing is authorized solely by an actually loaded demo
/// world, otherwise a cold exact response must enter the retained live queue.
@MainActor
enum PushDefaultActionRouter {
    static func route(_ payload: PushNotificationPayload, in model: AppModel,
                      knownGatewayIDs: Set<String>) {
        let scriptedDemo = model.demoDataLoaded
        let destination = PushRouteResolver.destination(
            for: payload,
            knownGatewayIDs: knownGatewayIDs,
            activeGatewayID: model.activeGatewayID,
            demo: scriptedDemo)
        let exactStoredSessionRoute = scriptedDemo ? nil
            : PushRouteResolver.exactStoredSessionRoute(
                for: payload,
                knownGatewayIDs: knownGatewayIDs,
                activeGatewayID: model.activeGatewayID)

        switch payload.kind {
        case .approval:
            model.selectedTab = .approvals
        case .gateway:
            model.selectedTab = .home
            model.openBotID = nil
            NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
        case .response:
            // A real response without exact saved-source authority is fail
            // closed; it must never fall through to a canonical chat.
            if let exactStoredSessionRoute {
                model.openExactStoredSession(
                    exactStoredSessionRoute, origin: .notification)
            } else if scriptedDemo,
                      let destination, let sessionID = destination.storedSessionID {
                model.openStoredSession(sessionID, botID: destination.botID)
            }
        default:
            guard let destination, destination.botID != "gateway" else {
                model.selectedTab = .activity
                return
            }
            // Session-bearing live pushes use the exact queue. Only an
            // actually loaded scripted world may use the demo session opener.
            if let exactStoredSessionRoute {
                model.openExactStoredSession(
                    exactStoredSessionRoute, origin: .notification)
            } else if scriptedDemo, let sessionID = payload.sessionID {
                model.openStoredSession(sessionID, botID: destination.botID)
            } else {
                model.openChat(botID: destination.botID)
            }
        }
    }
}

enum PushPayloadDecoder {
    static func decode(_ userInfo: [AnyHashable: Any]) -> PushNotificationPayload? {
        guard let rawKind = string(userInfo[PushPayloadKey.kind]),
              let kind = PushNotificationPolicy.kind(for: rawKind) else { return nil }
        return PushNotificationPayload(
            wireKind: rawKind,
            kind: kind,
            gatewayID: string(userInfo[PushPayloadKey.gatewayID]),
            bot: string(userInfo[PushPayloadKey.bot]),
            title: string(userInfo[PushPayloadKey.title]),
            body: string(userInfo[PushPayloadKey.body]),
            approvalRequestID: string(userInfo[PushPayloadKey.approvalRequestID]),
            sessionID: string(userInfo[PushPayloadKey.sessionID]),
            deeplink: string(userInfo[PushPayloadKey.deeplink]).flatMap(URL.init(string:)))
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// The minimum source-qualified identity required before a notification may
/// answer a live approval. Hook mode is the only valid source without a
/// request id, and is restricted to this exact source/profile/session FIFO.
struct PushApprovalIdentity: Sendable, Equatable {
    var gatewayID: String
    var profile: String
    var storedSessionID: String
    var requestID: String?

    static func resolve(gatewayID: String?, profile: String?, storedSessionID: String?,
                        requestID: String?, knownGatewayIDs: Set<String>) -> Self? {
        guard let gatewayID, knownGatewayIDs.contains(gatewayID),
              let profile, !profile.isEmpty,
              GatewayBotRoute(qualifiedID: profile) == nil,
              let storedSessionID, !storedSessionID.isEmpty else { return nil }
        return Self(gatewayID: gatewayID, profile: profile,
                    storedSessionID: storedSessionID,
                    requestID: requestID.flatMap { $0.isEmpty ? nil : $0 })
    }
}

enum PushApprovalSelection {
    static func select(_ pending: [ApprovalDetail], requestID: String?) -> ApprovalDetail? {
        guard let requestID else { return pending.first }
        let matches = pending.filter { $0.request.requestID == requestID }
        return matches.count == 1 ? matches[0] : nil
    }

    static func stillCurrent(_ selected: ApprovalDetail, in pending: [ApprovalDetail],
                             requestID: String?) -> Bool {
        select(pending, requestID: requestID)?.request.requestID == selected.request.requestID
    }
}

struct PushApprovalResumeSnapshot: Sendable, Equatable {
    var sessionID: String
    var storedSessionID: String
    var profile: String
}

struct PushApprovalActions {
    var resume: (_ storedSessionID: String, _ profile: String) async throws
        -> PushApprovalResumeSnapshot
    var pending: (_ liveSessionID: String) async throws -> [ApprovalDetail]
    var answer: (_ liveSessionID: String, _ requestID: String) async throws -> Int
}

enum PushApprovalOrchestrator {
    static func approve(identity: PushApprovalIdentity,
                        connect: (GatewayBotRoute) async throws -> PushApprovalActions)
        async throws -> ApprovalDetail {
        let route = GatewayBotRoute(gatewayID: identity.gatewayID, profile: identity.profile)
        return try await approve(identity: identity, actions: connect(route))
    }

    /// Cold notification approval transaction. Every read and the final write
    /// uses the same resumed live session, with a second pending read directly
    /// before mutation so a timeout/desktop response cannot advance the FIFO.
    static func approve(identity: PushApprovalIdentity,
                        actions: PushApprovalActions) async throws -> ApprovalDetail {
        let resumed = try await actions.resume(identity.storedSessionID, identity.profile)
        guard !resumed.sessionID.isEmpty else {
            throw GatewayError(code: -21, message: "Approval session is no longer available.")
        }
        guard resumed.profile == identity.profile,
              !resumed.storedSessionID.isEmpty,
              resumed.storedSessionID == identity.storedSessionID else {
            throw GatewayError(code: -20, message: "Approval session identity did not match.")
        }
        let first = try await actions.pending(resumed.sessionID)
        guard let selected = PushApprovalSelection.select(first, requestID: identity.requestID) else {
            throw GatewayError(code: -22, message: "Approval is no longer pending.")
        }
        let current = try await actions.pending(resumed.sessionID)
        guard PushApprovalSelection.stillCurrent(selected, in: current,
                                                 requestID: identity.requestID) else {
            throw GatewayError(code: -22, message: "Approval changed before it could be sent.")
        }
        guard try await actions.answer(resumed.sessionID, selected.request.requestID) > 0 else {
            throw GatewayError(code: -22, message: "Approval was already resolved.")
        }
        return selected
    }
}

public struct PushRegistrationFailure: Sendable, Equatable {
    public var message: String
    public var occurredAt: Date

    public init(message: String, occurredAt: Date = Date()) {
        self.message = message
        self.occurredAt = occurredAt
    }
}

/// Notification category / action identifiers, shared by PushCoordinator,
/// the service extension and the relay payloads.
public enum PushIdentifiers {
    public static let approvalCategory = PushNotificationPolicy.approvalCategory
    public static let responseCategory = PushNotificationPolicy.responseCategory
    public static let approveAction = "APPROVE_ACTION"
    public static let laterAction = "LATER_ACTION"
}

public extension Notification.Name {
    /// Posted when a talaria://connections deep link or gateway push arrives.
    /// Connections is a navigation push off the roster (not a tab), so the
    /// root view — which owns that push state — observes this and presents it.
    static let talariaOpenConnections = Notification.Name("bot.talaria.openConnections")
    /// APNs token registration completed or failed; Settings re-reads the
    /// typed state immediately instead of relying on a fixed sleep/pull.
    static let talariaPushRegistrationChanged = Notification.Name(
        "bot.talaria.pushRegistrationChanged")
}

/// Serializes read-preserve-write device upserts per gateway. The relay
/// replaces the whole record, so an automatic reconnect registration racing a
/// Settings filter edit must never restore the older filter after the user.
actor PushDeviceMutationQueue {
    static let shared = PushDeviceMutationQueue()

    private struct Tail {
        var generation: UInt64
        var task: Task<Void, Never>
    }
    private var tails: [String: Tail] = [:]
    private var generation: UInt64 = 0

    /// nil means success; a non-empty string is the operation's display error.
    func run(gatewayID: String,
             operation: @escaping @Sendable () async -> String?) async -> String? {
        let previous = tails[gatewayID]?.task
        generation &+= 1
        let mine = generation
        let result = Task<String?, Never> {
            if let previous { await previous.value }
            return await operation()
        }
        let tail = Task<Void, Never> { _ = await result.value }
        tails[gatewayID] = Tail(generation: mine, task: tail)
        let value = await result.value
        if tails[gatewayID]?.generation == mine { tails[gatewayID] = nil }
        return value
    }
}

/// Synchronous admission fence for Settings filter edits. SwiftUI launches the
/// network write in a Task, so an ordinary async `busy = true` is too late to
/// stop a second tap deriving from the same snapshot.
struct PushFilterMutationAdmission: Sendable {
    private(set) var active = false

    mutating func claim() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    mutating func release() { active = false }
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
    /// category titles follow the copy pack. Response-ready notifications
    /// intentionally register a separate category with no actions.
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
        let responseCategory = UNNotificationCategory(
            identifier: PushIdentifiers.responseCategory,
            actions: [],
            intentIdentifiers: [],
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            category, responseCategory,
        ])
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
        // Time Sensitive delivery is authorized by the app entitlement and the
        // user's notification settings. UNAuthorizationOptions.timeSensitive
        // is deprecated on current Apple SDKs.
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        if granted { registerForRemoteNotifications() }
        return granted
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func registerForRemoteNotifications() {
        registrationFailure = nil
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Device token (relay registration)

    /// Lower-cased hex APNs token once registration succeeded.
    public private(set) var deviceTokenHex: String?
    public private(set) var registrationFailure: PushRegistrationFailure?
    private var tokenWaiters: [CheckedContinuation<String?, Never>] = []

    /// Awaitable token for the gateway relay handshake: resolves immediately
    /// when registration already happened, otherwise suspends until the
    /// AppDelegate reports the token.
    public var deviceToken: String? {
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
        registrationFailure = nil
        NotificationCenter.default.post(name: .talariaPushRegistrationChanged, object: nil)
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: hex) }
        registerWithRelayIfConnected()
    }

    /// Wire environment must follow the signed build. Development entitlement
    /// uses APNs sandbox; TestFlight/App Store builds use production.
    public var apnsEnvironment: String {
        #if DEBUG
        "dev"
        #else
        "prod"
        #endif
    }

    /// Hand the token to the gateway's talaria-push relay plugin. Safe to call
    /// repeatedly (idempotent upsert server-side); silently skips when the
    /// gateway is absent or the plugin isn't installed.
    ///
    /// Connecting a gateway is the in-context moment to ask for notification
    /// permission — approvals are the whole point of the relay — so an
    /// undetermined status prompts once here rather than only in onboarding.
    public func registerWithRelayIfConnected() {
        registerWithRelay(gatewayID: nil)
    }

    /// Register against one selected gateway, or every saved gateway when no
    /// target is supplied. Multi-gateway push is not useful if only the active
    /// chat machine receives this device token.
    public func registerWithRelay(gatewayID: String?) {
        guard let model else { return }
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
            guard let hex = await deviceToken else { return }
            var clients: [(gatewayID: String, client: GatewayClient)] = []
            if let gatewayID {
                if let client = try? await model.routedClient(gatewayID: gatewayID) {
                    clients.append((gatewayID, client))
                }
            } else {
                let lookups = ConnectionRegistry.shared.saved.map { gateway in
                    Task { @MainActor in
                        (gateway.id, try? await model.routedClient(gatewayID: gateway.id))
                    }
                }
                for lookup in lookups {
                    let (id, candidate) = await lookup.value
                    if let candidate, !clients.contains(where: { $0.client === candidate }) {
                        clients.append((id, candidate))
                    }
                }
                if clients.isEmpty, let client = model.client,
                   let activeGatewayID = model.activeGatewayID {
                    clients.append((activeGatewayID, client))
                }
            }
            // The relay's upsert REPLACES the stored record wholesale
            // (talaria_push_relay/devices.py `upsert`), and an omitted
            // `profile_filter` normalizes to [] — "every bot". Re-sending the
            // existing filter is what stops this connect-time handshake from
            // silently undoing the per-bot choice made in Settings.
            // `environment` is deliberately NOT carried over: it describes this
            // build's aps-environment, not a user preference.
            let environment = apnsEnvironment
            let registrations = clients.map { target in
                Task {
                    await PushDeviceMutationQueue.shared.run(gatewayID: target.gatewayID) {
                    let existing = await target.client.pushDevice(tokenHex: hex)
                    do {
                        try await target.client.registerPushDevice(
                            tokenHex: hex, environment: environment, gatewayID: target.gatewayID,
                            profileFilter: existing?.profileFilter ?? [])
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                    }
                }
            }
            for registration in registrations { _ = await registration.value }
        }
    }

    /// Forwarded from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Release every handshake waiter. A later successful APNs callback invokes
    /// registration again, so retaining failed continuations only leaks tasks.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        deviceTokenHex = nil
        registrationFailure = PushRegistrationFailure(message: error.localizedDescription)
        NotificationCenter.default.post(name: .talariaPushRegistrationChanged, object: nil)
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    // MARK: - Routing

    /// Notification tap / action routing — same shape as the prototype's
    /// `bannerGo`: approval → approvals, gateway → roster (Connections is one
    /// tap deep), anything else → that bot's chat.
    private func handle(response: UNNotificationResponse) async {
        guard let model else { return }
        let info = response.notification.request.content.userInfo
        guard let payload = PushPayloadDecoder.decode(info) else { return }

        switch response.actionIdentifier {
        case PushIdentifiers.approveAction:
            // Category registration is not an authority boundary: a crafted
            // response can carry any action identifier. Only an explicitly
            // decoded approval push may enter the existing cold approval path.
            guard PushNotificationPolicy.allowsApprovalAction(for: payload.wireKind) else {
                return
            }
            do {
                try await approveFromPush(info, in: model)
            } catch {
                await surfaceApprovalFailure(error.localizedDescription)
            }
        case PushIdentifiers.laterAction:
            break // Explicitly deferred; the approval stays pending.
        case UNNotificationDefaultActionIdentifier:
            PushDefaultActionRouter.route(
                payload, in: model,
                knownGatewayIDs: Set(ConnectionRegistry.shared.saved.map(\.id)))
        default:
            break
        }
    }

    private func approveFromPush(_ info: [AnyHashable: Any], in model: AppModel) async throws {
        guard let payload = PushPayloadDecoder.decode(info), payload.kind == .approval else {
            throw GatewayError(code: -20, message: "Only approval pushes can answer work.")
        }
        let identity = PushApprovalIdentity.resolve(
            gatewayID: payload.gatewayID,
            profile: payload.bot,
            storedSessionID: payload.sessionID,
            requestID: payload.approvalRequestID,
            knownGatewayIDs: Set(ConnectionRegistry.shared.saved.map(\.id)))
        guard let identity else {
            throw GatewayError(code: -20, message: "Approval source is missing or no longer trusted.")
        }

        let selected = try await PushApprovalOrchestrator.approve(identity: identity) { route in
            let client = try await model.routedClient(for: route)
            await model.attachRoutedEventsIfNeeded(client: client, gatewayID: identity.gatewayID)
            return PushApprovalActions(
                resume: { storedID, profile in
                    let resumed = try await client.resumeSession(
                        storedID, profile: profile, deferHistory: true)
                    return PushApprovalResumeSnapshot(sessionID: resumed.sessionID,
                        storedSessionID: resumed.storedSessionID,
                        profile: resumed.info.profileName)
                },
                pending: { try await client.pendingApprovalDetails(sessionID: $0) },
                answer: {
                    try await client.answerApproval(sessionID: $0, choice: .once,
                                                    requestID: $1)
                })
        }

        let route = GatewayBotRoute(gatewayID: identity.gatewayID, profile: identity.profile)
        let rosterID = identity.gatewayID == model.activeGatewayID
            ? identity.profile : route.qualifiedID
        if let local = model.approval(matchingWireRequestID: selected.request.requestID,
                                      botID: rosterID) {
            ApprovalOutcomes.shared.record(local, approved: true)
            model.approvals.removeAll { $0.id == local.id }
            LiveRuntime.shared.approvalTargets.removeValue(forKey: local.id)
            ApprovalBridges.shared.details.removeValue(forKey: local.id)
            model.recomputeApprovalStatus(for: local.botID)
        }
    }

    private func surfaceApprovalFailure(_ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Approval not sent"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "talaria-approval-failed-\(UUID().uuidString)",
            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func routedBotID(from info: [AnyHashable: Any], model: AppModel) -> String? {
        guard let payload = PushPayloadDecoder.decode(info) else { return nil }
        return PushRouteResolver.destination(
            for: payload,
            knownGatewayIDs: Set(ConnectionRegistry.shared.saved.map(\.id)),
            activeGatewayID: model.activeGatewayID,
            demo: model.demoDataLoaded)?.botID
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
        public var sessionID: String?

        public init(botID: String, title: String, body: String,
                    kind: PushKind, approvalRequestID: String? = nil,
                    sessionID: String? = nil) {
            self.botID = botID; self.title = title; self.body = body
            self.kind = kind; self.approvalRequestID = approvalRequestID
            self.sessionID = sessionID
        }
    }

    /// Nonisolated so call sites (and the default argument below) can read it
    /// without hopping to the main actor — it's immutable Sendable data.
    public nonisolated static let demoPushes: [DemoPush] = [
        DemoPush(botID: "inbox", title: "inbox needs approval",
                 body: "Reply to Sarah Chen is ready to send.",
                 kind: .approval, approvalRequestID: "ap1"),
        DemoPush(botID: "inbox", title: "Agent reply ready",
                 body: "The draft reply to Sarah Chen is ready to review.",
                 kind: .response, sessionID: "s-8815"),
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
        if let category = PushNotificationPolicy.category(for: push.kind.rawValue) {
            content.categoryIdentifier = category
            content.interruptionLevel = push.kind == .approval ? .timeSensitive : .active
        }
        if push.kind == .approval {
            if let requestID = push.approvalRequestID {
                info[PushPayloadKey.approvalRequestID] = requestID
            }
        }
        if let sessionID = push.sessionID, !sessionID.isEmpty {
            info[PushPayloadKey.sessionID] = sessionID
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
        await handle(response: response)
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
}

#endif

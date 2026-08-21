import Foundation
import TalariaKit

/// Exact live-session identity shared by session controls and turn mutations.
/// A profile name or UI bot id alone is not authority: both can survive a
/// source switch or session rebind.
struct ExactSessionMutationTarget: Hashable {
    var route: GatewayBotRoute
    var runtimeSessionID: String
    var storedSessionID: String

    init?(route: GatewayBotRoute, runtimeSessionID: String,
          storedSessionID: String) {
        guard !runtimeSessionID.isEmpty, !storedSessionID.isEmpty else { return nil }
        self.route = route
        self.runtimeSessionID = runtimeSessionID
        self.storedSessionID = storedSessionID
    }
}

enum SessionControlMutationKind: String, Sendable, Equatable {
    case messageBranch
    case wholeSessionBranch
    case compression
}

struct SessionControlMutationClaim: Equatable {
    var id: UUID
    var botID: String
    var target: ExactSessionMutationTarget
    var kind: SessionControlMutationKind
}

/// MainActor admission gate for controls that mutate one live session. Turn
/// mutations retain their richer existing leases/fences; this coordinator is
/// the atomic cross-surface claim that keeps a branch/compress from starting
/// while steer/stop/kickoff state is being seeded (and vice versa).
@MainActor
final class SessionMutationCoordinator {
    static let shared = SessionMutationCoordinator()

    private(set) var claims: [ExactSessionMutationTarget: SessionControlMutationClaim] = [:]

    // Focused lower-wire seams for cross-surface admission tests.
    var wholeBranchForTesting:
        (@MainActor (GatewayClient, String) async throws -> SessionBranch)?
    var compressionForTesting:
        (@MainActor (GatewayClient, String) async throws -> SessionCompression)?
    var afterClaimForTesting:
        (@MainActor (SessionControlMutationClaim) async -> Void)?

    func isAvailable(_ target: ExactSessionMutationTarget) -> Bool {
        claims[target] == nil
    }

    func acquire(_ target: ExactSessionMutationTarget, botID: String,
                 kind: SessionControlMutationKind) -> SessionControlMutationClaim? {
        guard claims[target] == nil else { return nil }
        let claim = SessionControlMutationClaim(
            id: UUID(), botID: botID, target: target, kind: kind)
        claims[target] = claim
        return claim
    }

    func owns(_ claim: SessionControlMutationClaim) -> Bool {
        claims[claim.target]?.id == claim.id
    }

    func release(_ claim: SessionControlMutationClaim) {
        if owns(claim) { claims[claim.target] = nil }
    }

    func resetForTesting() {
        claims = [:]
        wholeBranchForTesting = nil
        compressionForTesting = nil
        afterClaimForTesting = nil
    }
}

extension AppModel {
    func exactSessionMutationTarget(botID: String) -> ExactSessionMutationTarget? {
        guard let route = gatewayRoute(for: botID),
              let chat = chats[botID],
              let runtimeSessionID = chat.sessionID,
              let storedSessionID = chat.storedSessionID else { return nil }
        return ExactSessionMutationTarget(
            route: route, runtimeSessionID: runtimeSessionID,
            storedSessionID: storedSessionID)
    }

    func sessionControlMutationIsActive(botID: String) -> Bool {
        guard let target = exactSessionMutationTarget(botID: botID) else { return false }
        return !SessionMutationCoordinator.shared.isAvailable(target)
    }

    /// Existing turn mutation state is operation-specific and remains its own
    /// source of reconciliation truth. Fold only leases/fences that name this
    /// exact route/runtime/durable triple into session-control admission.
    func turnMutationIsActive(botID: String,
                              target: ExactSessionMutationTarget) -> Bool {
        let runtime = ChatRuntime.shared
        func matches(_ route: GatewayBotRoute, _ sessionID: String,
                     _ storedID: String?) -> Bool {
            route == target.route && sessionID == target.runtimeSessionID
                && storedID == target.storedSessionID
        }

        if let value = runtime.steerActions[botID],
           matches(value.route, value.sessionID, value.storedID) { return true }
        if let value = runtime.steerFences[botID],
           matches(value.route, value.sessionID, value.storedID) { return true }
        if let value = runtime.stopActions[botID],
           matches(value.route, value.sessionID, value.storedID) { return true }
        if let value = runtime.stopFences[botID],
           matches(value.route, value.sessionID, value.storedID) { return true }
        if let value = runtime.transcriptLeases[botID],
           matches(GatewayBotRoute(gatewayID: value.gatewayID, profile: value.profile),
                   value.sessionID, value.storedID) { return true }
        if let value = runtime.transcriptFences[botID],
           matches(GatewayBotRoute(gatewayID: value.gatewayID, profile: value.profile),
                   value.sessionID, value.storedID) { return true }
        if let value = runtime.pendingStopRequests[botID],
           let sessionID = value.sessionID,
           matches(value.route, sessionID, value.storedID) { return true }
        if runtime.offlineComposeFences.values.contains(where: {
            matches($0.route, $0.sessionID, $0.storedID)
        }) { return true }

        let canonical = CanonicalChatRuntime.shared
        if let value = canonical.kickoffLeases[botID],
           let route = value.route,
           matches(route, value.sessionID, value.storedID) { return true }
        if let value = canonical.ambiguousKickoffs[botID],
           let route = value.route,
           matches(route, value.sessionID, value.storedID) { return true }

        // Legacy/focused callers may seed the compatibility owner without its
        // metadata side table. Same bot is the only authority available, so
        // fail closed instead of starting a concurrent session mutation.
        let transcriptOwnerHasNoMetadata = runtime.transcriptActions[botID] != nil
            && runtime.transcriptLeases[botID] == nil
        let kickoffOwnerHasNoMetadata = canonical.kickoffs[botID] != nil
            && canonical.kickoffLeases[botID] == nil
            && canonical.ambiguousKickoffs[botID] == nil
        return transcriptOwnerHasNoMetadata || kickoffOwnerHasNoMetadata
    }

    func sessionMutationAdmissionIsAvailable(botID: String,
                                             target: ExactSessionMutationTarget) -> Bool {
        SessionMutationCoordinator.shared.isAvailable(target)
            && !turnMutationIsActive(botID: botID, target: target)
    }
}

import Foundation
import TalariaKit

/// One message-level branch in flight per visible bot. This is deliberately
/// separate from edit/rewind/regenerate state: branching copies history into a
/// child and never rewrites the parent's transcript.
@MainActor
final class MessageBranchRuntime {
    static let shared = MessageBranchRuntime()

    var actionIDs: [String: UUID] = [:]
    var tasks: [String: Task<Void, Never>] = [:]

    // Focused RPC/navigation seams. Production always takes the nil branches.
    var historyForTesting:
        (@MainActor (GatewayClient, String) async throws -> JSONValue)?
    var mutationForTesting:
        (@MainActor (GatewayClient, String, Int) async throws -> SessionBranch)?
    var openForTesting:
        (@MainActor (ExactStoredSessionRoute) async throws -> Void)?
    var afterHistoryForTesting: (@MainActor () async -> Void)?
}

private struct MessageBranchLease {
    var id: UUID
    var botID: String
    var rowID: Int
    var sessionID: String
    var storedSessionID: String
    var route: GatewayBotRoute
    var lifecycle: ProfileLifecycleGenerationToken
    var chatID: ObjectIdentifier
    var wasPrimary: Bool
    var connectionGeneration: Int
    var savedURLString: String
    var mutationClaim: SessionControlMutationClaim
}

private struct MessageBranchSource {
    var client: GatewayClient
    var snapshot: GatewayClientPool.ConnectionSnapshot
    var lease: GatewayClientPool.ConnectionLease
}

private enum MessageBranchFlowError: Error, LocalizedError {
    case staleAuthority
    case unavailableSource
    case invalidChildRoute

    var errorDescription: String? {
        switch self {
        case .staleAuthority:
            return "The gateway, session, or message changed before the branch could be created."
        case .unavailableSource:
            return "The exact gateway for this message is no longer available."
        case .invalidChildRoute:
            return "Hermes returned an unusable child session route."
        }
    }
}

extension AppModel {
    public func isBranchingFromMessage(in botID: String) -> Bool {
        MessageBranchRuntime.shared.actionIDs[botID] != nil
    }

    /// A historical, durable assistant row in an idle live session. The newest
    /// assistant intentionally stays ineligible here because Sessions already
    /// owns the whole-tip branch action.
    public func canBranchFromMessage(_ message: ChatMessage, in botID: String) -> Bool {
        guard mode == .live else { return false }
        let runtime = MessageBranchRuntime.shared
        let chatRuntime = ChatRuntime.shared
        guard runtime.actionIDs[botID] == nil,
              chatRuntime.transcriptActions[botID] == nil,
              chatRuntime.transcriptFences[botID] == nil,
              let chat = chats[botID],
              let route = gatewayRoute(for: botID),
              stateRoute(for: botID) == route,
              botID == messageBranchRosterID(for: route),
              profileLifecycleGenerationToken(for: botID)?.route == route,
              profileLifecycleAllowsGatewayTraffic(route.gatewayID),
              !exactStoredSessionSourceIsInvalidated(gatewayID: route.gatewayID),
              let saved = ConnectionRegistry.shared.saved.first(where: {
                  $0.id == route.gatewayID
              }), ConnectionRegistry.shared.credential(for: saved) != nil,
              chat.sessionID?.isEmpty == false,
              chat.storedSessionID?.isEmpty == false,
              !chat.isRunning, !chat.isTyping,
              !LiveRuntime.shared.workingBotIDs.contains(botID) else { return false }
        guard let target = exactSessionMutationTarget(botID: botID),
              sessionMutationAdmissionIsAvailable(
                botID: botID, target: target) else { return false }
        return MessageBranching.isEligible(message, in: chat.messages)
    }

    /// Copy the authoritative history prefix through this assistant row and
    /// transactionally open the child on the same exact gateway/profile.
    public func branchFromMessage(_ message: ChatMessage, in botID: String) {
        guard canBranchFromMessage(message, in: botID),
              let rowID = message.rowID,
              let chat = chats[botID],
              let sessionID = chat.sessionID,
              let storedSessionID = chat.storedSessionID,
              let route = gatewayRoute(for: botID),
              let lifecycle = profileLifecycleGenerationToken(for: botID),
              let saved = ConnectionRegistry.shared.saved.first(where: {
                  $0.id == route.gatewayID
              }), ConnectionRegistry.shared.credential(for: saved) != nil,
              let target = ExactSessionMutationTarget(
                route: route, runtimeSessionID: sessionID,
                storedSessionID: storedSessionID),
              sessionMutationAdmissionIsAvailable(botID: botID, target: target),
              let mutationClaim = SessionMutationCoordinator.shared.acquire(
                target, botID: botID, kind: .messageBranch) else { return }

        let runtime = MessageBranchRuntime.shared
        let lease = MessageBranchLease(
            id: UUID(), botID: botID, rowID: rowID,
            sessionID: sessionID, storedSessionID: storedSessionID,
            route: route, lifecycle: lifecycle, chatID: ObjectIdentifier(chat),
            wasPrimary: route.gatewayID == activeGatewayID,
            connectionGeneration: LiveRuntime.shared.generation,
            savedURLString: saved.urlString, mutationClaim: mutationClaim)
        runtime.actionIDs[botID] = lease.id

        let task = Task { @MainActor in
            await self.performMessageBranch(lease)
        }
        runtime.tasks[botID] = task
    }

    private func performMessageBranch(_ branchLease: MessageBranchLease) async {
        let runtime = MessageBranchRuntime.shared
        var requestStarted = false
        var responseReceived = false
        var refreshed = false
        var acknowledgedBranch: SessionBranch?
        var recoverySource: MessageBranchSource?
        defer {
            SessionMutationCoordinator.shared.release(branchLease.mutationClaim)
            if runtime.actionIDs[branchLease.botID] == branchLease.id {
                runtime.actionIDs[branchLease.botID] = nil
                runtime.tasks[branchLease.botID] = nil
            }
            drainPendingMutationWork(botID: branchLease.botID)
        }

        do {
            let source = try await acquireMessageBranchSource(branchLease)
            recoverySource = source
            do {
                try await requireMessageBranchAuthority(branchLease, source: source)
                let history: JSONValue
                if let override = runtime.historyForTesting {
                    history = try await override(source.client, branchLease.sessionID)
                } else {
                    history = try await source.client.sessionHistory(branchLease.sessionID)
                }
                let count = try MessageBranching.countThroughAssistant(
                    rowID: branchLease.rowID, history: history)
                if let hook = runtime.afterHistoryForTesting { await hook() }
                try await requireMessageBranchAuthority(branchLease, source: source)

                // Hermes accepts only the prefix count, not the target row id.
                // Another client can still destructively rewrite the same live
                // transcript after this read and before branch accepts it. No
                // client-side fence can close that residual race until Hermes
                // offers row-id CAS on session.branch.
                requestStarted = true
                let result: SessionBranch
                if let override = runtime.mutationForTesting {
                    result = try await override(source.client, branchLease.sessionID, count)
                } else {
                    result = try await source.client.branchSession(
                        branchLease.sessionID, count: count)
                }
                responseReceived = true
                try SessionBranchAckAuthority.requireExact(
                    result, parentRuntimeSessionID: branchLease.sessionID,
                    parentStoredSessionID: branchLease.storedSessionID,
                    requestedCount: count)
                acknowledgedBranch = result
                try await requireMessageBranchAuthority(branchLease, source: source)
            } catch {
                await ConnectionRegistry.shared.clientPool.release(source.lease)
                throw error
            }
            await ConnectionRegistry.shared.clientPool.release(source.lease)

            await refreshMessageBranchSessions(branchLease, source: source)
            refreshed = true
            try await requireMessageBranchAuthority(
                branchLease, expectedSnapshot: source.snapshot,
                expectedClient: source.client)

            guard let child = acknowledgedBranch,
                  let childRoute = ExactStoredSessionRoute(
                    gatewayID: branchLease.route.gatewayID,
                    profile: branchLease.route.profile,
                    storedSessionID: child.storedSessionID) else {
                throw MessageBranchFlowError.invalidChildRoute
            }
            if let override = runtime.openForTesting {
                try await override(childRoute)
            } else {
                // Child profile/resume preflight can suspend after the last
                // parent fence above. Revalidate the exact parent at the
                // transaction's no-await visible-commit boundary.
                try await openAuthoritativeExactStoredSession(
                    childRoute,
                    validateImmediatelyBeforeBinding: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.requireMessageBranchAuthority(
                            branchLease, source: source)
                    })
            }
            toast(kind: .success, title: "Branch opened",
                  message: child.title.isEmpty ? "" : child.title,
                  botID: branchLease.botID)
        } catch {
            let ambiguous = requestStarted && PromptMutationFailure.isAmbiguous(error)
            if requestStarted && !refreshed && (responseReceived || ambiguous),
               let recoverySource {
                await refreshMessageBranchSessions(
                    branchLease, source: recoverySource)
            }
            if let child = acknowledgedBranch {
                let label = child.title.isEmpty ? child.storedSessionID : child.title
                toast(kind: .warning,
                      title: "Branch created, but couldn’t open it",
                      message: "\(label) is still saved in Sessions (\(child.storedSessionID)).",
                      botID: branchLease.botID)
            } else if ambiguous {
                toast(kind: .warning,
                      title: "Branch result is uncertain",
                      message: "Talaria did not retry the mutation. Check Sessions before trying again.",
                      botID: branchLease.botID)
            } else {
                toast(kind: .failure,
                      title: "Couldn’t branch from this message",
                      message: Self.reason(error), botID: branchLease.botID)
            }
        }
    }

    private func acquireMessageBranchSource(
        _ branchLease: MessageBranchLease
    ) async throws -> MessageBranchSource {
        guard let saved = ConnectionRegistry.shared.saved.first(where: {
            $0.id == branchLease.route.gatewayID
                && $0.urlString == branchLease.savedURLString
        }), let baseURL = saved.baseURL,
              let credential = ConnectionRegistry.shared.credential(for: saved) else {
            throw MessageBranchFlowError.unavailableSource
        }
        let pool = ConnectionRegistry.shared.clientPool
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: branchLease.route.gatewayID,
            baseURL: baseURL, credential: credential)
        guard let lease = await pool.acquireLease(
            snapshot, for: branchLease.route.gatewayID) else {
            throw MessageBranchFlowError.staleAuthority
        }
        return MessageBranchSource(client: snapshot.client,
                                   snapshot: snapshot, lease: lease)
    }

    private func requireMessageBranchAuthority(
        _ branchLease: MessageBranchLease,
        source: MessageBranchSource
    ) async throws {
        try await requireMessageBranchAuthority(
            branchLease, expectedSnapshot: source.snapshot,
            expectedClient: source.client)
    }

    private func requireMessageBranchAuthority(
        _ branchLease: MessageBranchLease,
        expectedSnapshot: GatewayClientPool.ConnectionSnapshot,
        expectedClient: GatewayClient
    ) async throws {
        try Task.checkCancellation()
        guard await ConnectionRegistry.shared.clientPool.isCurrent(
            expectedSnapshot, for: branchLease.route.gatewayID) else {
            throw MessageBranchFlowError.staleAuthority
        }
        try Task.checkCancellation()
        let nowPrimary = branchLease.route.gatewayID == activeGatewayID
        let chatRuntime = ChatRuntime.shared
        guard MessageBranchRuntime.shared.actionIDs[branchLease.botID] == branchLease.id,
              SessionMutationCoordinator.shared.owns(branchLease.mutationClaim),
              mode == .live,
              nowPrimary == branchLease.wasPrimary,
              branchLease.botID == messageBranchRosterID(for: branchLease.route),
              gatewayRoute(for: branchLease.botID) == branchLease.route,
              stateRoute(for: branchLease.botID) == branchLease.route,
              profileLifecycleAccepts(branchLease.lifecycle),
              profileLifecycleAllowsGatewayTraffic(branchLease.route.gatewayID),
              !exactStoredSessionSourceIsInvalidated(
                gatewayID: branchLease.route.gatewayID),
              let saved = ConnectionRegistry.shared.saved.first(where: {
                  $0.id == branchLease.route.gatewayID
                    && $0.urlString == branchLease.savedURLString
              }), ConnectionRegistry.shared.credential(for: saved) != nil,
              let chat = chats[branchLease.botID],
              ObjectIdentifier(chat) == branchLease.chatID,
              chat.sessionID == branchLease.sessionID,
              chat.storedSessionID == branchLease.storedSessionID,
              !chat.isRunning, !chat.isTyping,
              !LiveRuntime.shared.workingBotIDs.contains(branchLease.botID),
              chatRuntime.transcriptActions[branchLease.botID] == nil,
              chatRuntime.transcriptFences[branchLease.botID] == nil,
              !turnMutationIsActive(
                botID: branchLease.botID,
                target: branchLease.mutationClaim.target),
              MessageBranching.isEligibleAssistant(
                rowID: branchLease.rowID, in: chat.messages) else {
            throw MessageBranchFlowError.staleAuthority
        }
        if nowPrimary {
            guard LiveRuntime.shared.generation == branchLease.connectionGeneration,
                  client.map(ObjectIdentifier.init) == ObjectIdentifier(expectedClient) else {
                throw MessageBranchFlowError.staleAuthority
            }
        }
    }

    private func refreshMessageBranchSessions(
        _ branchLease: MessageBranchLease, source: MessageBranchSource
    ) async {
        _ = await refreshSessionsFromExactSource(
            botID: branchLease.botID,
            authority: ExactSessionListRefreshAuthority(
                route: branchLease.route, client: source.client,
                snapshot: source.snapshot, lifecycle: branchLease.lifecycle,
                connectionGeneration: branchLease.connectionGeneration,
                savedURLString: branchLease.savedURLString,
                wasPrimary: branchLease.wasPrimary, chatID: branchLease.chatID,
                sessionID: branchLease.sessionID,
                storedSessionID: branchLease.storedSessionID))
    }

    private func messageBranchRosterID(for route: GatewayBotRoute) -> String {
        route.gatewayID == activeGatewayID ? route.profile : route.qualifiedID
    }

    /// Focused test synchronization; production has no reason to await the
    /// unstructured UI task directly.
    func awaitMessageBranchForTesting(botID: String) async {
        if let task = MessageBranchRuntime.shared.tasks[botID] {
            await task.value
        }
    }
}

import Foundation
import TalariaKit

public enum ProfileLifecycleOutcome: Sendable, Equatable {
    case renamed(canonicalName: String, displayName: String?)
    case deleted
    case refused(String)
}

enum ProfileLifecyclePostcondition: Equatable {
    case committed
    case notCommitted
    case indeterminate

    static func rename(names: Set<String>, source: String, destination: String) -> Self {
        if !names.contains(source), names.contains(destination) { return .committed }
        if names.contains(source) { return .notCommitted }
        return .indeterminate
    }

    static func delete(names: Set<String>, source: String) -> Self {
        names.contains(source) ? .notCommitted : .committed
    }

    static func displayRename(inventory: [String: ProfileInventoryEntry],
                              source: String, requested: String) -> Self {
        guard let entry = inventory[source], let displayName = entry.displayName else {
            return .indeterminate
        }
        return displayName == requested ? .committed : .notCommitted
    }
}

@MainActor
private final class ProfileLifecycleRuntime {
    static let shared = ProfileLifecycleRuntime()
    var gatewaysInFlight: Set<String> = []
    /// An indeterminate filesystem mutation must not be followed by another
    /// lifecycle mutation on the same host until a fresh process/operator
    /// recovery establishes authority.
    var heldGateways: Set<String> = []
    var routeGenerations: [GatewayBotRoute: UInt64] = [:]
    var blockedRoutes: Set<GatewayBotRoute> = []

    func block(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.insert(route)
    }

    func restore(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.remove(route)
    }

    func activate(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.remove(route)
    }
}

struct ProfileLifecycleGenerationToken: Equatable, Sendable {
    var route: GatewayBotRoute
    var generation: UInt64
}

private struct ProfileLifecyclePreservedState {
    var portrait: Data?
    var unread: Int
}

extension AppModel {
    /// Capture one route generation before an async profile-owned operation.
    /// Lifecycle mutation blocks the route and bumps this generation before it
    /// can retire the socket; completions must re-check before publishing.
    internal func profileLifecycleGenerationToken(for botID: String)
        -> ProfileLifecycleGenerationToken? {
        guard let route = stateRoute(for: botID) else { return nil }
        let runtime = ProfileLifecycleRuntime.shared
        guard !runtime.blockedRoutes.contains(route) else { return nil }
        return ProfileLifecycleGenerationToken(
            route: route, generation: runtime.routeGenerations[route, default: 0])
    }

    internal func profileLifecycleAccepts(_ token: ProfileLifecycleGenerationToken) -> Bool {
        let runtime = ProfileLifecycleRuntime.shared
        return !runtime.blockedRoutes.contains(token.route)
            && runtime.routeGenerations[token.route, default: 0] == token.generation
    }

    /// Gateway-wide admission check for runtimes such as voice whose stream
    /// can outlive one profile route. Both an active mutation and an unresolved
    /// postcondition must stop new traffic until lifecycle authority returns.
    internal func profileLifecycleAllowsGatewayTraffic(_ gatewayID: String) -> Bool {
        let runtime = ProfileLifecycleRuntime.shared
        return !runtime.gatewaysInFlight.contains(gatewayID)
            && !runtime.heldGateways.contains(gatewayID)
    }

    /// A successful explicit create/recreate makes a formerly deleted identity
    /// authoritative again. Never infer this from a possibly stale roster.
    internal func activateProfileLifecycleRoute(gatewayID: String, profile: String) {
        ProfileLifecycleRuntime.shared.activate(
            GatewayBotRoute(gatewayID: gatewayID, profile: profile))
    }

    public func profileLifecycleTarget(rosterID: String) -> ProfileLifecycleTarget? {
        guard let route = profileRoute(for: rosterID),
              unionRosterBots.contains(where: { $0.id == rosterID }) else { return nil }
        return ProfileLifecycleTarget(rosterID: rosterID, route: route)
    }

    /// Rename the exact source-qualified profile captured by the UI. Route
    /// ownership is checked again immediately before the REST mutation; a
    /// stale sheet cannot act on the same bare name after a gateway switch.
    public func renameProfile(_ target: ProfileLifecycleTarget, to newName: String) async
        -> ProfileLifecycleOutcome {
        guard mode == .live else { return .refused("Connect to a gateway first.") }
        guard profileLifecycleTarget(rosterID: target.rosterID) == target else {
            return .refused("That profile or gateway changed. Reopen the profile manager.")
        }
        guard let (baseURL, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID)
        else { return .refused("Sign in to that gateway to rename this profile.") }
        guard !ProfileLifecycleRuntime.shared.heldGateways.contains(target.route.gatewayID) else {
            return .refused("That gateway has an unresolved profile change. Verify its profiles outside Talaria, then restart the app before trying again.")
        }
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return .refused("Enter a profile name.") }
        if target.route.profile != "default" {
            guard ProfileNamePolicy.validatesNamedProfile(cleanName) else {
                return .refused("Use a non-reserved profile name: lowercase letters, digits, hyphens, or underscores; start with a letter or digit.")
            }
            guard cleanName != target.route.profile else { return .refused("The profile name is unchanged.") }
        }
        guard ProfileLifecycleRuntime.shared.gatewaysInFlight.insert(target.route.gatewayID).inserted
        else { return .refused("Another profile change is already running on that gateway.") }
        defer { ProfileLifecycleRuntime.shared.gatewaysInFlight.remove(target.route.gatewayID) }

        let changesDirectory = target.route.profile != "default"
        let preserved = captureProfileLifecycleState(target)
        if changesDirectory {
            parkProfileLifecycleState(target)
            abortProfileRuntime(target)
        } else {
            // A default rename changes presentation metadata only, but late
            // profile-owned completions still must not publish across an
            // uncertain mutation response.
            ProfileLifecycleRuntime.shared.block(target.route)
        }
        let wasActive = changesDirectory
            ? await retireProfileLifecycleClient(target.route.gatewayID, baseURL: baseURL,
                                                  credential: credential)
            : false

        let result: ProfileRenameResult
        do {
            result = try await GatewayREST.renameProfile(baseURL: baseURL,
                                                         credential: credential,
                                                         profile: target.route.profile,
                                                         newName: cleanName)
        } catch let error as GatewayError {
            guard changesDirectory else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName, originalError: error.message,
                    baseURL: baseURL, credential: credential)
            }
            return await resolveAmbiguousRename(
                target, requested: cleanName, originalError: error.message,
                baseURL: baseURL, credential: credential, wasActive: wasActive,
                preserved: preserved)
        } catch {
            guard changesDirectory else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName, originalError: error.localizedDescription,
                    baseURL: baseURL, credential: credential)
            }
            return await resolveAmbiguousRename(
                target, requested: cleanName, originalError: error.localizedDescription,
                baseURL: baseURL, credential: credential, wasActive: wasActive,
                preserved: preserved)
        }

        let canonical = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return .refused("Hermes returned an empty profile name.") }
        // `default` is presentation-only and must keep the same canonical route.
        if !changesDirectory {
            guard canonical == target.route.profile, result.displayName == cleanName else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName,
                    originalError: "Hermes returned an inconsistent default-profile rename result.",
                    baseURL: baseURL, credential: credential)
            }
            ProfileLifecycleRuntime.shared.restore(target.route)
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
            return .renamed(canonicalName: canonical, displayName: result.displayName)
        }
        guard canonical != target.route.profile,
              ProfileNamePolicy.validatesNamedProfile(canonical) else {
            return await resolveAmbiguousRename(
                target, requested: cleanName,
                originalError: "Hermes did not return a valid changed canonical profile name.",
                baseURL: baseURL, credential: credential, wasActive: wasActive,
                preserved: preserved)
        }
        reconcileProfileRoute(target, canonicalNewName: canonical,
                              scope: baseURL, preserved: preserved,
                              restorePrimaryIfUnclaimed: wasActive)
        await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                            wasActive: wasActive, baseURL: baseURL,
                                            credential: credential)
        if !wasActive { await refreshProfileRoster(gatewayID: target.route.gatewayID) }
        return .renamed(canonicalName: canonical, displayName: result.displayName)
    }

    /// Delete only after the caller has presented destructive confirmation.
    /// This method deliberately has no name-only overload: every call site
    /// must carry the gateway route captured by that confirmation.
    public func deleteProfile(_ target: ProfileLifecycleTarget,
                              confirmed: Bool) async -> ProfileLifecycleOutcome {
        guard confirmed else { return .refused("Deletion was not confirmed.") }
        guard mode == .live else { return .refused("Connect to a gateway first.") }
        guard target.route.profile != "default" else {
            return .refused("Hermes does not allow deleting the default profile.")
        }
        guard profileLifecycleTarget(rosterID: target.rosterID) == target else {
            return .refused("That profile or gateway changed. Reopen the profile manager.")
        }
        guard let (baseURL, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID)
        else { return .refused("Sign in to that gateway to delete this profile.") }
        guard !ProfileLifecycleRuntime.shared.heldGateways.contains(target.route.gatewayID) else {
            return .refused("That gateway has an unresolved profile change. Verify its profiles outside Talaria, then restart the app before trying again.")
        }
        guard ProfileLifecycleRuntime.shared.gatewaysInFlight.insert(target.route.gatewayID).inserted
        else { return .refused("Another profile change is already running on that gateway.") }
        defer { ProfileLifecycleRuntime.shared.gatewaysInFlight.remove(target.route.gatewayID) }

        let preserved = captureProfileLifecycleState(target)
        parkProfileLifecycleState(target)
        abortProfileRuntime(target)
        let wasActive = await retireProfileLifecycleClient(target.route.gatewayID,
                                                           baseURL: baseURL,
                                                           credential: credential)

        do {
            try await GatewayREST.deleteProfile(baseURL: baseURL, credential: credential,
                                                profile: target.route.profile)
        } catch let error as GatewayError {
            return await resolveAmbiguousDelete(
                target, originalError: error.message, baseURL: baseURL,
                credential: credential, wasActive: wasActive,
                preserved: preserved)
        } catch {
            return await resolveAmbiguousDelete(
                target, originalError: error.localizedDescription, baseURL: baseURL,
                credential: credential, wasActive: wasActive,
                preserved: preserved)
        }

        reconcileProfileRoute(target, canonicalNewName: nil,
                              scope: baseURL, preserved: preserved,
                              restorePrimaryIfUnclaimed: wasActive)
        await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                            wasActive: wasActive, baseURL: baseURL,
                                            credential: credential)
        if !wasActive { await refreshProfileRoster(gatewayID: target.route.gatewayID) }
        return .deleted
    }

    private func resolveAmbiguousRename(
        _ target: ProfileLifecycleTarget, requested: String, originalError: String,
        baseURL: URL, credential: GatewayCredential, wasActive: Bool,
        preserved: ProfileLifecyclePreservedState
    ) async -> ProfileLifecycleOutcome {
        let names = try? await GatewayREST.profileNames(baseURL: baseURL, credential: credential)
        let verdict = names.map {
            ProfileLifecyclePostcondition.rename(names: $0, source: target.route.profile,
                                                 destination: requested)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            reconcileProfileRoute(target, canonicalNewName: requested, scope: baseURL,
                                  preserved: preserved,
                                  restorePrimaryIfUnclaimed: wasActive)
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                wasActive: wasActive, baseURL: baseURL,
                                                credential: credential)
            if !wasActive { await refreshProfileRoster(gatewayID: target.route.gatewayID) }
            return .renamed(canonicalName: requested, displayName: nil)
        case .notCommitted:
            restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: wasActive)
            ProfileLifecycleRuntime.shared.restore(target.route)
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                wasActive: wasActive, baseURL: baseURL,
                                                credential: credential)
            return .refused(originalError)
        case .indeterminate:
            holdIndeterminateLifecycle(target)
            return .refused("\(originalError) The profile result is uncertain, so this gateway remains fenced and queued work for that profile was quarantined.")
        }
    }

    private func resolveAmbiguousDefaultDisplayRename(
        _ target: ProfileLifecycleTarget, requested: String, originalError: String,
        baseURL: URL, credential: GatewayCredential
    ) async -> ProfileLifecycleOutcome {
        let inventory = try? await GatewayREST.profileInventory(
            baseURL: baseURL, credential: credential)
        let verdict = inventory.map {
            ProfileLifecyclePostcondition.displayRename(
                inventory: $0, source: target.route.profile, requested: requested)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            ProfileLifecycleRuntime.shared.restore(target.route)
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
            return .renamed(canonicalName: target.route.profile, displayName: requested)
        case .notCommitted:
            ProfileLifecycleRuntime.shared.restore(target.route)
            return .refused(originalError)
        case .indeterminate:
            ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
            return .refused("\(originalError) The default profile's display name is uncertain, so profile-owned work on this route remains fenced until the gateway is verified and Talaria restarts.")
        }
    }

    private func resolveAmbiguousDelete(
        _ target: ProfileLifecycleTarget, originalError: String,
        baseURL: URL, credential: GatewayCredential, wasActive: Bool,
        preserved: ProfileLifecyclePreservedState
    ) async -> ProfileLifecycleOutcome {
        let names = try? await GatewayREST.profileNames(baseURL: baseURL, credential: credential)
        let verdict = names.map {
            ProfileLifecyclePostcondition.delete(names: $0, source: target.route.profile)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            reconcileProfileRoute(target, canonicalNewName: nil, scope: baseURL,
                                  preserved: preserved,
                                  restorePrimaryIfUnclaimed: wasActive)
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                wasActive: wasActive, baseURL: baseURL,
                                                credential: credential)
            if !wasActive { await refreshProfileRoster(gatewayID: target.route.gatewayID) }
            return .deleted
        case .notCommitted:
            restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: wasActive)
            ProfileLifecycleRuntime.shared.restore(target.route)
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                wasActive: wasActive, baseURL: baseURL,
                                                credential: credential)
            return .refused(originalError)
        case .indeterminate:
            holdIndeterminateLifecycle(target)
            return .refused("\(originalError) The profile result is uncertain, so this gateway remains fenced and queued work for that profile was quarantined.")
        }
    }

    private func holdIndeterminateLifecycle(_ target: ProfileLifecycleTarget) {
        ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
        let sources: Set = [target.route.qualifiedID]
        ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources, destination: nil)
        if target.route.gatewayID == LiveRuntime.shared.gatewayID || client == nil {
            isOffline = true
        }
    }

    private func captureProfileLifecycleState(_ target: ProfileLifecycleTarget)
        -> ProfileLifecyclePreservedState {
        let route = target.route
        let routed = MultiGatewayRuntime.shared.routedUnread[route] ?? 0
        let visible = unionRosterBots.first(where: { $0.id == target.rosterID })?.unread ?? 0
        return ProfileLifecyclePreservedState(
            portrait: ProfileAssetStore.shared.portrait(for: route.qualifiedID),
            unread: max(routed, visible))
    }

    /// Before the first suspension, move a primary profile's portable state
    /// off its collision-prone bare key. The user may switch gateways while
    /// disconnect or REST is awaiting; from this point onward the mutation
    /// owns only the source-qualified key captured by `target`.
    internal func parkProfileLifecycleState(_ target: ProfileLifecycleTarget) {
        guard LiveRuntime.shared.gatewayID == target.route.gatewayID,
              GatewayBotRoute(qualifiedID: target.rosterID) == nil else { return }
        let source = target.route.profile
        let destination = target.route.qualifiedID
        guard source != destination else { return }

        rekeyProfileLifecyclePortableState(target, from: source, to: destination)
    }

    /// A failed mutation may reconnect the same gateway as primary. Move the
    /// parked state back only when no different gateway claimed the primary
    /// role during the await; otherwise its qualified identity remains the
    /// sole safe owner.
    internal func restoreParkedProfileLifecycleStateIfNeeded(
        _ target: ProfileLifecycleTarget, wasActive: Bool
    ) {
        let current = LiveRuntime.shared.gatewayID
        guard current == target.route.gatewayID || (current == nil && wasActive) else { return }
        rekeyProfileLifecyclePortableState(target, from: target.route.qualifiedID,
                                           to: target.route.profile)
    }

    private func rekeyProfileLifecyclePortableState(
        _ target: ProfileLifecycleTarget, from source: String, to destination: String
    ) {
        guard source != destination else { return }

        ProfileLifecycleCache.moveFirst(&chats, from: [source], to: destination)
        ProfileLifecycleCache.moveFirst(&memory, from: [source], to: destination)
        ProfileLifecycleCache.moveFirst(&sessions, from: [source], to: destination)
        ProfileLifecycleQueue.reconcile(&composeQueue, sources: [source],
                                        destination: destination)
        if openBotID == source { openBotID = destination }
        for day in activity.indices {
            for item in activity[day].items.indices where activity[day].items[item].botID == source {
                activity[day].items[item].botID = destination
            }
        }
        for index in agentInbox.indices {
            if agentInbox[index].fromBotID == source { agentInbox[index].fromBotID = destination }
            if agentInbox[index].toBotID == source { agentInbox[index].toBotID = destination }
        }
        for index in artifacts.indices where artifacts[index].botID == source {
            artifacts[index].botID = destination
        }
        for index in routines.indices where routines[index].botID == source {
            routines[index].botID = destination
        }
        for index in approvals.indices where approvals[index].botID == source {
            approvals[index].botID = destination
        }

        let runtime = LiveRuntime.shared
        runtime.sessionToBot = runtime.sessionToBot.mapValues {
            $0 == source ? destination : $0
        }
        runtime.routedSessionToBot = runtime.routedSessionToBot.mapValues {
            $0 == source ? destination : $0
        }
        if runtime.workingBotIDs.remove(source) != nil {
            runtime.workingBotIDs.insert(destination)
        }
        ProfileLifecycleCache.moveFirst(&runtime.lastSessionByBot,
                                        from: [source], to: destination)
        ProfileLifecycleCache.moveFirst(&runtime.attachTasks,
                                        from: [source], to: destination)
        reconcileCanonicalAndSessionCaches(sourceIDs: [source],
                                           destinationID: destination)
        reconcileFeedCaches(target: target.route, sourceIDs: [source],
                            destinationID: destination,
                            canonicalNewName: target.route.profile)
        let visibleUnread = bots.first(where: { $0.id == source })?.unread ?? 0
        if visibleUnread > 0 {
            MultiGatewayRuntime.shared.routedUnread[target.route] = max(
                MultiGatewayRuntime.shared.routedUnread[target.route] ?? 0,
                visibleUnread)
        }
    }

    /// Fence the exact gateway client before Hermes moves/deletes the profile
    /// directory. A pooled secondary has no automatic reconnect; a primary is
    /// deliberately disconnected, which cancels its supervisor before REST.
    private func retireProfileLifecycleClient(_ gatewayID: String, baseURL: URL,
                                              credential: GatewayCredential) async -> Bool {
        let wasActive = gatewayID == LiveRuntime.shared.gatewayID && client != nil
        if wasActive {
            await disconnectGateway()
        }
        // Leave an intentionally disconnected sentinel in the pool. Every
        // routed lookup receives it and fails closed instead of opening a new
        // socket while the old profile directory is between names.
        let sentinel = GatewayClient(baseURL: baseURL, credential: credential)
        await ConnectionRegistry.shared.clientPool.adopt(sentinel, for: gatewayID)
        return wasActive
    }

    /// Rehome a formerly active gateway onto its surviving/default backend.
    /// A failed reconnect intentionally leaves it disconnected; no old-profile
    /// socket remains able to recreate the directory just mutated.
    private func releaseProfileLifecycleFence(gatewayID: String, wasActive: Bool,
                                              baseURL: URL,
                                              credential: GatewayCredential) async {
        if !wasActive {
            // Remove the disconnected sentinel. The owner-roster refresh is
            // the only operation allowed to redial after a successful change;
            // failures remain disconnected until ordinary demand retries.
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gatewayID)
            return
        }
        do {
            try await connectGateway(baseURL: baseURL, credential: credential)
        } catch {
            client = nil
            isOffline = true
        }
    }

    // MARK: - State reconciliation

    /// Cancel every volatile producer that could publish old-profile state
    /// after the lifecycle fence is raised. The route generation is blocked
    /// before disconnect awaits, so a late socket or task completion cannot
    /// republish the parked state while the owning socket is being retired.
    internal func abortProfileRuntime(_ target: ProfileLifecycleTarget) {
        ProfileLifecycleRuntime.shared.block(target.route)
        var sourceIDs: Set = [target.route.qualifiedID]
        // This synchronous ownership check is safe: unlike the former caller
        // snapshot, it is never carried across an await. It also keeps this
        // cleanup helper correct when invoked directly before parking.
        if LiveRuntime.shared.gatewayID == target.route.gatewayID,
           GatewayBotRoute(qualifiedID: target.rosterID) == nil {
            sourceIDs.insert(target.route.profile)
        }

        let chatRuntime = ChatRuntime.shared
        for botID in sourceIDs {
            chatRuntime.submitWatchdogs.removeValue(forKey: botID)?.cancel()
            chatRuntime.demoTurns.removeValue(forKey: botID)?.cancel()
            chatRuntime.turnFloor.removeValue(forKey: botID)
            guard let chat = chats[botID] else { continue }
            chat.sessionID = nil
            chat.isRunning = false
            chat.isTyping = false
            for index in chat.messages.indices {
                chat.messages[index].isStreaming = false
                for tool in chat.messages[index].toolCalls.indices
                where chat.messages[index].toolCalls[tool].state == .running {
                    chat.messages[index].toolCalls[tool].state = .failed
                }
            }
        }

        let attachments = AttachmentRuntime.shared
        for botID in sourceIDs {
            guard let chat = chats[botID] else { continue }
            for attachment in chat.attachments { attachments.forget(attachment.id) }
            chat.attachments.removeAll()
        }
        if attachments.chooserBotID.map(sourceIDs.contains) == true { attachments.chooserBotID = nil }
        if attachments.photoBotID.map(sourceIDs.contains) == true { attachments.photoBotID = nil }
        if attachments.fileBotID.map(sourceIDs.contains) == true { attachments.fileBotID = nil }

        let liveness = LivenessRuntime.shared
        for botID in sourceIDs {
            liveness.settledSince.removeValue(forKey: botID)
            liveness.unverifiableSince.removeValue(forKey: botID)
        }

        let live = LiveRuntime.shared
        var affectedSessions = Set(live.sessionToBot.compactMap { sid, botID in
            sourceIDs.contains(botID)
                ? GatewaySessionRoute(gatewayID: target.route.gatewayID, sessionID: sid) : nil
        })
        affectedSessions.formUnion(live.routedSessionToBot.compactMap { route, botID in
            sourceIDs.contains(botID) ? route : nil
        })
        let approvalIDs = Set(approvals.compactMap { sourceIDs.contains($0.botID) ? $0.id : nil })
        let bridges = ApprovalBridges.shared
        bridges.prompts.removeAll { prompt in
            prompt.gatewayID == target.route.gatewayID
                && (prompt.botID.map(sourceIDs.contains) == true
                    || affectedSessions.contains(GatewaySessionRoute(
                        gatewayID: prompt.gatewayID, sessionID: prompt.sessionID)))
        }
        for id in approvalIDs {
            bridges.details.removeValue(forKey: id)
            bridges.decided.removeValue(forKey: id)
        }
        let approvalPrefix = GatewayApprovalRoute.qualifiedPrefix(
            gatewayID: target.route.gatewayID)
        let affectedSessionIDs = Set(affectedSessions.map(\.sessionID))
        let recoveredApprovalIDs = bridges.details.compactMap { id, detail in
            id.hasPrefix(approvalPrefix) && affectedSessionIDs.contains(detail.request.sessionID)
                ? id : nil
        }
        for id in recoveredApprovalIDs {
            bridges.details.removeValue(forKey: id)
            bridges.decided.removeValue(forKey: id)
        }
        bridges.sweptSessions.subtract(affectedSessions)
        bridges.sweepFailures = bridges.sweepFailures.filter { !affectedSessions.contains($0.key) }
        bridges.resetSweepScope(gatewayID: target.route.gatewayID)

        // A2A reply watches retain the recipient but not the sender. A remote
        // rename therefore fences only watches to that exact qualified row;
        // renaming a captured primary row must fence all primary-sender watches
        // because none can prove which local profile owns its return session.
        let a2a = A2ARuntime.shared
        let capturedPrimary = GatewayBotRoute(qualifiedID: target.rosterID) == nil
        var doomedDeliveries = Set(a2a.deliveries.compactMap { key, delivery in
            capturedPrimary || sourceIDs.contains(delivery.to) ? key : nil
        })
        if capturedPrimary { doomedDeliveries.formUnion(a2a.watchers.keys) }
        for key in doomedDeliveries {
            a2a.watchers.removeValue(forKey: key)?.cancel()
            a2a.watcherGeneration.removeValue(forKey: key)
            a2a.deliveries.removeValue(forKey: key)
        }
    }

    /// Re-key portable user state on rename and scrub it on delete. Runtime
    /// session/approval bindings are never transferred: Hermes tears down the
    /// old-name backend before changing its directory, so those wire ids are
    /// invalid after either operation and must fail closed.
    private func reconcileProfileRoute(_ target: ProfileLifecycleTarget,
                                       canonicalNewName: String?, scope: URL,
                                       preserved: ProfileLifecyclePreservedState,
                                       restorePrimaryIfUnclaimed: Bool) {
        let currentPrimaryGatewayID = LiveRuntime.shared.gatewayID
        let plan = ProfileLifecycleStatePlan(target: target,
                                             canonicalNewName: canonicalNewName,
                                             currentPrimaryGatewayID: currentPrimaryGatewayID,
                                             restorePrimaryIfUnclaimed: restorePrimaryIfUnclaimed)
        let sources = Set(plan.sourceIDs)
        if let destination = plan.destinationID {
            ProfileLifecycleRuntime.shared.activate(
                GatewayBotRoute(gatewayID: target.route.gatewayID,
                                profile: canonicalNewName ?? target.route.profile))
            // Hermes tears down the old-name backend during rename. Preserve
            // the transcript/durable key, never its now-invalid runtime sid.
            for source in sources {
                guard let chat = chats[source] else { continue }
                chat.sessionID = nil
                chat.isRunning = false
                chat.isTyping = false
                for index in chat.messages.indices {
                    chat.messages[index].isStreaming = false
                    for tool in chat.messages[index].toolCalls.indices
                    where chat.messages[index].toolCalls[tool].state == .running {
                        chat.messages[index].toolCalls[tool].state = .failed
                    }
                }
            }
            ProfileLifecycleCache.moveFirst(&chats, from: plan.sourceIDs, to: destination)
            ProfileLifecycleCache.moveFirst(&memory, from: plan.sourceIDs, to: destination)
            ProfileLifecycleCache.moveFirst(&sessions, from: plan.sourceIDs, to: destination)
            ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources,
                                            destination: destination)
            if let openBotID, sources.contains(openBotID) { self.openBotID = destination }
            for day in activity.indices {
                for item in activity[day].items.indices where sources.contains(activity[day].items[item].botID) {
                    activity[day].items[item].botID = destination
                }
            }
            for index in agentInbox.indices {
                if sources.contains(agentInbox[index].fromBotID) { agentInbox[index].fromBotID = destination }
                if sources.contains(agentInbox[index].toBotID) { agentInbox[index].toBotID = destination }
            }
            for index in artifacts.indices where sources.contains(artifacts[index].botID) {
                artifacts[index].botID = destination
            }
            for index in routines.indices where sources.contains(routines[index].botID) {
                routines[index].botID = destination
            }
        } else {
            for source in sources {
                chats.removeValue(forKey: source)
                memory.removeValue(forKey: source)
                sessions.removeValue(forKey: source)
            }
            ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources,
                                            destination: nil)
            if let openBotID, sources.contains(openBotID) { self.openBotID = nil }
            for day in activity.indices {
                activity[day].items.removeAll { sources.contains($0.botID) }
            }
            agentInbox.removeAll {
                sources.contains($0.fromBotID) || sources.contains($0.toBotID)
            }
            artifacts.removeAll { sources.contains($0.botID) }
            routines.removeAll { sources.contains($0.botID) }
        }

        // Pending operations and runtime session ids cannot survive Hermes'
        // backend teardown, even for rename.
        approvals.removeAll { sources.contains($0.botID) }
        let runtime = LiveRuntime.shared
        runtime.sessionToBot = runtime.sessionToBot.filter { !sources.contains($0.value) }
        runtime.routedSessionToBot = runtime.routedSessionToBot.filter { !sources.contains($0.value) }
        runtime.workingBotIDs.subtract(sources)
        runtime.lastSessionByBot = runtime.lastSessionByBot.filter { !sources.contains($0.key) }
        let tasks = runtime.attachTasks.filter { sources.contains($0.key) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys { runtime.attachTasks.removeValue(forKey: key) }
        let staleApprovals = runtime.approvalTargets.compactMap { key, value in
            value.bot == target.route ? key : nil
        }
        for key in staleApprovals { runtime.approvalTargets.removeValue(forKey: key) }

        reconcileCanonicalAndSessionCaches(sourceIDs: sources,
                                           destinationID: plan.destinationID)
        reconcileFeedCaches(target: target.route, sourceIDs: sources,
                            destinationID: plan.destinationID,
                            canonicalNewName: canonicalNewName)
        reconcileUnreadAndPortrait(target: target.route, newProfile: canonicalNewName,
                                   scope: scope, preserved: preserved,
                                   destinationIsPrimary: plan.destinationIsPrimary)
        scrubProfileEditorCaches(route: target.route, newProfile: canonicalNewName)
    }

    private func reconcileUnreadAndPortrait(target: GatewayBotRoute, newProfile: String?,
                                            scope: URL,
                                            preserved: ProfileLifecyclePreservedState,
                                            destinationIsPrimary: Bool) {
        MultiGatewayRuntime.shared.routedUnread.removeValue(forKey: target)
        let oldAssetID = target.qualifiedID
        if let newProfile {
            let destination = GatewayBotRoute(gatewayID: target.gatewayID, profile: newProfile)
            MultiGatewayRuntime.shared.routedUnread.removeValue(forKey: destination)
            if preserved.unread > 0 {
                MultiGatewayRuntime.shared.routedUnread[destination] = preserved.unread
            }
            if destinationIsPrimary,
               let index = bots.firstIndex(where: { $0.id == newProfile }) {
                bots[index].unread = preserved.unread
            }
            if let portrait = preserved.portrait {
                ProfileAssetStore.shared.set(portrait, for: destination.qualifiedID)
            } else {
                ProfileAssetStore.shared.markAbsent(destination.qualifiedID)
                let rosterID = destinationIsPrimary
                    ? newProfile : destination.qualifiedID
                Task { @MainActor [weak self] in
                    await self?.refreshAvatar(botID: rosterID, force: true)
                }
            }
        }
        ProfileAssetStore.shared.markAbsent(oldAssetID)
        UnreadWatermarkStore.shared.reconcileProfileLifecycle(
            profile: target.profile, newProfile: newProfile, scope: scope)
    }

    private func reconcileCanonicalAndSessionCaches(sourceIDs: Set<String>,
                                                     destinationID: String?) {
        let canonical = CanonicalChatRuntime.shared
        var sourcePin: String?
        for source in sourceIDs {
            if let pin = canonical.pins.removeValue(forKey: source), sourcePin == nil {
                sourcePin = pin
            }
            canonical.writing.remove(source)
            canonical.writeCount.removeValue(forKey: source)
            canonical.opens.removeValue(forKey: source)?.cancel()
        }
        if let destinationID {
            canonical.pins.removeValue(forKey: destinationID)
            if let sourcePin { canonical.pins[destinationID] = sourcePin }
        }

        let sessions = SessionsRuntime.shared
        func remap(_ input: [String: String]) -> [String: String] {
            var output = input.filter { key, _ in
                guard let destinationID,
                      let boundary = key.firstIndex(of: "\u{0}") else { return true }
                return String(key[..<boundary]) != destinationID
            }
            for (key, value) in input {
                guard let boundary = key.firstIndex(of: "\u{0}") else { continue }
                let botID = String(key[..<boundary])
                guard sourceIDs.contains(botID) else { continue }
                output.removeValue(forKey: key)
                if let destinationID {
                    let suffix = String(key[boundary...])
                    let destinationKey = destinationID + suffix
                    output[destinationKey] = value
                }
            }
            return output
        }
        sessions.titles = remap(sessions.titles)
        sessions.previews = remap(sessions.previews)
        if let destinationID { sessions.loadErrors.removeValue(forKey: destinationID) }
        for source in sourceIDs {
            if let error = sessions.loadErrors.removeValue(forKey: source),
               let destinationID {
                sessions.loadErrors[destinationID] = error
            }
        }
    }

    private func reconcileFeedCaches(target: GatewayBotRoute, sourceIDs: Set<String>,
                                     destinationID: String?, canonicalNewName: String?) {
        let feeds = FeedsRuntime.shared
        if !feeds.journalLoaded {
            feeds.journalLoaded = true
            feeds.journal = Self.loadJournal()
        }
        if let destinationID {
            feeds.knownPreviews.removeValue(forKey: destinationID)
            for index in feeds.journal.indices where sourceIDs.contains(feeds.journal[index].botID) {
                feeds.journal[index].botID = destinationID
            }
            for source in sourceIDs {
                if let preview = feeds.knownPreviews.removeValue(forKey: source),
                   !destinationID.isEmpty {
                    feeds.knownPreviews[destinationID] = preview
                }
            }
        } else {
            feeds.journal.removeAll { sourceIDs.contains($0.botID) }
            for source in sourceIDs { feeds.knownPreviews.removeValue(forKey: source) }
        }
        feeds.knownApprovals = feeds.knownApprovals.filter {
            !sourceIDs.contains($0.value.botID)
        }
        Self.saveJournal(feeds.journal)
        publishActivity()

        func reconciled(_ ref: SessionRef) -> SessionRef? {
            guard sourceIDs.contains(ref.botID) else { return ref }
            guard let destinationID else { return nil }
            return SessionRef(botID: destinationID, storedID: ref.storedID)
        }
        feeds.artifactSessions = feeds.artifactSessions.compactMapValues(reconciled)
        feeds.inboxSessions = feeds.inboxSessions.compactMapValues(reconciled)

        let matchingRoutines = feeds.routineTargets.compactMap { key, value in
            value.bot == target ? key : nil
        }
        for key in matchingRoutines {
            guard let canonicalNewName else {
                feeds.cronJobs.removeValue(forKey: key)
                feeds.cronScope.removeValue(forKey: key)
                feeds.routineTargets.removeValue(forKey: key)
                CronDetailRuntime.shared.detail.removeValue(forKey: key)
                CronDetailRuntime.shared.runs.removeValue(forKey: key)
                CronDetailRuntime.shared.detailError.removeValue(forKey: key)
                CronDetailRuntime.shared.quarantined.remove(key)
                continue
            }
            guard var route = feeds.routineTargets[key] else { continue }
            route.bot.profile = canonicalNewName
            if route.profile == target.profile { route.profile = canonicalNewName }
            feeds.routineTargets[key] = route
            if let scoped = feeds.cronScope[key] ?? nil, scoped == target.profile {
                feeds.cronScope[key] = canonicalNewName
            }
        }
    }

    /// Profile-specific editor caches retain credentials, capabilities, or
    /// generated state addressed to the old directory. Drop precisely this
    /// route; the next sheet load reconstructs it from the refreshed roster.
    private func scrubProfileEditorCaches(route: GatewayBotRoute, newProfile: String?) {
        var keys = [route.qualifiedID]
        if let newProfile {
            keys.append(GatewayBotRoute(gatewayID: route.gatewayID,
                                        profile: newProfile).qualifiedID)
        }
        for qualified in keys {
            if let state = ModelPickerRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            if let state = CapabilityRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            if let state = PetRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            PetRuntime.shared.loads.removeValue(forKey: qualified)?.cancel()
            PetRuntime.shared.loadIDs.removeValue(forKey: qualified)
        }
    }
}

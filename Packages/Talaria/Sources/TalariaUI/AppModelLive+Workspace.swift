import Foundation
import Observation
import TalariaKit

@MainActor
@Observable
public final class WorkspaceRuntime {
    public static let shared = WorkspaceRuntime()
    private static let capabilityKeys = [
        "projects", "projectActivity", "managedFiles", "files", "projectFiles",
        "roots", "git", "commands", "system", "usage", "memory", "curator",
    ]

    public var gatewayID: String?
    /// The exact raw profile selected for the profile-scoped Projects surface.
    /// It is intentionally not synthesized from a display name or the gateway
    /// default; a fresh `profiles.list` inventory must prove it before any
    /// `projects.*` RPC can run.
    public var profile: String?
    public var profiles: [WorkspaceProfileSource] = []
    public var generation: UInt64 = 0
    public var loading = false
    public var error = ""
    public var projects: [HermesProject] = []
    public var projectTree: [HermesProjectTree] = []
    public var projectUncertain = ""
    public var activeProjectID: String?
    public var fileListing: ManagedFileListing?
    public var fileRoots: [String] = []
    public var fileRootSources: [String: WorkspaceFileSource] = [:]
    public var fileUncertain = ""
    public var gitStatus: HermesGitStatus?
    public var gitFiles: [HermesGitFile] = []
    public var gitBranches: [HermesGitBranch] = []
    public var gitWorktrees: [HermesGitWorktree] = []
    public var gitPath = ""
    public var commands: [HermesCommand] = []
    public var commandOutput = ""
    public var commandRunning = false
    public var commandUncertain = ""
    public var commandPrefill = ""
    public var commandPrefillTargetID: String?
    public var commandPrefillDisplay: String?
    public var capability: [String: Bool] = [:]
    public var gitUncertain = ""
    public var mutationBusy = false
    @ObservationIgnored var mutationOwner: UUID?
    public var systemStatus: JSONValue?
    public var usage: JSONValue?
    public var memoryStatus: JSONValue?
    public var curatorStatus: JSONValue?
    public var backupArchive: String?
    public var backupExportURL: URL?
    public var backupDownloadRunning = false
    public var updateCanApply: Bool?
    public var updateRecommendedCommand: String?
    public var updateMessage: String?
    public var systemOutput = ""
    public var systemActionRunning = false
    public var systemUncertain = ""
    public var processTargetID: String?
    public var processesTargetID: String?
    public var processes: [HermesProcess] = []
    @ObservationIgnored var fileRequest: UInt64 = 0
    @ObservationIgnored var gitRequest: UInt64 = 0
    @ObservationIgnored var processRequest: UInt64 = 0

    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var backupDownloadTask: Task<URL, Error>?
    @ObservationIgnored var backupDownloadOwner: UUID?

    var projectRoute: GatewayWorkspaceRoute? {
        guard let gatewayID, let profile else { return nil }
        // Profile lifecycle owns the gateway-wide admission gate. Returning no
        // route here immediately removes Projects authority while a rename or
        // delete is in flight, before its old raw name could hit Hermes.
        guard ProfileLifecycleTrafficAdmission.allows(gatewayID) else { return nil }
        return WorkspaceProjectScope.route(gatewayID: gatewayID, rawProfile: profile,
                                           knownProfiles: profiles.map(\.profile))
    }

    func begin(gatewayID: String?, profile: String? = nil) -> UInt64 {
        let changedScope = self.gatewayID != gatewayID || self.profile != profile
        loadTask?.cancel()
        // A source change invalidates both an in-flight transfer and the
        // completed export it produced. A tab change must not call this path;
        // the Command Center owns that distinction at its sheet boundary.
        if changedScope { endCommandCenter() }
        self.gatewayID = gatewayID
        self.profile = profile
        // Every workspace load requires a fresh inventory. Do not leave a
        // route usable while `profiles.list` is in flight: an absent profile
        // must fail closed rather than relying on Hermes' launch-profile
        // fallback behavior. This also closes profile-bound sheets on refresh.
        profiles = []
        if changedScope {
            projectUncertain = ""; fileUncertain = ""; gitUncertain = ""
            commandUncertain = ""; systemUncertain = ""
            commandPrefill = ""; commandPrefillTargetID = nil; commandPrefillDisplay = nil
            if !GatewayMaintenanceRuntime.shared.preservesWorkspaceMutation(owner: mutationOwner) {
                mutationBusy = false; mutationOwner = nil
            }
            commandRunning = false; systemActionRunning = false
        }
        clearPublishedData()
        generation &+= 1
        fileRequest &+= 1; gitRequest &+= 1; processRequest &+= 1
        error = ""
        return generation
    }

    func matches(_ gatewayID: String, _ generation: UInt64) -> Bool {
        self.gatewayID == gatewayID && self.generation == generation
    }

    func matches(_ route: GatewayWorkspaceRoute, _ generation: UInt64) -> Bool {
        matches(route.gatewayID, generation) && profile == route.rawProfile
            && ProfileLifecycleTrafficAdmission.allows(route.gatewayID)
            && profiles.contains(where: { $0.profile == route.rawProfile })
    }

    /// A process-kill completion may mutate the visible list only while the
    /// exact gateway generation, list request, selected target, and published
    /// target are still the ones captured before the RPC began.
    func matchesProcessKill(gatewayID: String, generation: UInt64,
                            request: UInt64, targetID: String) -> Bool {
        matches(gatewayID, generation)
            && processRequest == request
            && processTargetID == targetID
            && processesTargetID == targetID
    }

    func beginFileRequest() -> UInt64 { fileRequest &+= 1; return fileRequest }
    func beginGitRequest() -> UInt64 { gitRequest &+= 1; return gitRequest }
    func beginProcessRequest() -> UInt64 { processRequest &+= 1; return processRequest }

    @discardableResult
    func resetProcesses(targetID: String?) -> UInt64 {
        let request = beginProcessRequest()
        processTargetID = targetID
        processesTargetID = nil
        processes = []
        return request
    }

    func publishProcesses(_ values: [HermesProcess], targetID: String,
                          request: UInt64) -> Bool {
        guard processRequest == request, processTargetID == targetID else { return false }
        processes = values
        processesTargetID = targetID
        return true
    }

    func clearPublishedFiles() {
        fileRequest &+= 1
        fileListing = nil
        fileRoots = []
        fileRootSources = [:]
    }

    @discardableResult
    func invalidateGit(path: String = "") -> UInt64 {
        gitRequest &+= 1
        clearGitSnapshot(path: path)
        return gitRequest
    }

    func clearGitSnapshot(path: String? = nil) {
        if let path { gitPath = path }
        gitStatus = nil
        gitFiles = []
        gitBranches = []
        gitWorktrees = []
        capability["git"] = false
    }

    func clearPublishedData() {
        projects = []; projectTree = []; activeProjectID = nil
        fileListing = nil; fileRoots = []; fileRootSources = [:]
        gitStatus = nil; gitFiles = []; gitBranches = []; gitWorktrees = []; gitPath = ""
        commands = []; commandOutput = ""
        capability = Dictionary(uniqueKeysWithValues: Self.capabilityKeys.map { ($0, false) })
        systemStatus = nil; usage = nil; memoryStatus = nil; curatorStatus = nil
        backupArchive = nil; updateCanApply = nil; updateRecommendedCommand = nil; updateMessage = nil
        systemOutput = ""; processTargetID = nil; processesTargetID = nil; processes = []
        loading = false
    }

    /// Publish a freshly proven Projects snapshot only into the exact source
    /// and profile generation that requested it.  Callers must invoke this
    /// while their pool and profile-lifecycle leases are still held; this last
    /// synchronous mutation is therefore the publication boundary, not a
    /// post-release best-effort check.
    @discardableResult
    func publishProjectSnapshot(_ snapshot: WorkspaceProjectSnapshot,
                                route: GatewayWorkspaceRoute,
                                generation: UInt64) -> Bool {
        guard matches(route, generation) else { return false }
        projects = snapshot.listing.projects
        activeProjectID = snapshot.listing.activeID
        projectTree = snapshot.tree
        capability["projects"] = true
        capability["projectActivity"] = true
        capability["roots"] = true
        return true
    }

    func removeBackupExport() {
        guard let url = backupExportURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        backupExportURL = nil
    }

    /// Cancel a transfer and discard its owned local export. This is reserved
    /// for a whole Command Center dismissal, source change, or explicit
    /// replacement; section views must not call it from `onDisappear` because
    /// switching tabs unmounts those sections.
    func endCommandCenter() {
        backupDownloadTask?.cancel()
        backupDownloadTask = nil
        backupDownloadOwner = nil
        backupDownloadRunning = false
        removeBackupExport()
    }

    func claimMutation() -> UUID? {
        guard mutationOwner == nil, GatewayMaintenanceRuntime.shared.fence == nil else { return nil }
        let owner = UUID()
        mutationOwner = owner
        mutationBusy = true
        return owner
    }

    func releaseMutation(_ owner: UUID) {
        guard mutationOwner == owner else { return }
        mutationOwner = nil
        mutationBusy = false
    }
}

public struct WorkspaceSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isActive: Bool
}

/// A raw Hermes profile identity plus its presentation label.  The label is
/// never sent to the gateway; only `profile` is a routing value.
public struct WorkspaceProfileSource: Identifiable, Hashable, Sendable {
    public var id: String { profile }
    public var profile: String
    public var label: String
    public var isDefault: Bool

    public init(profile: String, label: String? = nil, isDefault: Bool = false) {
        self.profile = profile
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmedLabel.isEmpty ? profile : trimmedLabel
        self.isDefault = isDefault
    }
}

private struct WorkspaceProjectAuthority: Sendable {
    var connection: GatewayClientPool.ConnectionSnapshot
    var poolLease: GatewayClientPool.ConnectionLease
    var trafficLease: GatewayClient.TrafficLease
    var route: GatewayWorkspaceRoute
}

/// Final publication proof for `projects.set_active`. c1e25 deliberately
/// serves an unknown explicit profile from the launch profile, so an echoed
/// project id is not sufficient by itself: the exact raw profile must still
/// exist in a fresh inventory observed after the mutation response.
enum WorkspaceProjectSelectionProof {
    static func validatedActiveID(
        _ acknowledgedActiveID: String?, selectedProjectID: String,
        route: GatewayWorkspaceRoute, postResponseProfiles: [HermesProfile]
    ) throws -> String {
        guard acknowledgedActiveID == selectedProjectID else {
            throw AckValidationError(
                operation: "Select project",
                detail: "Hermes did not echo the selected project identity."
            )
        }
        _ = try WorkspaceProjectScope.requireCurrent(route, in: postResponseProfiles)
        return selectedProjectID
    }
}

public struct WorkspaceProcessTarget: Identifiable, Hashable, Sendable {
    public var id: String { route.qualifiedID + "\u{1f}" + sessionID }
    public var route: GatewayBotRoute
    public var title: String
    public var sessionID: String
    public var botID: String
    public var storedSessionID: String?

    public var discriminator: String {
        "gateway \(route.gatewayID) · profile @\(route.profile) · session \(sessionID)"
    }
}

enum WorkspaceBackupDownloadPolicy {
    static let maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    static func exceedsLimit(expectedBytes: Int64, writtenBytes: Int64) -> Bool {
        expectedBytes > maximumBytes || writtenBytes > maximumBytes
    }
}

enum WorkspaceActionPollState: Equatable {
    case running
    case terminal(exitCode: Int)
    case malformedTerminal
    case untrackable(observedName: String?, observedPID: Int?)
}

enum WorkspaceActionPollPolicy {
    static func classify(_ status: JSONValue, acceptedName: String,
                         acceptedPID: Int) -> WorkspaceActionPollState {
        let observedName = status["name"]?.stringValue
        let observedPID = status["pid"]?.intValue
        guard observedName == acceptedName, observedPID == acceptedPID else {
            return .untrackable(observedName: observedName, observedPID: observedPID)
        }
        if status["running"]?.boolValue == true { return .running }
        if let exitCode = status["exit_code"]?.intValue {
            return .terminal(exitCode: exitCode)
        }
        return .malformedTerminal
    }
}

enum WorkspaceCommandCenterRequest {
    static func allows(mode: AppMode) -> Bool {
        mode == .live
    }

    static func resolve(explicit: String?, active: String?, available: [String]) -> String? {
        if let explicit {
            let requested = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty, available.contains(requested) else { return nil }
            return requested
        }
        if let active, available.contains(active) { return active }
        return available.first
    }
}

private final class WorkspaceBackupDownloadLimiter: NSObject, URLSessionDownloadDelegate,
                                                     @unchecked Sendable {
    private let lock = NSLock()
    private var didExceedLimit = false

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: totalBytesExpectedToWrite,
            writtenBytes: totalBytesWritten
        ) else { return }
        lock.lock()
        didExceedLimit = true
        lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

public extension AppModel {
    @discardableResult
    func requestCommandCenter(gatewayID: String? = nil) -> Bool {
        guard WorkspaceCommandCenterRequest.allows(mode: mode) else {
            WorkspaceRuntime.shared.error = "Command Center is available only with a live gateway connection."
            return false
        }
        let available = ConnectionRegistry.shared.saved.map(\.id)
        guard let resolved = WorkspaceCommandCenterRequest.resolve(
            explicit: gatewayID, active: activeGatewayID ?? LiveRuntime.shared.gatewayID,
            available: available
        ) else {
            WorkspaceRuntime.shared.error = gatewayID == nil
                ? "Add or reconnect a gateway before opening Command Center."
                : "The requested Command Center gateway is unknown or was removed."
            return false
        }
        NotificationCenter.default.post(
            name: .talariaOpenCommandCenter, object: nil,
            userInfo: ["gatewayID": resolved]
        )
        return true
    }

    var workspaceSources: [WorkspaceSource] {
        let active = LiveRuntime.shared.gatewayID
        return ConnectionRegistry.shared.saved.map {
            WorkspaceSource(id: $0.id, name: $0.name, isActive: $0.id == active)
        }
    }

    private func workspaceProfileInventory(_ rows: [HermesProfile]) throws -> [WorkspaceProfileSource] {
        _ = try WorkspaceProjectScope.knownRawProfiles(from: rows)
        return rows.map {
            WorkspaceProfileSource(profile: $0.name, label: $0.displayName, isDefault: $0.isDefault)
        }
    }

    private func workspaceRoute(gatewayID: String, requestedProfile: String?,
                                inventory: [WorkspaceProfileSource]) throws -> GatewayWorkspaceRoute {
        let raw: String
        if let requestedProfile {
            raw = requestedProfile
        } else if let defaultProfile = inventory.first(where: \.isDefault)?.profile {
            raw = defaultProfile
        } else if let first = inventory.first?.profile {
            raw = first
        } else {
            throw GatewayError(code: 404, message: "Hermes did not report a selectable profile for Projects.")
        }
        guard let route = WorkspaceProjectScope.route(
            gatewayID: gatewayID, rawProfile: raw, knownProfiles: inventory.map(\.profile)
        ) else {
            throw GatewayError(
                code: 400,
                message: "Projects require an exact, known Hermes profile. Choose a profile from this gateway before continuing."
            )
        }
        return route
    }

    private func invalidateWorkspaceProjectRoute(_ route: GatewayWorkspaceRoute, message: String) {
        let runtime = WorkspaceRuntime.shared
        guard runtime.gatewayID == route.gatewayID, runtime.profile == route.rawProfile else { return }
        // Preserve the captured raw name for an honest unavailable-picker row,
        // but remove every authority that could form another Projects request.
        runtime.loadTask?.cancel()
        runtime.profiles = []
        runtime.projects = []; runtime.projectTree = []; runtime.activeProjectID = nil
        runtime.capability["projects"] = false
        runtime.capability["projectActivity"] = false
        runtime.capability["roots"] = false
        runtime.generation &+= 1
        runtime.loading = false
        runtime.error = message
    }

    private func workspaceConnection(gatewayID: String) async throws
        -> GatewayClientPool.ConnectionSnapshot {
        guard profileLifecycleAllowsGatewayTraffic(gatewayID) else {
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL,
              let credential = registry.credential(for: gateway) else {
            throw GatewayRouteError.unknownGateway(gatewayID)
        }
        let snapshot = try await registry.clientPool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: baseURL, credential: credential
        )
        guard profileLifecycleAllowsGatewayTraffic(gatewayID),
              gatewayID != activeGatewayID || client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client)
        else { throw CancellationError() }
        return snapshot
    }

    private func workspaceConnectionIsCurrent(_ snapshot: GatewayClientPool.ConnectionSnapshot,
                                              gatewayID: String) async -> Bool {
        guard profileLifecycleAllowsGatewayTraffic(gatewayID),
              await ConnectionRegistry.shared.clientPool.isCurrent(snapshot, for: gatewayID) else {
            return false
        }
        return gatewayID != activeGatewayID || client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client)
    }

    /// Hold both replacement and profile-lifecycle admission across one
    /// logical Projects operation. The first RPC is always a fresh
    /// `profiles.list` on this exact captured client. That ordering prevents a
    /// stale raw name from reaching Hermes' unknown-profile launch-profile
    /// fallback, while the two leases close local rename/delete and reconnect
    /// races between validation and the `projects.*` request.
    private func withWorkspaceProjectAuthority<Value: Sendable>(
        gatewayID: String, requestedProfile: String?, generation: UInt64,
        _ operation: (WorkspaceProjectAuthority) async throws -> Value
    ) async throws -> Value {
        let runtime = WorkspaceRuntime.shared
        let registry = ConnectionRegistry.shared
        let connection = try await workspaceConnection(gatewayID: gatewayID)
        guard let poolLease = await registry.clientPool.acquireLease(connection, for: gatewayID) else {
            throw CancellationError()
        }
        guard let trafficLease = ProfileLifecycleTrafficAdmission.acquire(gatewayID) else {
            await registry.clientPool.release(poolLease)
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is paused while a profile change is being resolved.")
        }

        do {
            let rows = try await connection.client.listProfiles(includeSessions: false)
            let inventory = try workspaceProfileInventory(rows)
            guard runtime.matches(gatewayID, generation), !Task.isCancelled,
                  await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) else {
                throw CancellationError()
            }
            // Publish only the exact fresh inventory. Preserve a concurrently
            // selected raw value; route resolution below either proves it or
            // leaves it visibly unavailable and incapable of producing RPCs.
            runtime.profiles = inventory
            let route: GatewayWorkspaceRoute
            do {
                route = try workspaceRoute(gatewayID: gatewayID,
                                           requestedProfile: requestedProfile,
                                           inventory: inventory)
            } catch {
                if let requestedProfile {
                    invalidateWorkspaceProjectRoute(
                        GatewayWorkspaceRoute(gatewayID: gatewayID, profile: requestedProfile),
                        message: "The selected Hermes profile was renamed or deleted. Projects stay blocked to avoid launch-profile fallback."
                    )
                    // `invalidateWorkspaceProjectRoute` removes stale route
                    // authority. Restore only the newly observed picker rows.
                    runtime.profiles = inventory
                }
                throw error
            }
            runtime.profile = route.rawProfile
            guard runtime.matches(route, generation), !Task.isCancelled,
                  await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) else {
                throw CancellationError()
            }
            let authority = WorkspaceProjectAuthority(
                connection: connection, poolLease: poolLease,
                trafficLease: trafficLease, route: route
            )
            let value = try await operation(authority)
            await trafficLease.release()
            await registry.clientPool.release(poolLease)
            return value
        } catch {
            await trafficLease.release()
            await registry.clientPool.release(poolLease)
            throw error
        }
    }

    /// Refresh profile authority again before a second project read in the
    /// same logical operation (for example accepted-write reconciliation or
    /// tree -> drill-in). The outer traffic and pool leases remain held.
    @discardableResult
    private func refreshWorkspaceProjectAuthority(
        _ authority: WorkspaceProjectAuthority, generation: UInt64
    ) async throws -> [HermesProfile] {
        let runtime = WorkspaceRuntime.shared
        let rows = try await authority.connection.client.listProfiles(includeSessions: false)
        let inventory = try workspaceProfileInventory(rows)
        let names: [String]
        do {
            names = try WorkspaceProjectScope.requireCurrent(authority.route, in: rows)
        } catch {
            invalidateWorkspaceProjectRoute(
                authority.route,
                message: "The selected Hermes profile was renamed or deleted. Projects stay blocked to avoid launch-profile fallback."
            )
            runtime.profiles = inventory
            throw error
        }
        guard names == inventory.map(\.profile),
              runtime.matches(authority.route, generation), !Task.isCancelled,
              await workspaceConnectionIsCurrent(authority.connection,
                                                  gatewayID: authority.route.gatewayID) else {
            throw CancellationError()
        }
        runtime.profiles = inventory
        return rows
    }

    /// Build one snapshot while re-reading `profiles.list` immediately before
    /// every constituent profile-scoped RPC. The operation-level leases keep
    /// local lifecycle and pool replacement excluded; the repeated inventories
    /// also catch an external rename/delete at each remaining wire boundary.
    private func freshWorkspaceProjectSnapshot(
        _ authority: WorkspaceProjectAuthority, generation: UInt64
    ) async throws -> WorkspaceProjectSnapshot {
        let client = authority.connection.client
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        let roots = try await client.discoveredWorkspaceRoots(in: authority.route)
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        let listing = try await client.projects(in: authority.route)
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        let tree = try await client.projectTreeProof(in: authority.route)
        // A remote profile deletion can race after the pre-request inventory
        // and make c1e25 answer from its launch profile. Discard that response
        // unless the exact raw profile still exists after handler completion.
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        guard WorkspaceRuntime.shared.matches(authority.route, generation),
              await workspaceConnectionIsCurrent(authority.connection,
                                                  gatewayID: authority.route.gatewayID) else {
            throw CancellationError()
        }
        return WorkspaceProjectSnapshot(listing: listing, tree: tree.projects,
                                        discoveredRoots: roots,
                                        scopedSessionCount: tree.scopedSessionCount)
    }

    var workspaceProcessTargets: [WorkspaceProcessTarget] {
        guard let gatewayID = WorkspaceRuntime.shared.gatewayID else { return [] }
        return unionRosterBots.compactMap { bot in
            guard let route = stateRoute(for: bot.id), route.gatewayID == gatewayID,
                  let sessionID = chats[bot.id]?.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty else { return nil }
            return WorkspaceProcessTarget(route: route, title: bot.title ?? bot.id,
                                          sessionID: sessionID, botID: bot.id,
                                          storedSessionID: chats[bot.id]?.storedSessionID)
        }
    }

    func prepareWorkspace(gatewayID requested: String? = nil, profile requestedProfile: String? = nil) {
        guard WorkspaceCommandCenterRequest.allows(mode: mode) else {
            WorkspaceRuntime.shared.error = "Command Center is available only with a live gateway connection."
            return
        }
        let runtime = WorkspaceRuntime.shared
        guard !runtime.mutationBusy, !runtime.systemActionRunning, !runtime.commandRunning else {
            runtime.error = "Wait for the current source-qualified operation before changing workspace scope."
            return
        }
        let available = ConnectionRegistry.shared.saved.map(\.id)
        let target: String?
        if let requested {
            target = WorkspaceCommandCenterRequest.resolve(
                explicit: requested, active: nil, available: available
            )
        } else {
            target = WorkspaceCommandCenterRequest.resolve(
                explicit: nil,
                active: runtime.gatewayID ?? LiveRuntime.shared.gatewayID,
                available: available
            )
        }
        guard let target else {
            _ = runtime.begin(gatewayID: nil, profile: nil)
            runtime.error = requested == nil
                ? "No registered gateway is available for Command Center."
                : "The requested Command Center gateway is unknown or was removed."
            return
        }
        if let requestedProfile,
           requestedProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = runtime.begin(gatewayID: target, profile: nil)
            runtime.error = "Projects require an exact, nonblank Hermes profile."
            return
        }
        let profile: String?
        if let requestedProfile {
            profile = requestedProfile
        } else if runtime.gatewayID == target, let existing = runtime.profile {
            profile = existing
        } else {
            // A new gateway has no trusted local profile authority. Leave the
            // requested value nil so the fresh Hermes inventory selects its
            // declared default instead of a stale roster-derived guess.
            profile = nil
        }
        let generation = runtime.begin(gatewayID: target, profile: profile)
        // WorkspaceRuntime outlives the sheet. Never publish a directory from
        // its previous presentation while the new capability/root probe is in
        // flight, even when the gateway id happens to be unchanged.
        runtime.clearPublishedFiles()
        runtime.loading = true
        runtime.loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadWorkspace(gatewayID: target, requestedProfile: profile,
                                     generation: generation)
        }
    }

    internal func dropWorkspaceScope(gatewayID: String) {
        let runtime = WorkspaceRuntime.shared
        guard runtime.gatewayID == gatewayID else { return }
        runtime.loadTask?.cancel()
        runtime.endCommandCenter()
        runtime.generation &+= 1
        runtime.gatewayID = nil
        runtime.profile = nil
        runtime.profiles = []
        runtime.clearPublishedData()
        runtime.projectUncertain = ""; runtime.fileUncertain = ""; runtime.gitUncertain = ""
        runtime.commandUncertain = ""; runtime.systemUncertain = ""
        runtime.commandPrefill = ""; runtime.commandPrefillTargetID = nil
        runtime.commandPrefillDisplay = nil
        runtime.loading = false; runtime.commandRunning = false; runtime.systemActionRunning = false
        runtime.error = "Gateway disconnected. Choose another source or reconnect."
    }

    func selectWorkspaceGateway(_ gatewayID: String) {
        let runtime = WorkspaceRuntime.shared
        guard !runtime.mutationBusy, !runtime.systemActionRunning, !runtime.commandRunning else {
            runtime.error = "Wait for the current source-qualified operation before changing gateways."
            return
        }
        prepareWorkspace(gatewayID: gatewayID)
    }

    func selectWorkspaceProfile(_ profile: String) {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else {
            runtime.error = "Choose a gateway before selecting a Projects profile."
            return
        }
        guard WorkspaceProjectScope.route(gatewayID: gatewayID, rawProfile: profile,
                                          knownProfiles: runtime.profiles.map(\.profile)) != nil else {
            runtime.error = "That Projects profile is unknown or no longer available on this gateway."
            return
        }
        guard !runtime.mutationBusy, !runtime.systemActionRunning, !runtime.commandRunning else {
            runtime.error = "Wait for the current source-qualified operation before changing Projects profiles."
            return
        }
        prepareWorkspace(gatewayID: gatewayID, profile: profile)
    }

    func refreshWorkspace() async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else { return }
        guard !runtime.mutationBusy, !runtime.systemActionRunning, !runtime.commandRunning else {
            runtime.error = "Wait for the current gateway mutation to finish before refreshing."
            return
        }
        let profile = runtime.profile
        let generation = runtime.begin(gatewayID: gatewayID, profile: profile)
        runtime.loading = true
        await loadWorkspace(gatewayID: gatewayID, requestedProfile: profile, generation: generation)
    }

    private func loadWorkspace(gatewayID: String, requestedProfile: String?, generation: UInt64) async {
        let runtime = WorkspaceRuntime.shared
        let fileRequest = runtime.fileRequest
        let gitRequest = runtime.gitRequest
        do {
            // `projectSnapshot` awaits `projects.discover_repos {profile,
            // scan:true}` before it starts `projects.tree`; do not split those
            // calls back into independently scheduled capability probes.
            _ = try await withWorkspaceProjectAuthority(
                gatewayID: gatewayID, requestedProfile: requestedProfile,
                generation: generation
            ) { authority in
                let projectEnvelope = await capabilityValue {
                    try await self.freshWorkspaceProjectSnapshot(authority, generation: generation)
                }
                guard runtime.matches(authority.route, generation), !Task.isCancelled,
                      await workspaceConnectionIsCurrent(
                        authority.connection, gatewayID: authority.route.gatewayID
                      ) else { throw CancellationError() }
                let connection = authority.connection
                let route = authority.route
                let client = connection.client

                async let filesResult = capabilityValue { try await client.managedFiles() }
                async let commandsResult = capabilityValue { try await client.commandCatalog() }
                async let statusResult = capabilityValue { try await client.workspaceStatus() }
                async let usageResult = capabilityValue {
                    try await client.workspaceUsage(days: 30, profile: route.rawProfile)
                }
                async let memoryResult = capabilityValue { try await client.workspaceMemoryStatus() }
                async let curatorResult = capabilityValue { try await client.workspaceCuratorStatus() }
                let (fileEnvelope, commandEnvelope, statusEnvelope,
                     usageEnvelope, memoryEnvelope, curatorEnvelope) = await (
                    filesResult, commandsResult, statusResult,
                    usageResult, memoryResult, curatorResult)
                guard runtime.matches(route, generation), !Task.isCancelled,
                      await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) else { return }

                var discoveredRoots: [String] = []
                if case .available(let snapshot) = projectEnvelope {
                    guard runtime.publishProjectSnapshot(snapshot, route: route,
                                                         generation: generation) else { return }
                    discoveredRoots = snapshot.discoveredRoots
                } else {
                    runtime.projects = []; runtime.projectTree = []; runtime.activeProjectID = nil
                    runtime.capability["projects"] = false
                    runtime.capability["projectActivity"] = false
                    runtime.capability["roots"] = false
                    if case .failed(let message) = projectEnvelope { runtime.error = message }
                }

            let managedListing: ManagedFileListing?
            if case .available(let listing) = fileEnvelope {
                managedListing = listing
                runtime.capability["managedFiles"] = true
            } else {
                managedListing = nil
                runtime.capability["managedFiles"] = false
                if case .failed(let message) = fileEnvelope { runtime.error = message }
            }
            if runtime.fileRequest == fileRequest {
                var sources: [String: WorkspaceFileSource] = [:]
                for root in runtime.projects.flatMap({ $0.folders.map(\.path) }) {
                    if let normalized = WorkspacePathFence.normalized(root) { sources[normalized] = .project }
                }
                for root in discoveredRoots {
                    if let normalized = WorkspacePathFence.normalized(root) { sources[normalized] = .project }
                }
                if let locked = managedListing?.lockedRoot, !locked.isEmpty,
                   let normalized = WorkspacePathFence.normalized(locked) { sources[normalized] = .managed }
                let safeRoots = WorkspacePathFence.safeRoots(Array(sources.keys))
                let managedRoots = safeRoots.filter { sources[$0] == .managed }

                // `/api/fs/*` resolves arbitrary host paths but returns no
                // canonical target/root proof. A lexical client check cannot
                // distinguish `/project/link -> /outside`, so project roots
                // stay useful for Projects and Git but are not published as a
                // file browser. The managed-files API supplies its own locked,
                // symlink-safe root and remains available.
                let selectedListing: ManagedFileListing?
                if let selected = managedRoots.first {
                    if selected == managedListing.flatMap({ WorkspacePathFence.normalized($0.path) })
                        || selected == managedListing.flatMap({ WorkspacePathFence.normalized($0.lockedRoot ?? "") }) {
                        selectedListing = managedListing
                    } else {
                        selectedListing = try? await client.managedFiles(path: selected)
                    }
                } else {
                    selectedListing = nil
                }
                if runtime.matches(gatewayID, generation), runtime.fileRequest == fileRequest,
                   await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) {
                    runtime.fileRoots = safeRoots
                    runtime.fileRootSources = sources
                    runtime.capability["files"] = selectedListing != nil
                    runtime.capability["projectFiles"] = false
                    runtime.fileListing = selectedListing
                    if !managedRoots.isEmpty, selectedListing == nil {
                        runtime.error = "Hermes could not open its managed-files root."
                    }
                }
            }

            // A user may supersede only the directory request while the broad
            // capability probe is in flight. Skip that stale Files publication
            // without abandoning the already-fetched Commands/System results.
            guard runtime.matches(gatewayID, generation), !Task.isCancelled,
                  await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) else { return }

            if case .available(let commands) = commandEnvelope {
                runtime.commands = commands
                runtime.capability["commands"] = true
            } else {
                runtime.capability["commands"] = false
                if case .failed(let message) = commandEnvelope { runtime.error = message }
            }

            if case .available(let status) = statusEnvelope {
                runtime.systemStatus = status; runtime.capability["system"] = true
            } else {
                runtime.capability["system"] = false
                if case .failed(let message) = statusEnvelope { runtime.error = message }
            }
            if case .available(let usage) = usageEnvelope {
                runtime.usage = usage; runtime.capability["usage"] = true
            } else {
                runtime.capability["usage"] = false
                if case .failed(let message) = usageEnvelope { runtime.error = message }
            }
            if case .available(let memory) = memoryEnvelope {
                runtime.memoryStatus = memory; runtime.capability["memory"] = true
            } else {
                runtime.capability["memory"] = false
                if case .failed(let message) = memoryEnvelope { runtime.error = message }
            }
            if case .available(let curator) = curatorEnvelope {
                runtime.curatorStatus = curator; runtime.capability["curator"] = true
            } else {
                runtime.capability["curator"] = false
                if case .failed(let message) = curatorEnvelope { runtime.error = message }
            }

            if runtime.gitRequest == gitRequest, runtime.gitPath.isEmpty {
                runtime.gitPath = runtime.projects.first(where: { $0.id == runtime.activeProjectID })?.primaryPath
                    ?? runtime.projects.compactMap(\.primaryPath).first ?? ""
            }
            if runtime.gitRequest == gitRequest, !runtime.gitPath.isEmpty {
                do {
                    let path = runtime.gitPath
                    async let statusValue = client.workspaceGitStatus(path: path)
                    async let filesValue = client.gitReviewFiles(path: path)
                    async let branchesValue = client.gitBranches(path: path)
                    async let worktreesValue = client.gitWorktrees(path: path)
                    let (status, files, branches, worktrees) = try await (
                        statusValue, filesValue, branchesValue, worktreesValue)
                    if runtime.matches(gatewayID, generation), runtime.gitRequest == gitRequest,
                       await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) {
                        runtime.gitStatus = status
                        runtime.gitFiles = WorkspaceGitMerge.detailed(files, status: status)
                        runtime.gitBranches = branches; runtime.gitWorktrees = worktrees
                        runtime.capability["git"] = true
                    }
                } catch {
                    if runtime.matches(gatewayID, generation), runtime.gitRequest == gitRequest,
                       await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) {
                        runtime.gitStatus = nil
                        runtime.gitFiles = []
                        runtime.gitBranches = []; runtime.gitWorktrees = []
                        runtime.capability["git"] = false
                    }
                }
            }
                // This is the final broad-workspace publication.  It happens
                // before `withWorkspaceProjectAuthority` releases either the
                // pool slot or lifecycle admission lease.
                if runtime.matches(route, generation), !Task.isCancelled,
                   await workspaceConnectionIsCurrent(connection, gatewayID: gatewayID) {
                    runtime.loading = false
                }
            }
        } catch {
            guard runtime.matches(gatewayID, generation), !Task.isCancelled else { return }
            runtime.error = workspaceMessage(error)
            runtime.loading = false
        }
    }

    func openManagedDirectory(_ path: String?, source explicitSource: WorkspaceFileSource? = nil) async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else { return }
        guard !runtime.mutationBusy else {
            runtime.error = "Wait for the current workspace mutation before changing directories."
            return
        }
        let generation = runtime.generation
        let managedRoots = runtime.fileRoots.filter { runtime.fileRootSources[$0] == .managed }
        let target = path ?? managedRoots.first ?? ""
        if !WorkspacePathFence.contains(target, in: managedRoots) {
            runtime.error = "Talaria will not navigate above the selected project or managed root."
            return
        }
        let source = explicitSource ?? runtime.fileListing?.source
            ?? runtime.fileRootSources.first(where: {
                WorkspacePathFence.contains(target, in: [$0.key])
            })?.value ?? .project
        guard source == .managed else {
            runtime.error = "Project-file browsing is blocked because Hermes does not provide an authoritative symlink/realpath containment proof."
            return
        }
        let request = runtime.beginFileRequest()
        runtime.fileListing = nil
        runtime.capability["files"] = false
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            let listing = try await client.managedFiles(path: target)
            guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
            runtime.fileListing = listing
            runtime.capability["files"] = true
            runtime.error = ""
        } catch {
            guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
            runtime.error = workspaceMessage(error)
        }
    }

    func loadManagedFile(_ entry: ManagedFileEntry) async throws -> ManagedFileBody {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else { throw GatewayRouteError.noRoute }
        let generation = runtime.generation
        let request = runtime.fileRequest
        guard entry.source == .managed else {
            throw GatewayError(code: 501, message: "Project-file content is blocked until Hermes can prove realpath containment inside the selected project root.")
        }
        guard WorkspaceFileSizePolicy.allows(byteCount: entry.size) else {
            throw GatewayError(code: 413, message: "This file is larger than Talaria’s 12 MB mobile preview limit.")
        }
        guard WorkspacePathFence.contains(entry.path, in: runtime.fileRoots) else {
            throw GatewayError(code: 403, message: "The file is outside the selected workspace root.")
        }
        guard WorkspaceSensitivePath.allows(entry.path) else {
            throw GatewayError(code: 403, message: "Talaria does not expose credential or secret paths.")
        }
        let client = try await routedClient(gatewayID: gatewayID)
        let body = try await client.managedFile(path: entry.path)
        guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { throw CancellationError() }
        guard WorkspaceFileSizePolicy.allows(byteCount: body.bytes.count) else {
            throw GatewayError(code: 413, message: "Hermes returned more than Talaria’s 12 MB mobile preview limit.")
        }
        return body
    }

    func saveManagedText(path: String, source: WorkspaceFileSource,
                         original: Data, updated: String) async throws
        -> ManagedTextWriteResult {
        _ = path; _ = source; _ = original
        guard WorkspaceFileSizePolicy.allows(byteCount: Data(updated.utf8).count) else {
            throw GatewayError(code: 413, message: "Edited UTF-8 text exceeds Talaria’s 12 MB mobile limit.")
        }
        throw GatewayError(
            code: 501,
            message: "Managed files are read-only until Hermes provides an atomic expected-hash or If-Match write contract. Talaria will not claim conflict safety for a separate GET followed by POST."
        )
    }

    func uploadManagedFile(name: String, bytes: Data, mimeType: String, overwrite: Bool) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, let listing = runtime.fileListing else {
            throw GatewayRouteError.noRoute
        }
        guard listing.source == .managed else {
            throw GatewayError(code: 403, message: "Uploads are available only in the Hermes managed-files root.")
        }
        guard runtime.fileUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior file mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.fileRequest
        guard WorkspaceFileSizePolicy.allows(byteCount: bytes.count) else {
            throw GatewayError(code: 413, message: "Files larger than 12 MB are not uploaded from the phone.")
        }
        let target = try workspaceJoin(listing.path, name)
        guard WorkspacePathFence.contains(target, in: runtime.fileRoots) else {
            throw GatewayError(code: 403, message: "The upload target is outside the selected workspace root.")
        }
        guard WorkspaceSensitivePath.allows(target) else {
            throw GatewayError(code: 403, message: "Talaria does not create credential or secret paths.")
        }
        let client = try await routedClient(gatewayID: gatewayID)
        do {
            _ = try await client.uploadManagedFile(path: target, bytes: bytes,
                                                   mimeType: mimeType, overwrite: overwrite)
            guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
            runtime.fileListing = nil; runtime.capability["files"] = false
            do {
                let refreshed = try await client.managedFiles(path: listing.path)
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.fileListing = refreshed; runtime.capability["files"] = true
            } catch {
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.error = "Upload completed, but the directory refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.fileUncertain = "upload \(target)"
            }
            throw error
        }
    }

    func createWorkspaceFolder(name: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, let listing = runtime.fileListing else {
            throw GatewayRouteError.noRoute
        }
        guard listing.source == .managed else {
            throw GatewayError(code: 403, message: "New folders are available only in the Hermes managed-files root.")
        }
        guard runtime.fileUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior file mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.fileRequest
        let client = try await routedClient(gatewayID: gatewayID)
        let target = try workspaceJoin(listing.path, name)
        guard WorkspacePathFence.contains(target, in: runtime.fileRoots) else {
            throw GatewayError(code: 403, message: "The folder target is outside the selected workspace root.")
        }
        guard WorkspaceSensitivePath.allows(target) else {
            throw GatewayError(code: 403, message: "Talaria does not create credential or secret paths.")
        }
        do {
            _ = try await client.createManagedDirectory(path: target)
            guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
            runtime.fileListing = nil; runtime.capability["files"] = false
            do {
                let refreshed = try await client.managedFiles(path: listing.path)
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.fileListing = refreshed; runtime.capability["files"] = true
            } catch {
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.error = "Folder creation completed, but the directory refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.fileUncertain = "create folder \(target)"
            }
            throw error
        }
    }

    func deleteWorkspaceEntry(_ entry: ManagedFileEntry, recursive: Bool) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, let listing = runtime.fileListing else {
            throw GatewayRouteError.noRoute
        }
        guard entry.source == .managed, listing.source == .managed else {
            throw GatewayError(code: 403, message: "Permanent deletion is available only in the Hermes managed-files root.")
        }
        guard runtime.fileUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior file mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.fileRequest
        guard WorkspacePathFence.contains(entry.path, in: runtime.fileRoots) else {
            throw GatewayError(code: 403, message: "The entry is outside the selected workspace root.")
        }
        guard WorkspaceSensitivePath.allows(entry.path) else {
            throw GatewayError(code: 403, message: "Talaria does not mutate credential or secret paths.")
        }
        let client = try await routedClient(gatewayID: gatewayID)
        do {
            try await client.deleteManagedFile(path: entry.path, recursive: recursive)
            guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
            runtime.fileListing = nil; runtime.capability["files"] = false
            do {
                let refreshed = try await client.managedFiles(path: listing.path)
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.fileListing = refreshed; runtime.capability["files"] = true
            } catch {
                guard runtime.matches(gatewayID, generation), runtime.fileRequest == request else { return }
                runtime.error = "Deletion completed, but the directory refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.fileUncertain = "delete \(entry.path)"
            }
            throw error
        }
    }

    func createWorkspaceProject(name: String, root: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute else {
            throw GatewayError(code: 400,
                               message: "Projects require an exact, known Hermes profile.")
        }
        let gatewayID = route.gatewayID
        guard WorkspacePathFence.isRoot(root, in: runtime.fileRoots) else {
            throw GatewayError(code: 400, message: "Hermes did not report this folder as a safe workspace root.")
        }
        guard runtime.projectUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Wait for the current workspace mutation to finish.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.invalidateGit()
        do {
            _ = try await withWorkspaceProjectAuthority(
                gatewayID: gatewayID, requestedProfile: route.rawProfile,
                generation: generation
            ) { authority in
                guard authority.route == route else { throw CancellationError() }
                _ = try await authority.connection.client.createProject(
                    name: name, folders: [root], primaryPath: root, use: true, in: route
                )
                await reconcileProjectsAfterAcceptedMutation(
                    authority: authority, generation: generation, gitRequest: request
                )
            }
        } catch {
            if runtime.matches(route, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.projectUncertain = "create project \(name)"
            }
            throw error
        }
    }

    func deleteWorkspaceProject(_ project: HermesProject) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute else {
            throw GatewayError(code: 400,
                               message: "Projects require an exact, known Hermes profile.")
        }
        let gatewayID = route.gatewayID
        guard runtime.projectUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Wait for the current workspace mutation to finish.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.invalidateGit()
        do {
            _ = try await withWorkspaceProjectAuthority(
                gatewayID: gatewayID, requestedProfile: route.rawProfile,
                generation: generation
            ) { authority in
                guard authority.route == route else { throw CancellationError() }
                _ = try await authority.connection.client.deleteProject(id: project.id, in: route)
                await reconcileProjectsAfterAcceptedMutation(
                    authority: authority, generation: generation, gitRequest: request
                )
            }
        } catch {
            if runtime.matches(route, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.projectUncertain = "delete project \(project.name)"
            }
            throw error
        }
    }

    func updateWorkspaceProject(_ project: HermesProject, name: String,
                                description: String) async throws {
        try await mutateWorkspaceProject(invalidatesGit: false) { client, route in
            _ = try await client.updateProject(id: project.id, name: name, description: description,
                                               in: route)
        }
    }

    func archiveWorkspaceProject(_ project: HermesProject, restore: Bool) async throws {
        try await mutateWorkspaceProject(invalidatesGit: true) { client, route in
            _ = try await client.archiveProject(id: project.id, restore: restore, in: route)
        }
    }

    func addWorkspaceProjectFolder(_ project: HermesProject, path: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard WorkspacePathFence.isRoot(path, in: runtime.fileRoots) else {
            throw GatewayError(code: 400, message: "Hermes did not report this folder as a safe workspace root.")
        }
        try await mutateWorkspaceProject(invalidatesGit: true) { client, route in
            _ = try await client.addProjectFolder(id: project.id, path: path, in: route)
        }
    }

    func removeWorkspaceProjectFolder(_ project: HermesProject, path: String) async throws {
        try await mutateWorkspaceProject(invalidatesGit: true) { client, route in
            _ = try await client.removeProjectFolder(id: project.id, path: path, in: route)
        }
    }

    func setWorkspacePrimaryFolder(_ project: HermesProject, path: String) async throws {
        guard project.folders.contains(where: { $0.path == path }) else {
            throw GatewayError(code: 400, message: "Choose a folder already attached to this project.")
        }
        try await mutateWorkspaceProject(invalidatesGit: true) { client, route in
            _ = try await client.setPrimaryProjectFolder(id: project.id, path: path, in: route)
        }
    }

    private func mutateWorkspaceProject(
        invalidatesGit: Bool,
        _ operation: @escaping @Sendable (GatewayClient, GatewayWorkspaceRoute) async throws -> Void
    ) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute else {
            throw GatewayError(code: 400,
                               message: "Projects require an exact, known Hermes profile.")
        }
        let gatewayID = route.gatewayID
        guard runtime.projectUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Wait for the current workspace mutation to finish.")
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = invalidatesGit ? runtime.invalidateGit() : runtime.gitRequest
        do {
            _ = try await withWorkspaceProjectAuthority(
                gatewayID: gatewayID, requestedProfile: route.rawProfile,
                generation: generation
            ) { authority in
                guard authority.route == route else { throw CancellationError() }
                try await operation(authority.connection.client, route)
                await reconcileProjectsAfterAcceptedMutation(
                    authority: authority, generation: generation,
                    gitRequest: request, hydrateGit: invalidatesGit
                )
            }
        } catch {
            if runtime.matches(route, generation), workspaceMutationOutcomeIsUncertain(error) {
                runtime.projectUncertain = "update project"
            }
            throw error
        }
    }

    private func reconcileProjectsAfterAcceptedMutation(
        authority: WorkspaceProjectAuthority, generation: UInt64,
        gitRequest: UInt64,
        hydrateGit: Bool = true
    ) async {
        let runtime = WorkspaceRuntime.shared
        let route = authority.route
        let client = authority.connection.client
        guard runtime.matches(route, generation), runtime.gitRequest == gitRequest,
              await workspaceConnectionIsCurrent(authority.connection,
                                                  gatewayID: route.gatewayID) else { return }
        // The write is accepted; old rows are no longer authoritative while
        // the follow-up reads are in flight.
        runtime.projects = []; runtime.projectTree = []; runtime.activeProjectID = nil
        runtime.capability["projects"] = false
        runtime.capability["projectActivity"] = false
        do {
            // The accepted write is a separate operation from the read-back.
            // Re-read profiles immediately before the snapshot; never treat a
            // write acknowledgement's listing as authority after a remote
            // rename/delete could have changed the namespace.
            let snapshot = try await freshWorkspaceProjectSnapshot(
                authority, generation: generation
            )
            guard runtime.matches(route, generation), runtime.gitRequest == gitRequest,
                  await workspaceConnectionIsCurrent(authority.connection,
                                                      gatewayID: route.gatewayID) else { return }
            guard runtime.publishProjectSnapshot(snapshot, route: route,
                                                 generation: generation) else { return }
            guard hydrateGit else { return }

            let path = snapshot.listing.projects.first(where: {
                $0.id == snapshot.listing.activeID
            })?.primaryPath
                ?? snapshot.listing.projects.first(where: {
                    $0.id == snapshot.listing.activeID
                })?.folders.first?.path
                ?? ""
            runtime.gitPath = path
            guard !path.isEmpty else {
                runtime.capability["git"] = false
                return
            }
            do {
                try await refreshGitAfterAcceptedMutation(
                    client: client, gatewayID: route.gatewayID, generation: generation,
                    request: gitRequest, path: path
                )
            } catch {
                guard runtime.matches(route, generation), runtime.gitRequest == gitRequest,
                      await workspaceConnectionIsCurrent(authority.connection,
                                                          gatewayID: route.gatewayID) else { return }
                runtime.invalidateGit(path: path)
                runtime.error = "Project mutation completed, but Git hydration failed: \(workspaceMessage(error))"
            }
        } catch {
            guard runtime.matches(route, generation), runtime.gitRequest == gitRequest,
                  await workspaceConnectionIsCurrent(authority.connection,
                                                      gatewayID: route.gatewayID) else { return }
            runtime.error = "Project mutation completed, but the authoritative refresh failed: \(workspaceMessage(error))"
        }
    }

    func selectProject(_ project: HermesProject) async {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute, runtime.projectUncertain.isEmpty,
              !runtime.commandRunning, !runtime.systemActionRunning,
              let owner = runtime.claimMutation() else {
            runtime.error = "Wait for the current workspace mutation before changing projects."
            return
        }
        let gatewayID = route.gatewayID
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        let request = runtime.invalidateGit()
        do {
            _ = try await withWorkspaceProjectAuthority(
                gatewayID: gatewayID, requestedProfile: route.rawProfile,
                generation: generation
            ) { authority in
                guard authority.route == route else { throw CancellationError() }
                let activeID = try await authority.connection.client.setActiveProject(
                    id: project.id, in: route
                )
                // The response can be internally valid yet belong to c1e25's
                // launch-profile fallback if the selected profile disappeared
                // while the handler ran. Re-read the exact profile inventory
                // after the response, under the same pool/lifecycle leases,
                // before publishing even a single selection-derived field.
                let postResponseProfiles = try await refreshWorkspaceProjectAuthority(
                    authority, generation: generation
                )
                let provenActiveID = try WorkspaceProjectSelectionProof.validatedActiveID(
                    activeID, selectedProjectID: project.id, route: route,
                    postResponseProfiles: postResponseProfiles
                )
                let path = project.primaryPath ?? project.folders.first?.path ?? ""
                guard runtime.matches(route, generation), runtime.gitRequest == request,
                      await workspaceConnectionIsCurrent(authority.connection,
                                                          gatewayID: gatewayID) else {
                    throw CancellationError()
                }
                // Publish the accepted selection while the captured pool slot
                // is still leased. A delayed adoption cannot interleave between
                // this final fence and the state mutation.
                runtime.activeProjectID = provenActiveID
                runtime.gitPath = path
                runtime.error = ""
                // `projects.set_active` has already been accepted. Everything
                // below is read-only reconciliation, but it still publishes
                // while the same exact pool/lifecycle authority is held.
                guard !path.isEmpty else {
                    runtime.capability["git"] = false
                    return
                }
                do {
                    let client = authority.connection.client
                    let status = try await client.workspaceGitStatus(path: path)
                    async let filesValue = client.gitReviewFiles(path: path)
                    async let branchesValue = client.gitBranches(path: path)
                    async let worktreesValue = client.gitWorktrees(path: path)
                    let (files, branches, worktrees) = try await (
                        filesValue, branchesValue, worktreesValue)
                    guard runtime.matches(route, generation), runtime.gitRequest == request,
                          await workspaceConnectionIsCurrent(
                            authority.connection, gatewayID: gatewayID
                          ) else { return }
                    runtime.gitStatus = status
                    runtime.gitFiles = WorkspaceGitMerge.detailed(files, status: status)
                    runtime.gitBranches = branches; runtime.gitWorktrees = worktrees
                    runtime.capability["git"] = true
                } catch {
                    guard runtime.matches(route, generation), runtime.gitRequest == request,
                          await workspaceConnectionIsCurrent(
                            authority.connection, gatewayID: gatewayID
                          ) else { return }
                    runtime.gitStatus = nil; runtime.gitFiles = []
                    runtime.gitBranches = []; runtime.gitWorktrees = []
                    runtime.capability["git"] = false
                    runtime.error = "Project selected, but Git reconciliation failed: \(workspaceMessage(error))"
                }
            }
        } catch {
            guard runtime.matches(route, generation), runtime.gitRequest == request else { return }
            if workspaceMutationOutcomeIsUncertain(error) {
                runtime.projectUncertain = "select project \(project.name)"
            }
            runtime.error = workspaceMessage(error)
        }
    }

    private func provenWorkspaceProjectSessions(
        projectID: String, authority: WorkspaceProjectAuthority, generation: UInt64
    ) async throws -> HermesProjectTree {
        let runtime = WorkspaceRuntime.shared
        let route = authority.route
        // `project_sessions` lacks the profile-global total and scoped id
        // witness. Fetch a fresh tree in the same pool/traffic-leased
        // operation; a cached overview is never drill-in authority.
        let beforeHydration = try await authority.connection.client.projectTreeProof(in: route)
        guard runtime.matches(route, generation),
              await workspaceConnectionIsCurrent(authority.connection,
                                                  gatewayID: route.gatewayID) else {
            throw CancellationError()
        }
        // Validate after the tree response as well as directly before the next
        // profile-scoped read. This catches a remote deletion that made c1e25
        // answer the first request through launch-profile fallback.
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        let hydrated = try await authority.connection.client.projectSessions(
            id: projectID, in: route
        )
        // The sessions response is not publication authority until the exact
        // profile is re-proven after handler completion. This same inventory
        // is also the precondition for the post-hydration tree request.
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        let afterHydration = try await authority.connection.client.projectTreeProof(in: route)
        // Final response fence: no tree rows or navigation target are exposed
        // until profiles.list still contains the exact raw route afterward.
        try await refreshWorkspaceProjectAuthority(authority, generation: generation)
        guard runtime.matches(route, generation),
              await workspaceConnectionIsCurrent(authority.connection,
                                                  gatewayID: route.gatewayID) else {
            throw CancellationError()
        }
        return try WorkspaceProjectDrillInProof.validate(
            projectID: projectID, beforeHydration: beforeHydration,
            afterHydration: afterHydration, hydrated: hydrated
        )
    }

    /// The supplied publication executes before the exact source's pool slot
    /// and profile-lifecycle admission are released.  A source switch can
    /// therefore close the sheet, but can never receive an old source's rows.
    func publishAuthoritativeWorkspaceProjectSessions(
        projectID: String, publish: (HermesProjectTree) -> Void
    ) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute,
              runtime.capability["projectActivity"] == true else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        _ = try await withWorkspaceProjectAuthority(
            gatewayID: route.gatewayID, requestedProfile: route.rawProfile,
            generation: generation
        ) { authority in
            guard authority.route == route else { throw CancellationError() }
            let hydrated = try await provenWorkspaceProjectSessions(
                projectID: projectID, authority: authority, generation: generation
            )
            guard runtime.matches(route, generation),
                  await workspaceConnectionIsCurrent(
                    authority.connection, gatewayID: route.gatewayID
                  ) else { throw CancellationError() }
            publish(hydrated)
        }
    }

    /// Re-prove the cached row and perform the actual stored-session navigation
    /// before releasing source/profile/pool authority.  The destination is
    /// derived from the captured route, never `WorkspaceRuntime.gatewayID`.
    @discardableResult
    func openAuthoritativeWorkspaceProjectSession(
        _ cached: HermesProjectSessionPreview, projectID: String
    ) async throws -> Bool {
        let runtime = WorkspaceRuntime.shared
        guard let route = runtime.projectRoute,
              runtime.capability["projectActivity"] == true else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        return try await withWorkspaceProjectAuthority(
            gatewayID: route.gatewayID, requestedProfile: route.rawProfile,
            generation: generation
        ) { authority in
            guard authority.route == route else { throw CancellationError() }
            let hydrated = try await provenWorkspaceProjectSessions(
                projectID: projectID, authority: authority, generation: generation
            )
            let current = try WorkspaceProjectDrillInProof.validatedNavigation(
                cached: cached, in: hydrated
            )
            let destination = GatewayBotRoute(
                gatewayID: authority.route.gatewayID, profile: current.profile
            )
            guard destination.profile == authority.route.rawProfile,
                  runtime.matches(authority.route, generation),
                  await workspaceConnectionIsCurrent(
                    authority.connection, gatewayID: authority.route.gatewayID
                  ) else { throw CancellationError() }
            guard let botID = unionRosterBots.lazy.map(\.id).first(where: {
                stateRoute(for: $0) == destination
            }) else {
                throw GatewayError(code: 404,
                                   message: "That project session's profile is no longer in the exact gateway roster.")
            }
            // Re-prove immediately before session.resume, then once more from
            // the exact-source seam after its response and before binding.
            // Both checks run while this authority's pool/lifecycle leases are
            // held, and the seam never consults mutable active-gateway state.
            try await refreshWorkspaceProjectAuthority(authority, generation: generation)
            return try await openStoredSessionAwaiting(
                current.storedID, botID: botID, route: destination,
                client: authority.connection.client,
                validateBeforeBinding: {
                    try await self.refreshWorkspaceProjectAuthority(
                        authority, generation: generation
                    )
                }
            )
        }
    }

    func refreshGit() async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty else { return }
        guard !runtime.mutationBusy else {
            runtime.error = "Wait for the current Git mutation before refreshing repository state."
            return
        }
        let generation = runtime.generation
        let request = runtime.beginGitRequest()
        let path = runtime.gitPath
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            let status = try await client.workspaceGitStatus(path: path)
            let files = try await client.gitReviewFiles(path: path)
            let branches = try await client.gitBranches(path: path)
            let worktrees = try await client.gitWorktrees(path: path)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.gitStatus = status; runtime.gitFiles = WorkspaceGitMerge.detailed(files, status: status)
            runtime.gitBranches = branches; runtime.gitWorktrees = worktrees
            runtime.capability["git"] = true; runtime.error = ""
        } catch {
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.gitStatus = nil; runtime.gitFiles = []; runtime.gitBranches = []
            runtime.gitWorktrees = []; runtime.capability["git"] = false
            runtime.error = workspaceMessage(error)
        }
    }

    func loadGitDiff(_ file: HermesGitFile, staged: Bool) async throws -> String {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        let path = runtime.gitPath
        let request = runtime.gitRequest
        let value = try await routedClient(gatewayID: gatewayID)
            .gitDiff(path: path, file: file.path, staged: staged)
        guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { throw CancellationError() }
        return value
    }

    func mutateGitFile(_ file: HermesGitFile, action: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        let path = runtime.gitPath
        let request = runtime.gitRequest
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            try await client.mutateGitFile(path: path, file: file.path, action: action)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                runtime.error = "Git \(action) completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) { runtime.gitUncertain = "\(action) \(file.path)" }
            throw error
        }
    }

    func commitWorkspace(message: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        let path = runtime.gitPath
        let request = runtime.gitRequest
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            try await client.commitGit(path: path, message: message, push: false)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                runtime.error = "Commit completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) { runtime.gitUncertain = "commit \(message)" }
            throw error
        }
    }

    func pushWorkspace() async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        let path = runtime.gitPath
        let request = runtime.gitRequest
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            try await client.pushGit(path: path)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                runtime.error = "Push completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) { runtime.gitUncertain = "push \(path)" }
            throw error
        }
    }

    func createWorkspacePullRequest() async throws -> URL? {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation
        let path = runtime.gitPath
        let request = runtime.gitRequest
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let url = try await routedClient(gatewayID: gatewayID).createPullRequest(path: path)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return nil }
            return url
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) { runtime.gitUncertain = "create pull request for \(path)" }
            throw error
        }
    }

    func switchWorkspaceBranch(_ branch: HermesGitBranch) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation, request = runtime.gitRequest, path = runtime.gitPath
        guard !branch.checkedOut else {
            throw GatewayError(code: 409, message: "This branch is already checked out in a worktree.")
        }
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            if branch.isRemote {
                try await client.addExistingGitWorktree(path: path, branch: branch.name)
            } else {
                try await client.switchGitBranch(path: path, branch: branch.name)
            }
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                let action = branch.isRemote ? "Remote branch worktree creation" : "Branch switch"
                runtime.error = "\(action) completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) {
                runtime.gitUncertain = branch.isRemote
                    ? "track remote branch \(branch.name) in a worktree"
                    : "switch branch to \(branch.name)"
            }
            throw error
        }
    }

    func removeWorkspaceWorktree(_ worktree: HermesGitWorktree) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation, request = runtime.gitRequest, path = runtime.gitPath
        guard runtime.gitUncertain.isEmpty, !worktree.isMain,
              let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "The main worktree cannot be removed here.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            try await client.removeGitWorktree(path: path, worktreePath: worktree.path, force: false)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                runtime.error = "Worktree removal completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) {
                runtime.gitUncertain = "remove worktree \(worktree.path)"
            }
            throw error
        }
    }

    func createWorkspaceWorktree(name: String, branch: String) async throws {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.gitPath.isEmpty,
              runtime.capability["git"] == true, runtime.gitStatus != nil else {
            throw GatewayRouteError.noRoute
        }
        let generation = runtime.generation, request = runtime.gitRequest, path = runtime.gitPath
        guard runtime.gitUncertain.isEmpty, let owner = runtime.claimMutation() else {
            throw GatewayError(code: -80, message: "Resolve the prior Git mutation before sending another.")
        }
        defer { runtime.releaseMutation(owner) }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            try await client.addGitWorktree(path: path, name: name, branch: branch,
                                            base: runtime.gitStatus?.defaultBranch)
            guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
            runtime.clearGitSnapshot(path: path)
            do { try await refreshGitAfterAcceptedMutation(client: client, gatewayID: gatewayID,
                                                           generation: generation, request: request, path: path) }
            catch {
                guard runtime.matches(gatewayID, generation), runtime.gitRequest == request else { return }
                runtime.error = "Worktree creation completed, but the authoritative refresh failed: \(workspaceMessage(error))"
            }
        } catch {
            if runtime.matches(gatewayID, generation), runtime.gitRequest == request,
               workspaceMutationOutcomeIsUncertain(error) {
                runtime.gitUncertain = "create worktree \(branch)"
            }
            throw error
        }
    }

    private func refreshGitAfterAcceptedMutation(client: GatewayClient, gatewayID: String,
                                                  generation: UInt64, request: UInt64,
                                                  path: String) async throws {
        async let statusValue = client.workspaceGitStatus(path: path)
        async let filesValue = client.gitReviewFiles(path: path)
        async let branchesValue = client.gitBranches(path: path)
        async let worktreesValue = client.gitWorktrees(path: path)
        let (status, files, branches, worktrees) = try await (
            statusValue, filesValue, branchesValue, worktreesValue)
        guard WorkspaceRuntime.shared.matches(gatewayID, generation),
              WorkspaceRuntime.shared.gitRequest == request else { throw CancellationError() }
        WorkspaceRuntime.shared.gitStatus = status
        WorkspaceRuntime.shared.gitFiles = WorkspaceGitMerge.detailed(files, status: status)
        WorkspaceRuntime.shared.gitBranches = branches
        WorkspaceRuntime.shared.gitWorktrees = worktrees
        WorkspaceRuntime.shared.capability["git"] = true
    }

    private func workspaceMutationOutcomeIsUncertain(_ error: Error) -> Bool {
        WorkspaceMutationUncertainty.isAmbiguous(error)
    }

    func refreshWorkspaceProcesses(targetID: String? = nil) async {
        let runtime = WorkspaceRuntime.shared
        let targets = workspaceProcessTargets
        let id: String?
        if let targetID {
            id = targetID
        } else if let current = runtime.processTargetID,
                  targets.contains(where: { $0.id == current }) {
            id = current
        } else {
            id = targets.first?.id
        }
        guard let id, let target = workspaceProcessTargets.first(where: { $0.id == id }),
              target.route.gatewayID == runtime.gatewayID else {
            runtime.resetProcesses(targetID: nil)
            return
        }
        let generation = runtime.generation
        let request = runtime.resetProcesses(targetID: id)
        do {
            let values = try await routedClient(for: target.route).processes(sessionID: target.sessionID)
            guard runtime.matches(target.route.gatewayID, generation), runtime.processRequest == request,
                  runtime.processTargetID == id else { return }
            _ = runtime.publishProcesses(values, targetID: id, request: request)
        } catch {
            guard runtime.matches(target.route.gatewayID, generation), runtime.processRequest == request,
                  runtime.processTargetID == id else { return }
            runtime.error = workspaceMessage(error)
        }
    }

    func killWorkspaceProcess(_ process: HermesProcess, targetID explicitTargetID: String? = nil) async {
        let runtime = WorkspaceRuntime.shared
        let id = explicitTargetID ?? runtime.processTargetID
        guard let id,
              let target = workspaceProcessTargets.first(where: { $0.id == id }),
              target.route.gatewayID == runtime.gatewayID,
              runtime.processesTargetID == id,
              runtime.processes.contains(where: { $0.id == process.id }),
              runtime.commandUncertain.isEmpty,
              !runtime.commandRunning, !runtime.systemActionRunning,
              let owner = runtime.claimMutation() else {
            runtime.error = "Resolve the current source-qualified operation before stopping a process."
            return
        }
        defer { runtime.releaseMutation(owner) }
        let generation = runtime.generation
        // The process list is a separately requested, target-qualified read.
        // Capture its request before the kill awaits: a target picker change
        // can invalidate the list while the POST is in flight, and an accepted
        // response must never remove a row from the replacement target or
        // trigger a refresh that publishes against a newer request.
        let processRequest = runtime.processRequest
        do {
            try await routedClient(for: target.route)
                .killProcess(sessionID: target.sessionID, processID: process.id)
            guard runtime.matchesProcessKill(gatewayID: target.route.gatewayID,
                                             generation: generation,
                                             request: processRequest,
                                             targetID: id) else { return }
            runtime.processes.removeAll { $0.id == process.id }
            // Refresh using the exact target captured at acceptance. The
            // helper increments processRequest, so any completion from this
            // operation remains fenced from a subsequent picker selection.
            await refreshWorkspaceProcesses(targetID: id)
        } catch {
            guard runtime.matchesProcessKill(gatewayID: target.route.gatewayID,
                                             generation: generation,
                                             request: processRequest,
                                             targetID: id) else { return }
            if workspaceMutationOutcomeIsUncertain(error) {
                runtime.commandUncertain = "stop process \(process.id) on \(target.discriminator)"
            }
            runtime.error = workspaceMessage(error)
        }
    }

    func routeWorkspaceProcessEvent(_ event: GatewayEvent, sourceGatewayID: String?) {
        let runtime = WorkspaceRuntime.shared
        guard let sourceGatewayID, runtime.gatewayID == sourceGatewayID,
              let targetID = runtime.processTargetID,
              runtime.processesTargetID == targetID,
              let target = workspaceProcessTargets.first(where: { $0.id == targetID }),
              target.sessionID == event.sessionID else { return }
        let processID = event.payload?["process_id"]?.stringValue ?? ""
        guard !processID.isEmpty else { return }
        switch event.type {
        case "agent.terminal.output":
            guard let index = runtime.processes.firstIndex(where: { $0.id == processID }),
                  let chunk = event.payload?["chunk"]?.stringValue, !chunk.isEmpty else { return }
            runtime.processes[index].outputTail = String(
                (runtime.processes[index].outputTail + chunk).suffix(8_000))
        case "terminal.close":
            runtime.processes.removeAll { $0.id == processID }
        default:
            break
        }
    }

    enum WorkspaceSystemAction: String, Sendable {
        case doctor, securityAudit, backup, restartGateway, updateHermes
        case memoryReset, memoryFileReset, userFileReset, debugShare, curator

        var endpoint: String {
            switch self {
            case .doctor: "api/ops/doctor"
            case .securityAudit: "api/ops/security-audit"
            case .backup: "api/ops/backup"
            case .restartGateway: "api/gateway/restart"
            case .updateHermes: "api/hermes/update"
            case .memoryReset, .memoryFileReset, .userFileReset: "api/memory/reset"
            case .debugShare: "api/ops/debug-share"
            case .curator: "api/curator/run"
            }
        }

        var displayName: String {
            switch self {
            case .doctor: "Hermes doctor"
            case .securityAudit: "Security audit"
            case .backup: "Create backup"
            case .restartGateway: "Restart gateway"
            case .updateHermes: "Update Hermes"
            case .memoryReset: "Reset all built-in memory"
            case .memoryFileReset: "Reset MEMORY.md"
            case .userFileReset: "Reset USER.md"
            case .debugShare: "Upload debug share"
            case .curator: "Run curator"
            }
        }

        var requiresActionPolling: Bool {
            switch self {
            case .doctor, .securityAudit, .backup, .curator: true
            default: false
            }
        }

        var expectedActionName: String? {
            switch self {
            case .doctor: "doctor"
            case .securityAudit: "security-audit"
            case .backup: "backup"
            case .restartGateway: "gateway-restart"
            case .updateHermes: "hermes-update"
            case .curator: "curator-run"
            case .memoryReset, .memoryFileReset, .userFileReset, .debugShare: nil
            }
        }
    }

    func runWorkspaceSystemAction(_ action: WorkspaceSystemAction) async {
        let runtime = WorkspaceRuntime.shared
        if action == .updateHermes, runtime.updateCanApply != true {
            runtime.error = runtime.updateRecommendedCommand.map {
                "This Hermes installation is externally managed. Update it with: \($0)"
            } ?? "Check for updates first; Talaria only enables managed update when Hermes reports can_apply: true."
            return
        }
        guard let gatewayID = runtime.gatewayID, !runtime.systemActionRunning,
              runtime.systemUncertain.isEmpty,
              let owner = runtime.claimMutation() else {
            runtime.error = "Resolve the current source-qualified operation before starting another system action."
            return
        }
        let generation = runtime.generation
        runtime.systemActionRunning = true; runtime.systemOutput = ""; runtime.error = ""
        if action == .backup {
            runtime.backupDownloadTask?.cancel()
            runtime.backupDownloadTask = nil; runtime.backupDownloadOwner = nil
            runtime.backupDownloadRunning = false; runtime.backupArchive = nil
            runtime.removeBackupExport()
        }
        defer {
            runtime.releaseMutation(owner)
            if runtime.matches(gatewayID, generation) { runtime.systemActionRunning = false }
        }

        let client: GatewayClient
        do {
            client = try await routedClient(gatewayID: gatewayID)
            let response: JSONValue
            switch action {
            case .memoryReset:
                response = try await client.resetWorkspaceMemory(target: "all")
            case .memoryFileReset:
                response = try await client.resetWorkspaceMemory(target: "memory")
            case .userFileReset:
                response = try await client.resetWorkspaceMemory(target: "user")
            case .debugShare:
                response = try await client.createDebugShare()
            case .curator:
                response = try await client.runWorkspaceCurator()
            default:
                response = try await client.startWorkspaceAction(path: action.endpoint)
            }
            guard runtime.matches(gatewayID, generation) else { return }
            if response["ok"]?.boolValue == false {
                throw GatewayError(
                    code: 409,
                    message: response["message"]?.stringValue
                        ?? response["error"]?.stringValue
                        ?? "Hermes refused the operation."
                )
            }
            guard response["ok"]?.boolValue == true else {
                throw AckValidationError(operation: action.displayName)
            }
            switch action {
            case .memoryReset, .memoryFileReset, .userFileReset:
                guard response["deleted"]?.arrayValue != nil else {
                    throw AckValidationError(operation: action.displayName,
                                             detail: "Hermes omitted the authoritative deletion receipt.")
                }
            case .debugShare:
                guard response["urls"]?.objectValue != nil,
                      response["failures"]?.arrayValue != nil,
                      response["redacted"]?.boolValue != nil,
                      response["auto_delete_seconds"]?.intValue != nil else {
                    throw AckValidationError(operation: action.displayName,
                                             detail: "Hermes omitted the debug-share upload receipt.")
                }
            default:
                break
            }
            if let expectedName = action.expectedActionName {
                guard response["name"]?.stringValue == expectedName,
                      let acceptedPID = response["pid"]?.intValue,
                      acceptedPID > 0 else {
                    throw AckValidationError(operation: action.displayName,
                                             detail: "Hermes omitted or changed the accepted action identity.")
                }
            }
            if action == .backup,
               response["archive"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw AckValidationError(operation: action.displayName,
                                         detail: "Hermes omitted the created archive identity.")
            }
            runtime.systemOutput = prettyWorkspaceJSON(response)

            // These operations deliberately sever or replace the transport.
            // The 2xx acknowledgement is the acceptance boundary; do not
            // retry because a reconnect races the accepted operation.
            if action == .restartGateway || action == .updateHermes {
                runtime.systemOutput = "Accepted by \(gatewayID). The connection may close while \(action.displayName.lowercased()) runs. Talaria will not replay it.\n\n" + runtime.systemOutput
                return
            }

            guard action.requiresActionPolling,
                  let name = response["name"]?.stringValue?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty,
                  let acceptedPID = response["pid"]?.intValue,
                  acceptedPID > 0 else { return }

            // The POST above is the acceptance boundary. Polling is a separate
            // read phase: a failed status fetch must never imply the action was
            // refused or make Talaria replay it.
            let proposedArchive = action == .backup
                ? response["archive"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            do {
                var completed = false
                for _ in 0..<40 {
                    try await Task.sleep(for: .seconds(1.5))
                    guard runtime.matches(gatewayID, generation), !Task.isCancelled else { return }
                    let status = try await client.workspaceActionStatus(name: name)
                    guard runtime.matches(gatewayID, generation), !Task.isCancelled else { return }
                    runtime.systemOutput = prettyWorkspaceJSON(status)
                    switch WorkspaceActionPollPolicy.classify(
                        status, acceptedName: name, acceptedPID: acceptedPID
                    ) {
                    case .running:
                        continue
                    case .untrackable(let observedName, let observedPID):
                        let observed = observedName.map { "\($0) PID \(observedPID.map(String.init) ?? "missing")" }
                            ?? "a response with no action name (PID \(observedPID.map(String.init) ?? "missing"))"
                        runtime.systemUncertain = "\(action.displayName) PID \(acceptedPID) was accepted, but Hermes now tracks \(observed)."
                        runtime.error = "The action was accepted but is no longer authoritatively trackable. Talaria stopped polling, will not replay it, and will not publish completion artifacts."
                        return
                    case .malformedTerminal:
                        runtime.error = "\(action.displayName) was accepted, but Hermes did not publish a terminal exit status."
                        return
                    case .terminal(let exitCode):
                        completed = true
                        if exitCode == 0 {
                            if action == .backup, let proposedArchive, !proposedArchive.isEmpty {
                                runtime.backupArchive = proposedArchive
                            }
                        } else {
                            runtime.error = "\(action.displayName) was accepted, then exited with status \(exitCode)."
                        }
                        break
                    }
                    if completed { break }
                }
                if !completed {
                    runtime.error = "\(action.displayName) was accepted and is still running. Talaria stopped polling after one minute."
                }
            } catch is CancellationError {
                return
            } catch {
                guard runtime.matches(gatewayID, generation) else { return }
                runtime.error = "\(action.displayName) was accepted, but status polling failed: \(workspaceMessage(error))"
            }
        } catch {
            guard runtime.matches(gatewayID, generation) else { return }
            if workspaceMutationOutcomeIsUncertain(error) {
                runtime.systemUncertain = action.displayName
                runtime.error = "The connection ended before Talaria could prove whether Hermes accepted this operation. It will not be replayed."
            } else {
                runtime.error = workspaceMessage(error)
            }
        }
    }

    func checkWorkspaceUpdate() async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else { return }
        let generation = runtime.generation
        runtime.updateCanApply = nil; runtime.updateRecommendedCommand = nil
        runtime.updateMessage = nil; runtime.error = ""
        do {
            let result = try await routedClient(gatewayID: gatewayID).checkHermesUpdate()
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.updateCanApply = result.canApply
            runtime.updateRecommendedCommand = result.recommendedCommand
            runtime.updateMessage = result.message
            runtime.systemOutput = prettyWorkspaceJSON(result.raw)
            if !result.canApply, let message = result.message {
                runtime.error = message
            }
        } catch {
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.error = workspaceMessage(error)
        }
    }

    func setWorkspaceCuratorPaused(_ paused: Bool) async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID, !runtime.systemActionRunning,
              runtime.systemUncertain.isEmpty,
              let owner = runtime.claimMutation() else {
            runtime.error = "Resolve the current source-qualified operation before changing curator state."
            return
        }
        let generation = runtime.generation
        runtime.systemActionRunning = true; runtime.error = ""
        defer {
            runtime.releaseMutation(owner)
            if runtime.matches(gatewayID, generation) { runtime.systemActionRunning = false }
        }
        let client: GatewayClient
        do {
            client = try await routedClient(gatewayID: gatewayID)
            let accepted = try await client.setWorkspaceCuratorPaused(paused)
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.systemOutput = prettyWorkspaceJSON(accepted)
        } catch {
            guard runtime.matches(gatewayID, generation) else { return }
            if workspaceMutationOutcomeIsUncertain(error) {
                runtime.systemUncertain = paused ? "Pause curator" : "Resume curator"
                runtime.error = "The connection ended before Talaria could prove whether Hermes accepted this curator change. It will not be replayed."
            } else {
                runtime.error = workspaceMessage(error)
            }
            return
        }

        // The PUT above is the acceptance boundary. A failed status read does
        // not make the acknowledged state change uncertain or eligible for a
        // replay.
        do {
            let status = try await client.workspaceCuratorStatus()
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.curatorStatus = status
        } catch {
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.error = "Curator state changed, but its authoritative refresh failed: \(workspaceMessage(error))"
        }
    }

    func runWorkspaceCurator() async {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID else { return }
        let generation = runtime.generation
        await runWorkspaceSystemAction(.curator)
        guard runtime.matches(gatewayID, generation), runtime.systemUncertain.isEmpty,
              !runtime.systemOutput.isEmpty else { return }
        do {
            let client = try await routedClient(gatewayID: gatewayID)
            let status = try await client.workspaceCuratorStatus()
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.curatorStatus = status
        } catch {
            guard runtime.matches(gatewayID, generation) else { return }
            runtime.error = workspaceMessage(error)
        }
    }

    func downloadWorkspaceBackup() async throws -> URL {
        let runtime = WorkspaceRuntime.shared
        guard let gatewayID = runtime.gatewayID,
              let archive = runtime.backupArchive?.trimmingCharacters(in: .whitespacesAndNewlines),
              !archive.isEmpty else {
            throw GatewayError(code: 404, message: "Create a completed backup before downloading it.")
        }
        let generation = runtime.generation
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL else {
            throw GatewayRouteError.unknownGateway(gatewayID)
        }
        guard let credential = registry.credential(for: gateway) else {
            throw GatewayRouteError.missingCredential(gateway.name)
        }

        guard runtime.backupDownloadTask == nil else {
            throw GatewayError(code: 409, message: "A backup download is already running for this workspace source.")
        }
        runtime.removeBackupExport()
        let owner = UUID()
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performWorkspaceBackupDownload(
                archive: archive, gatewayID: gatewayID, generation: generation,
                baseURL: baseURL, credential: credential
            )
        }
        runtime.backupDownloadOwner = owner
        runtime.backupDownloadTask = task
        runtime.backupDownloadRunning = true
        defer {
            if runtime.backupDownloadOwner == owner {
                runtime.backupDownloadOwner = nil
                runtime.backupDownloadTask = nil
                runtime.backupDownloadRunning = false
            }
        }
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard runtime.matches(gatewayID, generation), runtime.backupDownloadOwner == owner else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw CancellationError()
        }
        runtime.backupExportURL = url
        return url
    }

    func cancelWorkspaceBackupDownload() {
        WorkspaceRuntime.shared.backupDownloadTask?.cancel()
    }

    private func performWorkspaceBackupDownload(
        archive: String, gatewayID: String, generation: UInt64,
        baseURL: URL, credential: GatewayCredential
    ) async throws -> URL {
        try Task.checkCancellation()

        var components = URLComponents(
            url: baseURL.appending(path: "api/ops/backup/download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "archive", value: archive)]
        guard let downloadURL = components?.url else {
            throw GatewayError(code: -11, message: "Could not build the backup download URL.")
        }
        var request = URLRequest(url: downloadURL, timeoutInterval: 600)
        GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &request)
        let downloadRequest = request

        // A download task streams to a temporary file instead of retaining an
        // archive in memory. Its delegate cancels as soon as either declared
        // or observed transfer size crosses the mobile cap; the final checks
        // defend against missing progress callbacks and filesystem races.
        let limiter = WorkspaceBackupDownloadLimiter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: limiter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var downloadedTemporary: URL?
        defer {
            if let downloadedTemporary { try? FileManager.default.removeItem(at: downloadedTemporary) }
        }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await GatewayREST.withTrafficLease(baseURL: baseURL) {
                try await session.download(for: downloadRequest)
            }
            downloadedTemporary = temporary
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if limiter.exceededLimit {
                throw GatewayError(code: 413, message: "This backup exceeds Talaria’s 2 GB mobile export limit.")
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GatewayError(code: status, message: "Backup download failed (HTTP \(status)).")
        }
        if WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: response.expectedContentLength,
            writtenBytes: 0
        ) {
            throw GatewayError(code: 413, message: "This backup exceeds Talaria’s 2 GB mobile export limit.")
        }
        let fileSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: response.expectedContentLength,
            writtenBytes: Int64(fileSize)
        ) else {
            throw GatewayError(code: 413, message: "This backup exceeds Talaria’s 2 GB mobile export limit.")
        }
        try Task.checkCancellation()
        guard WorkspaceRuntime.shared.matches(gatewayID, generation) else { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: folder) }
        }
        let rawName = WorkspaceRemotePath.basename(of: archive)
        let name = WorkspaceExportName.safe(rawName, fallback: "hermes-backup.zip")
        let url = folder.appending(path: name)
        try FileManager.default.moveItem(at: temporary, to: url)
        downloadedTemporary = nil
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        try Task.checkCancellation()
        guard WorkspaceRuntime.shared.matches(gatewayID, generation) else { throw CancellationError() }
        completed = true
        return url
    }

    private func workspaceJoin(_ directory: String, _ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        guard !clean.isEmpty, clean != ".", clean != ".." else {
            throw GatewayError(code: 400, message: "Choose a non-empty file or folder name.")
        }
        guard let normalizedDirectory = WorkspaceRemotePath.normalized(directory),
              WorkspaceRemotePath.isAbsolute(normalizedDirectory) else {
            throw GatewayError(code: 400, message: "Hermes did not return an absolute managed directory.")
        }
        if normalizedDirectory.hasSuffix("/") { return normalizedDirectory + clean }
        return normalizedDirectory + "/" + clean
    }

    private func workspaceMessage(_ error: Error) -> String {
        if let gateway = error as? GatewayError { return gateway.message }
        return error.localizedDescription
    }

    private func prettyWorkspaceJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}

private enum WorkspaceCapability<Value: Sendable>: Sendable {
    case available(Value)
    case missing
    case failed(String)
}

private func capabilityValue<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value)
    async -> WorkspaceCapability<Value> {
    do { return .available(try await operation()) }
    catch let error as GatewayError where error.code == -32601 || error.code == 404 {
        return .missing
    } catch {
        return .failed(error.localizedDescription)
    }
}

/// A mutation is blocked only when the request may have reached Hermes but no
/// authoritative response came back. Route/auth/validation failures are
/// definite refusals and must not strand the UI behind an "outcome uncertain"
/// acknowledgement. Gateway transport codes are defined in GatewayTransport.
enum WorkspaceMutationUncertainty {
    static func isAmbiguous(_ error: Error) -> Bool {
        if error is AckValidationError { return true }
        if error is CancellationError || error is AppModel.GatewayRouteError
            || error is AuthError { return false }

        if let gateway = error as? GatewayError {
            // -5: request timeout, -6: cancellation after send, -7: socket
            // closed with a correlated request outstanding.
            return [-5, -6, -7].contains(gateway.code)
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost:
                return true
            default:
                return false
            }
        }
        // REST already returned a 2xx body before JSON decoding happened, so
        // malformed success data cannot prove whether the write took effect.
        if error is DecodingError { return true }
        return false
    }
}

enum WorkspacePathFence {
    static func normalized(_ raw: String) -> String? {
        WorkspaceRemotePath.normalized(raw)
    }

    static func safeRoots(_ values: [String]) -> [String] {
        var result: [String] = []
        for root in values.compactMap(normalized).filter({
            WorkspaceRemotePath.isAbsolute($0)
                && !WorkspaceRemotePath.isFilesystemRoot($0) && $0 != "~"
        }) {
            guard !result.contains(where: {
                WorkspaceRemotePath.contains(root, in: $0)
                    && WorkspaceRemotePath.contains($0, in: root)
            }) else { continue }
            result.append(root)
        }
        return result.sorted()
    }

    static func isRoot(_ path: String, in roots: [String]) -> Bool {
        guard let path = normalized(path) else { return false }
        return roots.compactMap(normalized).contains {
            WorkspaceRemotePath.contains(path, in: $0)
                && WorkspaceRemotePath.contains($0, in: path)
        }
    }

    static func contains(_ path: String, in roots: [String]) -> Bool {
        roots.contains { WorkspaceRemotePath.contains(path, in: $0) }
    }

    static func preferredRoot(activeProjectID: String?, projects: [HermesProject],
                              roots: [String]) -> String? {
        if let activeProjectID,
           let active = projects.first(where: { $0.id == activeProjectID }),
           let path = active.primaryPath ?? active.folders.first?.path,
           isRoot(path, in: roots) { return normalized(path) }
        return roots.first
    }
}

enum WorkspaceGitMerge {
    static func detailed(_ files: [HermesGitFile], status: HermesGitStatus) -> [HermesGitFile] {
        let state = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0) })
        return files.map { file in
            guard let flags = state[file.path] else { return file }
            var merged = file
            merged.staged = flags.staged
            merged.unstaged = flags.unstaged
            return merged
        }
    }
}

enum WorkspaceExportName {
    static func safe(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }
}

public extension Notification.Name {
    /// Requests Command Center presentation. The notification payload contains
    /// only a registered gateway identifier under the `gatewayID` user-info key.
    static let talariaOpenCommandCenter = Notification.Name("bot.talaria.openCommandCenter")
}

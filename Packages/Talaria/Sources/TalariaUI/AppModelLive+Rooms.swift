import Foundation
import Observation
import TalariaKit

// Mobile room orchestration. Hermes Desktop's room loop is deterministic:
// one source-qualified member at a time, at most three rounds and ten posts,
// with per-thread/member watermarks. Talaria replaces the old 250 ms hand-off
// with a task chain: only one driver can own a room's side effects.

@MainActor
@Observable
final class RoomRuntime {
    static let shared = RoomRuntime()

    var rooms: [RoomRecord] = []
    var avatarData: [RoomID: Data] = [:]
    var openRoomID: RoomID?
    var loadError: String?
    var metadataPendingCount = 0
    var metadataLastError: String?
    var isLoaded = false

    @ObservationIgnored var store = RoomStore.shared
    @ObservationIgnored var driveTasks: [RoomID: Task<Void, Never>] = [:]
    @ObservationIgnored var driveTokens: [RoomID: UUID] = [:]
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored var baseTurnTimeout: TimeInterval = 180
    @ObservationIgnored var hardTurnTimeout: TimeInterval = 20 * 60
    @ObservationIgnored var driveOperation: (@MainActor (AppModel, RoomID) async -> Void)?
    @ObservationIgnored var loadOperation: (() async throws -> [RoomRecord])?
    @ObservationIgnored var submitOperation:
        (@MainActor (RoomAttempt, RoomMemberSessionSnapshot, [RoomOutboundAttachment]) async -> RoomPromptSubmission)?
    @ObservationIgnored var metadataMutationOperation:
        (@MainActor (RoomMetadataMutation) async throws -> Void)?
    /// Source-qualified lifecycle generations fence metadata flushes and room
    /// drive completions that outlive a profile rename/delete await.
    @ObservationIgnored var profileRouteGenerations: [GatewayBotRoute: UInt64] = [:]
    @ObservationIgnored var retiredProfileRoutes: Set<GatewayBotRoute> = []

    func replace(_ room: RoomRecord) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room }
        else { rooms.append(room) }
        rooms.sort {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.id.description < $1.id.description
        }
    }

    func remove(_ id: RoomID) {
        rooms.removeAll { $0.id == id }
        if openRoomID == id { openRoomID = nil }
    }

    func profileRouteGeneration(_ route: GatewayBotRoute) -> UInt64 {
        profileRouteGenerations[route, default: 0]
    }

    func bumpProfileRouteGeneration(_ route: GatewayBotRoute) -> UInt64 {
        let next = profileRouteGenerations[route, default: 0] &+ 1
        profileRouteGenerations[route] = next
        return next
    }

    func acceptsProfileRoute(_ route: GatewayBotRoute,
                             generation: UInt64) -> Bool {
        !retiredProfileRoutes.contains(route)
            && profileRouteGenerations[route, default: 0] == generation
    }
}

/// MainActor-side token captured before a profile lifecycle REST await. The
/// durable RoomStore mutation is performed only after the server postcondition
/// commits, while this token prevents the old source completion from writing
/// into a reused destination in the meantime.
struct RoomProfileLifecycleToken: Equatable, Sendable {
    var source: GatewayBotRoute
    var generation: UInt64
}

@MainActor
final class RoomMutationGate {
    static let shared = RoomMutationGate()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var held = Set<String>()
    private var waiters: [String: [Waiter]] = [:]
    private var activeOperations = 0
    private var quiescing = false
    private var admissionWaiters: [Waiter] = []
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainedWaiter: CheckedContinuation<Void, Never>?

    func queuedWaiterCount(for key: String) -> Int { waiters[key]?.count ?? 0 }

    func withLock<T>(_ key: String, _ operation: () async throws -> T) async throws -> T {
        guard await enterOperation() else { throw CancellationError() }
        var ownsKey = false
        defer {
            if ownsKey { release(key) }
            leaveOperation()
        }
        guard await acquire(key) else { throw CancellationError() }
        ownsKey = true
        try Task.checkCancellation()
        return try await operation()
    }

    /// Exclusive local-data boundary. New mutations wait outside; existing
    /// create/send/settings/disband work drains before deletion begins.
    func withQuiescence<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquireQuiescence()
        if activeOperations > 0 {
            await withCheckedContinuation { drainedWaiter = $0 }
        }
        defer {
            if !quiescenceWaiters.isEmpty {
                quiescenceWaiters.removeFirst().resume()
            } else {
                quiescing = false
                let queued = admissionWaiters
                admissionWaiters.removeAll()
                // Claim admission synchronously before resuming, so another
                // quiescence cannot slip between release and waiter wake-up.
                activeOperations += queued.count
                for waiter in queued { waiter.continuation.resume(returning: true) }
            }
        }
        return try await operation()
    }

    private func acquireQuiescence() async {
        if !quiescing { quiescing = true; return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
        // Ownership is handed directly by the prior exclusive caller; the
        // admission gate intentionally remains closed between them.
    }

    private func enterOperation() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard quiescing else { activeOperations += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { admissionWaiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAdmission(id) }
        }
    }

    private func leaveOperation() {
        activeOperations = max(0, activeOperations - 1)
        if quiescing, activeOperations == 0, let waiter = drainedWaiter {
            drainedWaiter = nil
            waiter.resume()
        }
    }

    private func acquire(_ key: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if held.insert(key).inserted { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[key, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelKeyWaiter(key, id: id) }
        }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiters[key] = nil } else { waiters[key] = queue }
            next.continuation.resume(returning: true)
        } else { held.remove(key) }
    }

    private func cancelAdmission(_ id: UUID) {
        guard let index = admissionWaiters.firstIndex(where: { $0.id == id }) else { return }
        admissionWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func cancelKeyWaiter(_ key: String, id: UUID) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { waiters[key] = nil } else { waiters[key] = queue }
        waiter.continuation.resume(returning: false)
    }
}

public enum RoomNameError: LocalizedError, Equatable {
    case empty
    case taken
    public var errorDescription: String? {
        switch self {
        case .empty: "Room name cannot be empty."
        case .taken: "A room with that name already exists."
        }
    }
}

public enum RoomSettingsError: LocalizedError, Equatable {
    case memberBusy
    public var errorDescription: String? {
        "A bot is still working in this room. Wait for its turn to settle before removing it."
    }
}

public enum RoomNamePolicy {
    public static let maximumLength = 64

    public static func normalized(_ proposed: String) throws -> String {
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RoomNameError.empty }
        return String(value.prefix(maximumLength))
    }

    public static func unique(_ proposed: String, existing: [String]) throws -> String {
        let base = try normalized(proposed)
        let used = Set(existing.map { $0.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var suffix = 2
        while true {
            let tail = " \(suffix)"
            let candidate = String(base.prefix(maximumLength - tail.count)) + tail
            if !used.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }
}

/// Transcript attention and transport uncertainty are deliberately separate.
/// `RoomRecord.needsUser` is owned only by an explicit `@user` mention (and is
/// cleared by the user's next turn); delivery state is derived from durable
/// attempts so reconciling or abandoning transport work cannot erase it.
public enum RoomDeliveryPolicy {
    public static func unresolvedAttempts(in room: RoomRecord) -> [RoomAttempt] {
        room.attempts.filter {
            $0.finishedAt == nil && [.working, .uncertain, .timedOut].contains($0.state)
        }
    }

    public static func hasUnresolvedDelivery(_ room: RoomRecord) -> Bool {
        !unresolvedAttempts(in: room).isEmpty
    }
}

public enum RoomMetadataOutboxStatus: Equatable, Sendable {
    case clear
    case waiting(count: Int)
    case retryRequired(count: Int, message: String)
}

public enum RoomMetadataOutboxPolicy {
    public static func status(pendingCount: Int, lastError: String?) -> RoomMetadataOutboxStatus {
        guard pendingCount > 0 else { return .clear }
        if let lastError, !lastError.isEmpty {
            return .retryRequired(count: pendingCount, message: lastError)
        }
        return .waiting(count: pendingCount)
    }
}

public extension AppModel {
    var rooms: [RoomRecord] { RoomRuntime.shared.rooms }
    var roomMetadataPendingCount: Int { RoomRuntime.shared.metadataPendingCount }
    var roomMetadataLastError: String? { RoomRuntime.shared.metadataLastError }
    var openRoomID: RoomID? {
        get { RoomRuntime.shared.openRoomID }
        set { RoomRuntime.shared.openRoomID = newValue }
    }

    func room(_ id: RoomID) -> RoomRecord? {
        RoomRuntime.shared.rooms.first { $0.id == id }
    }

    func roomAvatarData(_ id: RoomID) -> Data? { RoomRuntime.shared.avatarData[id] }

    func reconcileRoom(_ roomID: RoomID) {
        scheduleRoomReconciliation(roomID: roomID)
    }

    /// Explicit fail-closed resolution for a turn whose acceptance cannot be
    /// proven. Talaria never retries it automatically; the user may abandon
    /// the durable attempt after checking the owning Hermes session.
    func abandonRoomAttempt(roomID: RoomID, attemptID: RoomAttemptID) async {
        let updated = try? await RoomMutationGate.shared.withLock(roomID.description) {
            if let room = try await RoomRuntime.shared.store.room(id: roomID),
               let attempt = room.attempts.first(where: { $0.id == attemptID }),
               !attempt.stagedImagePaths.isEmpty,
               let client = try? await routedClient(for: attempt.member) {
                await client.detachRoomStagedImages(attempt.stagedImagePaths,
                                                    sessionID: attempt.runtimeSessionID)
            }
            return try await RoomRuntime.shared.store.mutate(roomID: roomID) { room in
                guard let index = room.attempts.firstIndex(where: { $0.id == attemptID }),
                      room.attempts[index].finishedAt == nil else { throw CancellationError() }
                let attempt = room.attempts[index]
                room.attempts[index].state = .cancelled
                room.attempts[index].finishedAt = Date()
                room.attempts[index].outboundAttachments = []
                room.attempts[index].stagedImagePaths = []
                RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch, kind: .cancelled,
                                                       member: attempt.member,
                                                       threadID: attempt.threadID), in: &room)
            }
        }
        if let updated { RoomRuntime.shared.replace(updated) }
    }

    func roomStorageUsage() async -> RoomStorageUsage? {
        try? await RoomStore.shared.storageUsage()
    }

    @discardableResult
    internal func prepareRoomProfileLifecycle(
        source route: GatewayBotRoute, deleting: Bool = false
    ) -> RoomProfileLifecycleToken {
        let runtime = RoomRuntime.shared
        let generation = runtime.bumpProfileRouteGeneration(route)
        if deleting { runtime.retiredProfileRoutes.insert(route) }
        let affected = runtime.rooms.filter { room in
            room.members.contains(where: { $0.route == route })
                || room.formerMembers.contains(where: { $0.route == route })
                || room.attempts.contains(where: { $0.member == route })
                || room.memberSessions[route.qualifiedID] != nil
        }.map(\.id)
        for id in affected {
            runtime.driveTasks[id]?.cancel()
            runtime.driveTokens[id] = UUID()
        }
        return RoomProfileLifecycleToken(source: route, generation: generation)
    }

    internal func commitRoomProfileRename(
        _ token: RoomProfileLifecycleToken, destination: GatewayBotRoute
    ) async throws {
        let runtime = RoomRuntime.shared
        guard runtime.acceptsProfileRoute(token.source, generation: token.generation)
        else { throw CancellationError() }
        let result = try await runtime.store.migrateProfileRoute(
            from: token.source, to: destination)
        guard runtime.acceptsProfileRoute(token.source, generation: token.generation)
        else { throw CancellationError() }
        runtime.retiredProfileRoutes.remove(token.source)
        _ = runtime.bumpProfileRouteGeneration(destination)
        runtime.rooms = result.rooms.sorted { $0.lastActivityAt > $1.lastActivityAt }
        runtime.metadataPendingCount = (try? await runtime.store.metadataOutbox().count) ?? 0
    }

    internal func abortRoomProfileLifecycle(_ token: RoomProfileLifecycleToken) {
        let runtime = RoomRuntime.shared
        guard runtime.profileRouteGeneration(token.source) == token.generation else { return }
        _ = runtime.bumpProfileRouteGeneration(token.source)
        runtime.retiredProfileRoutes.remove(token.source)
    }

    /// Settings → Delete local data. New room mutations are held outside the
    /// boundary, existing mutations and drive owners drain, then index/blobs
    /// are deleted before admission reopens. This prevents an in-flight create
    /// or send from resurrecting storage after the user saw deletion finish.
    func deleteAllRoomData() async throws {
        var deletionError: Error?
        var roomsToResume: [RoomRecord] = []
        await RoomMutationGate.shared.withQuiescence {
            let runtime = RoomRuntime.shared
            let tasks = Array(runtime.driveTasks.values)
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            // Local-data deletion does not mutate Hermes. In particular, an
            // accepted/uncertain prompt may still own queued provider payloads;
            // stripping them remotely would change an in-flight turn.
            do {
                try await runtime.store.deleteAll()
            } catch RoomStoreError.deleteCleanupFailed {
                // The empty index is authoritative, so no room can resurrect;
                // clear runtime but surface that residual files may remain.
                resetRoomRuntimeAfterDeletion(runtime)
                deletionError = RoomStoreError.deleteCleanupFailed
            } catch {
                // Empty-index publication failed. Preserve the in-memory world
                // so Settings cannot claim erasure or hide data that remains.
                // The quiescence boundary already cancelled every owner;
                // replace those stale task slots and resume exactly from the
                // durable drive/attempt ledger—never by replaying a prompt.
                runtime.driveTasks.removeAll()
                runtime.driveTokens.removeAll()
                roomsToResume = runtime.rooms
                deletionError = error
            }
            if deletionError == nil { resetRoomRuntimeAfterDeletion(runtime) }
        }
        // Resume after exclusive deletion admission reopens. A task created
        // while the quiescence owner is unwinding could otherwise inherit a
        // stale cancellation/admission boundary and never run.
        for room in roomsToResume {
            if !room.drives.isEmpty { scheduleRoomDrive(roomID: room.id) }
            else if room.attempts.contains(where: { $0.finishedAt == nil }) {
                scheduleRoomReconciliation(roomID: room.id)
            }
        }
        if let deletionError { throw deletionError }
    }

    private func resetRoomRuntimeAfterDeletion(_ runtime: RoomRuntime) {
            runtime.driveTasks.removeAll()
            runtime.driveTokens.removeAll()
            runtime.rooms = []
            runtime.avatarData = [:]
            runtime.openRoomID = nil
            runtime.loadError = nil
            runtime.metadataPendingCount = 0
            runtime.metadataLastError = nil
            runtime.isLoaded = false
            runtime.profileRouteGenerations.removeAll()
            runtime.retiredProfileRoutes.removeAll()
    }

    /// Root integration hook: call once when the roster shell appears. It is
    /// idempotent and resumes only durable queued/running drives.
    func loadRooms() async {
        _ = try? await RoomMutationGate.shared.withLock("load") {
            await loadRoomsUnlocked()
        }
        await flushRoomMetadataOutbox()
    }

    private func loadRoomsUnlocked() async {
        let runtime = RoomRuntime.shared
        guard !runtime.isLoaded else { return }
        do {
            let loaded: [RoomRecord]
            if let operation = runtime.loadOperation { loaded = try await operation() }
            else { loaded = try await runtime.store.loadAll() }
            runtime.rooms = loaded.sorted { $0.lastActivityAt > $1.lastActivityAt }
            runtime.retiredProfileRoutes = (try? await runtime.store.retiredMetadataRoutes()) ?? []
            for room in loaded {
                if let avatar = room.avatar,
                   let data = try? await runtime.store.readBlob(roomID: room.id, attachment: avatar) {
                    runtime.avatarData[room.id] = data
                }
            }
            runtime.loadError = nil
            runtime.isLoaded = true
            for room in loaded {
                if !room.drives.isEmpty { scheduleRoomDrive(roomID: room.id) }
                else if room.attempts.contains(where: { $0.finishedAt == nil }) {
                    scheduleRoomReconciliation(roomID: room.id)
                }
            }
        } catch {
            runtime.loadError = error.localizedDescription
        }
    }

    /// Members come from the union roster and are source-qualified before
    /// persistence, so duplicate profile names on two gateways never collide.
    @discardableResult
    func createRoom(name: String, members: [RoomMember]) async throws -> RoomID {
        try await RoomMutationGate.shared.withLock("create") {
            try await createRoomUnlocked(name: name, members: members)
        }
    }

    private func createRoomUnlocked(name: String, members proposedMembers: [RoomMember]) async throws -> RoomID {
        let existing = try await RoomRuntime.shared.store.loadAll().map(\.name)
        let trimmed = try RoomNamePolicy.unique(name, existing: existing)
        let unique = proposedMembers.reduce(into: [RoomMember]()) { members, member in
            if !members.contains(where: { $0.route == member.route }) { members.append(member) }
        }
        var record = RoomRecord(name: trimmed, members: unique)
        try RoomEngine.validate(record)
        record.updatedAt = Date()
        let metadata = record.members.map {
            RoomMetadataMutation(route: $0.route, kind: .add, newName: record.name)
        }
        try await RoomRuntime.shared.store.upsert(record, metadataMutations: metadata)
        RoomRuntime.shared.replace(record)
        RoomRuntime.shared.openRoomID = record.id
        await flushRoomMetadataOutbox()
        return record.id
    }

    func renameRoom(_ roomID: RoomID, name: String) async throws {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            try await renameRoomUnlocked(roomID, name: name)
        }
    }

    func updateRoomSettings(_ roomID: RoomID, name: String, members proposedMembers: [RoomMember],
                            avatar: RoomOutboundAttachment? = nil,
                            removeAvatar: Bool = false) async throws {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            guard let before = try await RoomRuntime.shared.store.room(id: roomID) else {
                throw RoomStoreError.roomNotFound(roomID)
            }
            let normalized = try RoomNamePolicy.normalized(name)
            let otherNames = try await RoomRuntime.shared.store.loadAll()
                .filter { $0.id != roomID }.map { $0.name.lowercased() }
            guard !otherNames.contains(normalized.lowercased()) else { throw RoomNameError.taken }

            let members = proposedMembers.reduce(into: [RoomMember]()) { result, member in
                if !result.contains(where: { $0.route == member.route }) { result.append(member) }
            }
            guard (RoomEngine.minimumMembers...RoomEngine.maximumMembers).contains(members.count) else {
                throw RoomValidationError.memberCount(members.count)
            }
            let activeRoutes = Set(members.map(\.route))
            let membershipChanged = activeRoutes != Set(before.members.map(\.route))
            let removed = before.members.filter { !activeRoutes.contains($0.route) }
            if before.attempts.contains(where: { attempt in
                removed.contains(where: { $0.route == attempt.member }) && attempt.finishedAt == nil
            }) { throw RoomSettingsError.memberBusy }

            var storedAvatar: RoomAttachment?
            if let avatar {
                storedAvatar = try await RoomRuntime.shared.store.storeBlob(
                    roomID: roomID, data: avatar.data, fileName: avatar.name,
                    mediaType: AttachmentEncoder.mimeType(forFilename: avatar.name))
            }
            let avatarToStore = storedAvatar
            let beforeRoutes = Set(before.members.map(\.route))
            let afterRoutes = Set(members.map(\.route))
            var metadata: [RoomMetadataMutation] = before.members
                .filter { !afterRoutes.contains($0.route) }
                .map { RoomMetadataMutation(route: $0.route, kind: .remove,
                                            oldName: before.name) }
            metadata += members.filter { !beforeRoutes.contains($0.route) }.map {
                RoomMetadataMutation(route: $0.route, kind: .add, newName: normalized)
            }
            if before.name != normalized {
                metadata += members.filter { beforeRoutes.contains($0.route) }.map {
                    RoomMetadataMutation(route: $0.route, kind: .rename,
                                         oldName: before.name, newName: normalized)
                }
            }
            let result: RoomRecord
            do {
                result = try await RoomRuntime.shared.store.mutate(
                    roomID: roomID, metadataMutations: metadata
                ) { current in
                    current.name = normalized
                    let currentRoutes = Set(members.map(\.route))
                    if membershipChanged {
                        current.epoch &+= 1
                        current.drives.removeAll()
                        current.activity.removeAll()
                    }
                    let departed = current.members.filter { !currentRoutes.contains($0.route) }
                    for member in departed where !current.formerMembers.contains(where: { $0.route == member.route }) {
                        current.formerMembers.append(member)
                    }
                    current.formerMembers.removeAll { currentRoutes.contains($0.route) }
                    current.members = members
                    if removeAvatar { current.avatar = nil }
                    else if let avatarToStore { current.avatar = avatarToStore }
                    current.updatedAt = Date()
                }
            } catch {
                _ = try? await RoomRuntime.shared.store.pruneOrphanedBlobs()
                throw error
            }

            _ = try? await RoomRuntime.shared.store.pruneOrphanedBlobs()
            if let avatar { RoomRuntime.shared.avatarData[roomID] = avatar.data }
            else if removeAvatar { RoomRuntime.shared.avatarData[roomID] = nil }
            RoomRuntime.shared.replace(result)
            await flushRoomMetadataOutbox()
        }
    }

    private func renameRoomUnlocked(_ roomID: RoomID, name: String) async throws {
        guard var room = try await RoomRuntime.shared.store.room(id: roomID) else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        let oldName = room.name
        let normalized = try RoomNamePolicy.normalized(name)
        let otherNames = try await RoomRuntime.shared.store.loadAll()
            .filter { $0.id != roomID }.map { $0.name.lowercased() }
        guard !otherNames.contains(normalized.lowercased()) else { throw RoomNameError.taken }
        let metadata = room.members.map {
            RoomMetadataMutation(route: $0.route, kind: .rename,
                                 oldName: oldName, newName: normalized)
        }
        room = try await RoomRuntime.shared.store.mutate(
            roomID: roomID, metadataMutations: metadata
        ) { current in
            current.name = normalized
            current.updatedAt = Date()
        }
        RoomRuntime.shared.replace(room)
        await flushRoomMetadataOutbox()
    }

    /// Invalidate/persist first, cancel and await the sole driver second,
    /// delete durable room+blobs third, retire navigation last.
    func disbandRoom(_ roomID: RoomID) async throws {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            try await disbandRoomUnlocked(roomID)
        }
    }

    private func disbandRoomUnlocked(_ roomID: RoomID) async throws {
        let runtime = RoomRuntime.shared
        guard var room = try await runtime.store.room(id: roomID) else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        room = try await runtime.store.mutate(roomID: roomID) { current in
            current.epoch &+= 1
            for index in current.attempts.indices where current.attempts[index].finishedAt == nil {
                current.attempts[index].state = .cancelled
                current.attempts[index].finishedAt = Date()
                current.attempts[index].outboundAttachments = []
            }
            current.drives.removeAll()
            RoomEngine.recordActivity(RoomActivity(epoch: current.epoch, kind: .cancelled), in: &current)
        }
        runtime.replace(room)

        let task = runtime.driveTasks[roomID]
        task?.cancel()
        await task?.value
        // Explicit disband proves these uncertain turns are abandoned. Undo
        // any queued image/PDF state before deleting the durable path ledger.
        for attempt in room.attempts where !attempt.stagedImagePaths.isEmpty {
            if let client = try? await routedClient(for: attempt.member) {
                await client.detachRoomStagedImages(attempt.stagedImagePaths,
                                                   sessionID: attempt.runtimeSessionID)
            }
        }
        let metadata = room.members.map {
            RoomMetadataMutation(route: $0.route, kind: .remove, oldName: room.name)
        }
        try await runtime.store.delete(roomID: roomID, metadataMutations: metadata)
        runtime.driveTasks[roomID] = nil
        runtime.driveTokens[roomID] = nil
        runtime.remove(roomID)
        await flushRoomMetadataOutbox()
    }

    /// Main composer mints a stable topic; a reply supplies its thread id.
    /// Blobs commit before the entry references them.
    @discardableResult
    func sendRoomMessage(roomID: RoomID, text: String,
                         threadID: RoomThreadID? = nil,
                         attachments: [RoomOutboundAttachment] = []) async throws -> RoomThreadID {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            try await sendRoomMessageUnlocked(roomID: roomID, text: text,
                                              threadID: threadID, attachments: attachments)
        }
    }

    private func sendRoomMessageUnlocked(roomID: RoomID, text: String,
                                         threadID: RoomThreadID?,
                                         attachments: [RoomOutboundAttachment]) async throws -> RoomThreadID {
        let runtime = RoomRuntime.shared
        guard try await runtime.store.room(id: roomID) != nil else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty else {
            throw GatewayError(code: -8, message: "A room message cannot be empty.")
        }

        let target = threadID ?? RoomThreadID()
        let room = try await runtime.store.mutate(roomID: roomID) { current in
            current.epoch &+= 1
            current.needsUser = false
            current.activity.removeAll()
            if let threadID {
                guard current.threads.contains(where: { $0.id == threadID }) else {
                    throw RoomValidationError.unknownThread
                }
            } else {
                current.threads.append(RoomThread(id: target))
            }
        }
        var storedAttachments: [RoomAttachment] = []
        do {
            for attachment in attachments {
                let mediaType: String = switch attachment.kind {
                case .image: AttachmentEncoder.mimeType(forFilename: attachment.name)
                case .pdf: "application/pdf"
                case .file: AttachmentEncoder.mimeType(forFilename: attachment.name)
                }
                storedAttachments.append(try await runtime.store.storeBlob(
                    roomID: roomID, data: attachment.data, fileName: attachment.name,
                    mediaType: mediaType))
            }
        } catch {
            _ = try? await runtime.store.pruneOrphanedBlobs()
            throw error
        }

        let expectedEpoch = room.epoch
        let attachmentsToStore = storedAttachments
        let final: RoomRecord
        do {
            final = try await runtime.store.mutate(roomID: roomID) { current in
                // This public mutation gate prevents another send, while an
                // older driver may only observe supersession and retire.
                guard current.epoch == expectedEpoch else { throw CancellationError() }
                try RoomEngine.append(RoomEntry(threadID: target, speaker: .user,
                                                speakerName: "You", text: body,
                                                attachments: attachmentsToStore), to: &current)
                current.drives.removeAll { $0.epoch != current.epoch }
                current.drives.append(RoomDriveState(threadID: target, epoch: current.epoch))
                RoomEngine.recordActivity(RoomActivity(epoch: current.epoch, kind: .queued,
                                                       threadID: target), in: &current)
            }
        } catch {
            _ = try? await runtime.store.pruneOrphanedBlobs()
            throw error
        }
        runtime.replace(final)
        scheduleRoomDrive(roomID: roomID)
        return target
    }
}

// MARK: - Serialized driver

extension AppModel {
    func flushRoomMetadataOutbox() async {
        _ = try? await RoomMutationGate.shared.withLock("metadata-outbox") {
            let runtime = RoomRuntime.shared
            let mutations: [RoomMetadataMutation]
            do { mutations = try await runtime.store.metadataOutbox() }
            catch {
                runtime.metadataLastError = error.localizedDescription
                return
            }
            runtime.metadataPendingCount = mutations.count
            if mutations.isEmpty { runtime.metadataLastError = nil; return }
            var blockedRoutes = Set<GatewayBotRoute>()
            for mutation in mutations {
                guard !blockedRoutes.contains(mutation.route) else { continue }
                let generation = runtime.profileRouteGeneration(mutation.route)
                guard runtime.acceptsProfileRoute(mutation.route, generation: generation) else {
                    blockedRoutes.insert(mutation.route)
                    continue
                }
                do {
                    if let operation = runtime.metadataMutationOperation {
                        try await operation(mutation)
                    } else {
                        try await applyRoomMetadataMutation(mutation)
                    }
                    // A committed profile rename may have rewritten this same
                    // id while the network request was suspended. Do not let
                    // the old completion remove the destination mutation.
                    guard runtime.acceptsProfileRoute(mutation.route,
                                                      generation: generation) else {
                        blockedRoutes.insert(mutation.route)
                        continue
                    }
                    try await runtime.store.removeMetadataMutation(
                        id: mutation.id, matching: mutation)
                    runtime.metadataPendingCount = max(0, runtime.metadataPendingCount - 1)
                    runtime.metadataLastError = nil
                } catch {
                    // Keep the exact source-qualified mutation durable. A
                    // later union-roster refresh/reconnect retries it in order.
                    runtime.metadataLastError = error.localizedDescription
                    blockedRoutes.insert(mutation.route)
                }
            }
        }
    }

    private func applyRoomMetadataMutation(_ mutation: RoomMetadataMutation) async throws {
        let client = try await routedClient(for: mutation.route)
        try await withBotModeMetaMutation(route: mutation.route) {
            let profiles = try await client.listProfiles(includeSessions: false)
            guard let profile = profiles.first(where: { $0.name == mutation.route.profile }) else {
                throw GatewayError(code: -8, message: "Room member profile is unavailable.")
            }
            var block = profile.uiMeta?["hermes-bots"]?.objectValue ?? [:]
            var groups = BotModeMeta(uiMeta: profile.uiMeta)?.groups ?? []
            switch mutation.kind {
            case .add:
                guard let name = mutation.newName, !name.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata add is malformed.")
                }
                if !groups.contains(name) { groups.append(name) }
            case .remove:
                guard let name = mutation.oldName, !name.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata removal is malformed.")
                }
                groups.removeAll { $0 == name }
            case .rename:
                guard let oldName = mutation.oldName, let newName = mutation.newName,
                      !oldName.isEmpty, !newName.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata rename is malformed.")
                }
                // Desktop maps the existing ordered membership in place.
                // Appending would change the legacy `group` projection when
                // the renamed room was first in the array.
                groups = BotModeMeta.replacingGroup(oldName, with: newName, in: groups)
            }
            for (key, value) in BotModeMeta.membershipProjection(groups) { block[key] = value }
            let applied = try await client.applyProfileEdit(
                name: mutation.route.profile,
                ProfileEdit(uiMeta: .object(["hermes-bots": .object(block)])))
            guard applied["ui_meta"] == true else {
                throw GatewayError(code: -8, message: "Hermes did not confirm room metadata.")
            }
        }
    }

    func scheduleRoomDrive(roomID: RoomID) {
        let runtime = RoomRuntime.shared
        let prior = runtime.driveTasks[roomID]
        let token = UUID()
        runtime.driveTokens[roomID] = token
        let next = Task { @MainActor [weak self] in
            await prior?.value
            guard !Task.isCancelled, let self else { return }
            if let operation = RoomRuntime.shared.driveOperation {
                await operation(self, roomID)
            } else {
                await self.runRoomDrive(roomID: roomID)
            }
            if RoomRuntime.shared.driveTokens[roomID] == token {
                RoomRuntime.shared.driveTasks[roomID] = nil
                RoomRuntime.shared.driveTokens[roomID] = nil
            }
        }
        runtime.driveTasks[roomID] = next
    }

    func scheduleRoomReconciliation(roomID: RoomID) {
        let runtime = RoomRuntime.shared
        let prior = runtime.driveTasks[roomID]
        let token = UUID()
        runtime.driveTokens[roomID] = token
        let next = Task { @MainActor [weak self] in
            await prior?.value
            guard !Task.isCancelled, let self,
                  let room = try? await RoomRuntime.shared.store.room(id: roomID) else { return }
            await self.harvestRoomAttempts(roomID: roomID, epoch: room.epoch)
            if !Task.isCancelled,
               let refreshed = try? await RoomRuntime.shared.store.room(id: roomID),
               refreshed.drives.contains(where: { $0.epoch == refreshed.epoch }) {
                await self.runRoomDrive(roomID: roomID)
            }
            if RoomRuntime.shared.driveTokens[roomID] == token {
                RoomRuntime.shared.driveTasks[roomID] = nil
                RoomRuntime.shared.driveTokens[roomID] = nil
            }
        }
        runtime.driveTasks[roomID] = next
    }

    private func roomRouteGenerationSnapshot(_ room: RoomRecord)
        -> [GatewayBotRoute: UInt64] {
        var routes = Set(room.members.map(\.route))
        routes.formUnion(room.formerMembers.map(\.route))
        routes.formUnion(room.attempts.map(\.member))
        routes.formUnion(room.drives.flatMap(\.roundMembers))
        routes.formUnion(room.activity.compactMap(\.member))
        routes.formUnion(room.memberSessions.keys.compactMap(GatewayBotRoute.init(qualifiedID:)))
        return Dictionary(uniqueKeysWithValues: routes.map {
            ($0, RoomRuntime.shared.profileRouteGeneration($0))
        })
    }

    private func acceptsRoomRouteGenerations(
        _ generations: [GatewayBotRoute: UInt64]
    ) -> Bool {
        generations.allSatisfy {
            RoomRuntime.shared.acceptsProfileRoute($0.key, generation: $0.value)
        }
    }

    func runRoomDrive(roomID: RoomID) async {
        let runtime = RoomRuntime.shared
        guard let initial = try? await runtime.store.room(id: roomID) else { return }
        let routeGenerations = roomRouteGenerationSnapshot(initial)
        while !Task.isCancelled {
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            guard var room = try? await runtime.store.room(id: roomID),
                  let driveIndex = room.drives.firstIndex(where: { $0.epoch == room.epoch })
            else { return }
            var drive = room.drives[driveIndex]
            guard drive.round < RoomEngine.maximumRounds,
                  drive.posted < RoomEngine.maximumPosts else {
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                await settleRoomDrive(roomID: roomID, epoch: drive.epoch,
                                      threadID: drive.threadID,
                                      routeGenerations: routeGenerations)
                return
            }

            // Late-result reconciliation precedes any new selection.
            await harvestRoomAttempts(roomID: roomID, epoch: drive.epoch)
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            guard let refreshed = try? await runtime.store.room(id: roomID),
                  refreshed.epoch == drive.epoch,
                  let refreshedDrive = refreshed.drives.first(where: { $0.epoch == drive.epoch })
            else { return }
            room = refreshed
            drive = refreshedDrive

            let responders: [RoomMember]
            if drive.roundMembers.isEmpty {
                responders = RoomEngine.scheduledResponders(
                    entries: room.entries, members: room.members, threadID: drive.threadID,
                    round: drive.round, posted: drive.posted)
                drive.roundMembers = responders.map(\.route)
                let driveToPersist = drive
                let expectedEpoch = drive.epoch
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                guard let updated = try? await runtime.store.mutate(roomID: roomID, { current in
                    guard current.epoch == expectedEpoch,
                          let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                    else { throw CancellationError() }
                    current.drives[index] = driveToPersist
                }) else { return }
                room = updated
                runtime.replace(updated)
            } else {
                responders = drive.roundMembers.compactMap { route in
                    room.members.first { $0.route == route }
                }
            }
            if responders.isEmpty || drive.nextMemberIndex >= responders.count {
                // Durable roundStartPosted keeps this correct after a crash in
                // the middle of a round.
                if drive.posted == drive.roundStartPosted {
                    guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                    await settleRoomDrive(roomID: roomID, epoch: drive.epoch,
                                          threadID: drive.threadID,
                                          routeGenerations: routeGenerations)
                    return
                }
                drive.round += 1
                drive.roundMembers = []
                drive.nextMemberIndex = 0
                drive.roundStartPosted = drive.posted
                drive.status = .running
                drive.updatedAt = Date()
                let driveToPersist = drive
                let expectedEpoch = drive.epoch
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                guard let updated = try? await runtime.store.mutate(roomID: roomID, { current in
                    guard current.epoch == expectedEpoch,
                          let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                    else { throw CancellationError() }
                    current.drives[index] = driveToPersist
                }) else { return }
                runtime.replace(updated)
                continue
            }

            let member = responders[drive.nextMemberIndex]
            guard runtime.acceptsProfileRoute(
                member.route, generation: routeGenerations[member.route] ?? 0) else { return }
            await runRoomMemberBoundary(roomID: roomID, epoch: drive.epoch,
                                        threadID: drive.threadID, member: member)
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }

            let expectedEpoch = drive.epoch
            if let parked = try? await runtime.store.room(id: roomID),
               parked.epoch == expectedEpoch,
               parked.attempts.contains(where: {
                   $0.epoch == expectedEpoch && $0.member == member.route
                       && $0.state == .waiting && $0.finishedAt == nil
               }) {
                try? await Task.sleep(for: runtime.pollInterval)
                continue
            }
            guard acceptsRoomRouteGenerations(routeGenerations),
                  let nextRoom = try? await runtime.store.mutate(roomID: roomID, { current in
                guard current.epoch == expectedEpoch,
                      let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                else { throw CancellationError() }
                current.drives[index].nextMemberIndex += 1
                current.drives[index].status = .running
                current.drives[index].updatedAt = Date()
            }) else { return }
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            runtime.replace(nextRoom)
        }
    }

    func runRoomMemberBoundary(roomID: RoomID, epoch: UInt64,
                               threadID: RoomThreadID, member: RoomMember) async {
        let runtime = RoomRuntime.shared
        guard var room = try? await runtime.store.room(id: roomID), room.epoch == epoch else { return }
        let routeGeneration = runtime.profileRouteGeneration(member.route)
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        // An accepted/uncertain/timed-out attempt is stranded work. Harvest it
        // at boundaries; never submit a replacement into that session.
        if room.attempts.contains(where: {
            $0.member == member.route && $0.finishedAt == nil &&
                [.waiting, .accepted, .uncertain, .working, .timedOut].contains($0.state)
        }) {
            await harvestRoomAttempts(roomID: roomID, epoch: epoch, member: member.route)
            return
        }

        let key = RoomEngine.watermarkKey(threadID: threadID, member: member.route)
        let seen = room.watermarks[key] ?? 0
        let delta = Array(room.entries.dropFirst(min(seen, room.entries.count)))
            .filter { $0.threadID == threadID }
        guard !delta.isEmpty else { return }

        let client: GatewayClient
        do { client = try await routedClient(for: member.route) }
        catch {
            await persistRoomActivity(roomID: roomID, epoch: epoch, kind: .failed,
                                      member: member.route, threadID: threadID,
                                      routeGeneration: routeGeneration)
            return
        }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        let session: RoomMemberSessionSnapshot
        do {
            session = try await client.ensureRoomSession(
                roomTitle: room.name, profile: member.route.profile,
                storedID: room.memberSessions[member.route.qualifiedID])
        } catch {
            await persistRoomActivity(roomID: roomID, epoch: epoch, kind: .failed,
                                      member: member.route, threadID: threadID,
                                      routeGeneration: routeGeneration)
            return
        }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        let prompt = roomTurnPrompt(room: room, viewer: member,
                                    delta: Array(delta.suffix(RoomEngine.historyLimit)))
        let exactAttachments = delta.flatMap(\.attachments)
        // `.working` is persisted BEFORE the network acceptance boundary. A
        // crash or local result-save failure can then only reconcile by exact
        // marker; it can never treat the turn as unsent and duplicate it.
        let initialState: RoomAttemptState = session.running ? .waiting : .working
        let attempt = RoomAttempt(threadID: threadID, member: member.route, epoch: epoch,
                                  promptText: prompt, storedSessionID: session.storedID,
                                  runtimeSessionID: session.runtimeID,
                                  outboundAttachments: exactAttachments, state: initialState,
                                  baselineMessageCount: session.messageCount)
        if session.running {
            // Durable wait proves no room prompt was submitted. Reconciliation
            // watches until idle, then settles this boundary without a blind
            // submission; a later round can consider fresh deltas normally.
            guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
            if let waiting = try? await runtime.store.mutate(roomID: roomID, { current in
                guard current.epoch == epoch else { throw CancellationError() }
                current.memberSessions[member.route.qualifiedID] = session.storedID
                current.attempts.append(attempt)
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .queued,
                                                       member: member.route, threadID: threadID),
                                          in: &current)
            }) {
                guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
                runtime.replace(waiting)
            }
            return
        }

        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        guard let persisted = try? await runtime.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            current.memberSessions[member.route.qualifiedID] = session.storedID
            current.attempts.append(attempt)
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .working,
                                                   member: member.route, threadID: threadID), in: &current)
        }) else { return }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        room = persisted
        runtime.replace(persisted)

        let outbound = await roomOutboundAttachments(roomID: roomID,
                                                     descriptors: attempt.outboundAttachments)
        let submitted: RoomPromptSubmission
        if let operation = runtime.submitOperation {
            submitted = await operation(attempt, session, outbound)
        } else {
            submitted = await client.submitRoomPrompt(
                attempt: attempt, session: session,
                profile: member.route.profile, attachments: outbound)
        }

        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        let saved = await persistRoomSubmission(roomID: roomID, attemptID: attempt.id,
                                                member: member.route, epoch: epoch,
                                                threadID: threadID, submitted: submitted,
                                                routeGeneration: routeGeneration)
        if saved, case .accepted = submitted.acceptance {
            await waitForRoomReply(roomID: roomID, attemptID: attempt.id)
        }
    }

    @discardableResult
    func persistRoomSubmission(roomID: RoomID, attemptID: RoomAttemptID,
                               member: GatewayBotRoute, epoch: UInt64,
                               threadID: RoomThreadID,
                               submitted: RoomPromptSubmission,
                               routeGeneration: UInt64? = nil) async -> Bool {
        let runtime = RoomRuntime.shared
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member, generation: routeGeneration) { return false }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID })
            else { throw CancellationError() }
            guard current.attempts[index].member == member,
                  current.attempts[index].epoch == epoch else { throw CancellationError() }
            current.attempts[index].baselineMessageCount = submitted.baseline
            current.attempts[index].storedSessionID = submitted.storedID
            current.attempts[index].runtimeSessionID = submitted.runtimeID
            current.attempts[index].stagedImagePaths = submitted.stagedImagePaths
            switch submitted.acceptance {
            case .accepted:
                current.attempts[index].state = .accepted
                current.memberSessions[member.qualifiedID] = submitted.storedID
            case .uncertain:
                current.attempts[index].state = .uncertain
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .uncertain,
                                                       member: member, threadID: threadID), in: &current)
            case .busy:
                current.attempts[index].state = .waiting
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .queued,
                                                       member: member, threadID: threadID), in: &current)
            case .rejected:
                current.attempts[index].state = .failed
                current.attempts[index].finishedAt = Date()
                current.attempts[index].outboundAttachments = []
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .failed,
                                                       member: member, threadID: threadID), in: &current)
            }
        }) else { return false }
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member, generation: routeGeneration) { return false }
        runtime.replace(room)
        return true
    }

    func waitForRoomReply(roomID: RoomID, attemptID: RoomAttemptID) async {
        let runtime = RoomRuntime.shared
        let started = Date()
        var deadline = started.addingTimeInterval(runtime.baseTurnTimeout)
        while !Task.isCancelled, Date() < deadline {
            guard let current = try? await runtime.store.room(id: roomID),
                  let currentAttempt = current.attempts.first(where: { $0.id == attemptID }),
                  current.epoch == currentAttempt.epoch else { return }
            try? await Task.sleep(for: runtime.pollInterval)
            guard let room = try? await runtime.store.room(id: roomID),
                  let attempt = room.attempts.first(where: { $0.id == attemptID }),
                  attempt.finishedAt == nil,
                  room.epoch == attempt.epoch,
                  let member = room.members.first(where: { $0.route == attempt.member }),
                  let routeGeneration = Optional(runtime.profileRouteGeneration(attempt.member)),
                  let client = try? await routedClient(for: attempt.member),
                  let session = try? await client.readRoomSession(
                    storedID: attempt.storedSessionID, profile: attempt.member.profile)
            else { return }
            if let reply = session.assistantReply(for: attempt), !session.running {
                await finishRoomAttempt(roomID: roomID, attemptID: attemptID,
                                        member: member, reply: reply, delivered: false,
                                        routeGeneration: routeGeneration)
                return
            }
            if session.running {
                deadline = min(started.addingTimeInterval(runtime.hardTurnTimeout),
                               max(deadline, Date().addingTimeInterval(runtime.baseTurnTimeout)))
            } else if session.containsAttempt(attempt) {
                // Accepted with no assistant row (tool-only/no output): pass.
                await finishRoomAttempt(roomID: roomID, attemptID: attemptID,
                                        member: member, reply: nil, delivered: false,
                                        routeGeneration: routeGeneration)
                return
            }
        }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID }),
                  current.attempts[index].finishedAt == nil,
                  current.epoch == current.attempts[index].epoch else { throw CancellationError() }
            current.attempts[index].state = .timedOut
            RoomEngine.recordActivity(RoomActivity(epoch: current.attempts[index].epoch,
                                                   kind: .timedOut,
                                                   member: current.attempts[index].member,
                                                   threadID: current.attempts[index].threadID), in: &current)
        }) else { return }
        runtime.replace(room)
    }

    /// Reconcile accepted/uncertain/timed-out work. Uncertainty becomes
    /// accepted only when the exact marker is present. Neither path submits.
    func harvestRoomAttempts(roomID: RoomID, epoch: UInt64,
                             member: GatewayBotRoute? = nil) async {
        let runtime = RoomRuntime.shared
        guard let room = try? await runtime.store.room(id: roomID) else { return }
        let pending = room.attempts.filter {
            $0.finishedAt == nil && (member == nil || $0.member == member) &&
                [.waiting, .accepted, .uncertain, .working, .timedOut].contains($0.state)
        }
        for attempt in pending {
            guard !Task.isCancelled,
                  let current = try? await runtime.store.room(id: roomID) else { continue }
            let routeGeneration = runtime.profileRouteGeneration(attempt.member)
            guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else {
                continue
            }
            if attempt.state == .waiting, current.epoch != attempt.epoch {
                if let cancelled = try? await runtime.store.mutate(roomID: roomID, { value in
                    guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                          value.attempts[index].state == .waiting else { throw CancellationError() }
                    value.attempts[index].state = .cancelled
                    value.attempts[index].finishedAt = Date()
                    value.attempts[index].outboundAttachments = []
                }) { runtime.replace(cancelled) }
                continue
            }
            guard let seat = current.members.first(where: { $0.route == attempt.member }),
                  let client = try? await routedClient(for: attempt.member),
                  let session = try? await client.readRoomSession(
                    storedID: attempt.storedSessionID, profile: attempt.member.profile)
            else { continue }
            if attempt.state == .waiting {
                guard !session.running else { continue }
                if session.containsAttempt(attempt) {
                    if let accepted = try? await runtime.store.mutate(roomID: roomID, { value in
                        guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id })
                        else { throw CancellationError() }
                        value.attempts[index].state = .accepted
                    }) { runtime.replace(accepted) }
                } else {
                    await submitWaitingRoomAttempt(roomID: roomID, attempt: attempt,
                                                   session: session, client: client)
                    continue
                }
            }
            if !session.running, !session.containsAttempt(attempt),
               [.working, .uncertain, .timedOut].contains(attempt.state) {
                if let unresolved = try? await runtime.store.mutate(roomID: roomID, { value in
                    guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                          value.attempts[index].finishedAt == nil else { throw CancellationError() }
                    if value.attempts[index].state == .working {
                        value.attempts[index].state = .uncertain
                    }
                    if !value.activity.contains(where: {
                        $0.epoch == attempt.epoch && $0.member == attempt.member
                            && $0.threadID == attempt.threadID && $0.kind == .uncertain
                    }) {
                        RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch,
                                                               kind: .uncertain,
                                                               member: attempt.member,
                                                               threadID: attempt.threadID), in: &value)
                    }
                }) { runtime.replace(unresolved) }
                continue
            }
            if let reply = session.assistantReply(for: attempt), !session.running {
                await finishRoomAttempt(roomID: roomID, attemptID: attempt.id,
                                        member: seat, reply: reply, delivered: true,
                                        routeGeneration: routeGeneration)
            } else if !session.running, session.containsAttempt(attempt) {
                await finishRoomAttempt(roomID: roomID, attemptID: attempt.id,
                                        member: seat, reply: nil, delivered: true,
                                        routeGeneration: routeGeneration)
            }
        }
    }

    /// Busy→idle hand-off. The compare-and-set is the exactly-once boundary:
    /// only `.waiting` may become `.working`; relaunch sees working and can
    /// reconcile the marker but can never enter this submit path again.
    func submitWaitingRoomAttempt(roomID: RoomID, attempt: RoomAttempt,
                                  session: RoomMemberSessionSnapshot,
                                  client: GatewayClient) async {
        let runtime = RoomRuntime.shared
        let routeGeneration = runtime.profileRouteGeneration(attempt.member)
        guard !session.running,
              runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration),
              let claimed = try? await runtime.store.mutate(roomID: roomID, { value in
                  guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                        value.attempts[index].state == .waiting,
                        value.attempts[index].member == attempt.member,
                        value.attempts[index].epoch == attempt.epoch else { throw CancellationError() }
                  if value.epoch != attempt.epoch {
                      value.attempts[index].state = .cancelled
                      value.attempts[index].finishedAt = Date()
                      value.attempts[index].outboundAttachments = []
                      return
                  }
                  value.attempts[index].state = .working
                  value.attempts[index].baselineMessageCount = session.messageCount
                  value.attempts[index].storedSessionID = session.storedID
                  value.attempts[index].runtimeSessionID = session.runtimeID
              }), let claimedAttempt = claimed.attempts.first(where: { $0.id == attempt.id })
        else { return }
        runtime.replace(claimed)
        guard claimedAttempt.state == .working else { return }
        guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else { return }
        let payloads = await roomOutboundAttachments(
            roomID: roomID, descriptors: claimedAttempt.outboundAttachments)
        let submitted: RoomPromptSubmission
        if let operation = runtime.submitOperation {
            submitted = await operation(claimedAttempt, session, payloads)
        } else {
            submitted = await client.submitRoomPrompt(
                attempt: claimedAttempt, session: session,
                profile: claimedAttempt.member.profile, attachments: payloads)
        }
        guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else { return }
        let saved = await persistRoomSubmission(
            roomID: roomID, attemptID: claimedAttempt.id,
            member: claimedAttempt.member, epoch: claimedAttempt.epoch,
            threadID: claimedAttempt.threadID, submitted: submitted,
            routeGeneration: routeGeneration)
        if saved, case .accepted = submitted.acceptance {
            await waitForRoomReply(roomID: roomID, attemptID: claimedAttempt.id)
        }
    }

    func finishRoomAttempt(roomID: RoomID, attemptID: RoomAttemptID,
                           member: RoomMember, reply: String?, delivered: Bool,
                           routeGeneration: UInt64? = nil) async {
        let runtime = RoomRuntime.shared
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member.route, generation: routeGeneration) { return }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID }),
                  current.attempts[index].finishedAt == nil,
                  current.attempts[index].member == member.route else { throw CancellationError() }
            let attempt = current.attempts[index]
            let pass = RoomEngine.isPass(reply)
            current.attempts[index].state = pass ? .passed : (delivered ? .delivered : .replied)
            current.attempts[index].finishedAt = Date()
            current.attempts[index].stagedImagePaths = []
            current.attempts[index].outboundAttachments = []
            if !pass, let reply {
                let label = member.title?.isEmpty == false ? member.title! :
                    (member.route.profile.lowercased() == "default" ? "Hermes" : member.route.profile)
                try RoomEngine.append(RoomEntry(threadID: attempt.threadID, speaker: .member,
                                                memberRoute: member.route, speakerName: label,
                                                sourceLabel: member.sourceLabel, text: reply), to: &current)
                if let driveIndex = current.drives.firstIndex(where: { $0.epoch == attempt.epoch }) {
                    current.drives[driveIndex].posted += 1
                }
            }
            current.watermarks[RoomEngine.watermarkKey(threadID: attempt.threadID,
                                                       member: member.route)] = current.entries.count
            RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch,
                                                   kind: pass ? .passed : (delivered ? .delivered : .replied),
                                                   member: member.route, threadID: attempt.threadID), in: &current)
        }) else { return }
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member.route, generation: routeGeneration) { return }
        runtime.replace(room)
    }

    func settleRoomDrive(roomID: RoomID, epoch: UInt64, threadID: RoomThreadID,
                         routeGenerations: [GatewayBotRoute: UInt64]? = nil) async {
        let runtime = RoomRuntime.shared
        if let routeGenerations,
           !acceptsRoomRouteGenerations(routeGenerations) { return }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            current.drives.removeAll { $0.epoch == epoch }
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .settled,
                                                   threadID: threadID), in: &current)
        }) else { return }
        if let routeGenerations,
           !acceptsRoomRouteGenerations(routeGenerations) { return }
        runtime.replace(room)
    }

    func persistRoomActivity(roomID: RoomID, epoch: UInt64, kind: RoomActivityKind,
                             member: GatewayBotRoute?, threadID: RoomThreadID?,
                             routeGeneration: UInt64? = nil) async {
        if let member, let routeGeneration = routeGeneration,
           !RoomRuntime.shared.acceptsProfileRoute(member, generation: routeGeneration) { return }
        guard let room = try? await RoomRuntime.shared.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: kind,
                                                   member: member, threadID: threadID), in: &current)
        }) else { return }
        if let member, let routeGeneration = routeGeneration,
           !RoomRuntime.shared.acceptsProfileRoute(member, generation: routeGeneration) { return }
        RoomRuntime.shared.replace(room)
    }

    func roomTurnPrompt(room: RoomRecord, viewer: RoomMember, delta: [RoomEntry]) -> String {
        let peers = room.members.filter { $0.route != viewer.route }.map { member in
            let title = member.title?.isEmpty == false ? "\(member.title!) (@\(member.handle))" : "@\(member.handle)"
            return member.sourceLabel.map { "\(title) [on \($0)]" } ?? title
        }.joined(separator: ", ")
        let lines = delta.map { entry -> String in
            let files = entry.attachments.map { attachment in
                let label = attachment.mediaType == "application/pdf" ? "attached PDF" :
                    (attachment.mediaType.hasPrefix("image/") ? "attached image" : "attached file")
                return "[\(label): \(attachment.fileName)]"
            }.joined(separator: " ")
            if entry.speaker == .user { return "You (user): \(entry.text) \(files)" }
            let you = entry.memberRoute == viewer.route ? " (you)" : ""
            let source = entry.sourceLabel.map { " [\($0)]" } ?? ""
            return "\(entry.speakerName)\(you)\(source): \(entry.text) \(files)"
        }
        return ([
            "[Group chat: \"\(room.name)\"] You are @\(viewer.handle), one participant in a group chat with \(peers.isEmpty ? "no one else yet" : peers) and the user.",
            "", "New messages in this thread since your last turn (oldest first):",
        ] + lines.map { "  \($0)" } + [
            "", "Rules for this room:",
            "- Reply with ONE conversational message only when you have something new worth adding. Give substantive work at full quality; keep chatter short.",
            "- If you have nothing new to add, reply with exactly \"(pass)\".",
            "- Mention a teammate as @name to pull them in; mention @user only for a judgment call or result. Do not repeat points already made.",
            "- Never reveal content from private 1:1 chats. Your reply text goes to the room verbatim."
        ]).joined(separator: "\n")
    }

    func roomOutboundAttachments(roomID: RoomID,
                                 descriptors: [RoomAttachment]) async -> [RoomOutboundAttachment] {
        let store = RoomRuntime.shared.store
        var result: [RoomOutboundAttachment] = []
        for attachment in descriptors {
            guard let data = try? await store.readBlob(roomID: roomID, attachment: attachment) else { continue }
            let kind: RoomOutboundAttachment.Kind = attachment.mediaType == "application/pdf" ? .pdf :
                (attachment.mediaType.hasPrefix("image/") ? .image : .file)
            result.append(RoomOutboundAttachment(id: attachment.id, kind: kind,
                                                 name: attachment.fileName, data: data))
        }
        return result
    }
}

import Foundation

public enum RoomStoreError: Error, Equatable, Sendable {
    case corruptIndex
    case invalidRoom(RoomID)
    case roomNotFound(RoomID)
    case attachmentNotFound
    case corruptAttachment
    case unsafePath
    case deleteCommitFailed
    case deleteCleanupFailed
}

public enum RoomStoreDeletePhase: Sendable { case beforeEmptyCommit, afterEmptyCommit }

/// Result of a source-qualified profile lifecycle mutation. The actor commits
/// the room records and metadata outbox together, then returns the published
/// snapshot for the MainActor cache to adopt without re-reading a stale copy.
public struct RoomProfileRouteMutationResult: Equatable, Sendable {
    public var rooms: [RoomRecord]
    public var migratedMutationCount: Int
    public var retiredMutationCount: Int

    public init(rooms: [RoomRecord] = [], migratedMutationCount: Int = 0,
                retiredMutationCount: Int = 0) {
        self.rooms = rooms
        self.migratedMutationCount = migratedMutationCount
        self.retiredMutationCount = retiredMutationCount
    }
}

public struct RoomStorageUsage: Equatable, Sendable {
    public var indexBytes: Int64
    public var blobBytes: Int64
    public var totalBytes: Int64 { indexBytes + blobBytes }

    public init(indexBytes: Int64 = 0, blobBytes: Int64 = 0) {
        self.indexBytes = indexBytes; self.blobBytes = blobBytes
    }
}

/// Application Support persistence for rooms. The small JSON index is replaced
/// atomically; attachment bytes live in UUID-named room directories so a large
/// image never gets copied through every transcript save.
public actor RoomStore {
    public static let maximumMetadataOutboxCount = 4_096
    private struct Envelope: Codable {
        var version: Int
        var rooms: [RoomRecord]
        var metadataOutbox: [RoomMetadataMutation]
        /// Route tombstones survive a profile delete. A later room mutation
        /// carrying the reused profile id is ignored until an explicit
        /// profile-create/activation clears this exact source route.
        var retiredMetadataRoutes: [GatewayBotRoute]
        /// Cancelled commands remain auditable in the append-only index but
        /// are excluded from all retry reads, including after activation of a
        /// reused route.
        var ignoredMetadataMutationIDs: [UUID]

        init(version: Int, rooms: [RoomRecord], metadataOutbox: [RoomMetadataMutation],
             retiredMetadataRoutes: [GatewayBotRoute],
             ignoredMetadataMutationIDs: [UUID]) {
            self.version = version; self.rooms = rooms; self.metadataOutbox = metadataOutbox
            self.retiredMetadataRoutes = retiredMetadataRoutes
            self.ignoredMetadataMutationIDs = ignoredMetadataMutationIDs
        }

        private enum CodingKeys: String, CodingKey {
            case version, rooms, metadataOutbox, retiredMetadataRoutes,
                 ignoredMetadataMutationIDs
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            rooms = try values.decode([RoomRecord].self, forKey: .rooms)
            metadataOutbox = try values.decodeIfPresent([RoomMetadataMutation].self,
                                                         forKey: .metadataOutbox) ?? []
            retiredMetadataRoutes = try values.decodeIfPresent([GatewayBotRoute].self,
                                                                forKey: .retiredMetadataRoutes) ?? []
            ignoredMetadataMutationIDs = try values.decodeIfPresent([UUID].self,
                                                                     forKey: .ignoredMetadataMutationIDs) ?? []
        }
    }

    public static let schemaVersion = 1
    /// One process-wide cache/serializer. Runtime, storage inventory, and
    /// Delete Local Data must not each invent a divergent RoomStore instance.
    public static let shared = RoomStore()

    private let fileManager: FileManager
    private let deleteFailure: (@Sendable (RoomStoreDeletePhase) throws -> Void)?
    public let rootURL: URL
    public let protectsFiles: Bool
    private var cachedRooms: [RoomID: RoomRecord]?
    private var cachedMetadataOutbox: [RoomMetadataMutation]?
    private var cachedRetiredMetadataRoutes: Set<GatewayBotRoute>?
    private var cachedIgnoredMetadataMutationIDs: Set<UUID>?

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default,
                protectsFiles: Bool? = nil,
                deleteFailure: (@Sendable (RoomStoreDeletePhase) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.deleteFailure = deleteFailure
        self.protectsFiles = protectsFiles ?? (baseDirectory == nil)
        if let baseDirectory {
            rootURL = baseDirectory.appendingPathComponent("Rooms", isDirectory: true)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
            rootURL = support.appendingPathComponent("Talaria", isDirectory: true)
                .appendingPathComponent("Rooms", isDirectory: true)
        }
    }

    private var indexURL: URL { rootURL.appendingPathComponent("rooms-v1.json") }
    private var blobsURL: URL { rootURL.appendingPathComponent("blobs", isDirectory: true) }

    /// A malformed index is an error, never an empty-room success. Returning
    /// [] would make a transient/corrupt read look like the user deleted every
    /// room and let the next save overwrite the only durable copy.
    public func loadAll() throws -> [RoomRecord] {
        if let cachedRooms { return sorted(cachedRooms.values) }
        try prepareDirectories()
        if (try? fileManager.destinationOfSymbolicLink(atPath: indexURL.path)) != nil {
            throw RoomStoreError.unsafePath
        }
        guard fileManager.fileExists(atPath: indexURL.path) else {
            cachedRooms = [:]
            cachedMetadataOutbox = []
            cachedRetiredMetadataRoutes = []
            cachedIgnoredMetadataMutationIDs = []
            return []
        }
        do {
            let values = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RoomStoreError.unsafePath
            }
        } catch let error as RoomStoreError { throw error }
        catch { throw RoomStoreError.corruptIndex }
        let data: Data
        do { data = try Data(contentsOf: indexURL, options: [.mappedIfSafe]) }
        catch { throw RoomStoreError.corruptIndex }
        let envelope: Envelope
        let decoder = JSONDecoder()
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw RoomStoreError.corruptIndex }
        guard envelope.version == Self.schemaVersion else { throw RoomStoreError.corruptIndex }

        var rooms: [RoomID: RoomRecord] = [:]
        var migrated = false
        for original in envelope.rooms {
            var room = original
            migrated = RoomEngine.migrateLegacyThreads(in: &room) || migrated
            do { try RoomEngine.validate(room) }
            catch { throw RoomStoreError.invalidRoom(room.id) }
            guard rooms.updateValue(room, forKey: room.id) == nil else {
                throw RoomStoreError.invalidRoom(room.id)
            }
            try validateAttachmentFiles(in: room)
        }
        try validateMetadataOutbox(envelope.metadataOutbox)
        try validateRetiredMetadataRoutes(envelope.retiredMetadataRoutes)
        try validateIgnoredMetadataMutationIDs(envelope.ignoredMetadataMutationIDs)
        cachedMetadataOutbox = envelope.metadataOutbox
        cachedRetiredMetadataRoutes = Set(envelope.retiredMetadataRoutes)
        cachedIgnoredMetadataMutationIDs = Set(envelope.ignoredMetadataMutationIDs)
        if migrated {
            try persist(Array(rooms.values), outbox: envelope.metadataOutbox,
                        retiredRoutes: envelope.retiredMetadataRoutes,
                        ignoredMutationIDs: envelope.ignoredMetadataMutationIDs)
        }
        cachedRooms = rooms
        return sorted(rooms.values)
    }

    public func room(id: RoomID) throws -> RoomRecord? {
        try ensureLoaded()[id]
    }

    public func metadataOutbox() throws -> [RoomMetadataMutation] {
        _ = try ensureLoaded()
        let ignored = cachedIgnoredMetadataMutationIDs ?? []
        return (cachedMetadataOutbox ?? []).filter { !ignored.contains($0.id) }
    }

    /// Routes retired by an authoritative profile deletion. The set is
    /// intentionally exposed read-only for lifecycle tests and diagnostics;
    /// mutations are made only through the actor APIs below.
    public func retiredMetadataRoutes() throws -> Set<GatewayBotRoute> {
        _ = try ensureLoaded()
        return cachedRetiredMetadataRoutes ?? []
    }

    public func removeMetadataMutation(id: UUID) throws {
        try removeMetadataMutation(id: id, matching: nil)
    }

    /// Remove an outbox item only when it is still byte-for-byte equal to the
    /// snapshot that produced the network completion. A profile rename can
    /// rewrite the same id to a new route while that completion is suspended;
    /// an unconditional id delete would erase the committed destination row.
    public func removeMetadataMutation(id: UUID,
                                       matching expected: RoomMetadataMutation?) throws {
        let rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        outbox.removeAll { current in
            guard current.id == id else { return false }
            guard let expected else { return true }
            return current == expected
        }
        try persist(Array(rooms.values), outbox: outbox,
                    retiredRoutes: Array(cachedRetiredMetadataRoutes ?? []))
        cachedMetadataOutbox = outbox
    }

    /// Explicit profile creation/recreation is the only operation that can
    /// clear a route tombstone. A stale roster refresh never activates it.
    public func activateProfileRoute(_ route: GatewayBotRoute) throws {
        _ = try ensureLoaded()
        var retired = cachedRetiredMetadataRoutes ?? []
        guard retired.remove(route) != nil else { return }
        try persist(Array((cachedRooms ?? [:]).values),
                    outbox: cachedMetadataOutbox ?? [], retiredRoutes: Array(retired))
        cachedRetiredMetadataRoutes = retired
    }

    public func upsert(_ proposed: RoomRecord,
                       metadataMutations: [RoomMetadataMutation] = []) throws {
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        let retiredRoutes = cachedRetiredMetadataRoutes ?? []
        var room = proposed
        let previousBlobIDs = rooms[room.id].map(referencedBlobIDs) ?? []
        _ = RoomEngine.migrateLegacyThreads(in: &room)
        var removedBlobIDs = pruneTranscript(&room, limit: RoomEngine.retainedEntries)
        try RoomEngine.validate(room)
        try validateAttachmentFiles(in: room)
        removedBlobIDs.formUnion(previousBlobIDs.subtracting(referencedBlobIDs(room)))
        rooms[room.id] = room
        // A route tombstone is a durable anti-reuse fence. Ignore stale
        // mutation snapshots for it; an explicit profile activation clears the
        // tombstone before a fresh room add can enter the outbox.
        outbox.append(contentsOf: metadataMutations.filter {
            !retiredRoutes.contains($0.route)
        })
        try persist(Array(rooms.values), outbox: outbox,
                    retiredRoutes: Array(retiredRoutes))
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        cachedRetiredMetadataRoutes = retiredRoutes
        // Index first, deletion second: a crash can leave an unreferenced blob
        // but can never leave a freshly-committed index pointing at one we
        // deleted before the commit.
        try? removeBlobs(removedBlobIDs, roomID: room.id)
    }

    /// Serialized read-modify-validate-persist for an existing room. Every
    /// runtime state transition uses this instead of racing whole-record
    /// snapshots through `upsert` and silently losing the earlier mutation.
    @discardableResult
    public func mutate(
        roomID: RoomID,
        metadataMutations: [RoomMetadataMutation] = [],
        _ body: @Sendable (inout RoomRecord) throws -> Void
    ) throws -> RoomRecord {
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        let retiredRoutes = cachedRetiredMetadataRoutes ?? []
        guard var room = rooms[roomID] else { throw RoomStoreError.roomNotFound(roomID) }
        let previousBlobIDs = referencedBlobIDs(room)
        try body(&room)
        _ = RoomEngine.migrateLegacyThreads(in: &room)
        var removedBlobIDs = pruneTranscript(&room, limit: RoomEngine.retainedEntries)
        try RoomEngine.validate(room)
        try validateAttachmentFiles(in: room)
        removedBlobIDs.formUnion(previousBlobIDs.subtracting(referencedBlobIDs(room)))
        rooms[roomID] = room
        outbox.append(contentsOf: metadataMutations.filter {
            !retiredRoutes.contains($0.route)
        })
        try persist(Array(rooms.values), outbox: outbox,
                    retiredRoutes: Array(retiredRoutes))
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        cachedRetiredMetadataRoutes = retiredRoutes
        try? removeBlobs(removedBlobIDs, roomID: room.id)
        return room
    }

    public func delete(roomID: RoomID,
                       metadataMutations: [RoomMetadataMutation] = []) throws {
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        let retiredRoutes = cachedRetiredMetadataRoutes ?? []
        guard rooms.removeValue(forKey: roomID) != nil else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        outbox.append(contentsOf: metadataMutations.filter {
            !retiredRoutes.contains($0.route)
        })
        try persist(Array(rooms.values), outbox: outbox,
                    retiredRoutes: Array(retiredRoutes))
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        cachedRetiredMetadataRoutes = retiredRoutes
        let directory = blobDirectory(roomID: roomID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Atomically migrate one exact profile route across every durable room
    /// projection and pending metadata command. The source gateway is part of
    /// the key, so same-named profiles on another gateway are untouched.
    @discardableResult
    public func migrateProfileRoute(from source: GatewayBotRoute,
                                    to destination: GatewayBotRoute)
        throws -> RoomProfileRouteMutationResult {
        guard source != destination else {
            return RoomProfileRouteMutationResult(rooms: sorted(try ensureLoaded().values))
        }
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        var retired = cachedRetiredMetadataRoutes ?? []
        var changed = false
        var migratedMutations = 0
        for id in rooms.keys {
            guard var room = rooms[id] else { continue }
            let before = room
            migrate(&room, from: source, to: destination)
            if room != before {
                rooms[id] = room
                changed = true
            }
        }
        for index in outbox.indices where outbox[index].route == source {
            outbox[index].route = destination
            migratedMutations += 1
            changed = true
        }
        changed = retired.remove(source) != nil || changed
        changed = retired.remove(destination) != nil || changed
        guard changed else {
            return RoomProfileRouteMutationResult(rooms: sorted(rooms.values))
        }
        try validateMetadataOutbox(outbox)
        try validateRetiredMetadataRoutes(Array(retired))
        try persist(Array(rooms.values), outbox: outbox, retiredRoutes: Array(retired))
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        cachedRetiredMetadataRoutes = retired
        return RoomProfileRouteMutationResult(
            rooms: sorted(rooms.values), migratedMutationCount: migratedMutations)
    }

    @discardableResult
    public func migrateRoute(from source: GatewayBotRoute,
                             to destination: GatewayBotRoute)
        throws -> RoomProfileRouteMutationResult {
        try migrateProfileRoute(from: source, to: destination)
    }

    @discardableResult
    public func retireProfileRoute(_ route: GatewayBotRoute)
        throws -> RoomProfileRouteMutationResult {
        let rooms = try ensureLoaded()
        let outbox = cachedMetadataOutbox ?? []
        var retired = cachedRetiredMetadataRoutes ?? []
        var ignored = cachedIgnoredMetadataMutationIDs ?? []
        guard retired.insert(route).inserted else {
            return RoomProfileRouteMutationResult(rooms: sorted(rooms.values))
        }
        let ids = outbox.filter { $0.route == route }.map(\.id)
        ignored.formUnion(ids)
        try persist(Array(rooms.values), outbox: outbox,
                    retiredRoutes: Array(retired),
                    ignoredMutationIDs: Array(ignored))
        cachedRetiredMetadataRoutes = retired
        cachedIgnoredMetadataMutationIDs = ignored
        return RoomProfileRouteMutationResult(
            rooms: sorted(rooms.values), retiredMutationCount: ids.count)
    }

    /// Atomically publish an empty index before removing the tree. If cleanup
    /// is interrupted, a fresh process sees either no store or the committed
    /// empty store — never the deleted rooms with only some blobs missing.
    public func deleteAll() throws {
        // Explicit erasure is also the recovery path for a corrupt index, so
        // it must not require decoding the data the user asked us to remove.
        do {
            try deleteFailure?(.beforeEmptyCommit)
            try persist([], outbox: [], retiredRoutes: [], ignoredMutationIDs: [])
        } catch { throw RoomStoreError.deleteCommitFailed }
        cachedRooms = [:]
        cachedMetadataOutbox = []
        cachedRetiredMetadataRoutes = []
        cachedIgnoredMetadataMutationIDs = []
        do {
            try deleteFailure?(.afterEmptyCommit)
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
        } catch { throw RoomStoreError.deleteCleanupFailed }
    }

    @discardableResult
    public func storeBlob(roomID: RoomID, data: Data, fileName: String,
                          mediaType: String, at: Date = Date()) throws -> RoomAttachment {
        guard try ensureLoaded()[roomID] != nil else { throw RoomStoreError.roomNotFound(roomID) }
        try prepareDirectories()
        let directory = blobDirectory(roomID: roomID)
        try createProtectedDirectory(directory)
        let blobID = UUID().uuidString.lowercased()
        let target = directory.appendingPathComponent(blobID, isDirectory: false)
        try writeProtected(data, to: target)
        return RoomAttachment(blobID: blobID, fileName: fileName, mediaType: mediaType,
                              byteCount: Int64(data.count), contentHash: RoomAttachment.hash(data),
                              createdAt: at)
    }

    public func readBlob(roomID: RoomID, attachment: RoomAttachment) throws -> Data {
        guard isSafeBlobID(attachment.blobID) else { throw RoomStoreError.unsafePath }
        let target = blobDirectory(roomID: roomID).appendingPathComponent(attachment.blobID)
        if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw RoomStoreError.unsafePath
        }
        guard fileManager.fileExists(atPath: target.path) else { throw RoomStoreError.attachmentNotFound }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == attachment.byteCount
        else { throw RoomStoreError.corruptAttachment }
        let data = try Data(contentsOf: target, options: [.mappedIfSafe])
        guard Int64(data.count) == attachment.byteCount,
              RoomAttachment.hash(data) == attachment.contentHash
        else { throw RoomStoreError.corruptAttachment }
        return data
    }

    /// Remove blobs no surviving entry references, including leftovers from a
    /// crash between an atomic index replacement and post-commit cleanup.
    @discardableResult
    public func pruneOrphanedBlobs() throws -> Int {
        let rooms = try ensureLoaded()
        let referenced = Set(rooms.values.flatMap { room in
            (room.entries.flatMap(\.attachments)
                + room.attempts.filter { $0.finishedAt == nil }.flatMap(\.outboundAttachments)
                + [room.avatar].compactMap { $0 })
                .map { "\(room.id.description)/\($0.blobID)" }
        })
        guard fileManager.fileExists(atPath: blobsURL.path) else { return 0 }
        var removed = 0
        let roomDirs = try fileManager.contentsOfDirectory(at: blobsURL,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        for directory in roomDirs {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for file in try fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles]) {
                let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                let key = "\(directory.lastPathComponent)/\(file.lastPathComponent)"
                if !referenced.contains(key) {
                    try fileManager.removeItem(at: file)
                    removed += 1
                }
            }
            if (try fileManager.contentsOfDirectory(atPath: directory.path)).isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
        return removed
    }

    public func storageUsage() throws -> RoomStorageUsage {
        try prepareDirectories()
        let index = fileSize(indexURL)
        var blobs: Int64 = 0
        if let enumerator = fileManager.enumerator(at: blobsURL,
                                                   includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey,
                                                                                .isSymbolicLinkKey],
                                                   options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let value = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                              .isSymbolicLinkKey])
                if value.isRegularFile == true, value.isSymbolicLink != true {
                    blobs += Int64(value.fileSize ?? 0)
                }
            }
        }
        return RoomStorageUsage(indexBytes: index, blobBytes: blobs)
    }

    private func ensureLoaded() throws -> [RoomID: RoomRecord] {
        if let cachedRooms { return cachedRooms }
        _ = try loadAll()
        return cachedRooms ?? [:]
    }

    private func persist(_ rooms: [RoomRecord],
                         outbox: [RoomMetadataMutation]? = nil,
                         retiredRoutes: [GatewayBotRoute]? = nil,
                         ignoredMutationIDs: [UUID]? = nil) throws {
        try prepareDirectories()
        let metadataOutbox = outbox ?? cachedMetadataOutbox ?? []
        let routes = retiredRoutes ?? Array(cachedRetiredMetadataRoutes ?? [])
        let ignored = ignoredMutationIDs ?? Array(cachedIgnoredMetadataMutationIDs ?? [])
        try validateMetadataOutbox(metadataOutbox)
        try validateRetiredMetadataRoutes(routes)
        try validateIgnoredMetadataMutationIDs(ignored)
        let envelope = Envelope(version: Self.schemaVersion, rooms: sorted(rooms),
                                metadataOutbox: metadataOutbox,
                                retiredMetadataRoutes: routes.sorted {
                                    $0.qualifiedID < $1.qualifiedID
                                }, ignoredMetadataMutationIDs: ignored.sorted {
                                    $0.uuidString < $1.uuidString
                                })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try writeProtected(data, to: indexURL)
    }

    private func validateAttachmentFiles(in room: RoomRecord) throws {
        let attachments = room.entries.flatMap(\.attachments)
            + room.attempts.filter { $0.finishedAt == nil }.flatMap(\.outboundAttachments)
            + [room.avatar].compactMap { $0 }
        for attachment in attachments {
            guard isSafeBlobID(attachment.blobID) else { throw RoomStoreError.invalidRoom(room.id) }
            let target = blobDirectory(roomID: room.id).appendingPathComponent(attachment.blobID)
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                throw RoomStoreError.unsafePath
            }
            let values: URLResourceValues
            do {
                values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            } catch { throw RoomStoreError.corruptAttachment }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == attachment.byteCount
            else { throw RoomStoreError.corruptAttachment }
            let data: Data
            do { data = try Data(contentsOf: target, options: [.mappedIfSafe]) }
            catch { throw RoomStoreError.corruptAttachment }
            guard RoomAttachment.hash(data) == attachment.contentHash else {
                throw RoomStoreError.corruptAttachment
            }
        }
    }

    private func validateMetadataOutbox(_ outbox: [RoomMetadataMutation]) throws {
        guard outbox.count <= Self.maximumMetadataOutboxCount,
              Set(outbox.map(\.id)).count == outbox.count,
              outbox.allSatisfy({ $0.isStructurallyValid() }) else {
            throw RoomStoreError.corruptIndex
        }
    }

    private func validateRetiredMetadataRoutes(_ routes: [GatewayBotRoute]) throws {
        guard Set(routes).count == routes.count,
              routes.allSatisfy({ route in
                  !route.gatewayID.isEmpty && !route.profile.isEmpty
                      && route == GatewayBotRoute(qualifiedID: route.qualifiedID)
              }) else { throw RoomStoreError.corruptIndex }
    }

    private func validateIgnoredMetadataMutationIDs(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else { throw RoomStoreError.corruptIndex }
    }

    /// Apply the route change to every identity-bearing projection in one
    /// in-memory record before the enclosing actor persists its index.
    private func migrate(_ room: inout RoomRecord,
                         from source: GatewayBotRoute,
                         to destination: GatewayBotRoute) {
        var changed = false
        if let index = room.members.firstIndex(where: { $0.route == source }),
           !room.members.contains(where: { $0.route == destination }) {
            let member = room.members[index]
            room.members[index] = RoomMember(route: destination, title: member.title,
                                             handle: member.handle,
                                             sourceLabel: member.sourceLabel)
            changed = true
        }
        if let index = room.formerMembers.firstIndex(where: { $0.route == source }),
           !room.formerMembers.contains(where: { $0.route == destination }) {
            let member = room.formerMembers[index]
            room.formerMembers[index] = RoomMember(route: destination, title: member.title,
                                                   handle: member.handle,
                                                   sourceLabel: member.sourceLabel)
            changed = true
        }
        for index in room.entries.indices where room.entries[index].memberRoute == source {
            room.entries[index].memberRoute = destination
            changed = true
        }
        for index in room.attempts.indices where room.attempts[index].member == source {
            let attempt = room.attempts[index]
            room.attempts[index] = RoomAttempt(
                id: attempt.id, threadID: attempt.threadID, member: destination,
                epoch: attempt.epoch, promptText: attempt.promptText,
                storedSessionID: attempt.storedSessionID,
                runtimeSessionID: attempt.runtimeSessionID,
                stagedImagePaths: attempt.stagedImagePaths,
                outboundAttachments: attempt.outboundAttachments,
                state: attempt.state, baselineMessageCount: attempt.baselineMessageCount,
                startedAt: attempt.startedAt, finishedAt: attempt.finishedAt)
            changed = true
        }
        for index in room.drives.indices {
            let mapped = room.drives[index].roundMembers.map {
                $0 == source ? destination : $0
            }
            if mapped != room.drives[index].roundMembers {
                room.drives[index].roundMembers = mapped
                changed = true
            }
        }
        for index in room.activity.indices where room.activity[index].member == source {
            room.activity[index].member = destination
            changed = true
        }
        let sourceSessionKey = source.qualifiedID
        let destinationSessionKey = destination.qualifiedID
        if let session = room.memberSessions.removeValue(forKey: sourceSessionKey) {
            if room.memberSessions[destinationSessionKey] == nil {
                room.memberSessions[destinationSessionKey] = session
            }
            changed = true
        }
        let sourceSuffix = "::\(source.qualifiedID)"
        let destinationSuffix = "::\(destination.qualifiedID)"
        var watermarks = room.watermarks
        for (key, value) in room.watermarks where key.hasSuffix(sourceSuffix) {
            let destinationKey = String(key.dropLast(sourceSuffix.count)) + destinationSuffix
            watermarks.removeValue(forKey: key)
            watermarks[destinationKey] = max(watermarks[destinationKey] ?? 0, value)
            changed = true
        }
        room.watermarks = watermarks
        if changed { room.updatedAt = Date() }
    }

    private func retire(_ room: inout RoomRecord, route: GatewayBotRoute) {
        _ = room
        _ = route
    }

    private func pruneTranscript(_ room: inout RoomRecord, limit: Int) -> Set<String> {
        guard room.entries.count > limit else {
            room.activity = Array(room.activity.filter { $0.epoch == room.epoch }.suffix(RoomEngine.activityLimit))
            return []
        }
        let drop = room.entries.count - limit
        let removed = room.entries.prefix(drop)
        room.entries.removeFirst(drop)
        for key in room.watermarks.keys {
            room.watermarks[key] = max(0, (room.watermarks[key] ?? 0) - drop)
        }
        // A transcript window may age out every visible row for a thread while
        // Hermes still owns an accepted/uncertain/waiting attempt from it.
        // Keep that thread's durable reconciliation identity until the attempt
        // finishes, and likewise keep any resumable drive cursor.
        let protectedThreadIDs = Set(room.attempts.lazy.filter { $0.finishedAt == nil }.map(\.threadID))
            .union(room.drives.map(\.threadID))
        let retainedThreadIDs = Set(room.entries.compactMap(\.threadID)).union(protectedThreadIDs)
        room.threads.removeAll { !retainedThreadIDs.contains($0.id) }
        room.attempts.removeAll { !retainedThreadIDs.contains($0.threadID) }
        room.drives.removeAll { !retainedThreadIDs.contains($0.threadID) }
        let historicalRoutes = room.members.map(\.route) + room.formerMembers.map(\.route)
        let retainedWatermarkKeys = Set(retainedThreadIDs.flatMap { threadID in
            historicalRoutes.map { RoomEngine.watermarkKey(threadID: threadID, member: $0) }
        })
        room.watermarks = room.watermarks.filter { retainedWatermarkKeys.contains($0.key) }
        room.activity = Array(room.activity.filter {
            $0.epoch == room.epoch && ($0.threadID.map(retainedThreadIDs.contains) ?? true)
        }.suffix(RoomEngine.activityLimit))
        let retained = Set((room.entries.flatMap(\.attachments)
            + room.attempts.filter { $0.finishedAt == nil }.flatMap(\.outboundAttachments)
            + [room.avatar].compactMap { $0 })
            .map(\.blobID))
        return Set(removed.flatMap(\.attachments).map(\.blobID)).subtracting(retained)
    }

    private func removeBlobs(_ ids: Set<String>, roomID: RoomID) throws {
        let directory = blobDirectory(roomID: roomID)
        for id in ids where isSafeBlobID(id) {
            let target = directory.appendingPathComponent(id)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        }
    }

    private func referencedBlobIDs(_ room: RoomRecord) -> Set<String> {
        Set((room.entries.flatMap(\.attachments)
            + room.attempts.filter { $0.finishedAt == nil }.flatMap(\.outboundAttachments)
            + [room.avatar].compactMap { $0 }).map(\.blobID))
    }

    private func prepareDirectories() throws {
        try createProtectedDirectory(rootURL)
        try createProtectedDirectory(blobsURL)
    }

    private func createProtectedDirectory(_ url: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw RoomStoreError.unsafePath
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomStoreError.unsafePath
        }
        #if os(iOS)
        if protectsFiles {
            try fileManager.setAttributes([.protectionKey:
                                            FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: url.path)
        }
        #endif
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw RoomStoreError.unsafePath
        }
        if fileManager.fileExists(atPath: url.path) {
            let existing = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard existing.isRegularFile == true, existing.isSymbolicLink != true else {
                throw RoomStoreError.unsafePath
            }
        }
        #if os(iOS)
        if protectsFiles {
            // Room reconciliation and notification-driven work must remain
            // durable after the first unlock while the phone is locked.
            try data.write(to: url,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        else { try data.write(to: url, options: [.atomic]) }
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        // The atomic protected write is already committed. Backup exclusion is
        // advisory and must not turn a successful commit into an apparent
        // failure that leaves the actor cache behind the file it just wrote.
        try? mutable.setResourceValues(values)
    }

    private func blobDirectory(roomID: RoomID) -> URL {
        blobsURL.appendingPathComponent(roomID.description, isDirectory: true)
    }

    private func isSafeBlobID(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\") && !value.contains("..")
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              value.isRegularFile == true else { return 0 }
        return Int64(value.fileSize ?? 0)
    }

    private func sorted<S: Sequence>(_ rooms: S) -> [RoomRecord] where S.Element == RoomRecord {
        rooms.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.description < $1.id.description
        }
    }
}

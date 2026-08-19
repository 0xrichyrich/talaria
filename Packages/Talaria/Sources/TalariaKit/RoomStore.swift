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

        init(version: Int, rooms: [RoomRecord], metadataOutbox: [RoomMetadataMutation]) {
            self.version = version; self.rooms = rooms; self.metadataOutbox = metadataOutbox
        }

        private enum CodingKeys: String, CodingKey { case version, rooms, metadataOutbox }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            rooms = try values.decode([RoomRecord].self, forKey: .rooms)
            metadataOutbox = try values.decodeIfPresent([RoomMetadataMutation].self,
                                                         forKey: .metadataOutbox) ?? []
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
        cachedMetadataOutbox = envelope.metadataOutbox
        if migrated { try persist(Array(rooms.values), outbox: envelope.metadataOutbox) }
        cachedRooms = rooms
        return sorted(rooms.values)
    }

    public func room(id: RoomID) throws -> RoomRecord? {
        try ensureLoaded()[id]
    }

    public func metadataOutbox() throws -> [RoomMetadataMutation] {
        _ = try ensureLoaded()
        return cachedMetadataOutbox ?? []
    }

    public func removeMetadataMutation(id: UUID) throws {
        let rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        outbox.removeAll { $0.id == id }
        try persist(Array(rooms.values), outbox: outbox)
        cachedMetadataOutbox = outbox
    }

    public func upsert(_ proposed: RoomRecord,
                       metadataMutations: [RoomMetadataMutation] = []) throws {
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        var room = proposed
        let previousBlobIDs = rooms[room.id].map(referencedBlobIDs) ?? []
        _ = RoomEngine.migrateLegacyThreads(in: &room)
        var removedBlobIDs = pruneTranscript(&room, limit: RoomEngine.retainedEntries)
        try RoomEngine.validate(room)
        try validateAttachmentFiles(in: room)
        removedBlobIDs.formUnion(previousBlobIDs.subtracting(referencedBlobIDs(room)))
        rooms[room.id] = room
        outbox.append(contentsOf: metadataMutations)
        try persist(Array(rooms.values), outbox: outbox)
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
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
        guard var room = rooms[roomID] else { throw RoomStoreError.roomNotFound(roomID) }
        let previousBlobIDs = referencedBlobIDs(room)
        try body(&room)
        _ = RoomEngine.migrateLegacyThreads(in: &room)
        var removedBlobIDs = pruneTranscript(&room, limit: RoomEngine.retainedEntries)
        try RoomEngine.validate(room)
        try validateAttachmentFiles(in: room)
        removedBlobIDs.formUnion(previousBlobIDs.subtracting(referencedBlobIDs(room)))
        rooms[roomID] = room
        outbox.append(contentsOf: metadataMutations)
        try persist(Array(rooms.values), outbox: outbox)
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        try? removeBlobs(removedBlobIDs, roomID: room.id)
        return room
    }

    public func delete(roomID: RoomID,
                       metadataMutations: [RoomMetadataMutation] = []) throws {
        var rooms = try ensureLoaded()
        var outbox = cachedMetadataOutbox ?? []
        guard rooms.removeValue(forKey: roomID) != nil else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        outbox.append(contentsOf: metadataMutations)
        try persist(Array(rooms.values), outbox: outbox)
        cachedRooms = rooms
        cachedMetadataOutbox = outbox
        let directory = blobDirectory(roomID: roomID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Atomically publish an empty index before removing the tree. If cleanup
    /// is interrupted, a fresh process sees either no store or the committed
    /// empty store — never the deleted rooms with only some blobs missing.
    public func deleteAll() throws {
        // Explicit erasure is also the recovery path for a corrupt index, so
        // it must not require decoding the data the user asked us to remove.
        do {
            try deleteFailure?(.beforeEmptyCommit)
            try persist([], outbox: [])
        } catch { throw RoomStoreError.deleteCommitFailed }
        cachedRooms = [:]
        cachedMetadataOutbox = []
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
                         outbox: [RoomMetadataMutation]? = nil) throws {
        try prepareDirectories()
        let metadataOutbox = outbox ?? cachedMetadataOutbox ?? []
        try validateMetadataOutbox(metadataOutbox)
        let envelope = Envelope(version: Self.schemaVersion, rooms: sorted(rooms),
                                metadataOutbox: metadataOutbox)
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

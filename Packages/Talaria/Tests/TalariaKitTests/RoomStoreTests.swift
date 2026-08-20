#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class RoomStoreTests: XCTestCase {
    private func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func members() -> [RoomMember] {
        [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "ops")),
        ]
    }

    func testStandaloneRoomRoundTripsWithoutProfileMetadata() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = RoomID()
        let room = RoomRecord(id: id, name: "Standalone", members: members())
        let writer = RoomStore(baseDirectory: base)
        try await writer.upsert(room)

        let reader = RoomStore(baseDirectory: base)
        let restored = try await reader.loadAll()
        XCTAssertEqual(restored.map(\.id), [id])
        XCTAssertEqual(restored.first?.name, "Standalone")
    }

    func testMalformedIndexFailsClosedInsteadOfReturningEmpty() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: root.appendingPathComponent("rooms-v1.json"))
        let store = RoomStore(baseDirectory: base)
        do {
            _ = try await store.loadAll()
            XCTFail("corrupt index must not masquerade as an empty store")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }

    func testBlobIsSeparateProtectedStorageAndAccountingIsExact() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Files", members: members())
        try await store.upsert(room)
        let payload = Data("room attachment secret bytes".utf8)
        let attachment = try await store.storeBlob(roomID: room.id, data: payload,
                                                   fileName: "note.txt", mediaType: "text/plain")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "attached", attachments: [attachment])]
        try await store.upsert(room)

        let restoredPayload = try await store.readBlob(roomID: room.id, attachment: attachment)
        XCTAssertEqual(restoredPayload, payload)
        let usage = try await store.storageUsage()
        XCTAssertEqual(usage.blobBytes, Int64(payload.count))
        XCTAssertGreaterThan(usage.indexBytes, 0)
        XCTAssertEqual(usage.totalBytes, usage.indexBytes + Int64(payload.count))
        let index = try String(contentsOf: base.appendingPathComponent("Rooms/rooms-v1.json"),
                               encoding: .utf8)
        XCTAssertFalse(index.contains("room attachment secret bytes"))
        // Injected stores are deterministic test fixtures and remain writable
        // even when the macOS login session is locked. Real Application
        // Support storage always enables complete file protection.
        let injectedProtectsFiles = await store.protectsFiles
        let applicationProtectsFiles = await RoomStore().protectsFiles
        XCTAssertFalse(injectedProtectsFiles)
        XCTAssertTrue(applicationProtectsFiles)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("Rooms/rooms-v1.json.tmp").path))
    }

    func testTranscriptPruningDeletesOnlyUnreferencedBlobAndAdjustsWatermark() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Bounded", members: members())
        try await store.upsert(room)
        let first = try await store.storeBlob(roomID: room.id, data: Data([1]),
                                              fileName: "old", mediaType: "application/octet-stream")
        let retained = try await store.storeBlob(roomID: room.id, data: Data([2, 3]),
                                                 fileName: "new", mediaType: "application/octet-stream")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = (0...RoomEngine.retainedEntries).map { index in
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "\(index)",
                      attachments: index == 0 ? [first] : (index == 1 ? [retained] : []))
        }
        let mark = RoomEngine.watermarkKey(threadID: thread.id, member: room.members[0].route)
        room.watermarks = [mark: room.entries.count]
        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, RoomEngine.retainedEntries)
        XCTAssertEqual(restored.entries.first?.attachments, [retained])
        XCTAssertEqual(restored.watermarks[mark], RoomEngine.retainedEntries)
        do {
            _ = try await store.readBlob(roomID: room.id, attachment: first)
            XCTFail("pruned blob should be removed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .attachmentNotFound) }
        let retainedPayload = try await store.readBlob(roomID: room.id, attachment: retained)
        XCTAssertEqual(retainedPayload, Data([2, 3]))
    }

    func testPruningRetainsUnfinishedAttemptAndRemovesOrphanWatermark() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let old = RoomThread(createdAt: Date(timeIntervalSince1970: 1))
        let abandoned = RoomThread(createdAt: Date(timeIntervalSince1970: 2))
        let current = RoomThread(createdAt: Date(timeIntervalSince1970: 3))
        let routes = members()
        let attempt = RoomAttempt(threadID: old.id, member: routes[0].route, epoch: 1,
                                  promptText: "reconcile exactly", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .uncertain)
        var entries = [
            RoomEntry(threadID: old.id, speaker: .user, speakerName: "You", text: "old"),
            RoomEntry(threadID: abandoned.id, speaker: .user, speakerName: "You", text: "done"),
        ]
        entries += (0..<RoomEngine.retainedEntries).map {
            RoomEntry(threadID: current.id, speaker: .user, speakerName: "You", text: "new-\($0)")
        }
        let oldMark = RoomEngine.watermarkKey(threadID: old.id, member: routes[0].route)
        let abandonedMark = RoomEngine.watermarkKey(threadID: abandoned.id, member: routes[0].route)
        let room = RoomRecord(name: "Reconcile", members: routes,
                              threads: [old, abandoned, current], entries: entries,
                              attempts: [attempt], watermarks: [oldMark: 1, abandonedMark: 2],
                              epoch: 1)

        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, RoomEngine.retainedEntries)
        XCTAssertTrue(restored.threads.contains { $0.id == old.id })
        XCTAssertFalse(restored.threads.contains { $0.id == abandoned.id })
        XCTAssertEqual(restored.attempts.first?.id, attempt.id)
        XCTAssertEqual(restored.attempts.first?.state, .uncertain)
        XCTAssertEqual(restored.watermarks[oldMark], 0)
        XCTAssertNil(restored.watermarks[abandonedMark])
        XCTAssertNoThrow(try RoomEngine.validate(restored))
    }

    func testPrunedEntryBlobSurvivesUntilExactAttemptFinishes() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let old = RoomThread(createdAt: Date(timeIntervalSince1970: 1))
        let current = RoomThread(createdAt: Date(timeIntervalSince1970: 2))
        let routes = members()
        var room = RoomRecord(name: "Exact payload", members: routes,
                              threads: [old, current], epoch: 1)
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7, 8, 9]),
                                                   fileName: "payload.png", mediaType: "image/png")
        let attempt = RoomAttempt(threadID: old.id, member: routes[0].route, epoch: 1,
                                  promptText: "wait with image", storedSessionID: "stored",
                                  runtimeSessionID: "runtime",
                                  outboundAttachments: [attachment], state: .waiting)
        room.entries = [
            RoomEntry(threadID: old.id, speaker: .user, speakerName: "You", text: "old",
                      attachments: [attachment]),
        ] + (0..<RoomEngine.retainedEntries).map {
            RoomEntry(threadID: current.id, speaker: .user, speakerName: "You", text: "new-\($0)")
        }
        room.attempts = [attempt]
        try await store.upsert(room)

        let loaded = try await store.room(id: room.id)
        let afterPrune = try XCTUnwrap(loaded)
        XCTAssertFalse(afterPrune.entries.flatMap(\.attachments).contains(attachment))
        XCTAssertEqual(afterPrune.attempts.first?.outboundAttachments, [attachment])
        let payload = try await store.readBlob(roomID: room.id, attachment: attachment)
        XCTAssertEqual(payload, Data([7, 8, 9]))

        _ = try await store.mutate(roomID: room.id) { value in
            value.attempts[0].state = .cancelled
            value.attempts[0].finishedAt = Date()
            value.attempts[0].outboundAttachments = []
        }
        do {
            _ = try await store.readBlob(roomID: room.id, attachment: attachment)
            XCTFail("terminal attempt must release its no-longer-referenced blob")
        } catch { XCTAssertEqual(error as? RoomStoreError, .attachmentNotFound) }
    }

    func testMissingReferencedBlobFailsClosedOnFreshLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Missing", members: members())
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7]),
                                                   fileName: "x", mediaType: "x/test")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "x", attachments: [attachment])]
        try await store.upsert(room)
        let blob = base.appendingPathComponent("Rooms/blobs/\(room.id.description)/\(attachment.blobID)")
        try FileManager.default.removeItem(at: blob)
        let reader = RoomStore(baseDirectory: base)
        do {
            _ = try await reader.loadAll()
            XCTFail("missing referenced bytes must not load as healthy")
        } catch { XCTAssertEqual(error as? RoomStoreError, .corruptAttachment) }
    }

    func testSameSizeBlobTamperingFailsHashValidation() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Tamper", members: members())
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7]),
                                                   fileName: "x", mediaType: "x/test")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "x", attachments: [attachment])]
        try await store.upsert(room)
        let blob = base.appendingPathComponent("Rooms/blobs/\(room.id.description)/\(attachment.blobID)")
        try Data([8]).write(to: blob)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("same-size content corruption must not pass the size check")
        } catch { XCTAssertEqual(error as? RoomStoreError, .corruptAttachment) }
    }

    func testOrphanPruningAndRoomDeletionReclaimStorage() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Delete", members: members())
        try await store.upsert(room)
        _ = try await store.storeBlob(roomID: room.id, data: Data([1, 2, 3]),
                                      fileName: "orphan", mediaType: "x/test")
        let pruned = try await store.pruneOrphanedBlobs()
        XCTAssertEqual(pruned, 1)
        let usage = try await store.storageUsage()
        XCTAssertEqual(usage.blobBytes, 0)
        try await store.delete(roomID: room.id)
        let rooms = try await store.loadAll()
        XCTAssertTrue(rooms.isEmpty)
        do {
            try await store.delete(roomID: room.id)
            XCTFail("second delete must identify missing room")
        } catch { XCTAssertEqual(error as? RoomStoreError, .roomNotFound(room.id)) }
    }

    func testDeleteAllRemovesIndexBlobsAndReloadsEmpty() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Erase", members: members())
        try await store.upsert(room)
        room.avatar = try await store.storeBlob(roomID: room.id, data: Data([4, 5, 6]),
                                                fileName: "room.png", mediaType: "image/png")
        try await store.upsert(room)
        let intact = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(intact.first?.avatar, room.avatar)
        let before = try await store.storageUsage()
        XCTAssertGreaterThan(before.totalBytes, 0)

        try await store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Rooms").path))
        let cached = try await store.loadAll()
        XCTAssertTrue(cached.isEmpty)
        let fresh = RoomStore(baseDirectory: base)
        let reloaded = try await fresh.loadAll()
        XCTAssertTrue(reloaded.isEmpty)
        let after = try await fresh.storageUsage()
        XCTAssertEqual(after, RoomStorageUsage())
    }

    func testDeleteAllRecoversCorruptIndex() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("rooms-v1.json"))
        let store = RoomStore(baseDirectory: base)
        try await store.deleteAll()
        let rooms = try await store.loadAll()
        XCTAssertTrue(rooms.isEmpty)
    }

    func testAtomicMutationDoesNotLoseConcurrentEntries() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let thread = RoomThread()
        let room = RoomRecord(name: "Serialized", members: members(), threads: [thread])
        try await store.upsert(room)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await store.mutate(roomID: room.id) { record in
                        let entry = RoomEntry(threadID: thread.id, speaker: .user,
                                              speakerName: "You", text: "entry-\(index)")
                        try RoomEngine.append(entry, to: &record)
                    }
                }
            }
            try await group.waitForAll()
        }
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, 20)
        XCTAssertEqual(Set(restored.entries.map(\.text)).count, 20)
    }

    func testSymlinkedStoreAndIndexFailClosed() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("Rooms", isDirectory: true),
            withDestinationURL: outside)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("symlinked root must fail closed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .unsafePath) }

        try FileManager.default.removeItem(at: base.appendingPathComponent("Rooms"))
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("outside-index")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("rooms-v1.json"), withDestinationURL: target)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("symlinked index must fail closed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .unsafePath) }
    }

    func testLegacyThreadMigrationIsPersistedOnLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Legacy", members: members(), entries: [
            RoomEntry(speaker: .user, speakerName: "You", text: "hello")
        ])
        // Upsert itself migrates, proving callers cannot persist threadless
        // records; a fresh reader sees the same stable id.
        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        room = try XCTUnwrap(loaded)
        let threadID = try XCTUnwrap(room.entries.first?.threadID)
        let reader = RoomStore(baseDirectory: base)
        let restored = try await reader.room(id: room.id)
        XCTAssertEqual(restored?.entries.first?.threadID, threadID)
    }

    func testLiteralPreThreadWireShapeDecodesAndMigrates() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let room = RoomRecord(name: "Legacy wire", members: members(), entries: [
            RoomEntry(speaker: .user, speakerName: "You", text: "before threads")
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(room)) as? [String: Any])
        for key in ["formerMembers", "avatar", "threads", "attempts", "drives", "activity",
                    "memberSessions", "watermarks", "epoch", "needsUser", "updatedAt"] {
            object.removeValue(forKey: key)
        }
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "threadID")
        entries[0].removeValue(forKey: "sourceLabel")
        entries[0].removeValue(forKey: "attachments")
        object["entries"] = entries
        let envelope: [String: Any] = ["version": RoomStore.schemaVersion, "rooms": [object]]
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: root.appendingPathComponent("rooms-v1.json"))

        let store = RoomStore(baseDirectory: base)
        let loaded = try await store.loadAll()
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, room.id)
        XCTAssertEqual(restored.entries.first?.attachments, [])
        XCTAssertNotNil(restored.entries.first?.threadID)
        XCTAssertEqual(restored.threads.count, 1)
        XCTAssertNoThrow(try RoomEngine.validate(restored))

        let persisted = try String(contentsOf: root.appendingPathComponent("rooms-v1.json"),
                                   encoding: .utf8)
        XCTAssertTrue(persisted.contains("\"threads\""))
        XCTAssertTrue(persisted.contains("\"attachments\""))
    }

    func testMetadataOutboxIsAtomicWithRoomCreateAndDisband() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Fleet", members: members())
        let add = RoomMetadataMutation(route: room.members[0].route,
                                       kind: .add, newName: room.name)
        try await store.upsert(room, metadataMutations: [add])

        let fresh = RoomStore(baseDirectory: base)
        let createdOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(createdOutbox, [add])
        let remove = RoomMetadataMutation(route: room.members[0].route,
                                          kind: .remove, oldName: room.name)
        try await fresh.delete(roomID: room.id, metadataMutations: [remove])
        let deletedRoom = try await fresh.room(id: room.id)
        let deletedOutbox = try await fresh.metadataOutbox()
        XCTAssertNil(deletedRoom)
        XCTAssertEqual(deletedOutbox, [add, remove])

        try await fresh.removeMetadataMutation(id: add.id)
        let remainingOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(remainingOutbox, [remove])
        try await fresh.deleteAll()
        let erased = RoomStore(baseDirectory: base)
        let erasedOutbox = try await erased.metadataOutbox()
        XCTAssertEqual(erasedOutbox, [])
    }

    func testProfileRouteMigrationRekeysEveryRoomProjectionAndOnlyExactOutboxRoutes()
        async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "new")
        let sibling = GatewayBotRoute(gatewayID: "lab", profile: "old")
        let sourceMember = RoomMember(route: source, handle: "old")
        let siblingMember = RoomMember(route: sibling, handle: "old-lab")
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: source, epoch: 1,
                                  promptText: "pending", storedSessionID: "stored-old",
                                  runtimeSessionID: "runtime-old", state: .accepted)
        let sourceWatermark = RoomEngine.watermarkKey(threadID: thread.id, member: source)
        let siblingWatermark = RoomEngine.watermarkKey(threadID: thread.id, member: sibling)
        let room = RoomRecord(name: "Fleet", members: [sourceMember, siblingMember],
                              threads: [thread], entries: [
                                  RoomEntry(threadID: thread.id, speaker: .member,
                                            memberRoute: source, speakerName: "old",
                                            text: "hello")
                              ], attempts: [attempt], drives: [
                                  RoomDriveState(threadID: thread.id, epoch: 1,
                                                 roundMembers: [source, sibling],
                                                 nextMemberIndex: 1)
                              ], activity: [
                                  RoomActivity(epoch: 1, kind: .working, member: source,
                                               threadID: thread.id)
                              ], memberSessions: [source.qualifiedID: "stored-old",
                                                  sibling.qualifiedID: "stored-lab"],
                              watermarks: [sourceWatermark: 1, siblingWatermark: 1], epoch: 1)
        let sourceMutation = RoomMetadataMutation(route: source, kind: .rename,
                                                  oldName: "Fleet", newName: "Fleet 2")
        let siblingMutation = RoomMetadataMutation(route: sibling, kind: .rename,
                                                   oldName: "Fleet", newName: "Fleet 2")
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room, metadataMutations: [sourceMutation, siblingMutation])

        let result = try await store.migrateProfileRoute(from: source, to: destination)
        let migrated = try XCTUnwrap(result.rooms.first)
        XCTAssertEqual(migrated.members.map(\.route), [destination, sibling])
        XCTAssertEqual(migrated.entries.first?.memberRoute, destination)
        XCTAssertEqual(migrated.attempts.first?.member, destination)
        XCTAssertEqual(migrated.drives.first?.roundMembers, [destination, sibling])
        XCTAssertEqual(migrated.activity.first?.member, destination)
        XCTAssertEqual(migrated.memberSessions[destination.qualifiedID], "stored-old")
        XCTAssertNil(migrated.memberSessions[source.qualifiedID])
        XCTAssertEqual(migrated.watermarks[RoomEngine.watermarkKey(threadID: thread.id,
                                                                   member: destination)], 1)
        XCTAssertEqual(migrated.watermarks[siblingWatermark], 1)
        XCTAssertNil(migrated.watermarks[sourceWatermark])

        let outbox = try await store.metadataOutbox()
        XCTAssertEqual(outbox.map(\.route), [destination, sibling])
        XCTAssertEqual(result.migratedMutationCount, 1)
        let fresh = RoomStore(baseDirectory: base)
        let freshOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(freshOutbox.map(\.route), [destination, sibling])
        _ = try await fresh.loadAll()
    }

    func testProfileRouteRetirementMovesSeatAndSettlesDurableWork() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let sibling = GatewayBotRoute(gatewayID: "lab", profile: "peer")
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: source, epoch: 1,
                                  promptText: "pending", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .working)
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: source), RoomMember(route: sibling)
        ], threads: [thread], entries: [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "go")
        ], attempts: [attempt], drives: [
            RoomDriveState(threadID: thread.id, epoch: 1,
                           roundMembers: [source, sibling], nextMemberIndex: 1)
        ], epoch: 1)
        let mutation = RoomMetadataMutation(route: source, kind: .rename,
                                            oldName: "Fleet", newName: "Fleet 2")
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room, metadataMutations: [mutation])

        _ = try await store.retireProfileRoute(source)
        let retiredValue = try await store.room(id: room.id)
        let retired = try XCTUnwrap(retiredValue)
        XCTAssertEqual(retired.members.map(\.route), [sibling])
        XCTAssertEqual(retired.formerMembers.map(\.route), [source])
        XCTAssertEqual(retired.attempts.first?.state, .cancelled)
        XCTAssertNotNil(retired.attempts.first?.finishedAt)
        XCTAssertTrue(retired.drives.isEmpty)
        let pending = try await store.metadataOutbox()
        XCTAssertTrue(pending.isEmpty)
        let retiredRoutes = try await store.retiredMetadataRoutes()
        XCTAssertEqual(retiredRoutes, [source])
        XCTAssertNoThrow(try RoomEngine.validate(retired))
    }

    func testProfileRouteMigrationDedupesLiveDestinationDriveCursor() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "new")
        let peer = GatewayBotRoute(gatewayID: "lab", profile: "peer")
        let thread = RoomThread()
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: source), RoomMember(route: destination), RoomMember(route: peer)
        ], threads: [thread], entries: [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "go")
        ], drives: [RoomDriveState(threadID: thread.id, epoch: 1,
                                   roundMembers: [source, destination, peer],
                                   nextMemberIndex: 1)], epoch: 1)
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room)
        let result = try await store.migrateProfileRoute(from: source, to: destination)
        let migrated = try XCTUnwrap(result.rooms.first)
        XCTAssertEqual(migrated.drives.first?.roundMembers, [destination, peer])
        XCTAssertEqual(migrated.drives.first?.nextMemberIndex, 1)
        XCTAssertNoThrow(try RoomEngine.validate(migrated))
    }

    func testMetadataRenamePreservesOrderedLegacyProjectionAndDedupes() {
        let renamed = BotModeMeta.replacingGroup("A", with: "C", in: ["A", "B"])
        XCTAssertEqual(renamed, ["C", "B"])
        XCTAssertEqual(BotModeMeta.membershipProjection(renamed)["group"], .string("C"))
        XCTAssertEqual(BotModeMeta.replacingGroup("A", with: "B", in: ["A", "B"]), ["B"])
    }

    func testMetadataOutboxRejectsMalformedDuplicateAndOversizedCommands() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Fleet", members: members())
        let valid = RoomMetadataMutation(route: room.members[0].route,
                                         kind: .add, newName: room.name)
        let malformed = RoomMetadataMutation(route: room.members[0].route,
                                             kind: .rename, oldName: "Fleet", newName: " ")
        do { try await store.upsert(room, metadataMutations: [malformed]); XCTFail("accepted malformed") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
        do { try await store.upsert(room, metadataMutations: [valid, valid]); XCTFail("accepted duplicate") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
        let oversized = (0...RoomStore.maximumMetadataOutboxCount).map { offset in
            RoomMetadataMutation(route: room.members[0].route, kind: .add,
                                 newName: "R\(offset)")
        }
        do { try await store.upsert(room, metadataMutations: oversized); XCTFail("accepted oversized") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
    }

    func testMalformedPersistedMetadataOutboxFailsClosedOnLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let room = RoomRecord(name: "Fleet", members: members())
        let valid = RoomMetadataMutation(route: room.members[0].route,
                                         kind: .add, newName: room.name)
        try await RoomStore(baseDirectory: base).upsert(room, metadataMutations: [valid])
        let indexURL = base.appendingPathComponent("Rooms/rooms-v1.json")
        let data = try Data(contentsOf: indexURL)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var outbox = try XCTUnwrap(root["metadataOutbox"] as? [[String: Any]])
        outbox[0]["newName"] = ""
        root["metadataOutbox"] = outbox
        try JSONSerialization.data(withJSONObject: root).write(to: indexURL, options: .atomic)

        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("malformed durable outbox must fail closed")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }
}
#endif

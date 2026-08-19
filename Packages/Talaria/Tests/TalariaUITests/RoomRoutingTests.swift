#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor RoomDriveProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var starts: [RoomID] = []

    func begin(_ id: RoomID) {
        active += 1
        maximumActive = max(maximumActive, active)
        starts.append(id)
    }

    func end() { active -= 1 }
}

private actor RoomSubmitProbe {
    private(set) var calls = 0
    private(set) var sawWorking = false
    func record(working: Bool) { calls += 1; sawWorking = sawWorking || working }
}

@MainActor
final class RoomRoutingTests: XCTestCase {
    override func tearDown() {
        let runtime = RoomRuntime.shared
        for task in runtime.driveTasks.values { task.cancel() }
        runtime.driveTasks.removeAll()
        runtime.driveTokens.removeAll()
        runtime.driveOperation = nil
        runtime.loadOperation = nil
        runtime.submitOperation = nil
        runtime.store = RoomStore.shared
        runtime.pollInterval = .seconds(2)
        runtime.rooms = []
        runtime.openRoomID = nil
        super.tearDown()
    }

    func testRoomDrivesWaitForActualPriorCompletion() async {
        let runtime = RoomRuntime.shared
        let model = AppModel()
        let roomID = RoomID()
        let probe = RoomDriveProbe()
        runtime.driveOperation = { _, id in
            await probe.begin(id)
            try? await Task.sleep(for: .milliseconds(60))
            await probe.end()
        }

        model.scheduleRoomDrive(roomID: roomID)
        model.scheduleRoomDrive(roomID: roomID)
        await runtime.driveTasks[roomID]?.value

        let maximum = await probe.maximumActive
        let starts = await probe.starts
        XCTAssertEqual(maximum, 1, "A 250 ms timer hand-off would allow overlapping owners")
        XCTAssertEqual(starts, [roomID, roomID])
    }

    func testRoomMutationGateDropsCancelledWaiterWithoutWedgingNext() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }

        var cancelledRan = false
        let cancelled = Task { @MainActor in
            try? await gate.withLock("room") { cancelledRan = true }
        }
        await Task.yield()
        var finalRan = false
        let final = Task { @MainActor in
            try? await gate.withLock("room") { finalRan = true }
        }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(cancelledRan)
        XCTAssertFalse(finalRan)

        releaseOwner?.resume()
        await owner.value
        await final.value
        XCTAssertTrue(finalRan)
    }

    func testRoomMutationCancellationAfterGrantReleasesKey() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }
        var cancelledRan = false
        let cancelled = Task { @MainActor in
            try? await gate.withLock("room") { cancelledRan = true }
        }
        while gate.queuedWaiterCount(for: "room") == 0 { await Task.yield() }

        releaseOwner?.resume()
        cancelled.cancel()
        await owner.value
        await cancelled.value
        XCTAssertFalse(cancelledRan)

        var finalRan = false
        try? await gate.withLock("room") { finalRan = true }
        XCTAssertTrue(finalRan)
    }

    func testRoomQuiescenceDrainsOwnerAndBlocksNewMutationUntilDeletionEnds() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room-a") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }

        var quiescenceEntered = false
        var releaseQuiescence: CheckedContinuation<Void, Never>?
        let deletion = Task { @MainActor in
            await gate.withQuiescence {
                quiescenceEntered = true
                await withCheckedContinuation { releaseQuiescence = $0 }
            }
        }
        await Task.yield()
        var laterMutationRan = false
        let later = Task { @MainActor in
            try? await gate.withLock("room-b") { laterMutationRan = true }
        }
        await Task.yield()
        XCTAssertFalse(quiescenceEntered)
        XCTAssertFalse(laterMutationRan)

        releaseOwner?.resume()
        await owner.value
        while releaseQuiescence == nil { await Task.yield() }
        XCTAssertTrue(quiescenceEntered)
        XCTAssertFalse(laterMutationRan)

        releaseQuiescence?.resume()
        await deletion.value
        await later.value
        XCTAssertTrue(laterMutationRan)
    }

    func testRoomLoadCannotRepublishSnapshotAcrossLocalDataDeletion() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-load-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.isLoaded = false
        let room = RoomRecord(name: "Snapshot", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        var releaseLoad: CheckedContinuation<Void, Never>?
        runtime.loadOperation = {
            await withCheckedContinuation { releaseLoad = $0 }
            return [room]
        }
        let model = AppModel()
        let load = Task { @MainActor in await model.loadRooms() }
        while releaseLoad == nil { await Task.yield() }
        let deletion = Task { @MainActor in try await model.deleteAllRoomData() }
        await Task.yield()

        releaseLoad?.resume()
        await load.value
        try await deletion.value
        XCTAssertTrue(runtime.rooms.isEmpty)
        XCTAssertFalse(runtime.isLoaded)
        let erased = try await store.loadAll()
        XCTAssertEqual(erased, [])
    }

    func testRoomDeletionFailsClosedBeforeEmptyCommitAndPreservesRuntime() async throws {
        enum Injected: Error { case stop }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-delete-precommit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base, deleteFailure: { phase in
            if case .beforeEmptyCommit = phase { throw Injected.stop }
        })
        let members = [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ]
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: members[0].route, epoch: 1,
                                  promptText: "accepted already", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Private", members: members, threads: [thread],
                              attempts: [attempt], drives: [
                                RoomDriveState(threadID: thread.id, epoch: 1)
                              ], epoch: 1)
        try await store.upsert(room)
        RoomRuntime.shared.store = store
        RoomRuntime.shared.rooms = [room]
        RoomRuntime.shared.driveTasks[room.id] = Task {}
        RoomRuntime.shared.driveTokens[room.id] = UUID()
        var resumedOwners = 0
        var submissions = 0
        RoomRuntime.shared.driveOperation = { _, _ in resumedOwners += 1 }
        RoomRuntime.shared.submitOperation = { _, _, _ in
            submissions += 1
            return RoomPromptSubmission(acceptance: .uncertain("must not run"),
                                        runtimeID: "runtime", storedID: "stored", baseline: 0)
        }
        defer {
            RoomRuntime.shared.driveOperation = nil
            RoomRuntime.shared.submitOperation = nil
            RoomRuntime.shared.driveTasks.removeAll()
            RoomRuntime.shared.driveTokens.removeAll()
        }
        let model = AppModel()
        do { try await model.deleteAllRoomData(); XCTFail("reported false erasure") }
        catch { XCTAssertEqual(error as? RoomStoreError, .deleteCommitFailed) }
        for _ in 0..<1_000 where resumedOwners == 0 { await Task.yield() }
        XCTAssertEqual(resumedOwners, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(RoomRuntime.shared.rooms.map(\.id), [room.id])
        let preserved = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(preserved.map(\.id), [room.id])
    }

    func testRoomDeletionSurfacesCleanupFailureAfterAuthoritativeEmptyCommit() async throws {
        enum Injected: Error { case stop }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-delete-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base, deleteFailure: { phase in
            if case .afterEmptyCommit = phase { throw Injected.stop }
        })
        let room = RoomRecord(name: "Private", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        RoomRuntime.shared.store = store
        RoomRuntime.shared.rooms = [room]
        do { try await AppModel().deleteAllRoomData(); XCTFail("hid residual cleanup") }
        catch { XCTAssertEqual(error as? RoomStoreError, .deleteCleanupFailed) }
        XCTAssertTrue(RoomRuntime.shared.rooms.isEmpty)
        let erased = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(erased, [])
    }

    func testExactAttemptAnchorAndPromptHashReconcileAcceptance() {
        let attempt = makeAttempt(prompt: "Exact room delta")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText
                        + "\n\nAttached files staged in your session workspace:\na → @file:a"),
            ], running: false)

        XCTAssertTrue(snapshot.containsAttempt(attempt))

        let forged = RoomAttempt(threadID: attempt.threadID, member: attempt.member,
                                 epoch: attempt.epoch, promptText: "Different delta",
                                 storedSessionID: "stored", runtimeSessionID: "deadbeef")
        let sameMarkerWrongBody = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: forged.promptAnchor + "\nnot the persisted prompt"),
            ], running: false)
        XCTAssertFalse(sameMarkerWrongBody.containsAttempt(forged))
    }

    func testRoomSessionResolverNeverCreatesAfterTransientResumeFailure() async {
        var resumes: [String] = []
        var creates = 0
        do {
            _ = try await RoomSessionResolver.resolve(
                storedID: "durable", title: "Group: Team",
                resume: { target -> String in
                    resumes.append(target)
                    throw GatewayError(code: -3, message: "offline")
                },
                create: { creates += 1; return "created" })
            XCTFail("Transient durable resume must propagate")
        } catch {}
        XCTAssertEqual(resumes, ["durable"])
        XCTAssertEqual(creates, 0)

        resumes = []; creates = 0
        do {
            _ = try await RoomSessionResolver.resolve(
                storedID: "gone", title: "Group: Team",
                resume: { target -> String in
                    resumes.append(target)
                    if target == "gone" {
                        throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
                    }
                    throw GatewayError(code: -3, message: "offline")
                },
                create: { creates += 1; return "created" })
            XCTFail("Transient title resume must propagate")
        } catch {}
        XCTAssertEqual(resumes, ["gone", "Group: Team"])
        XCTAssertEqual(creates, 0)
    }

    func testRoomSessionResolverCreatesOnlyAfterBothTargetsAreDefinitelyMissing() async throws {
        var resumes: [String] = []
        var creates = 0
        let result = try await RoomSessionResolver.resolve(
            storedID: "gone", title: "Group: Team",
            resume: { target -> String in
                resumes.append(target)
                throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
            },
            create: { creates += 1; return "created" })
        XCTAssertEqual(result, "created")
        XCTAssertEqual(resumes, ["gone", "Group: Team"])
        XCTAssertEqual(creates, 1)
    }

    func testReplyMustFollowExactAnchorBeforeAnyLaterUserTurn() {
        let attempt = makeAttempt(prompt: "Room turn")
        let unrelated = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText),
                message(role: "user", text: "unrelated later turn"),
                message(role: "assistant", text: "not the room reply"),
            ], running: false)
        XCTAssertNil(unrelated.assistantReply(for: attempt))

        let causal = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText),
                message(role: "assistant", text: "room answer"),
                message(role: "user", text: "later"),
                message(role: "assistant", text: "later answer"),
            ], running: false)
        XCTAssertEqual(causal.assistantReply(for: attempt), "room answer")
    }

    func testRoomNavigationIdentitySurvivesRename() {
        let id = RoomID()
        let routeA = GatewayBotRoute(gatewayID: "mini", profile: "default")
        let routeB = GatewayBotRoute(gatewayID: "lab", profile: "default")
        var room = RoomRecord(id: id, name: "Old name", members: [
            RoomMember(route: routeA), RoomMember(route: routeB, handle: "hermes-lab"),
        ])
        room.name = "New name"
        XCTAssertEqual(room.id, id)
        XCTAssertNotEqual(room.members[0].route, room.members[1].route)
    }

    func testConcurrentUserSendsAppendBothWithoutClobberingEpoch() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.driveOperation = { _, _ in }
        let model = AppModel()
        let room = RoomRecord(name: "Team", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        runtime.replace(room)

        async let first = model.sendRoomMessage(roomID: room.id, text: "first")
        async let second = model.sendRoomMessage(roomID: room.id, text: "second")
        _ = try await (first, second)
        await runtime.driveTasks[room.id]?.value

        let loaded = try await store.room(id: room.id)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(Set(persisted.entries.map(\.text)), ["first", "second"])
        XCTAssertEqual(persisted.entries.count, 2)
        XCTAssertEqual(persisted.threads.count, 2)
        XCTAssertEqual(persisted.epoch, 2)
        try await store.deleteAll()
    }

    func testSupersededAcceptedTurnDoesNotHoldNewDriveUntilTimeout() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-supersede-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.pollInterval = .seconds(10)
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "old turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 2)
        try await store.upsert(room)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await model.waitForRoomReply(roomID: room.id, attemptID: attempt.id)
        }
        XCTAssertLessThan(elapsed, .milliseconds(100))
        try await store.deleteAll()
    }

    func testRoomNamesAreCappedAndCreationSuffixesCollisions() throws {
        XCTAssertEqual(try RoomNamePolicy.unique("Ops", existing: ["ops", "Ops 2"]), "Ops 3")
        XCTAssertEqual(try RoomNamePolicy.normalized(String(repeating: "x", count: 80)).count, 64)
        XCTAssertThrowsError(try RoomNamePolicy.normalized("  "))
    }

    func testBusyAttemptSubmitsOnceAfterIdleAndWorkingNeverResubmits() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-waiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.pollInterval = .milliseconds(1)
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "persisted delta", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .waiting)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room)
        let probe = RoomSubmitProbe()
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        let index = root.appendingPathComponent("rooms-v1.json")
        let backup = root.appendingPathComponent("rooms-v1.backup")
        let sentinel = base.appendingPathComponent("sentinel")
        try Data("do-not-overwrite".utf8).write(to: sentinel)
        runtime.submitOperation = { claimed, session, _ in
            let loaded = try? await store.room(id: room.id)
            let working = loaded?.attempts.first(where: { $0.id == claimed.id })?.state == .working
            await probe.record(working: working)
            // Force only the post-network result save to fail closed. The
            // pre-network `.working` CAS is already durable in `backup`.
            try? FileManager.default.moveItem(at: index, to: backup)
            try? FileManager.default.createSymbolicLink(at: index,
                                                        withDestinationURL: sentinel)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: session.runtimeID,
                                        storedID: session.storedID,
                                        baseline: session.messageCount)
        }
        let snapshot = RoomMemberSessionSnapshot(runtimeID: "runtime", storedID: "stored",
                                                 messages: [], running: false)
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("test"))

        async let first: Void = model.submitWaitingRoomAttempt(
            roomID: room.id, attempt: attempt, session: snapshot, client: client)
        async let second: Void = model.submitWaitingRoomAttempt(
            roomID: room.id, attempt: attempt, session: snapshot, client: client)
        _ = await (first, second)

        let firstCalls = await probe.calls
        let sawWorking = await probe.sawWorking
        XCTAssertEqual(firstCalls, 1)
        XCTAssertTrue(sawWorking)
        try? FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        let relaunched = RoomStore(baseDirectory: base)
        let relaunchedRoom = try await relaunched.room(id: room.id)
        let durable = try XCTUnwrap(relaunchedRoom)
        XCTAssertEqual(durable.attempts.first?.state, .working)
        // Relaunch sees `.working`; the waiting CAS cannot cross the network
        // boundary again even though the accepted-result save was lost.
        await model.submitWaitingRoomAttempt(roomID: room.id, attempt: attempt,
                                             session: snapshot, client: client)
        let finalCalls = await probe.calls
        XCTAssertEqual(finalCalls, 1)
        try await store.deleteAll()
    }

    func testFrozenPrimaryRoutesAndOfflineMembersSurviveSettingsSave() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-frozen-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let model = AppModel()
        let frozen = [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default"),
                       handle: "hermes-mini", sourceLabel: "Mini"),
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "default"),
                       handle: "hermes-lab", sourceLabel: "Lab"),
        ]
        let id = try await model.createRoom(name: "Fleet", members: frozen)
        // Neither route is in the current union roster; settings accepts the
        // frozen descriptors instead of rebuilding from whatever is online.
        try await model.updateRoomSettings(id, name: "Fleet renamed", members: frozen)
        let loaded = try await store.room(id: id)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.members.map(\.route), frozen.map(\.route))
        XCTAssertEqual(persisted.name, "Fleet renamed")
        try await store.deleteAll()
    }

    func testOfflineCreateAndDisbandKeepSourceQualifiedMetadataOutbox() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-metadata-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let model = AppModel()
        let members = [
            RoomMember(route: GatewayBotRoute(gatewayID: "offline-a", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "offline-b", profile: "default")),
        ]
        let id = try await model.createRoom(name: "Fleet", members: members)
        let afterCreate = try await store.metadataOutbox()
        XCTAssertEqual(afterCreate.count, 2)
        XCTAssertEqual(Set(afterCreate.map(\.route)), Set(members.map(\.route)))
        XCTAssertTrue(afterCreate.allSatisfy { $0.kind == .add && $0.newName == "Fleet" })

        try await model.disbandRoom(id)
        let fresh = RoomStore(baseDirectory: base)
        let afterDisband = try await fresh.metadataOutbox()
        XCTAssertEqual(afterDisband.count, 4)
        XCTAssertEqual(afterDisband.suffix(2).map(\.kind), [.remove, .remove])
        XCTAssertTrue(afterDisband.suffix(2).allSatisfy { $0.oldName == "Fleet" })
        try await fresh.deleteAll()
    }

    func testSupersededWaitingAttemptCancelsWithoutSubmitting() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-stale-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "stale", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .waiting)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 2)
        try await store.upsert(room)
        let probe = RoomSubmitProbe()
        runtime.submitOperation = { _, session, _ in
            await probe.record(working: true)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: session.runtimeID,
                                        storedID: session.storedID, baseline: 0)
        }
        let snapshot = RoomMemberSessionSnapshot(runtimeID: "runtime", storedID: "stored",
                                                 messages: [], running: false)
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("test"))
        await model.submitWaitingRoomAttempt(roomID: room.id, attempt: attempt,
                                             session: snapshot, client: client)
        let loaded = try await store.room(id: room.id)
        XCTAssertEqual(loaded?.attempts.first?.state, .cancelled)
        XCTAssertNotNil(loaded?.attempts.first?.finishedAt)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        try await store.deleteAll()
    }

    func testDeliveryResolutionNeverClearsGenuineUserAttention() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-abandon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "maybe sent", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .uncertain)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 1, needsUser: true)
        try await store.upsert(room)

        await AppModel().abandonRoomAttempt(roomID: room.id, attemptID: attempt.id)
        let loaded = try await store.room(id: room.id)
        XCTAssertEqual(loaded?.attempts.first?.state, .cancelled)
        XCTAssertNotNil(loaded?.attempts.first?.finishedAt)
        XCTAssertTrue(loaded?.needsUser ?? false)
        XCTAssertFalse(RoomDeliveryPolicy.hasUnresolvedDelivery(try XCTUnwrap(loaded)))

        // Reconciliation/terminal completion is the other delivery-resolution
        // path. It likewise leaves transcript attention under @user ownership.
        let accepted = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                   promptText: "accepted", storedSessionID: "stored-2",
                                   runtimeSessionID: "runtime-2", state: .accepted)
        var withAccepted = try XCTUnwrap(loaded)
        withAccepted.attempts.append(accepted)
        try await store.upsert(withAccepted)
        await AppModel().finishRoomAttempt(
            roomID: room.id, attemptID: accepted.id, member: a,
            reply: "resolved without a new mention", delivered: true)
        let reconciledValue = try await store.room(id: room.id)
        let reconciled = try XCTUnwrap(reconciledValue)
        XCTAssertTrue(reconciled.needsUser)
        XCTAssertFalse(RoomDeliveryPolicy.hasUnresolvedDelivery(reconciled))
    }

    private func makeAttempt(prompt: String) -> RoomAttempt {
        RoomAttempt(threadID: RoomThreadID(),
                    member: GatewayBotRoute(gatewayID: "mini", profile: "research"),
                    epoch: 3, promptText: prompt,
                    storedSessionID: "stored", runtimeSessionID: "deadbeef")
    }

    private func message(role: String, text: String) -> JSONValue {
        .object(["role": .string(role), "content": .string(text)])
    }
}
#endif

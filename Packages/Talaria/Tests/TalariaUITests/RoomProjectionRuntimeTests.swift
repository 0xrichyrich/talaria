#if canImport(XCTest)
import XCTest
@testable import TalariaUI
import TalariaKit

private actor ProjectionReadbackGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ProjectionTargetsGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ProjectionTestBackend {
    struct CASWrite: Sendable {
        var gatewayID: String
        var profileName: String
        var expected: Int
        var projection: RoomProjectionEnvelope
    }

    struct LegacyWrite: Sendable {
        var gatewayID: String
        var profileName: String
        var projection: RoomProjectionEnvelope
    }

    struct ReconcileEvent: Sendable {
        var gatewayID: String
        var projection: RoomProjectionEnvelope
        var preservingKeys: Set<String>
    }

    enum InjectedFailure: Error { case read }

    private var targetRows: [RoomProjectionSyncTarget]
    private var local: RoomProjectionEnvelope
    private var remotes: [String: RoomProjectionRemoteState]
    private var conflictWinners: [String: RoomProjectionEnvelope] = [:]
    private var alwaysFailReads = Set<String>()
    private var gatedReadbackGatewayID: String?
    private var readbackGate: ProjectionReadbackGate?
    private var didGateReadback = false
    private var targetsGate: ProjectionTargetsGate?
    private var shouldGateTargets = false
    private var foldReconcilesIntoLocal = false
    private var readCounts: [String: Int] = [:]
    private var casWriteLog: [CASWrite] = []
    private var legacyWriteLog: [LegacyWrite] = []
    private var reconcileLog: [ReconcileEvent] = []
    private var sleepLog: [Duration] = []
    private var leasedGenerationLog: [UInt64] = []

    init(targets: [RoomProjectionSyncTarget], local: RoomProjectionEnvelope,
         remotes: [String: RoomProjectionRemoteState]) {
        targetRows = targets
        self.local = local
        self.remotes = remotes
    }

    func setConflictWinner(_ projection: RoomProjectionEnvelope,
                           gatewayID: String) {
        conflictWinners[gatewayID] = projection
    }

    func setAlwaysFailReads(gatewayID: String) {
        alwaysFailReads.insert(gatewayID)
    }

    func gateFirstReadback(gatewayID: String,
                           gate: ProjectionReadbackGate) {
        gatedReadbackGatewayID = gatewayID
        readbackGate = gate
        didGateReadback = false
    }

    func gateNextTargets(_ gate: ProjectionTargetsGate) {
        targetsGate = gate
        shouldGateTargets = true
    }

    func enableReconcileIntoLocal() { foldReconcilesIntoLocal = true }

    func targets() async -> [RoomProjectionSyncTarget] {
        if shouldGateTargets, let targetsGate {
            shouldGateTargets = false
            await targetsGate.wait()
        }
        return targetRows
    }

    func read(_ leased: RoomProjectionLeasedTarget) async throws
        -> RoomProjectionRemoteState {
        leasedGenerationLog.append(leased.connectionGeneration)
        let target = leased.target
        let gatewayID = target.gatewayID
        readCounts[gatewayID, default: 0] += 1
        if alwaysFailReads.contains(gatewayID) { throw InjectedFailure.read }
        if gatewayID == gatedReadbackGatewayID,
           readCounts[gatewayID] == 2,
           !didGateReadback,
           let readbackGate {
            didGateReadback = true
            await readbackGate.wait()
        }
        return remotes[gatewayID]
            ?? RoomProjectionRemoteState(projection: nil, supportsCAS: false)
    }

    func localProjection(updatedAt: UInt64) -> RoomProjectionEnvelope {
        var copy = local
        copy.updatedAt = updatedAt
        return copy.bounded()
    }

    func reconcile(_ projection: RoomProjectionEnvelope,
                   target: RoomProjectionSyncTarget,
                   preservingKeys: Set<String>) {
        reconcileLog.append(ReconcileEvent(
            gatewayID: target.gatewayID,
            projection: projection,
            preservingKeys: preservingKeys))
        if foldReconcilesIntoLocal {
            local = RoomProjectionEnvelope.merging(
                remote: projection, local: local)
        }
    }

    func writeCAS(leased: RoomProjectionLeasedTarget, profileName: String,
                  projection: RoomProjectionEnvelope, expected: Int)
        -> ProfileConfigureResult {
        leasedGenerationLog.append(leased.connectionGeneration)
        let target = leased.target
        casWriteLog.append(CASWrite(
            gatewayID: target.gatewayID, profileName: profileName,
            expected: expected, projection: projection))
        let key = RoomProjectionEnvelope.metadataKey
        if let winner = conflictWinners.removeValue(forKey: target.gatewayID) {
            let actual = expected + 1
            remotes[target.gatewayID] = RoomProjectionRemoteState(
                projection: winner, revision: actual, supportsCAS: true,
                profileName: profileName)
            return ProfileConfigureResult(.object([
                "applied": .object([
                    "ui_meta": .bool(false),
                    "ui_meta_revisions": .object([key: .number(Double(actual))]),
                    "ui_meta_conflicts": .object([
                        key: .object([
                            "expected": .number(Double(expected)),
                            "actual": .number(Double(actual)),
                        ]),
                    ]),
                ]),
            ]))
        }

        let committed = expected + 1
        remotes[target.gatewayID] = RoomProjectionRemoteState(
            projection: projection, revision: committed, supportsCAS: true,
            profileName: profileName)
        return ProfileConfigureResult(.object([
            "applied": .object([
                "ui_meta": .bool(true),
                "ui_meta_revisions": .object([key: .number(Double(committed))]),
            ]),
        ]))
    }

    func writeLegacy(leased: RoomProjectionLeasedTarget, profileName: String,
                     projection: RoomProjectionEnvelope) -> [String: Bool] {
        leasedGenerationLog.append(leased.connectionGeneration)
        let target = leased.target
        legacyWriteLog.append(LegacyWrite(
            gatewayID: target.gatewayID, profileName: profileName,
            projection: projection))
        remotes[target.gatewayID] = RoomProjectionRemoteState(
            projection: projection, supportsCAS: false,
            profileName: profileName)
        return ["ui_meta": true]
    }

    func slept(_ duration: Duration) { sleepLog.append(duration) }

    func readCount(_ gatewayID: String) -> Int { readCounts[gatewayID] ?? 0 }
    func casWrites() -> [CASWrite] { casWriteLog }
    func legacyWrites() -> [LegacyWrite] { legacyWriteLog }
    func reconciles() -> [ReconcileEvent] { reconcileLog }
    func sleeps() -> [Duration] { sleepLog }
    func localSnapshot() -> RoomProjectionEnvelope { local }
    func leasedGenerations() -> [UInt64] { leasedGenerationLog }
}

@MainActor
final class RoomProjectionRuntimeTests: XCTestCase {
    func testCoalescedJobUnionsChangedDeletedAndAllowEmptyIntent() {
        let first = RoomProjectionSyncJob(
            changedRooms: ["id:a"], deletedRooms: ["id:old"])
        let merged = first.merging(RoomProjectionSyncJob(
            allowEmpty: true,
            changedRooms: ["id:a", "id:b"],
            deletedRooms: ["id:older", "id:old"]))

        XCTAssertTrue(merged.allowEmpty)
        XCTAssertEqual(merged.changedRooms, ["id:a", "id:b"])
        XCTAssertEqual(merged.deletedRooms, ["id:old", "id:older"])
    }

    func testFanoutWritesEveryConfiguredCredentialedTarget() async {
        let key = RoomProjectionEnvelope.idKey("local-room")
        let local = envelope([(key, "Shared", 0)], updatedAt: 10)
        let targets = [
            RoomProjectionSyncTarget(gatewayID: "home", label: "Home"),
            RoomProjectionSyncTarget(gatewayID: "work", label: "Work"),
        ]
        let empty = RoomProjectionEnvelope(updatedAt: 1)
        let backend = ProjectionTestBackend(
            targets: targets, local: local,
            remotes: [
                "home": RoomProjectionRemoteState(
                    projection: empty, revision: 0, supportsCAS: true),
                "work": RoomProjectionRemoteState(
                    projection: empty, revision: 4, supportsCAS: true),
            ])
        let runtime = makeRuntime(backend)
        let model = AppModel()

        runtime.schedule(model: model, changedRooms: [key])
        await waitUntilIdle(runtime)

        let writes = await backend.casWrites()
        XCTAssertEqual(Set(writes.map(\.gatewayID)), ["home", "work"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: writes.map {
            ($0.gatewayID, $0.expected)
        }), ["home": 0, "work": 4])
        let homeReads = await backend.readCount("home")
        let workReads = await backend.readCount("work")
        XCTAssertEqual(homeReads, 2)
        XCTAssertEqual(workReads, 2)
    }

    func testCASConflictRetriesAndKeepsBothStableRoomIDs() async {
        let localKey = RoomProjectionEnvelope.idKey("phone-room")
        let winnerKey = RoomProjectionEnvelope.idKey("desktop-room")
        let local = envelope([(localKey, "Phone", 0)], updatedAt: 10)
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: local,
            remotes: ["home": RoomProjectionRemoteState(
                projection: RoomProjectionEnvelope(updatedAt: 1),
                revision: 0, supportsCAS: true)])
        await backend.setConflictWinner(
            envelope([(winnerKey, "Desktop", 1)], updatedAt: 20),
            gatewayID: "home")
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [localKey])
        await waitUntilIdle(runtime)

        let writes = await backend.casWrites()
        XCTAssertEqual(writes.map(\.expected), [0, 1])
        let writtenKeys = writes.last.map { Set($0.projection.rooms.keys) }
            ?? Set<String>()
        XCTAssertEqual(writtenKeys, [localKey, winnerKey])
        XCTAssertEqual(writes.last?.projection.rooms[localKey]?.revision, 2)
        XCTAssertEqual(writes.last?.projection.rooms[winnerKey]?.revision, 1)
    }

    func testCASUsesExactExpectedIncrementAndReadsBackBeforeSuccess() async {
        let key = RoomProjectionEnvelope.idKey("stable-room")
        let remote = envelope([(key, "Old name", 7)], updatedAt: 10)
        let local = envelope([(key, "New name", 7)], updatedAt: 20)
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: local,
            remotes: ["home": RoomProjectionRemoteState(
                projection: remote, revision: 7, supportsCAS: true)])
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [key])
        await waitUntilIdle(runtime)

        let writes = await backend.casWrites()
        XCTAssertEqual(writes.count, 1)
        guard let write = writes.first else { return }
        XCTAssertEqual(write.expected, 7)
        XCTAssertEqual(write.projection.rooms[key]?.revision, 8)
        XCTAssertEqual(write.projection.rooms[key]?.name, "New name")
        let readCount = await backend.readCount("home")
        XCTAssertEqual(readCount, 2,
                       "configure must be followed by profiles.list")
        let reconciles = await backend.reconciles()
        XCTAssertEqual(reconciles.last?.projection.rooms[key]?.revision, 8)
    }

    func testEveryRPCUsesTheExactLeasedConnectionGeneration() async {
        let key = RoomProjectionEnvelope.idKey("leased-room")
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: envelope([(key, "Leased", 0)], updatedAt: 1),
            remotes: ["home": RoomProjectionRemoteState(
                projection: RoomProjectionEnvelope(updatedAt: 1),
                revision: 0, supportsCAS: true)])
        let runtime = makeRuntime(backend, leasedGeneration: 77)

        runtime.schedule(model: AppModel(), changedRooms: [key])
        await waitUntilIdle(runtime)

        let leasedGenerations = await backend.leasedGenerations()
        XCTAssertEqual(leasedGenerations, [77, 77, 77],
                       "read, CAS write, and readback must share one lease")
    }

    func testProfileSelectionAcceptsOnlyLiteralDefaultName() {
        XCTAssertTrue(RoomProjectionSyncOperations.isExactDefaultProfileName("default"))
        XCTAssertFalse(RoomProjectionSyncOperations.isExactDefaultProfileName("primary"))
        XCTAssertFalse(RoomProjectionSyncOperations.isExactDefaultProfileName("Default"))
    }

    func testPayloadNoopIgnoresUpdatedAt() async {
        let key = RoomProjectionEnvelope.idKey("same-room")
        let remote = envelope([(key, "Same", 3)], updatedAt: 1)
        let local = envelope([(key, "Same", 3)], updatedAt: 999)
        XCTAssertTrue(RoomProjectionRuntime.payloadEqual(local, remote))
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: local,
            remotes: ["home": RoomProjectionRemoteState(
                projection: remote, revision: 12, supportsCAS: true)])
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel())
        await waitUntilIdle(runtime)

        let casWrites = await backend.casWrites()
        let legacyWrites = await backend.legacyWrites()
        let readCount = await backend.readCount("home")
        XCTAssertTrue(casWrites.isEmpty)
        XCTAssertTrue(legacyWrites.isEmpty)
        XCTAssertEqual(readCount, 1)
    }

    func testMissingProjectionNeverReconcilesAsAnEmptyObservation() async {
        let key = RoomProjectionEnvelope.idKey("kept-room")
        let local = envelope([(key, "Kept", 0)], updatedAt: 10)
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "legacy")],
            local: local,
            remotes: ["legacy": RoomProjectionRemoteState(
                projection: nil, supportsCAS: false)])
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [key])
        await waitUntilIdle(runtime)

        let events = await backend.reconciles()
        XCTAssertEqual(events.count, 1,
                       "only the post-write present projection is observable")
        guard let event = events.first else { return }
        XCTAssertEqual(Set(event.projection.rooms.keys), [key])
        let localSnapshot = await backend.localSnapshot()
        XCTAssertEqual(Set(localSnapshot.rooms.keys), [key])
    }

    func testNilRevisionMapUsesLegacyBestEffortAndStillReadsBack() async {
        let oldKey = RoomProjectionEnvelope.idKey("old-room")
        let newKey = RoomProjectionEnvelope.idKey("new-room")
        let remote = envelope([(oldKey, "Old", 1)], updatedAt: 1)
        let local = envelope([(newKey, "New", 0)], updatedAt: 2)
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "legacy")],
            local: local,
            remotes: ["legacy": RoomProjectionRemoteState(
                projection: remote, supportsCAS: false)])
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [newKey])
        await waitUntilIdle(runtime)

        let casWrites = await backend.casWrites()
        XCTAssertTrue(casWrites.isEmpty)
        let legacy = await backend.legacyWrites()
        XCTAssertEqual(legacy.count, 1)
        guard let write = legacy.first else { return }
        XCTAssertEqual(Set(write.projection.rooms.keys), [oldKey, newKey])
        let readCount = await backend.readCount("legacy")
        XCTAssertEqual(readCount, 2)
    }

    func testFailureStopsAfterEightRetriesWithExactBackoffLadder() async {
        let key = RoomProjectionEnvelope.idKey("offline-room")
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "offline")],
            local: envelope([(key, "Offline", 0)], updatedAt: 1),
            remotes: [:])
        await backend.setAlwaysFailReads(gatewayID: "offline")
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [key])
        await waitUntilIdle(runtime)

        let readCount = await backend.readCount("offline")
        XCTAssertEqual(readCount, 9,
                       "one initial attempt plus eight retries")
        let retrySleeps = await backend.sleeps().filter { $0 != .zero }
        XCTAssertEqual(retrySleeps, [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8),
            .seconds(16), .seconds(30), .seconds(30), .seconds(30),
        ])
        XCTAssertEqual(runtime.retryCount(gatewayID: "offline"), 0)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testNewerCoalescedJobIsPreservedDuringReadbackAndRunsNext() async {
        let firstKey = RoomProjectionEnvelope.idKey("first-room")
        let newerKey = RoomProjectionEnvelope.idKey("newer-room")
        let local = envelope([
            (firstKey, "First", 0),
            (newerKey, "Newer", 0),
        ], updatedAt: 10)
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: local,
            remotes: ["home": RoomProjectionRemoteState(
                projection: RoomProjectionEnvelope(updatedAt: 1),
                revision: 0, supportsCAS: true)])
        let gate = ProjectionReadbackGate()
        await backend.gateFirstReadback(gatewayID: "home", gate: gate)
        let runtime = makeRuntime(backend)
        let model = AppModel()

        runtime.schedule(model: model, changedRooms: [firstKey])
        await waitUntil { await gate.isWaiting }
        runtime.schedule(model: model, changedRooms: [newerKey])
        await gate.open()
        await waitUntilIdle(runtime)

        let events = await backend.reconciles()
        XCTAssertTrue(events.contains {
            $0.projection.rooms[firstKey] != nil
                && $0.preservingKeys.contains(newerKey)
        }, "readback must not overlay a newer pending edit")
        let writes = await backend.casWrites()
        XCTAssertEqual(writes.map(\.expected), [0, 1])
        XCTAssertEqual(writes.last?.projection.rooms[newerKey]?.revision, 2)
    }

    func testPrivacyResetCancelsSuspendedReadbackWithoutRehydrating() async {
        let key = RoomProjectionEnvelope.idKey("private-room")
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: envelope([(key, "Private", 0)], updatedAt: 1),
            remotes: ["home": RoomProjectionRemoteState(
                projection: RoomProjectionEnvelope(updatedAt: 1),
                revision: 0, supportsCAS: true)])
        let gate = ProjectionReadbackGate()
        await backend.gateFirstReadback(gatewayID: "home", gate: gate)
        let runtime = makeRuntime(backend)

        runtime.schedule(model: AppModel(), changedRooms: [key])
        await waitUntil { await gate.isWaiting }
        let before = (await backend.reconciles()).count
        runtime.resetForPrivacyDeletion()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }

        let after = await backend.reconciles().count
        XCTAssertEqual(after, before)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testPrivacyResetWinsWhileReconnectTargetDiscoveryIsSuspended() async {
        let key = RoomProjectionEnvelope.idKey("private-room")
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: envelope([(key, "Private", 0)], updatedAt: 1),
            remotes: ["home": RoomProjectionRemoteState(
                projection: envelope([(key, "Remote", 1)], updatedAt: 2),
                revision: 1, supportsCAS: true)])
        let gate = ProjectionTargetsGate()
        await backend.gateNextTargets(gate)
        let runtime = makeRuntime(backend)

        let pull = Task { await runtime.pullAndReseed(
            model: AppModel(), gatewayID: "home") }
        await waitUntil { await gate.isWaiting }
        runtime.resetForPrivacyDeletion()
        await gate.open()
        await pull.value
        for _ in 0..<20 { await Task.yield() }

        let readCount = await backend.readCount("home")
        let reconciles = await backend.reconciles()
        XCTAssertEqual(readCount, 0)
        XCTAssertTrue(reconciles.isEmpty)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testCancelWinsWhileReconnectTargetDiscoveryIsSuspended() async {
        let key = RoomProjectionEnvelope.idKey("signed-out-room")
        let backend = ProjectionTestBackend(
            targets: [RoomProjectionSyncTarget(gatewayID: "home")],
            local: envelope([(key, "Local", 0)], updatedAt: 1),
            remotes: ["home": RoomProjectionRemoteState(
                projection: envelope([(key, "Remote", 1)], updatedAt: 2),
                revision: 1, supportsCAS: true)])
        let gate = ProjectionTargetsGate()
        await backend.gateNextTargets(gate)
        let runtime = makeRuntime(backend)

        let pull = Task { await runtime.pullAndReseed(
            model: AppModel(), gatewayID: "home") }
        await waitUntil { await gate.isWaiting }
        runtime.cancel(gatewayID: "home")
        await gate.open()
        await pull.value
        for _ in 0..<20 { await Task.yield() }

        let readCount = await backend.readCount("home")
        let reconciles = await backend.reconciles()
        XCTAssertEqual(readCount, 0)
        XCTAssertTrue(reconciles.isEmpty)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testSourceFinalRoomTombstoneReseedsStalePeerWithoutGenericAllowEmpty() async {
        let key = RoomProjectionEnvelope.idKey("final-room")
        let stale = envelope([(key, "Final", 1)], updatedAt: 1)
        let tombstone = RoomProjectionEnvelope(
            updatedAt: 5, rooms: [:], deleted: [key: 5])
        let backend = ProjectionTestBackend(
            targets: [
                RoomProjectionSyncTarget(gatewayID: "source"),
                RoomProjectionSyncTarget(gatewayID: "peer"),
            ],
            local: stale,
            remotes: [
                "source": RoomProjectionRemoteState(
                    projection: tombstone, revision: 5, supportsCAS: true),
                "peer": RoomProjectionRemoteState(
                    projection: stale, revision: 2, supportsCAS: true),
            ])
        await backend.enableReconcileIntoLocal()
        let runtime = makeRuntime(backend)

        await runtime.pullAndReseed(model: AppModel(), gatewayID: "source")
        await waitUntilIdle(runtime)

        let peerWrites = await backend.casWrites().filter { $0.gatewayID == "peer" }
        XCTAssertEqual(peerWrites.count, 1)
        XCTAssertTrue(peerWrites[0].projection.rooms.isEmpty,
                      "the final room must not be resurrected on the peer")
        XCTAssertEqual(peerWrites[0].projection.deleted[key], 5,
                       "the explicit outbound final-room tombstone must survive fanout")
    }

    private func makeRuntime(_ backend: ProjectionTestBackend,
                             leasedGeneration: UInt64 = 0)
        -> RoomProjectionRuntime {
        let operations = RoomProjectionSyncOperations(
            targets: { _ in await backend.targets() },
            withTargetLease: { _, target, operation in
                try await operation(RoomProjectionLeasedTarget(
                    target: target, connectionGeneration: leasedGeneration))
            },
            read: { leased in try await backend.read(leased) },
            localProjection: { await backend.localProjection(updatedAt: $0) },
            reconcile: { projection, target, preserving in
                await backend.reconcile(
                    projection, target: target, preservingKeys: preserving)
            },
            writeCAS: { leased, profileName, projection, expected in
                await backend.writeCAS(
                    leased: leased, profileName: profileName,
                    projection: projection, expected: expected)
            },
            writeLegacy: { leased, profileName, projection in
                await backend.writeLegacy(
                    leased: leased, profileName: profileName,
                    projection: projection)
            },
            sleep: { duration in await backend.slept(duration) },
            nowMilliseconds: { 1_000 })
        return RoomProjectionRuntime(
            operations: operations, coalescingDelay: .zero)
    }

    private func envelope(_ rows: [(key: String, name: String, revision: UInt64)],
                          updatedAt: UInt64) -> RoomProjectionEnvelope {
        let author = RoomProjectionAuthor(kind: .user, name: "You")
        return RoomProjectionEnvelope(
            updatedAt: updatedAt,
            rooms: Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.key, RoomProjectionRoom(
                    name: row.name,
                    roomID: row.key.hasPrefix("id:")
                        ? String(row.key.dropFirst(3)) : nil,
                    log: [RoomProjectionEntry(
                        id: "message-\(row.key)", from: author,
                        text: row.name, at: 100)],
                    revision: row.revision))
            }))
    }

    private func waitUntilIdle(_ runtime: RoomProjectionRuntime,
                               file: StaticString = #filePath,
                               line: UInt = #line) async {
        await waitUntil({ !runtime.hasPendingWork }, file: file, line: line)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<20_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for projection runtime", file: file, line: line)
    }
}
#endif

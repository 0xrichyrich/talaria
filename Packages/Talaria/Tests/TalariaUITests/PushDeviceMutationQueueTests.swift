#if canImport(XCTest)
import XCTest
@testable import TalariaUI
import TalariaKit

private actor PushQueueGate {
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

private actor PushQueueLog {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    var snapshot: [String] { values }
}

@MainActor
private final class FakeVoiceRouterInstaller {
    var fence = VoiceRouterLeaseFence()
    private(set) var installedGateway: String?

    func delayedBackgroundInstall(gate: PushQueueGate) async {
        guard let generation = fence.beginBackgroundIntent() else { return }
        await gate.wait()
        if fence.accepts(generation: generation, gatewayID: "primary") {
            installedGateway = "primary"
        }
    }

    func acquireAndInstall(_ gateway: String, lease: UUID = UUID()) -> UUID {
        let claim = fence.acquireOverlay(gatewayID: gateway, lease: lease)
        if fence.accepts(generation: claim.generation, gatewayID: gateway) {
            installedGateway = gateway
        }
        return claim.lease
    }

    func release(_ lease: UUID) -> Bool { fence.releaseOverlay(lease) }
}

private actor ColdApprovalFake {
    enum Call: Equatable { case resume(String, String), pending(String), answer(String, String) }

    var resume = PushApprovalResumeSnapshot(sessionID: "live-1", storedSessionID: "stored-1",
                                            profile: "default")
    var pendingReads: [[ApprovalDetail]] = []
    var resolved = 1
    private(set) var calls: [Call] = []
    private(set) var routes: [GatewayBotRoute] = []

    func setResume(_ value: PushApprovalResumeSnapshot) { resume = value }
    func setPending(_ value: [[ApprovalDetail]]) { pendingReads = value }
    func connect(_ route: GatewayBotRoute) -> PushApprovalActions {
        routes.append(route)
        return PushApprovalActions(
            resume: { self.resume($0, profile: $1) },
            pending: { self.pending($0) },
            answer: { self.answer($0, request: $1) })
    }

    func resume(_ stored: String, profile: String) -> PushApprovalResumeSnapshot {
        calls.append(.resume(stored, profile)); return resume
    }

    func pending(_ session: String) -> [ApprovalDetail] {
        calls.append(.pending(session))
        return pendingReads.isEmpty ? [] : pendingReads.removeFirst()
    }

    func answer(_ session: String, request: String) -> Int {
        calls.append(.answer(session, request)); return resolved
    }

    var snapshot: [Call] { calls }
    var routed: [GatewayBotRoute] { routes }
}

final class PushDeviceMutationQueueTests: XCTestCase {
    func testRelayContractSurfacesConfigurationAndDeliveryFailures() throws {
        let status: JSONValue = [
            "apns_configured": .bool(false),
            "apns_missing_env": .array([.string("TALARIA_APNS_KEY_ID"),
                                         .string("TALARIA_APNS_TEAM_ID")]),
        ]
        XCTAssertEqual(PushRelayContract.configurationIssue(status),
                       "missing TALARIA_APNS_KEY_ID, TALARIA_APNS_TEAM_ID")
        XCTAssertEqual(PushRelayContract.configurationIssue(["relay_disabled": .bool(true)]),
                       "the relay is disabled")
        XCTAssertEqual(PushRelayContract.configurationIssue([
            "relay_disabled": .bool(true),
            "apns_configured": .bool(false),
            "apns_missing_env": .array([.string("TALARIA_APNS_KEY_ID")]),
        ]), "the relay is disabled; missing TALARIA_APNS_KEY_ID")
        XCTAssertNil(PushRelayContract.configurationIssue(["apns_configured": .bool(true)]))

        XCTAssertNoThrow(try PushRelayContract.validateTestResponse([
            "results": .array([["ok": .bool(true), "status": .number(200)]])
        ]))
        XCTAssertThrowsError(try PushRelayContract.validateTestResponse([
            "results": .array([[
                "ok": .bool(false), "status": .number(403),
                "reason": .string("InvalidProviderToken"),
            ]])
        ])) { error in
            XCTAssertEqual((error as? GatewayError)?.message,
                           "APNs rejected the test push (403 InvalidProviderToken).")
        }
    }
    func testRapidFilterIntentCannotEnterBeforeFirstMutationFinishes() {
        var admission = PushFilterMutationAdmission()
        XCTAssertTrue(admission.claim())
        XCTAssertFalse(admission.claim(), "second tap must be rejected before deriving a snapshot")
        admission.release()
        XCTAssertTrue(admission.claim())
    }

    func testUserFilterMutationFinishesAfterEarlierAutomaticRegistration() async {
        let queue = PushDeviceMutationQueue()
        let gate = PushQueueGate()
        let log = PushQueueLog()

        let automatic = Task {
            await queue.run(gatewayID: "homelab") {
                await gate.wait()
                await log.append("automatic")
                return nil
            }
        }
        while !(await gate.isWaiting) { await Task.yield() }

        let user = Task {
            await queue.run(gatewayID: "homelab") {
                await log.append("user")
                return nil
            }
        }
        await gate.open()
        _ = await automatic.value
        _ = await user.value

        let values = await log.snapshot
        XCTAssertEqual(values, ["automatic", "user"])
    }

    func testDifferentGatewaysDoNotBlockEachOther() async {
        let queue = PushDeviceMutationQueue()
        let gate = PushQueueGate()
        let log = PushQueueLog()

        let sleeping = Task {
            await queue.run(gatewayID: "sleeping") {
                await gate.wait()
                await log.append("sleeping")
                return nil
            }
        }
        while !(await gate.isWaiting) { await Task.yield() }

        _ = await queue.run(gatewayID: "awake") {
            await log.append("awake")
            return nil
        }
        let values = await log.snapshot
        XCTAssertEqual(values, ["awake"])
        await gate.open()
        _ = await sleeping.value
    }

    func testVoiceProviderOptionsDecodeDynamicSchema() {
        let options = VoiceProviderOptions(.object([
            "fields": .object([
                "tts.provider": .object(["options": .array(["edge", "custom"])]),
                "stt.provider": .object(["options": .array(["local", "plugin-stt"])]),
            ]),
        ]))

        XCTAssertEqual(options.tts, ["edge", "custom"])
        XCTAssertEqual(options.stt, ["local", "plugin-stt"])
    }

    func testPushRouteResolverQualifiesForeignGateway() {
        XCTAssertEqual(PushRouteResolver.botID(
            raw: "default", sourceGatewayID: "homelab",
            knownGatewayIDs: ["primary", "homelab"], activeGatewayID: "primary"),
            "homelab::default")
        XCTAssertEqual(PushRouteResolver.botID(
            raw: "default", sourceGatewayID: "primary",
            knownGatewayIDs: ["primary", "homelab"], activeGatewayID: "primary"),
            "default")
    }

    func testAmbiguousOrUnknownPushSourceFailsClosed() {
        XCTAssertNil(PushRouteResolver.botID(
            raw: "default", sourceGatewayID: nil,
            knownGatewayIDs: ["primary", "homelab"], activeGatewayID: "primary"))
        XCTAssertNil(PushRouteResolver.botID(
            raw: "default", sourceGatewayID: "attacker",
            knownGatewayIDs: ["primary", "homelab"], activeGatewayID: "primary"))
    }

    func testLegacyPushWithOneSavedGatewayStillRoutesSafely() {
        XCTAssertEqual(PushRouteResolver.botID(
            raw: "worker", sourceGatewayID: nil,
            knownGatewayIDs: ["homelab"], activeGatewayID: nil),
            "homelab::worker")
    }

    func testProfileSTTReadinessHonorsExplicitDisableAndUnknown() {
        let disabled = ProfileSTTReadiness(config: .object([
            "stt": .object(["enabled": .bool(false), "provider": .string("local")]),
        ]))
        XCTAssertTrue(disabled.probed)
        XCTAssertFalse(disabled.canTranscribe)

        let enabled = ProfileSTTReadiness(config: .object([
            "stt": .object(["enabled": .bool(true), "provider": .string("local")]),
        ]))
        XCTAssertTrue(enabled.canTranscribe)
        XCTAssertFalse(ProfileSTTReadiness.unknown.probed)
        XCTAssertFalse(ProfileSTTReadiness.unknown.canTranscribe)
    }

    func testApprovalPushRequiresExactStampedIdentity() {
        let known: Set<String> = ["primary", "homelab"]
        XCTAssertEqual(PushApprovalIdentity.resolve(
            gatewayID: "homelab", profile: "default", storedSessionID: "stored-1",
            requestID: "request-1", knownGatewayIDs: known),
            PushApprovalIdentity(gatewayID: "homelab", profile: "default",
                                 storedSessionID: "stored-1", requestID: "request-1"))
        XCTAssertNil(PushApprovalIdentity.resolve(
            gatewayID: nil, profile: "default", storedSessionID: "stored-1",
            requestID: nil, knownGatewayIDs: known))
        XCTAssertNil(PushApprovalIdentity.resolve(
            gatewayID: "attacker", profile: "default", storedSessionID: "stored-1",
            requestID: nil, knownGatewayIDs: known))
        XCTAssertNil(PushApprovalIdentity.resolve(
            gatewayID: "homelab", profile: "primary::default", storedSessionID: "stored-1",
            requestID: nil, knownGatewayIDs: known))
    }

    func testApprovalSelectionExactIDAndHookFIFOAreRevalidated() {
        func detail(_ id: String) -> ApprovalDetail {
            ApprovalDetail(.object([
                "request_id": .string(id), "command": .string("echo ok"),
                "choices": .array([.string("once"), .string("deny")]),
            ]), sessionID: "live-session", replayed: true)
        }
        let first = detail("first")
        let second = detail("second")
        XCTAssertEqual(PushApprovalSelection.select([first, second], requestID: "second")?.id,
                       "second")
        XCTAssertNil(PushApprovalSelection.select([first, first], requestID: "first"))
        XCTAssertEqual(PushApprovalSelection.select([first, second], requestID: nil)?.id, "first")
        XCTAssertFalse(PushApprovalSelection.stillCurrent(first, in: [second], requestID: nil))
    }

    func testColdApprovalUsesCapturedProfileResumeTwoReadsAndExactRequest() async throws {
        let fake = ColdApprovalFake()
        let wanted = approvalDetail("wanted")
        await fake.setPending([[approvalDetail("other"), wanted], [wanted]])
        let identity = PushApprovalIdentity(gatewayID: "homelab", profile: "default",
                                            storedSessionID: "stored-1", requestID: "wanted")

        let selected = try await PushApprovalOrchestrator.approve(identity: identity) {
            await fake.connect($0)
        }

        XCTAssertEqual(selected.id, "wanted")
        let routes = await fake.routed
        XCTAssertEqual(routes.map(\.gatewayID), ["homelab"])
        XCTAssertEqual(routes.map(\.profile), ["default"])
        let calls = await fake.snapshot
        XCTAssertEqual(calls, [
            .resume("stored-1", "default"), .pending("live-1"),
            .pending("live-1"), .answer("live-1", "wanted"),
        ])
    }

    func testColdApprovalIdentityMismatchNeverReadsOrMutatesApproval() async {
        let fake = ColdApprovalFake()
        await fake.setResume(PushApprovalResumeSnapshot(
            sessionID: "live-1", storedSessionID: "other", profile: "default"))
        let identity = PushApprovalIdentity(gatewayID: "homelab", profile: "default",
                                            storedSessionID: "stored-1", requestID: "wanted")

        do {
            _ = try await PushApprovalOrchestrator.approve(
                identity: identity, actions: approvalActions(fake))
            XCTFail("identity mismatch must fail")
        } catch {}

        let calls = await fake.snapshot
        XCTAssertEqual(calls, [.resume("stored-1", "default")])
    }

    func testColdHookFIFOAdvanceBetweenReadsNeverMutates() async {
        let fake = ColdApprovalFake()
        await fake.setPending([[approvalDetail("first")], [approvalDetail("second")]])
        let identity = PushApprovalIdentity(gatewayID: "homelab", profile: "default",
                                            storedSessionID: "stored-1", requestID: nil)

        do {
            _ = try await PushApprovalOrchestrator.approve(
                identity: identity, actions: approvalActions(fake))
            XCTFail("advanced FIFO must fail")
        } catch {}

        let calls = await fake.snapshot
        XCTAssertEqual(calls, [
            .resume("stored-1", "default"), .pending("live-1"), .pending("live-1"),
        ])
    }

    @MainActor
    func testVoiceRuntimeRejectsStaleOrForeignHandlerEvents() {
        let runtime = VoiceRuntime.shared
        let priorFence = runtime.routerFence
        let priorGateway = runtime.handlerGatewayID
        defer {
            runtime.routerFence = priorFence
            runtime.handlerGatewayID = priorGateway
        }
        runtime.routerFence = VoiceRouterLeaseFence(generation: 41)
        runtime.handlerGatewayID = "homelab"
        let before = runtime.interruptions
        let event = GatewayEvent(type: "voice.interrupted", sessionID: "", payload: nil)

        runtime.handle(event, gatewayID: "primary", generation: 41)
        runtime.handle(event, gatewayID: "homelab", generation: 40)
        XCTAssertEqual(runtime.interruptions, before)

        runtime.handle(event, gatewayID: "homelab", generation: 41)
        XCTAssertEqual(runtime.interruptions, before + 1)
    }

    @MainActor
    func testOverlayLeaseBeatsDelayedPrimaryInstallAndStaleReleaseCannotWin() async {
        let installer = FakeVoiceRouterInstaller()
        let gate = PushQueueGate()
        let delayed = Task { await installer.delayedBackgroundInstall(gate: gate) }
        while !(await gate.isWaiting) { await Task.yield() }

        let oldLease = installer.acquireAndInstall("homelab")
        await gate.open()
        await delayed.value
        XCTAssertEqual(installer.installedGateway, "homelab")

        let newLease = installer.acquireAndInstall("work")
        XCTAssertFalse(installer.release(oldLease))
        XCTAssertEqual(installer.installedGateway, "work")
        XCTAssertEqual(installer.fence.overlayLease, newLease)
    }

    @MainActor
    func testProfileLifecycleFenceRejectsVoiceReconnectBeforePoolMutation() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "homelab", profile: "worker")
        let target = ProfileLifecycleTarget(rosterID: route.qualifiedID, route: route)

        model.activateProfileLifecycleRoute(gatewayID: route.gatewayID,
                                            profile: route.profile)
        XCTAssertNotNil(model.voiceReconnectLifecycleToken(for: route))

        // Rename/delete raises this block before awaiting client retirement.
        // Voice must observe it before interpreting the intentionally closed
        // pool sentinel as an ordinary dead socket and evicting it.
        model.abortProfileRuntime(target)
        XCTAssertNil(model.voiceReconnectLifecycleToken(for: route))

        // Leave shared lifecycle state usable for subsequent serialized tests.
        model.activateProfileLifecycleRoute(gatewayID: route.gatewayID,
                                            profile: route.profile)
    }


    private func approvalDetail(_ id: String) -> ApprovalDetail {
        ApprovalDetail(.object([
            "request_id": .string(id), "command": .string("echo ok"),
            "choices": .array([.string("once"), .string("deny")]),
        ]), sessionID: "live-1", replayed: true)
    }

    private func approvalActions(_ fake: ColdApprovalFake) -> PushApprovalActions {
        PushApprovalActions(
            resume: { await fake.resume($0, profile: $1) },
            pending: { await fake.pending($0) },
            answer: { await fake.answer($0, request: $1) })
    }
}
#endif

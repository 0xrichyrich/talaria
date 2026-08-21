#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor DelayedCronAddGate {
    private var released = false
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func hasArrived() -> Bool { arrived }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

final class CronReasoningEffortTests: XCTestCase {
    func testListAndDetailPreserveRawOptionalValue() {
        let listed = CronJobRecord([
            "job_id": "job-1",
            "reasoning_effort": "  FUTURE-level  ",
            "profile_name": "primary-store",
        ])
        let detail = CronJobDetail([
            "id": "job-1",
            "reasoning_effort": "  FUTURE-level  ",
            "profile": "primary-store",
        ])
        let empty = CronJobDetail([
            "id": "job-2",
            "reasoning_effort": "",
        ])
        let absent = CronJobDetail(["id": "job-3"])

        XCTAssertEqual(listed.reasoningEffortRaw, "  FUTURE-level  ")
        XCTAssertEqual(listed.profile, "primary-store")
        XCTAssertEqual(detail.reasoningEffortRaw, "  FUTURE-level  ")
        XCTAssertEqual(detail.profile, "primary-store")
        XCTAssertEqual(empty.reasoningEffortRaw, "")
        XCTAssertNil(absent.reasoningEffortRaw)
    }

    func testReadStatusMatchesHermesParserSemantics() {
        for level in CronReasoningEffort.canonicalValues {
            XCTAssertEqual(CronReasoningEffort(raw: " \(level.uppercased()) "),
                           .pinned(level))
        }
        XCTAssertEqual(CronReasoningEffort(raw: "false"), .pinned("none"))
        XCTAssertEqual(CronReasoningEffort(raw: "DISABLED"), .pinned("none"))
        XCTAssertEqual(CronReasoningEffort(raw: nil), .followsConfiguration)
        XCTAssertEqual(CronReasoningEffort(raw: " \n "), .followsConfiguration)

        let unknown = CronReasoningEffort(raw: "future-level")
        XCTAssertEqual(unknown, .unknown("future-level"))
        XCTAssertNil(unknown.pinnedValue)
        XCTAssertTrue(unknown.followsConfiguration)
    }

    func testMutationNormalizesAllowedAliasesAndClear() throws {
        for level in CronReasoningEffort.canonicalValues {
            XCTAssertEqual(try CronReasoningEffort.canonicalMutation(
                " \(level.uppercased()) "), level)
        }
        XCTAssertEqual(try CronReasoningEffort.canonicalMutation("false"), "none")
        XCTAssertEqual(try CronReasoningEffort.canonicalMutation("disabled"), "none")
        XCTAssertNil(try CronReasoningEffort.canonicalMutation(""))
        XCTAssertNil(try CronReasoningEffort.canonicalMutation(" \n "))
        XCTAssertEqual(try CronReasoningEffort.wireMutation(" HIGH "), .string("high"))
        XCTAssertEqual(try CronReasoningEffort.wireMutation(""), .null)
    }

    func testMutationRejectsUnknownBeforeAnyWrite() {
        XCTAssertThrowsError(try CronReasoningEffort.canonicalMutation("turbo")) { error in
            guard let gateway = error as? GatewayError else {
                return XCTFail("expected GatewayError, got \(error)")
            }
            XCTAssertEqual(gateway.code, 400)
            XCTAssertTrue(gateway.message.contains("turbo"))
            XCTAssertTrue(gateway.message.contains("minimal"))
            XCTAssertTrue(gateway.message.contains("ultra"))
        }
    }

    func testUnrelatedOrUnseededEditOmitsRawEffortPatch() {
        XCTAssertNil(CronReasoningEffort.authoredMutation(
            draft: "future-level", baseline: "future-level"))
        XCTAssertNil(CronReasoningEffort.authoredMutation(
            draft: "", baseline: nil))
        XCTAssertNil(CronReasoningEffort.authoredMutation(
            draft: "high", baseline: nil))

        XCTAssertEqual(CronReasoningEffort.authoredMutation(
            draft: "", baseline: "future-level"), "")
        XCTAssertEqual(CronReasoningEffort.authoredMutation(
            draft: "low", baseline: "high"), "low")
    }

    func testRoutineMutationFenceRequiresSourceProfileAndGeneration() {
        let target = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same-id"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "coder"),
            profile: "coder")
        let source = CronSourceMutationFence(
            gatewayID: "primary", profile: "coder", generation: .primary(7))
        let fence = CronRoutineMutationFence(
            routineID: "same-id", target: target, source: source)

        XCTAssertTrue(CronRoutineMutationFence.accepts(
            fence, currentTarget: target, primaryGatewayID: "primary",
            primaryGeneration: 7, retainedGenerations: [:]))
        XCTAssertFalse(CronRoutineMutationFence.accepts(
            fence, currentTarget: target, primaryGatewayID: "primary",
            primaryGeneration: 8, retainedGenerations: [:]))
        XCTAssertFalse(CronRoutineMutationFence.accepts(
            fence, currentTarget: target, primaryGatewayID: "other",
            primaryGeneration: 7, retainedGenerations: ["primary": 7]))

        var moved = target
        moved.profile = "default"
        XCTAssertFalse(CronRoutineMutationFence.accepts(
            fence, currentTarget: moved, primaryGatewayID: "primary",
            primaryGeneration: 7, retainedGenerations: [:]))

        let mismatchedStore = CronRoutineMutationFence(
            routineID: "same-id", target: target,
            source: CronSourceMutationFence(
                gatewayID: "primary", profile: "default", generation: .primary(7)))
        XCTAssertFalse(CronRoutineMutationFence.accepts(
            mismatchedStore, currentTarget: target, primaryGatewayID: "primary",
            primaryGeneration: 7, retainedGenerations: [:]))
    }

    func testSourceChangedErrorDoesNotCollideWithTransportTimeout() {
        XCTAssertNotEqual(CronMutationFenceError.sourceChanged, -5)
        XCTAssertEqual(CronMutationFenceError.sourceChanged, -10)
    }

    func testActivityIdentityIncludesProfileGeneration() {
        let target = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same-id"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"),
            profile: "default")
        let source = CronSourceMutationFence(
            gatewayID: "homelab", profile: "default", generation: .retained(4))
        let first = CronRoutineMutationFence(
            routineID: "same-id", target: target, source: source, profileGeneration: 11)
        let replacement = CronRoutineMutationFence(
            routineID: "same-id", target: target, source: source, profileGeneration: 12)

        XCTAssertNotEqual(first.activityIdentity, replacement.activityIdentity)
    }

    func testAcceptedDeleteCannotClearReplacementSameIDTarget() {
        let oldTarget = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same-id"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"),
            profile: "default")
        var replacement = oldTarget
        replacement.profile = "researcher"
        replacement.bot = GatewayBotRoute(gatewayID: "primary", profile: "researcher")

        XCTAssertTrue(CronDeletePostRefreshPolicy.mayClear(
            capturedTarget: oldTarget, currentTarget: nil))
        XCTAssertTrue(CronDeletePostRefreshPolicy.mayClear(
            capturedTarget: oldTarget, currentTarget: oldTarget))
        XCTAssertFalse(CronDeletePostRefreshPolicy.mayClear(
            capturedTarget: oldTarget, currentTarget: replacement))
    }

    func testCreateRESTAcknowledgementRequiresExactIDAndProfile() {
        let expected = CronJobDetail([
            "id": "same-id", "profile_name": "default",
        ])
        let wrongID = CronJobDetail([
            "id": "other-id", "profile_name": "default",
        ])
        let wrongProfile = CronJobDetail([
            "id": "same-id", "profile": "researcher",
        ])
        let unscoped = CronJobDetail(["id": "same-id"])

        XCTAssertTrue(CronCreateAcknowledgementPolicy.accepts(
            expected, jobID: "same-id", profile: "default"))
        XCTAssertFalse(CronCreateAcknowledgementPolicy.accepts(
            wrongID, jobID: "same-id", profile: "default"))
        XCTAssertFalse(CronCreateAcknowledgementPolicy.accepts(
            wrongProfile, jobID: "same-id", profile: "default"))
        XCTAssertFalse(CronCreateAcknowledgementPolicy.accepts(
            unscoped, jobID: "same-id", profile: "default"))
    }

    func testAcceptedPartialOutcomeIsNotAResubmitInstruction() {
        let outcome = CronCreateOutcome.acceptedPartial(
            CronAcceptedPartialOutcome(
                jobID: "same-id", gatewayID: "homelab", profile: "default",
                reason: .followUpAmbiguous))

        XCTAssertEqual(outcome.acceptedPartial?.jobID, "same-id")
        XCTAssertEqual(outcome.acceptedPartial?.reason, .followUpAmbiguous)
        XCTAssertNil(CronCreateOutcome.completed.acceptedPartial)
    }

    func testRetainedMutationFenceRejectsReplacedClientGeneration() {
        let fence = CronSourceMutationFence(
            gatewayID: "homelab", profile: nil, generation: .retained(4))
        XCTAssertTrue(CronSourceMutationFence.accepts(
            fence, primaryGatewayID: "primary", primaryGeneration: 10,
            retainedGenerations: ["homelab": 4]))
        XCTAssertFalse(CronSourceMutationFence.accepts(
            fence, primaryGatewayID: "primary", primaryGeneration: 10,
            retainedGenerations: ["homelab": 5]))
        XCTAssertFalse(CronSourceMutationFence.accepts(
            fence, primaryGatewayID: "homelab", primaryGeneration: 10,
            retainedGenerations: ["homelab": 4]))
    }

    func testDelayedAddAndRetainedPoolReplacementRefuseRESTPatch() async {
        let gate = DelayedCronAddGate()
        let add = Task {
            await gate.waitForRelease()
            return "job-accepted"
        }
        while !(await gate.hasArrived()) { await Task.yield() }

        // The retained client occupying this gateway id is replaced while the
        // irreversible socket add is suspended.
        await gate.release()
        let jobID = await add.value
        let source = CronSourceMutationFence(
            gatewayID: "homelab", profile: nil, generation: .retained(4))
        let decision = CronCreatePostAddPolicy.decision(
            sourceFence: source,
            primaryGatewayID: "primary",
            primaryGeneration: 10,
            retainedGenerations: ["homelab": 5],
            hasRESTOnlyFields: true,
            hasJobID: !jobID.isEmpty,
            hasRESTAuthority: true,
            restSupported: true)

        var restPatchCount = 0
        if decision.shouldIssueRESTPatch { restPatchCount += 1 }
        XCTAssertEqual(decision, .acceptedButStale)
        XCTAssertTrue(decision.preservesAcceptedAdd)
        XCTAssertTrue(decision.requiresRecoveryNotice)
        XCTAssertFalse(decision.shouldIssueRESTPatch)
        XCTAssertEqual(restPatchCount, 0)
    }

    func testDelayedExistingMutationRejectsCompletionAfterSourceReplacement() async {
        let gate = DelayedCronAddGate()
        let oldFence = CronSourceMutationFence(
            gatewayID: "homelab", profile: "default", generation: .retained(4))
        let write = Task {
            await gate.waitForRelease()
            let stillOwned = CronSourceMutationFence.accepts(
                oldFence, primaryGatewayID: "primary", primaryGeneration: 10,
                retainedGenerations: ["homelab": 5])
            return CronAsyncFencePolicy(sourceAccepted: stillOwned)
        }
        while !(await gate.hasArrived()) { await Task.yield() }

        // The pool replacement happens while the existing-job write is
        // suspended. The completion must be an explicit stale outcome, not a
        // successful no-op that lets the editor pop or records a success toast.
        await gate.release()
        let outcome = await write.value
        XCTAssertEqual(outcome, .sourceChanged)
        XCTAssertFalse(outcome.mayPublish)
        XCTAssertTrue(outcome.shouldRollbackOptimisticState)
    }

    func testStaleTogglePolicyRollsBackAndNeverSettlesAsSuccess() {
        let outcome = CronAsyncFencePolicy(sourceAccepted: false)
        XCTAssertTrue(outcome.shouldRollbackOptimisticState)
        XCTAssertFalse(outcome.mayPublish)
    }

    func testDelayedReadCannotClearReplacementAuthority() {
        let target = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same-id"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"),
            profile: "default")
        let oldFence = CronRoutineMutationFence(
            routineID: "routine", target: target,
            source: CronSourceMutationFence(
                gatewayID: "homelab", profile: "default", generation: .retained(4)))
        let replacementFence = CronRoutineMutationFence(
            routineID: "routine", target: target,
            source: CronSourceMutationFence(
                gatewayID: "homelab", profile: "default", generation: .retained(5)))

        XCTAssertFalse(CronReadCachePolicy.shouldClearBeforeRead(
            sourceAccepted: false, cacheFence: replacementFence, operationFence: oldFence))
        XCTAssertTrue(CronReadCachePolicy.shouldClearBeforeRead(
            sourceAccepted: true, cacheFence: oldFence, operationFence: replacementFence))
    }

    func testQuarantinePauseFailureLeavesVictimRetryable() {
        var quarantined: Set<String> = ["legacy-job|homelab|legacy-job|default|retained-4|9"]
        let quarantineKey = "legacy-job|homelab|legacy-job|default|retained-4|9"
        if !CronQuarantinePolicy.retainMarkerAfterPauseFailure {
            quarantined.remove(quarantineKey)
        }
        XCTAssertTrue(quarantined.isEmpty)
    }

    func testRoutineEditorLocksExistingMutationUntilDetailIsAuthoritative() {
        XCTAssertFalse(RoutineEditorDetailPolicy.allowsEditingExisting(
            restAvailable: true, hasAuthoritativeDetail: false, quarantined: false))
        XCTAssertFalse(RoutineEditorDetailPolicy.allowsSubmittingExisting(
            restAvailable: true, hasAuthoritativeDetail: false, quarantined: false,
            dirty: true, saving: false, busy: false))

        XCTAssertTrue(RoutineEditorDetailPolicy.allowsEditingExisting(
            restAvailable: true, hasAuthoritativeDetail: true, quarantined: false))
        XCTAssertTrue(RoutineEditorDetailPolicy.allowsSubmittingExisting(
            restAvailable: true, hasAuthoritativeDetail: true, quarantined: false,
            dirty: true, saving: false, busy: false))
        XCTAssertFalse(RoutineEditorDetailPolicy.allowsSubmittingExisting(
            restAvailable: false, hasAuthoritativeDetail: true, quarantined: false,
            dirty: true, saving: false, busy: false))
    }
}
#endif

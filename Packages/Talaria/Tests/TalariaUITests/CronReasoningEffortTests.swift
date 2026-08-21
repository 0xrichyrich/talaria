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

    func testCentralCronAcknowledgementRejectsMissingOrMismatchedProfile() {
        let primary = CronJobDetail([
            "id": "same-id", "profile_name": "primary-launch",
        ])
        let retained = CronJobDetail([
            "id": "same-id", "profile": "retained-launch",
        ])
        let missing = CronJobDetail(["id": "same-id"])

        XCTAssertEqual(CronJobAcknowledgementPolicy.returnedProfile(
            primary, jobID: "same-id", expectedProfile: "primary-launch"),
                       "primary-launch")
        XCTAssertEqual(CronJobAcknowledgementPolicy.returnedProfile(
            retained, jobID: "same-id", expectedProfile: "retained-launch"),
                       "retained-launch")
        XCTAssertNil(CronJobAcknowledgementPolicy.returnedProfile(
            retained, jobID: "same-id", expectedProfile: "primary-launch"))
        XCTAssertNil(CronJobAcknowledgementPolicy.returnedProfile(
            missing, jobID: "same-id", expectedProfile: "retained-launch"))
        XCTAssertFalse(CronJobAcknowledgementPolicy.accepts(
            primary, jobID: "same-id", profile: nil))
    }

    func testUnscopedRESTDetailCannotRetargetCollidingJobID() {
        let launchRow = CronJobDetail([
            "id": "same-id", "profile": "launch-store",
        ])
        let retainedCollision = CronJobDetail([
            "id": "same-id", "profile": "retained-store",
        ])

        // `_find_cron_job_profile` may return either store for an unscoped
        // REST lookup. Only the socket's already-scoped target can authorize
        // detail publication; a nil target profile must never be promoted.
        XCTAssertFalse(CronDetailAuthorityPolicy.allowsProfileScopedREST(profile: nil))
        XCTAssertTrue(CronDetailAuthorityPolicy.allowsProfileScopedREST(
            profile: "retained-store"))
        XCTAssertFalse(CronJobAcknowledgementPolicy.accepts(
            retainedCollision, jobID: "same-id", profile: "launch-store"))
        XCTAssertTrue(CronJobAcknowledgementPolicy.accepts(
            launchRow, jobID: "same-id", profile: "launch-store"))
    }

    func testUnscopedNamedLaunchRowsNeverGainRosterDefaultAuthority() {
        let primary = CronJobRecord([
            "job_id": "primary-job", "name": "[bot:default] Primary",
        ])
        let retained = CronJobRecord([
            "job_id": "retained-job", "name": "[bot:default] Retained",
        ])

        // A title tag is a display/delegation identity, not the process
        // launch profile. The list response did not echo either store.
        XCTAssertNil(primary.profile)
        XCTAssertNil(retained.profile)
        XCTAssertEqual(primary.taggedBotID, "default")
        XCTAssertEqual(retained.taggedBotID, "default")
    }

    func testPrimaryAndRetainedUnscopedListingsIgnoreDeceptiveProfileFields() {
        let primaryJob = CronJobRecord([
            "job_id": "same-id", "name": "[bot:primary] Job",
            "profile": "retained-store",
        ])
        let retainedJob = CronJobRecord([
            "job_id": "same-id", "name": "[bot:retained] Job",
            "profile_name": "primary-store",
        ])
        let primaryListing = CronListing(
            jobs: [primaryJob], scopedProfile: nil, profile: "retained-store")
        let retainedListing = CronListing(
            jobs: [retainedJob], scopedProfile: nil, profile: "primary-store")

        // Both calls were unscoped. Neither row nor top-level profile metadata
        // can prove which HERMES_HOME produced the result.
        XCTAssertNil(CronListingScopePolicy.scope(
            for: primaryListing, requestedProfile: nil))
        XCTAssertNil(CronListingScopePolicy.scope(
            for: retainedListing, requestedProfile: nil))
        XCTAssertEqual(CronListingAttributionPolicy.displayBotID(for: primaryJob), "primary")
        XCTAssertEqual(CronListingAttributionPolicy.displayBotID(for: retainedJob), "retained")

        // A requested profile becomes authoritative only when the response
        // echoes that exact requested scope; deceptive row metadata is ignored.
        let scoped = CronListing(
            jobs: [primaryJob], scopedProfile: "primary-store", profile: "retained-store")
        XCTAssertEqual(CronListingScopePolicy.scope(
            for: scoped, requestedProfile: "primary-store"), "primary-store")
        XCTAssertEqual(CronListingAttributionPolicy.displayBotID(
            for: primaryJob, scopedProfile: "primary-store"), "primary")
    }

    func testUnscopedDisplayTagIsNotStoreOrRESTAuthority() {
        let job = CronJobRecord([
            "job_id": "created",
            "name": "[bot:worker] Created",
            "profile": "deceptive-store",
        ])
        let target = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: job.id),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "worker"),
            profile: nil)

        // The validated namespace remains useful for the selected bot's UI
        // row and socket actions, but it cannot authorize a REST/profile store.
        XCTAssertEqual(CronListingAttributionPolicy.displayBotID(for: job), "worker")
        XCTAssertEqual(target.bot.profile, "worker")
        XCTAssertNil(target.profile)
        XCTAssertFalse(CronDetailAuthorityPolicy.allowsProfileScopedREST(
            profile: target.profile))
    }

    func testMissingScopedEchoIsAnIncompleteSnapshot() {
        let missing = CronListing(
            jobs: [CronJobRecord(["job_id": "same-id", "name": "[bot:a] Job"])],
            scopedProfile: nil,
            profile: "a")
        let exact = CronListing(
            jobs: [], scopedProfile: "a", profile: "deceptive")

        XCTAssertFalse(CronListingScopePolicy.acceptsExactScopeEcho(
            missing, requestedProfile: "a"))
        XCTAssertTrue(CronListingScopePolicy.acceptsExactScopeEcho(
            exact, requestedProfile: "a"))
        XCTAssertEqual(
            CronListingScopePolicy.incompleteScopeMessage,
            "Profile-scoped routine response did not echo its requested profile.")
    }

    func testSecondaryRefreshCapturesEveryProfileAndRejectsAChangeDuringB() {
        let profileA = ProfileLifecycleGenerationToken(
            route: GatewayBotRoute(gatewayID: "homelab", profile: "a"), generation: 4)
        let profileB = ProfileLifecycleGenerationToken(
            route: GatewayBotRoute(gatewayID: "homelab", profile: "b"), generation: 9)
        let expected = ["a", "b"]
        let tokens = ["a": profileA, "b": profileB]
        var current = ["a": UInt64(4), "b": UInt64(9)]

        XCTAssertTrue(CronProfileRefreshPolicy.hasAllExpectedProfileTokens(
            expectedProfiles: expected, tokens: tokens))
        XCTAssertTrue(CronProfileRefreshPolicy.capturedProfilesRemainCurrent(
            expectedProfiles: expected, tokens: tokens,
            isCurrent: { current[$0.route.profile] == $0.generation }))

        // Profile A changes while the later B request is in flight. Checking
        // only B would publish a mixed snapshot; checking all captured tokens
        // retains the previous verified rows instead.
        current["a"] = 5
        XCTAssertFalse(CronProfileRefreshPolicy.capturedProfilesRemainCurrent(
            expectedProfiles: expected, tokens: tokens,
            isCurrent: { current[$0.route.profile] == $0.generation }))
        XCTAssertFalse(CronProfileRefreshPolicy.hasAllExpectedProfileTokens(
            expectedProfiles: expected, tokens: ["a": profileA]))
    }

    func testLegacyRoutineRefreshIsDemoOnlyAndCannotPublishLiveRows() {
        XCTAssertTrue(CronRoutineRefreshAuthorityPolicy.allowsLegacyRefresh(mode: .demo))
        XCTAssertFalse(CronRoutineRefreshAuthorityPolicy.allowsLegacyRefresh(mode: .live))
    }

    func testPrimaryAndRetainedRESTOnlyCreateStayAcceptedPartialWithoutLaunchAuthority() {
        let primary = CronCreatePostAddPolicy.decision(
            sourceFence: CronSourceMutationFence(
                gatewayID: "primary", profile: nil, generation: .primary(3)),
            primaryGatewayID: "primary", primaryGeneration: 3,
            retainedGenerations: [:], hasRESTOnlyFields: true, hasJobID: true,
            hasRESTAuthority: false, restSupported: false)
        let retained = CronCreatePostAddPolicy.decision(
            sourceFence: CronSourceMutationFence(
                gatewayID: "retained", profile: nil, generation: .retained(7)),
            primaryGatewayID: "primary", primaryGeneration: 3,
            retainedGenerations: ["retained": 7], hasRESTOnlyFields: true,
            hasJobID: true, hasRESTAuthority: false, restSupported: false)

        XCTAssertEqual(primary, .acceptedWithoutREST)
        XCTAssertEqual(retained, .acceptedWithoutREST)
        XCTAssertFalse(primary.shouldIssueRESTPatch)
        XCTAssertFalse(retained.shouldIssueRESTPatch)
    }

    func testUnscopedCreateSuppressesRESTExtrasAndOrdinaryAddCompletes() {
        XCTAssertFalse(CronCreateRESTPolicy.allowsExtras(launchProfile: nil))
        XCTAssertTrue(CronCreateRESTPolicy.extras(
            launchProfile: nil, deliver: ["local"], model: "model",
            provider: "provider", reasoningEffort: "high").isEmpty)

        let primary = CronCreatePostAddPolicy.decision(
            sourceFence: CronSourceMutationFence(
                gatewayID: "primary", profile: nil, generation: .primary(4)),
            primaryGatewayID: "primary", primaryGeneration: 4,
            retainedGenerations: [:], hasRESTOnlyFields: false, hasJobID: true,
            hasRESTAuthority: false, restSupported: false)
        XCTAssertEqual(primary, .accepted)
        XCTAssertFalse(primary.requiresRecoveryNotice)
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

    func testProfileRefreshRaceRetainsSnapshotWhenLifecycleAuthorityChanges() {
        XCTAssertTrue(CronProfileRefreshPolicy.mayPublishSnapshot(
            sourceAccepted: true, lifecycleAuthorityAccepted: true))
        XCTAssertFalse(CronProfileRefreshPolicy.mayPublishSnapshot(
            sourceAccepted: true, lifecycleAuthorityAccepted: false))
        XCTAssertFalse(CronProfileRefreshPolicy.mayPublishSnapshot(
            sourceAccepted: false, lifecycleAuthorityAccepted: true))
    }

    func testProfileDeletionOwnsFullCronActivityKeys() {
        XCTAssertTrue(CronQuarantinePolicy.ownsActivityKey(
            "cron-quarantine:job-1|homelab|job-1|default|retained-4|9",
            routineID: "job-1"))
        XCTAssertTrue(CronQuarantinePolicy.ownsActivityKey(
            "cron-run:job-1|homelab|job-1|default|retained-4|9:1720000000",
            routineID: "job-1"))
        XCTAssertFalse(CronQuarantinePolicy.ownsActivityKey(
            "cron-quarantine:job-10|homelab|job-10|default|retained-4|9",
            routineID: "job-1"))
        XCTAssertFalse(CronQuarantinePolicy.ownsActivityKey(
            "routine-toggle:job-1|homelab|job-1|default|retained-4|9",
            routineID: "job-1"))
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

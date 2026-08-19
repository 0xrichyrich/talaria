#if canImport(XCTest)
import XCTest
import TalariaKit
@testable import TalariaUI

@MainActor
final class SourceQualifiedRoutingTests: XCTestCase {
    override func tearDown() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = nil
        runtime.defaultBotID = nil
        runtime.sessionToBot.removeAll()
        runtime.routedSessionToBot.removeAll()
        runtime.approvalTargets.removeAll()
        MultiGatewayRuntime.shared.routedUnread.removeAll()
        ApprovalBridges.shared.details.removeAll()
        ApprovalBridges.shared.prompts.removeAll()
        ApprovalBridges.shared.decided.removeAll()
        ApprovalBridges.shared.sweptSessions.removeAll()
        ApprovalBridges.shared.sweepFailures.removeAll()
        ApprovalBridges.shared.sweepEpochs.removeAll()
        FeedsRuntime.shared.cronJobs.removeAll()
        FeedsRuntime.shared.cronScope.removeAll()
        FeedsRuntime.shared.routineTargets.removeAll()
        CronDetailRuntime.shared.reset()
        CronDetailRuntime.shared.changeTick = 0
        CapabilityRuntime.shared.states.removeAll()
        ProfileAssetStore.shared.flush()
        PetRuntime.shared.reset()
        SessionsRuntime.shared.resetPrimaryScope()
        SessionsRuntime.shared.resetRoutedScope(gatewayID: "homelab")
        super.tearDown()
    }

    func testSameRuntimeSessionIDRoutesByGateway() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "primary"),
                       "default")
        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "homelab"),
                       "homelab::researcher")
        XCTAssertNil(model.botID(forSession: "deadbeef", sourceGatewayID: "unknown"))
    }

    func testRemoteDeltaCannotMutateCollidingPrimaryChat() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        let event = GatewayEvent(type: "message.delta", sessionID: "deadbeef",
                                 payload: .object(["text": .string("remote answer")]))
        model.handle(event: event, sourceGatewayID: "homelab")

        XCTAssertTrue(model.chat(for: "default").messages.isEmpty)
        XCTAssertEqual(model.chat(for: "homelab::researcher").messages.last?.text,
                       "remote answer")
    }

    func testForeignOpenKeepsQualifiedIdentity() async {
        let model = AppModel()
        let entry = ForeignRosterEntry(gatewayID: "homelab",
                                       connectionLabel: "Homelab",
                                       connectionKind: .tailscale,
                                       profile: "researcher",
                                       handle: "researcher")

        await model.openForeignBot(entry)

        XCTAssertEqual(model.openBotID, "homelab::researcher")
        XCTAssertEqual(model.selectedTab, .home)
    }

    func testPrimaryResetPreservesRemoteSessionRouting() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["aaaaaaaa"] = "default"
        let remote = GatewaySessionRoute(gatewayID: "homelab", sessionID: "bbbbbbbb")
        runtime.routedSessionToBot[remote] = "homelab::researcher"
        runtime.workingBotIDs = ["default", "homelab::researcher"]
        runtime.approvalTargets["primary"] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "primary-wire")
        runtime.approvalTargets["remote"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "bbbbbbbb",
            requestID: "remote-wire")

        runtime.resetSessionState()

        XCTAssertTrue(runtime.sessionToBot.isEmpty)
        XCTAssertEqual(runtime.routedSessionToBot[remote], "homelab::researcher")
        XCTAssertEqual(runtime.workingBotIDs, ["homelab::researcher"])
        XCTAssertNil(runtime.approvalTargets["primary"])
        XCTAssertEqual(runtime.approvalTargets["remote"]?.requestID, "remote-wire")
    }

    func testRemoteSessionTitleCannotPatchCollidingPrimaryStoredID() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        model.chat(for: "default").storedSessions = [
            SessionSummary(id: "same-row", title: "Primary", when: "now", messageCount: 1),
        ]
        model.chat(for: "homelab::researcher").storedSessions = [
            SessionSummary(id: "same-row", title: "Remote", when: "now", messageCount: 1),
        ]

        let event = GatewayEvent(type: "session.title", sessionID: "deadbeef",
                                 payload: .object([
                                    "session_id": .string("same-row"),
                                    "title": .string("Remote renamed"),
                                 ]))
        model.applySessionTitle(event, sourceGatewayID: "homelab")

        XCTAssertEqual(model.chat(for: "default").storedSessions[0].title, "Primary")
        XCTAssertEqual(model.chat(for: "homelab::researcher").storedSessions[0].title,
                       "Remote renamed")
        XCTAssertNil(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "default", sessionID: "same-row")])
        XCTAssertEqual(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "homelab::researcher", sessionID: "same-row")],
                       "Remote renamed")
    }

    func testRemoteCompletionPrunesOnlyExactGatewaySessionRoute() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        runtime.approvalTargets["primary-approval"] = target(
            gatewayID: "primary", profile: "default", sessionID: "deadbeef",
            requestID: "primary-wire")
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "remote-wire")
        model.approvals = [
            approval(id: "primary-approval", botID: "default"),
            approval(id: "remote-approval", botID: "homelab::researcher"),
        ]

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("")])),
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.approvals.map(\.id), ["primary-approval"])
        XCTAssertEqual(runtime.approvalTargets["primary-approval"]?.session.sessionID,
                       "deadbeef")
        XCTAssertNil(runtime.approvalTargets["remote-approval"])
    }

    func testUnmappedRemoteApprovalCannotFallbackToPrimaryBot() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.defaultBotID = "default"

        model.handle(event: approvalEvent(requestID: "orphaned", sessionID: "deadbeef"),
                     sourceGatewayID: "homelab")

        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertTrue(runtime.approvalTargets.isEmpty)
    }

    func testApprovalResponseRejectsMixedGatewayOwnership() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "wire-request")
        let item = approval(id: "remote-approval", botID: "default")

        let target = model.approvalResponseTarget(
            for: item, botRoute: GatewayBotRoute(gatewayID: "primary", profile: "default"))

        XCTAssertNil(target)
    }

    func testApprovalResponseKeepsQualifiedRemoteDestination() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let session = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "wire-request")
        let item = approval(id: "remote-approval", botID: "homelab::researcher")
        let bot = GatewayBotRoute(gatewayID: "homelab", profile: "researcher")

        XCTAssertEqual(model.approvalResponseTarget(for: item, botRoute: bot),
                       ApprovalResponseTarget(bot: bot, session: session,
                                              requestID: "wire-request"))
    }

    func testSameApprovalRequestIDRemainsDistinctAcrossGateways() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::default"

        model.handle(event: approvalEvent(requestID: "same-request", sessionID: "deadbeef"),
                     sourceGatewayID: "primary")
        model.handle(event: approvalEvent(requestID: "same-request", sessionID: "deadbeef"),
                     sourceGatewayID: "homelab")

        XCTAssertEqual(model.approvals.count, 2)
        XCTAssertEqual(Set(model.approvals.map(\.id)).count, 2)
        XCTAssertEqual(Set(runtime.approvalTargets.values.map(\.requestID)), ["same-request"])
        XCTAssertEqual(Set(runtime.approvalTargets.values.map(\.session.gatewayID)),
                       ["primary", "homelab"])
    }

    func testCollidingBlockingPromptIDsDismissOnlyOwningGateway() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::default"
        let event = GatewayEvent(type: "clarify.request", sessionID: "deadbeef",
                                 payload: .object([
                                    "request_id": .string("same-request"),
                                    "question": .string("Continue?"),
                                 ]))

        model.handleBridgeEvent(event, sourceGatewayID: "primary")
        model.handleBridgeEvent(event, sourceGatewayID: "homelab")

        XCTAssertEqual(ApprovalBridges.shared.prompts.count, 2)
        XCTAssertEqual(Set(ApprovalBridges.shared.prompts.map(\.id)).count, 2)
        model.dismissBlockingPrompt("same-request")
        XCTAssertEqual(ApprovalBridges.shared.prompts.count, 2,
                       "a bare colliding request id must fail closed")
        model.dismissBlockingPrompt("same-request", sourceGatewayID: "homelab")
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.gatewayID), ["primary"])
    }

    func testWireApprovalLookupUsesBotToDisambiguateGatewayCollision() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        let primaryID = GatewayApprovalRoute(gatewayID: "primary",
                                              requestID: "same-request").qualifiedID
        let remoteID = GatewayApprovalRoute(gatewayID: "homelab",
                                             requestID: "same-request").qualifiedID
        runtime.approvalTargets[primaryID] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "same-request")
        runtime.approvalTargets[remoteID] = target(
            gatewayID: "homelab", profile: "default", sessionID: "bbbbbbbb",
            requestID: "same-request")
        model.approvals = [
            approval(id: primaryID, botID: "default"),
            approval(id: remoteID, botID: "homelab::default"),
        ]

        XCTAssertNil(model.approval(matchingWireRequestID: "same-request", botID: nil))
        XCTAssertEqual(model.approval(matchingWireRequestID: "same-request",
                                      botID: "homelab::default")?.id, remoteID)
    }

    func testGatewayDetachDropsOnlyItsApprovalSurfaces() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        let primaryID = GatewayApprovalRoute(gatewayID: "primary",
                                              requestID: "primary").qualifiedID
        let remoteID = GatewayApprovalRoute(gatewayID: "homelab",
                                             requestID: "remote").qualifiedID
        runtime.approvalTargets[primaryID] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "primary")
        runtime.approvalTargets[remoteID] = target(
            gatewayID: "homelab", profile: "default", sessionID: "bbbbbbbb",
            requestID: "remote")
        model.approvals = [
            approval(id: primaryID, botID: "default"),
            approval(id: remoteID, botID: "homelab::default"),
        ]
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .sudo, gatewayID: "primary", requestID: "prompt",
                           sessionID: "aaaaaaaa", botID: "default", question: ""),
            BlockingPrompt(kind: .sudo, gatewayID: "homelab", requestID: "prompt",
                           sessionID: "bbbbbbbb", botID: "homelab::default", question: ""),
        ]

        model.dropApprovalScope(gatewayID: "homelab")

        XCTAssertEqual(model.approvals.map(\.id), [primaryID])
        XCTAssertNotNil(runtime.approvalTargets[primaryID])
        XCTAssertNil(runtime.approvalTargets[remoteID])
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.gatewayID), ["primary"])
    }

    func testFailedApprovalResponseReopensCardAndClearsFalseOutcome() {
        let model = AppModel()
        let item = approval(id: "retry", botID: "default")
        ApprovalOutcomes.shared.record(item, approved: true)
        ApprovalBridges.shared.decided[item.id] = .always

        model.restoreFailedApproval(item)

        XCTAssertEqual(model.approvals, [item])
        XCTAssertNil(ApprovalOutcomes.shared.choice(for: item.id))
    }

    func testCollidingRoutineIDsKeepDistinctGatewayTargets() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let primary = routine(id: "same", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: "default")

        XCTAssertTrue(model.routineHasFullManagement(primary))
        XCTAssertTrue(model.routineHasFullManagement(remote))
        XCTAssertEqual(model.routineTarget(primary.id)?.route,
                       GatewayRoutineRoute(gatewayID: "primary", jobID: "same"))
        XCTAssertEqual(model.routineTarget(remote.id)?.route,
                       GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"))
        XCTAssertEqual(model.cronScope(primary.id), nil)
        XCTAssertEqual(model.cronScope(remote.id), "default")
        XCTAssertEqual(model.routineGatewayID(routineID: primary.id), "primary")
        XCTAssertEqual(model.routineGatewayID(routineID: remote.id), "homelab")
        XCTAssertEqual(model.routineGatewayID(botID: "default"), "primary")
        XCTAssertEqual(model.routineGatewayID(botID: "homelab::default"), "homelab")
    }

    func testRoutineRESTCapabilityAndDeliveryCachesAreGatewayScoped() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let primary = routine(id: "same", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        let runtime = CronDetailRuntime.shared
        runtime.restSupported["primary"] = false
        runtime.restSupported["homelab"] = true
        runtime.deliveryTargets["primary"] = [CronDeliveryTarget(["id": "local"])]
        runtime.deliveryTargets["homelab"] = [CronDeliveryTarget(["id": "telegram"])]

        XCTAssertEqual(model.cronDeliveryTargets(routineID: primary.id).map(\.id), ["local"])
        XCTAssertEqual(model.cronDeliveryTargets(routineID: remote.id).map(\.id), ["telegram"])
        XCTAssertEqual(runtime.restSupported[model.routineGatewayID(routineID: primary.id)!], false)
        XCTAssertEqual(runtime.restSupported[model.routineGatewayID(routineID: remote.id)!], true)
    }

    func testRoutineRunTranscriptKeepsOwningGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        LiveRuntime.shared.defaultBotID = "default"
        let primaryID = "same"
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        FeedsRuntime.shared.routineTargets[primaryID] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remoteID] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        let run = CronRun(["id": "cron_same_1", "profile": "default"])

        XCTAssertEqual(model.routineRunBotID(run, routineID: primaryID,
                                             fallbackBotID: "default"), "default")
        XCTAssertEqual(model.routineRunBotID(run, routineID: remoteID,
                                             fallbackBotID: "default"), "homelab::default")
    }

    func testCollidingCapabilityProfilesKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.capabilities(for: "default")
        let remote = model.capabilities(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target,
                       CapabilityTarget(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target,
                       CapabilityTarget(gatewayID: "homelab", profile: "default"))
        XCTAssertNotEqual(primary.target?.stateKey, remote.target?.stateKey)
        XCTAssertEqual(model.capabilityTarget(profileID: "homelab::default")?.profile,
                       "default")
    }

    func testCapabilityStateFollowsGatewayRoleWithoutCollision() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let before = model.capabilities(for: "default")
        LiveRuntime.shared.gatewayID = "homelab"
        let after = model.capabilities(for: "default")

        XCTAssertFalse(before === after)
        XCTAssertEqual(before.target?.gatewayID, "primary")
        XCTAssertEqual(after.target?.gatewayID, "homelab")
    }

    func testCapabilityGatewayDetachPreservesOtherGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.capabilities(for: "default")
        let remote = model.capabilities(for: "homelab::default")
        let primaryKey = primary.target!.stateKey
        let remoteKey = remote.target!.stateKey
        remote.skills = [SkillEntry(name: "browser", category: "web",
                                    scope: .profile, enabled: true)]
        remote.busy.insert("skill:browser")
        remote.hasLoaded = true

        model.dropCapabilityScope(gatewayID: "homelab")

        XCTAssertTrue(CapabilityRuntime.shared.states[primaryKey] === primary)
        XCTAssertNil(CapabilityRuntime.shared.states[remoteKey])
        XCTAssertTrue(remote.skills.isEmpty)
        XCTAssertTrue(remote.busy.isEmpty)
        XCTAssertFalse(remote.hasLoaded)
    }

    func testProfileRPCIdentityStripsOnlyTheQualifiedSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"

        XCTAssertEqual(model.profileRoute(for: "default"),
                       GatewayBotRoute(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(model.profileRoute(for: "homelab::default"),
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
        XCTAssertEqual(model.cloneID(for: "homelab::default"), "default-2")
    }

    func testPortraitCacheKeepsCollidingProfilesInGatewayScopes() {
        let store = ProfileAssetStore.shared
        LiveRuntime.shared.gatewayID = "primary"
        let primary = Data([0x01])
        let remote = Data([0x02])

        store.set(primary, for: "default")
        store.set(remote, for: "homelab::default")

        XCTAssertEqual(store.portrait(for: "default"), primary)
        XCTAssertEqual(store.portrait(for: "homelab::default"), remote)
        store.drop(gatewayID: "homelab")
        XCTAssertEqual(store.portrait(for: "default"), primary)
        XCTAssertNil(store.portrait(for: "homelab::default"))
        store.set(remote, for: "homelab::default")
        LiveRuntime.shared.gatewayID = "homelab"
        XCTAssertEqual(store.portrait(for: "default"), remote)
    }

    func testProfileEditRequiresEveryIndependentSectionAcknowledgement() {
        let edit = ProfileEdit(description: "Ops", soul: "Careful",
                               model: "model-a", provider: "provider-a",
                               disabledSkills: ["browser"], enabledToolsets: [],
                               uiMeta: .object(["hermes-bots": .object([:])]))

        XCTAssertEqual(edit.expectedAppliedSections,
                       ["description", "soul", "model", "skills", "toolsets", "ui_meta"])
        XCTAssertFalse(edit.wasFullyApplied([
            "description": true, "soul": true, "model": true,
            "skills": true, "toolsets": false, "ui_meta": true
        ]))
        XCTAssertTrue(edit.wasFullyApplied(Dictionary(
            uniqueKeysWithValues: edit.expectedAppliedSections.map { ($0, true) })))
        let invalidPin = ProfileEdit(model: "model-a")
        XCTAssertFalse(invalidPin.isWireValid)
        XCTAssertFalse(invalidPin.wasFullyApplied([:]))
    }

    func testCollidingPetProfilesKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target, PetTarget(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target, PetTarget(gatewayID: "homelab", profile: "default"))
        XCTAssertNotEqual(primary.target?.stateKey, remote.target?.stateKey)
    }

    func testPetUnsupportedCapabilityIsScopedToItsGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        PetRuntime.shared.unsupportedGateways.insert("homelab")

        XCTAssertTrue(model.pets(for: "default").supported)
        XCTAssertFalse(model.pets(for: "homelab::default").supported)
    }

    func testPetGatewayDetachScrubsOnlyOwningSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")
        primary.hasLoaded = true
        remote.hasLoaded = true
        remote.notice = "private remote failure"
        remote.busy.insert("select:fox")
        let primaryKey = primary.target!.stateKey
        let remoteKey = remote.target!.stateKey
        PetRuntime.shared.loadIDs[primaryKey] = UUID()
        PetRuntime.shared.loadIDs[remoteKey] = UUID()
        PetRuntime.shared.refreshTasks["primary"] = Task {}
        PetRuntime.shared.refreshTasks["homelab"] = Task {}

        model.dropPetScope(gatewayID: "homelab")

        XCTAssertTrue(PetRuntime.shared.states[primaryKey] === primary)
        XCTAssertNil(PetRuntime.shared.states[remoteKey])
        XCTAssertTrue(primary.hasLoaded)
        XCTAssertFalse(remote.hasLoaded)
        XCTAssertNil(remote.notice)
        XCTAssertTrue(remote.busy.isEmpty)
        XCTAssertNotNil(PetRuntime.shared.loadIDs[primaryKey])
        XCTAssertNil(PetRuntime.shared.loadIDs[remoteKey])
        XCTAssertNotNil(PetRuntime.shared.refreshTasks["primary"])
        XCTAssertNil(PetRuntime.shared.refreshTasks["homelab"])
    }

    func testPetGenerationProgressRequiresOwningGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = model.pets(for: "homelab::default")
        remote.generation.phase = .drafting
        PetRuntime.shared.generatingProfiles["homelab"] = remote.target!.stateKey
        let event = GatewayEvent(type: "pet.generate.progress", sessionID: "",
                                 payload: .object(["token": .string("remote-token"),
                                                   "count": .number(4)]))

        model.routePetEvent(event, sourceGatewayID: "primary")
        XCTAssertTrue(remote.generation.token.isEmpty)
        model.routePetEvent(event, sourceGatewayID: "homelab")
        XCTAssertEqual(remote.generation.token, "remote-token")
        XCTAssertEqual(remote.generation.expectedDrafts, 4)
    }

    func testPetGenerationRunsAreIndependentPerGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")
        let runtime = PetRuntime.shared
        primary.generation.phase = .drafting
        remote.generation.phase = .drafting
        runtime.generatingProfiles["primary"] = primary.target!.stateKey
        runtime.generatingProfiles["homelab"] = remote.target!.stateKey
        runtime.runIDs["primary"] = UUID()
        runtime.runIDs["homelab"] = UUID()
        runtime.runTasks["primary"] = Task { try? await Task.sleep(for: .seconds(10)) }
        runtime.runTasks["homelab"] = Task { try? await Task.sleep(for: .seconds(10)) }

        model.dropPetScope(gatewayID: "homelab")

        XCTAssertNotNil(runtime.runTasks["primary"])
        XCTAssertNotNil(runtime.runIDs["primary"])
        XCTAssertEqual(runtime.generatingProfiles["primary"], primary.target!.stateKey)
        XCTAssertNil(runtime.runTasks["homelab"])
        XCTAssertNil(runtime.runIDs["homelab"])
        XCTAssertNil(runtime.generatingProfiles["homelab"])
    }

    func testRoutineGatewayDetachPreservesOtherGatewayRows() {
        let model = AppModel()
        let primary = routine(id: "primary-job", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "remote-job").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        let orphanedCacheRow = routine(id: "stale-cache", botID: "homelab::researcher")
        model.routines = [primary, remote, orphanedCacheRow]
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "primary-job"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "remote-job"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        CronDetailRuntime.shared.detail[primary.id] = CronJobDetail(["id": "primary-job"])
        CronDetailRuntime.shared.detail[remote.id] = CronJobDetail(["id": "remote-job"])
        CronDetailRuntime.shared.deliveryTargets["primary"] = [CronDeliveryTarget(["id": "local"])]
        CronDetailRuntime.shared.deliveryTargets["homelab"] = [CronDeliveryTarget(["id": "telegram"])]
        CronDetailRuntime.shared.restSupported["primary"] = true
        CronDetailRuntime.shared.restSupported["homelab"] = true

        model.dropRoutineScope(gatewayID: "homelab")

        XCTAssertEqual(model.routines, [primary])
        XCTAssertNotNil(FeedsRuntime.shared.routineTargets[primary.id])
        XCTAssertNil(FeedsRuntime.shared.routineTargets[remote.id])
        XCTAssertNotNil(CronDetailRuntime.shared.detail[primary.id])
        XCTAssertNil(CronDetailRuntime.shared.detail[remote.id])
        XCTAssertNotNil(CronDetailRuntime.shared.deliveryTargets["primary"])
        XCTAssertNil(CronDetailRuntime.shared.deliveryTargets["homelab"])
        XCTAssertEqual(CronDetailRuntime.shared.restSupported["primary"], true)
        XCTAssertNil(CronDetailRuntime.shared.restSupported["homelab"])
    }

    func testUnreadWatermarksKeepCollidingProfilesInSeparateGatewayScopes() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!

        XCTAssertTrue(store.ingest(["default": 100], openBot: nil, scope: primary).isEmpty)
        XCTAssertTrue(store.ingest(["default": 500], openBot: nil, scope: homelab).isEmpty)
        XCTAssertEqual(store.ingest(["default": 101], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertEqual(store.ingest(["default": 501], openBot: nil, scope: homelab),
                       ["default"])
    }

    func testUnreadAcknowledgeNamesItsGatewayExplicitly() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!
        _ = store.ingest(["default": 100], openBot: nil, scope: primary)
        _ = store.ingest(["default": 100], openBot: nil, scope: homelab)

        store.acknowledge("default", scope: homelab)

        XCTAssertEqual(store.ingest(["default": 200], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertTrue(store.ingest(["default": 200], openBot: nil, scope: homelab).isEmpty)
    }

    func testRemoteUnreadCannotBadgeOrClearCollidingPrimaryBot() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.recordUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
        XCTAssertEqual(model.totalRosterUnread, 1)

        model.recordUnread(for: "default")
        model.clearUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 1)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testRemoteCompletionBadgesOnlyItsQualifiedBot() {
        let model = AppModel()
        model.mode = .live
        model.bots = [.unlisted(id: "default")]
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let route = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.routedSessionToBot[route] = "homelab::default"
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("done")])),
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
    }

    func testOpeningRemoteChatClearsOnlyItsQualifiedUnread() {
        let model = AppModel()
        model.mode = .demo
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 2
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        MultiGatewayRuntime.shared.routedUnread[remote] = 3

        model.openChat(botID: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 2)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testUnreadCountSurvivesGatewayRoleTransitionsExactlyOnce() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 3
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")

        model.preservePrimaryUnreadForGatewaySwitch()

        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[route], 3)
        model.bots = []
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 3)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[route])
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 0)
    }

    private func approval(id: String, botID: String) -> Approval {
        Approval(id: id, botID: botID, kind: .command, title: "Run",
                 target: "shell", subject: "echo ok", body: "echo ok",
                 why: "test", age: "now")
    }

    private func approvalEvent(requestID: String, sessionID: String) -> GatewayEvent {
        GatewayEvent(type: "approval.request", sessionID: sessionID, payload: .object([
            "request_id": .string(requestID),
            "command": .string("echo ok"),
            "description": .string("Run command"),
            "choices": .array([.string("once"), .string("deny")]),
        ]))
    }

    private func target(gatewayID: String, profile: String, sessionID: String,
                        requestID: String) -> ApprovalResponseTarget {
        ApprovalResponseTarget(
            bot: GatewayBotRoute(gatewayID: gatewayID, profile: profile),
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: sessionID),
            requestID: requestID)
    }

    private func routine(id: String, botID: String) -> Routine {
        Routine(id: id, botID: botID, name: "Backup", schedule: "every 1h",
                next: "in 1h", last: "", isOn: true)
    }
}
#endif

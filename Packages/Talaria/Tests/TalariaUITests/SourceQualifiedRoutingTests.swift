#if canImport(XCTest)
import XCTest
@testable import TalariaKit
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
        FeedsRuntime.shared.inboxSessions.removeAll()
        CronDetailRuntime.shared.reset()
        CronDetailRuntime.shared.changeTick = 0
        CapabilityRuntime.shared.states.removeAll()
        ModelPickerRuntime.shared.states.removeAll()
        ApprovalPolicyRuntime.shared.reset()
        ProfileAssetStore.shared.flush()
        PetRuntime.shared.reset()
        SessionsRuntime.shared.resetPrimaryScope()
        SessionsRuntime.shared.resetRoutedScope(gatewayID: "homelab")
        A2ARuntime.shared.reset()
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

    func testApprovalPolicyStoresRemainDistinctAcrossGateways() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let runtime = ApprovalPolicyRuntime.shared

        runtime.selectedGatewayID = "primary"
        let primary = model.approvalPolicy
        primary.mode = .manual
        primary.pairing = PairingSnapshot(
            pending: [], approved: [PairedUser(platform: "telegram", userID: "one",
                                               userName: "One", approvedAt: nil)])

        runtime.selectedGatewayID = "homelab"
        let remote = model.approvalPolicy
        remote.mode = .smart
        remote.pairing = PairingSnapshot(
            pending: [], approved: [PairedUser(platform: "discord", userID: "two",
                                               userName: "Two", approvedAt: nil)])

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.mode, .manual)
        XCTAssertEqual(remote.mode, .smart)
        XCTAssertEqual(primary.pairing.approved.map(\.userID), ["one"])
        XCTAssertEqual(remote.pairing.approved.map(\.userID), ["two"])
    }

    func testApprovalPolicySelectionSurvivesPrimaryRoleTransition() {
        let model = AppModel()
        model.mode = .live
        let runtime = ApprovalPolicyRuntime.shared
        runtime.selectedGatewayID = "homelab"
        let selected = model.approvalPolicy
        selected.mode = .off

        LiveRuntime.shared.gatewayID = "primary"
        XCTAssertTrue(model.approvalPolicy === selected)
        LiveRuntime.shared.gatewayID = "homelab"
        XCTAssertTrue(model.approvalPolicy === selected)
        XCTAssertEqual(model.approvalPolicy.mode, .off)
    }

    func testSelectedRemotePolicyListsOnlyItsSessionBypasses() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        ApprovalPolicyRuntime.shared.selectedGatewayID = "homelab"
        let primary = Bot.unlisted(id: "default")
        let remote = Bot.unlisted(id: "homelab::researcher")
        model.chat(for: primary.id).yolo = true
        model.chat(for: remote.id).yolo = true

        let visible = model.approvalSessionBypassBots(in: [primary, remote])

        XCTAssertEqual(visible.map(\.id), ["homelab::researcher"])
    }

    func testApprovalPolicyDetachDropsOnlyOwningGateway() {
        let model = AppModel()
        model.mode = .live
        let runtime = ApprovalPolicyRuntime.shared
        runtime.selectedGatewayID = "primary"
        let primary = model.approvalPolicy
        primary.mode = .smart
        runtime.selectedGatewayID = "homelab"
        let remote = model.approvalPolicy
        remote.mode = .off

        model.dropApprovalPolicyScope(gatewayID: "homelab")

        runtime.selectedGatewayID = "primary"
        XCTAssertTrue(model.approvalPolicy === primary)
        XCTAssertEqual(model.approvalPolicy.mode, .smart)
        runtime.selectedGatewayID = "homelab"
        XCTAssertFalse(model.approvalPolicy === remote)
        XCTAssertEqual(model.approvalPolicy.mode, .manual)
    }

    func testPairingChangeDuringReadQueuesOneFollowUpRefresh() async {
        let model = AppModel()
        let store = model.approvalPolicy
        store.isLoadingPairing = true

        await model.loadPairing()

        XCTAssertTrue(store.pairingRefreshPending)
        store.isLoadingPairing = false
        await model.loadPairing()
        await Task.yield()
        XCTAssertFalse(store.pairingRefreshPending)
        XCTAssertTrue(store.hasLoadedPairing)
        XCTAssertEqual(store.pairingSupport, .supported)
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

    func testCollidingModelPickersKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.modelPicker(for: "default")
        let remote = model.modelPicker(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target, GatewayBotRoute(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target, GatewayBotRoute(gatewayID: "homelab", profile: "default"))
        primary.catalog.model = "primary-model"
        remote.catalog.model = "remote-model"
        XCTAssertEqual(primary.catalog.model, "primary-model")
        XCTAssertEqual(remote.catalog.model, "remote-model")
    }

    func testModelPickerFollowsGatewayRoleWithoutCollision() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let originalPrimary = model.modelPicker(for: "default")
        originalPrimary.catalog.model = "primary-model"

        LiveRuntime.shared.gatewayID = "homelab"
        let formerPrimaryAsRemote = model.modelPicker(for: "primary::default")
        let newPrimary = model.modelPicker(for: "default")

        XCTAssertTrue(formerPrimaryAsRemote === originalPrimary)
        XCTAssertEqual(formerPrimaryAsRemote.catalog.model, "primary-model")
        XCTAssertFalse(newPrimary === originalPrimary)
        XCTAssertEqual(newPrimary.target,
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
    }

    func testModelSettingsTargetPrefersExplicitGateway() {
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: "homelab", available: ["primary", "homelab"],
            active: "primary", runtime: "primary"), "homelab")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: nil, available: ["primary"],
            active: "primary", runtime: "stale"), "primary")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: nil, available: [],
            active: nil, runtime: "reconnecting"), "reconnecting")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: "deleted", available: ["primary"],
            active: "primary", runtime: "primary"), "primary")
    }

    func testModelSettingsRejectsLateResultAfterGatewayRoundTrip() {
        // A → B → A has the same apparent gateway id, but not the same
        // generation. The first A request must not paint over the second.
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 4, currentGeneration: 6))
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "homelab", targetGatewayID: "primary",
            generation: 6, currentGeneration: 6))
        XCTAssertTrue(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 6, currentGeneration: 6))
    }

    func testModelSettingsRejectsLateMutationErrorAfterGatewaySwitch() {
        // Mutation errors use the same fence as successes. A failure from the
        // old gateway must not become the notice shown for the newly selected
        // gateway, even when the async operation itself throws.
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "homelab", targetGatewayID: "primary",
            generation: 8, currentGeneration: 9))
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 8, currentGeneration: 9))
    }

    func testOperatorConfigParsesOnlySafeMobileControls() {
        let parsed = GatewayOperatorConfig(.object([
            "agent": .object(["max_turns": .number(750),
                              "image_input_mode": .string("text")]),
            "memory": .object(["memory_enabled": .bool(false),
                               "user_profile_enabled": .bool(true),
                               "write_approval": .bool(true)]),
        ]))
        XCTAssertEqual(parsed.maxTurns, 750)
        XCTAssertEqual(parsed.imageInputMode, "text")
        XCTAssertFalse(parsed.memoryEnabled)
        XCTAssertTrue(parsed.userProfileEnabled)
        XCTAssertTrue(parsed.memoryWriteApproval)
    }

    func testOperatorConfigFailsClosedToDocumentedDefaults() {
        let parsed = GatewayOperatorConfig(.object([
            "agent": .object(["max_turns": .number(0),
                              "image_input_mode": .string("invented")]),
        ]))
        XCTAssertEqual(parsed.maxTurns, 1)
        XCTAssertEqual(parsed.imageInputMode, "auto")
        XCTAssertTrue(parsed.memoryEnabled)
        XCTAssertTrue(parsed.userProfileEnabled)
        XCTAssertFalse(parsed.memoryWriteApproval)
    }

    func testModelGatewayDetachScrubsOnlyOwningSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.modelPicker(for: "default")
        let remote = model.modelPicker(for: "homelab::default")
        primary.pendingConfirmation = PendingModelConfirmation(
            provider: "primary-provider", model: "primary-model", message: "primary")
        remote.pendingConfirmation = PendingModelConfirmation(
            provider: "remote-provider", model: "remote-model", message: "remote")

        model.dropModelScope(gatewayID: "homelab")

        XCTAssertTrue(model.modelPicker(for: "default") === primary)
        XCTAssertFalse(model.modelPicker(for: "homelab::default") === remote)
        XCTAssertEqual(primary.pendingConfirmation?.provider, "primary-provider")
        XCTAssertNil(remote.pendingConfirmation)
        XCTAssertFalse(remote.hasLoaded)
        XCTAssertNil(remote.loadError)
        XCTAssertNil(remote.busyRow)
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

    func testQualifiedRemoteMentionSpeakerExcludesOnlyItself() {
        let primary = Bot.unlisted(id: "default")
        let remote = Bot(id: "homelab::default", job: "", shape: .circle, hue: .teal,
                         handleOverride: "default-homelab",
                         remoteSource: BotSource(profile: "default", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))

        let result = MentionResolver.resolve("@default check", roster: [primary, remote],
                                             speaking: "homelab::default")

        XCTAssertEqual(result.bots.map(\.id), ["default"])
    }

    func testForeignMentionBecomesExactRoutableEndpoint() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = Bot(id: "homelab::researcher", job: "", shape: .circle, hue: .teal,
                         remoteSource: BotSource(profile: "researcher", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))
        let draft = MentionMiddleware.route("@researcher investigate", roster: [remote],
                                            speaking: "default")

        XCTAssertEqual(draft.recipients.map(\.id), ["homelab::researcher"])
        XCTAssertTrue(draft.unreachable.isEmpty)
        XCTAssertEqual(model.a2aEndpoint(for: remote)?.route,
                       GatewayBotRoute(gatewayID: "homelab", profile: "researcher"))
    }

    func testRemoteDefaultEndpointKeepsRouteHandleAndBareAttributionHandleDistinct() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = Bot(id: "homelab::default", job: "", shape: .circle, hue: .teal,
                         handleOverride: "default-homelab",
                         remoteSource: BotSource(profile: "default", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))

        let endpoint = model.a2aEndpoint(for: remote)

        XCTAssertEqual(endpoint?.handle, "default-homelab")
        XCTAssertEqual(endpoint?.attributionHandle, "hermes")
        XCTAssertEqual(endpoint?.route,
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
    }

    func testAttemptDeliveryKeysIsolateEqualProfilesBodiesAndSessions() {
        let body = "same body"
        let attempt = UUID()
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        let primaryKey = AppModel.deliveryKey(route: primary, body: body, attemptID: attempt)
        let remoteKey = AppModel.deliveryKey(route: remote, body: body, attemptID: attempt)
        let repeatKey = AppModel.deliveryKey(route: primary, body: body, attemptID: UUID())

        XCTAssertEqual(Set([primaryKey, remoteKey, repeatKey]).count, 3)
    }

    func testOptimisticDeliveryLookupUsesAttemptUUIDBeforeEqualBodyFallback() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let firstID = UUID()
        let secondID = UUID()
        let firstKey = AppModel.deliveryKey(route: route, body: "same", attemptID: firstID)
        let secondKey = AppModel.deliveryKey(route: route, body: "same", attemptID: secondID)
        A2ARuntime.shared.deliveries[firstKey] = A2ADelivery(
            to: "default", route: route, attemptID: firstID,
            bodyHash: AppModel.stableHash("same"), queuedBehindRun: false,
            state: .replied, at: Date(timeIntervalSince1970: 1))
        A2ARuntime.shared.deliveries[secondKey] = A2ADelivery(
            to: "default", route: route, attemptID: secondID,
            bodyHash: AppModel.stableHash("same"), queuedBehindRun: true,
            state: .waiting, at: Date(timeIntervalSince1970: 2))
        let firstRow = A2AMessage(id: firstID, fromBotID: "ops", toBotID: "default",
                                  time: "now", text: "same")

        XCTAssertEqual(model.delivery(for: firstRow)?.state, .replied)
        XCTAssertEqual(model.delivery(for: firstRow)?.attemptID, firstID)
    }

    func testA2AScopeResetCancelsOnlyOwningGateway() {
        let runtime = A2ARuntime.shared
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        let primaryKey = AppModel.deliveryKey(route: primary, body: "same", attemptID: UUID())
        let remoteKey = AppModel.deliveryKey(route: remote, body: "same", attemptID: UUID())
        let primaryTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let remoteTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let primaryOpen = Task<A2ACanonicalSession, Error> {
            try await Task.sleep(for: .seconds(60))
            return A2ACanonicalSession(runtime: "same", stored: "same")
        }
        let remoteOpen = Task<A2ACanonicalSession, Error> {
            try await Task.sleep(for: .seconds(60))
            return A2ACanonicalSession(runtime: "same", stored: "same")
        }
        runtime.watchers[primaryKey] = primaryTask
        runtime.watchers[remoteKey] = remoteTask
        runtime.watcherScopes[primaryKey] = "primary"
        runtime.watcherScopes[remoteKey] = "homelab"
        runtime.canonicalOpens[primary] = primaryOpen
        runtime.canonicalOpens[remote] = remoteOpen
        runtime.deliveries[primaryKey] = A2ADelivery(
            to: "default", route: primary, queuedBehindRun: false,
            state: .waiting, at: Date())
        runtime.deliveries[remoteKey] = A2ADelivery(
            to: "homelab::default", route: remote, queuedBehindRun: false,
            state: .waiting, at: Date())

        runtime.reset(gatewayID: "homelab")

        XCTAssertFalse(primaryTask.isCancelled)
        XCTAssertTrue(remoteTask.isCancelled)
        XCTAssertFalse(primaryOpen.isCancelled)
        XCTAssertTrue(remoteOpen.isCancelled)
        XCTAssertNotNil(runtime.deliveries[primaryKey])
        XCTAssertNil(runtime.deliveries[remoteKey])
        primaryTask.cancel()
        primaryOpen.cancel()
    }

    func testCapturedPrimaryDisconnectScrubsBareScopeButPreservesRemote() {
        let model = AppModel()
        let primaryID = UUID()
        let remoteID = UUID()
        model.agentInbox = [
            A2AMessage(id: primaryID, fromBotID: "ops", toBotID: "default",
                       time: "now", text: "primary"),
            A2AMessage(id: remoteID, fromBotID: "ops", toBotID: "homelab::default",
                       time: "now", text: "remote"),
        ]
        FeedsRuntime.shared.inboxSessions = [
            primaryID: SessionRef(gatewayID: "primary", botID: "default", storedID: "same"),
            remoteID: SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                 storedID: "same"),
        ]
        // Reproduce the deliberate-disconnect ordering that previously lost
        // source identity before A2A teardown.
        LiveRuntime.shared.gatewayID = nil

        model.detachA2ARouter(departingGatewayID: "primary")

        XCTAssertEqual(model.agentInbox.map(\.id), [remoteID])
        XCTAssertNil(FeedsRuntime.shared.inboxSessions[primaryID])
        XCTAssertEqual(FeedsRuntime.shared.inboxSessions[remoteID]?.gatewayID, "homelab")
    }

    func testAcceptedSubmitNeverBecomesFailureWhenScopeInvalidates() {
        let retained = A2AAcceptedOutcome.afterSubmit(scopeIsCurrent: true)
        let detached = A2AAcceptedOutcome.afterSubmit(scopeIsCurrent: false)

        XCTAssertEqual(retained.state, .waiting)
        XCTAssertTrue(retained.retainWatcher)
        XCTAssertEqual(detached.state, .quiet)
        XCTAssertFalse(detached.retainWatcher)
        if case .failed = detached.state {
            XCTFail("an accepted prompt cannot be reclassified as transport failure")
        }
    }

    func testFederatedInboxMergePreservesUnscannedRemoteAndReplacesAnchoredOptimistic() {
        let primaryID = UUID()
        let remoteAttempt = UUID()
        let legacyRemoteID = UUID()
        let primary = A2AMessage(id: primaryID, fromBotID: "ops", toBotID: "default",
                                 time: "now", text: "primary old")
        let remote = A2AMessage(id: remoteAttempt, fromBotID: "ops",
                                toBotID: "homelab::default", time: "now", text: "remote")
        // Older persisted rows can have bare participants on both sides. The
        // source-qualified SessionRef, not the colliding ids, owns them.
        let legacyRemote = A2AMessage(id: legacyRemoteID, fromBotID: "ops",
                                      toBotID: "default", time: "now", text: "legacy remote")
        let refs = [
            primaryID: SessionRef(gatewayID: "primary", botID: "default", storedID: "same"),
            remoteAttempt: SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                      storedID: "same"),
            legacyRemoteID: SessionRef(gatewayID: "homelab", botID: "default",
                                       storedID: "same"),
        ]
        let primaryServer = A2AMessage(id: UUID(), fromBotID: "ci", toBotID: "default",
                                       time: "now", text: "primary fresh")
        let primaryRef = SessionRef(gatewayID: "primary", botID: "default", storedID: "same")

        let first = A2AInboxMerge.merge(
            existing: [primary, remote, legacyRemote], existingRefs: refs,
            server: [(primaryServer, Date(), primaryRef)], successfulGateways: ["primary"],
            optimisticRows: [remoteAttempt: "homelab"], primaryGatewayID: "primary", limit: 80)

        XCTAssertEqual(Set(first.messages.map(\.id)),
                       [remoteAttempt, legacyRemoteID, primaryServer.id])
        XCTAssertEqual(first.refs[remoteAttempt]?.gatewayID, "homelab")
        XCTAssertEqual(first.refs[legacyRemoteID]?.gatewayID, "homelab")

        let remoteServer = A2AMessage(id: remoteAttempt, fromBotID: "ops",
                                      toBotID: "homelab::default", time: "now", text: "remote")
        let remoteRef = SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                   storedID: "same")
        let second = A2AInboxMerge.merge(
            existing: first.messages, existingRefs: first.refs,
            server: [(remoteServer, Date(), remoteRef)], successfulGateways: ["homelab"],
            optimisticRows: [remoteAttempt: "homelab"], primaryGatewayID: "primary", limit: 80)

        XCTAssertEqual(second.messages.filter { $0.id == remoteAttempt }.count, 1)
        XCTAssertEqual(second.refs[remoteAttempt]?.gatewayID, "homelab")
        XCTAssertTrue(second.settled.contains(remoteAttempt))
    }

    func testSessionRefReopensItsCapturedGatewayAcrossPrimaryRoleChanges() {
        let ref = SessionRef(gatewayID: "homelab", botID: "default", storedID: "same")

        XCTAssertEqual(ref.rosterID(activeGatewayID: "primary"), "homelab::default")
        XCTAssertEqual(ref.rosterID(activeGatewayID: "homelab"), "default")
        XCTAssertNil(SessionRef(gatewayID: "", botID: "default", storedID: "same")
            .rosterID(activeGatewayID: "primary"))
    }

    func testFreshPinAuthorityHonorsRepinDeletionRaceAndReadFailure() {
        XCTAssertEqual(A2APinAuthority.choose(
            cached: "old", current: "old", sampledWrite: 2, currentWrite: 2,
            serverReadSucceeded: true, serverPin: "desktop-new"), "desktop-new")
        XCTAssertNil(A2APinAuthority.choose(
            cached: "old", current: "old", sampledWrite: 2, currentWrite: 2,
            serverReadSucceeded: true, serverPin: nil))
        XCTAssertEqual(A2APinAuthority.choose(
            cached: "old", current: "phone-new", sampledWrite: 2, currentWrite: 3,
            serverReadSucceeded: true, serverPin: "stale-server"), "phone-new")
        XCTAssertEqual(A2APinAuthority.choose(
            cached: "old", current: "old", sampledWrite: 2, currentWrite: 2,
            serverReadSucceeded: false, serverPin: nil), "old")
    }

    func testCanonicalLookupUsesDatabaseTitleAfterPinWithoutFortyRowWindow() {
        // Forty-one newer sessions cannot hide Bot Chat because production
        // sends this exact title to session.resume instead of searching a list.
        let newerSessionCount = 41
        XCTAssertGreaterThan(newerSessionCount, 40)
        XCTAssertEqual(A2ASessionResolver.lookupTargets(pin: "pinned", title: "Bot Chat"),
                       ["pinned", "Bot Chat"])
        XCTAssertEqual(A2ASessionResolver.lookupTargets(pin: nil, title: "Bot Chat"),
                       ["Bot Chat"])
    }

    func testReplyRequiresExactAttributedPromptAnchor() {
        let attributed = "Message from 🤖 Ops (@ops): deploy"
        let substringOnly: [JSONValue] = [
            .object(["role": .string("user"),
                     "content": .string("prefix \(attributed) suffix")]),
            .object(["role": .string("assistant"), "content": .string("wrong")]),
        ]
        let exact: [JSONValue] = substringOnly + [
            .object(["role": .string("user"), "content": .string(attributed)]),
            .object(["role": .string("assistant"), "content": .string("right")]),
        ]

        XCTAssertNil(A2AReplyResolver.reply(to: attributed, in: substringOnly))
        XCTAssertEqual(A2AReplyResolver.reply(to: attributed, in: exact), "right")
    }

    func testIdenticalHandoffBodiesRelayOnlyTheirOwnAttemptReply() {
        let body = "deploy the same build"
        let first = A2AWire.attributed(displayTitle: "Ops", handle: "ops", body: body,
                                       attemptID: UUID(uuidString:
                                        "00000000-0000-0000-0000-000000000001")!)
        let second = A2AWire.attributed(displayTitle: "Ops", handle: "ops", body: body,
                                        attemptID: UUID(uuidString:
                                         "00000000-0000-0000-0000-000000000002")!)
        let transcript: [JSONValue] = [
            .object(["role": .string("user"), "content": .string(first)]),
            .object(["role": .string("assistant"), "content": .string("first reply")]),
            .object(["role": .string("user"), "content": .string(second)]),
            .object(["role": .string("assistant"), "content": .string("second reply")]),
        ]

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(A2AReplyResolver.reply(to: first, in: transcript), "first reply")
        XCTAssertEqual(A2AReplyResolver.reply(to: second, in: transcript), "second reply")
        XCTAssertEqual(AppModel.strippedA2A(first), body,
                       "the wire attempt UUID must not leak into the inbox preview")
        XCTAssertEqual(AppModel.strippedA2A(second), body)
        XCTAssertEqual(AppModel.a2aSender(in: first), "ops")
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

    func testPrimaryForeverChatPersistsModelGloballyAndMoAStaysSession() {
        let model = AppModel()
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "default", provider: "anthropic"))
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "seek", provider: "anthropic"))
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "homelab::default", provider: "anthropic"))
        XCTAssertFalse(model.shouldPersistModelAsDefault(botID: "default", provider: "moa"))
        XCTAssertEqual(
            GatewayClient.modelSwitchValue(model: "claude-sonnet-4.6", provider: "anthropic",
                                           persistAsDefault: true),
            "claude-sonnet-4.6 --provider anthropic --global"
        )
        XCTAssertEqual(
            GatewayClient.modelSwitchValue(model: "ensemble", provider: "moa",
                                           persistAsDefault: false),
            "ensemble --provider moa --session"
        )
    }
}
#endif

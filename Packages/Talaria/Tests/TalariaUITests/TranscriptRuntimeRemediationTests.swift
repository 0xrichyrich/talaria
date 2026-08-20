#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptRuntimeRemediationTests: XCTestCase {
    func testTranscriptPlansRequireDurableRowAddress() {
        let local = ChatMessage(author: .user, text: "retry")
        XCTAssertNil(TranscriptActing.planRestore([local], from: local.id))
        XCTAssertNil(TranscriptActing.planEdit([local], from: local.id, text: "edited"))

        let durable = ChatMessage(author: .user, text: "retry", rowID: 42)
        let assistant = ChatMessage(author: .bot, text: "answer", rowID: 43)
        XCTAssertEqual(TranscriptActing.planRestore([durable, assistant], from: durable.id)?
            .truncate.rowID, 42)
        XCTAssertEqual(TranscriptActing.planReload([durable, assistant], from: assistant.id)?
            .truncate.rowID, 42)
    }

    func testPromptQueueMirrorRequiresExactQueuedReceipt() {
        XCTAssertTrue(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["status": .string("queued")])
        ))
        XCTAssertFalse(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["status": .string("streaming")])
        ))
        XCTAssertFalse(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["ok": .bool(false), "status": .string("queued")])
        ))
        XCTAssertThrowsError(try PromptSubmitReceipt.requireAccepted(
            .object(["status": .string("unknown")]), operation: "test"))
    }

    @MainActor
    func testQueuedMirrorKeepsDuplicateTextByIdentityAndDrainsExactLifecycle() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-a")
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-a")
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-b")
        XCTAssertEqual(model.promptQueue.count, 3)

        model.markQueuedPromptsEligible(botID: "bot", sessionID: "session-a")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session-b")
        XCTAssertEqual(model.promptQueue.count, 3, "a foreign session start cannot drain")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session-a")
        XCTAssertEqual(model.promptQueue.count, 2, "one start consumes one FIFO entry")

        let dismissed = model.promptQueue[0].id
        model.dismissQueuedPrompt(id: dismissed)
        XCTAssertFalse(model.promptQueue.contains(where: { $0.id == dismissed }))
        XCTAssertNil(ChatRuntime.shared.queuedBindings[dismissed])
        XCTAssertEqual(model.promptQueue.count, 1, "dismiss is local and identity-specific")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testQueuedAckAfterCompletionIsEligibleAndAckAfterNextStartDoesNotLagFIFO() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        let firstSubmission = model.beginQueuedSubmission(botID: "bot", sessionID: "session")

        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(firstSubmission, text: "after completion")
        let first = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(first.flatMap { ChatRuntime.shared.queuedBindings[$0] }?
            .eligibleAfterCurrentTurn, true)

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertTrue(model.promptQueue.isEmpty)

        let next = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(next, text: "already executing")
        XCTAssertTrue(model.promptQueue.isEmpty,
                      "an ack arriving after completion+start must not recreate an executing item")
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testExistingQ0StartDoesNotSuppressDelayedQ1Acknowledgement() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("Q0", botID: "bot", sessionID: "session")
        model.markQueuedPromptsEligible(botID: "bot", sessionID: "session")
        let delayedQ1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(delayedQ1, text: "Q1")

        XCTAssertEqual(model.promptQueue.map(\.text), ["Q1"])
        XCTAssertEqual(ChatRuntime.shared.pendingQueuedSubmissions.values.flatMap { $0 }.count, 0)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testConcurrentQueuedAcknowledgementsPreserveSubmissionOrderAndIdentity() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let q1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        let q2 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")

        model.acceptQueuedSubmission(q2, text: "Q2")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"],
                       "the earlier still-pending Q1 owns the first start")
        model.acceptQueuedSubmission(q1, text: "Q1")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"],
                       "Q1 already started before its acknowledgement")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertTrue(model.promptQueue.isEmpty)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testNonqueuedDelayedSubmissionReassignsConsumedStartToNextAcceptedPrompt() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let delayedQ1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        let q2 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(q2, text: "Q2")

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"])

        model.discardQueuedSubmission(delayedQ1)
        XCTAssertTrue(model.promptQueue.isEmpty,
                      "Q1's provisional start must transfer to accepted Q2")
        XCTAssertTrue(ChatRuntime.shared.pendingQueuedSubmissions.isEmpty)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testConsumedStartTransferCannotCrossReusedRuntimeIntoDifferentStoredSession() {
        let model = AppModel()
        let botID = "worker"
        let sid = "reused-runtime"
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored-a"
        LiveRuntime.shared.gatewayID = "gateway"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let delayedA = model.beginQueuedSubmission(botID: botID, sessionID: sid)

        chat.storedSessionID = "stored-b"
        let acceptedB = model.beginQueuedSubmission(botID: botID, sessionID: sid)
        model.noteQueuedPromptCompletion(botID: botID, sessionID: sid)
        model.acceptQueuedSubmission(acceptedB, text: "B")

        chat.storedSessionID = "stored-a"
        model.noteQueuedPromptStart(botID: botID, sessionID: sid)
        model.drainStartedQueuedPrompt(botID: botID, sessionID: sid)
        model.discardQueuedSubmission(delayedA)

        XCTAssertEqual(model.promptQueue.map(\.text), ["B"])
        let remaining = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(remaining.flatMap { ChatRuntime.shared.queuedBindings[$0]?.storedID },
                       "stored-b")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testCanonicalKickoffRollbackRequiresExactOwnerAndCannotEraseRepin() {
        let model = AppModel()
        let botID = "bot"
        let chat = ChatState()
        let row = ChatMessage(author: .user, text: "kickoff")
        chat.messages = [row]
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        model.chats[botID] = chat

        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-a", storedID: "stored-a",
            rowID: row.id, chatID: ObjectIdentifier(chat))
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.pins[botID] = "stored-b"

        model.rollbackCanonicalKickoffIfOwned(lease)
        XCTAssertEqual(chat.sessionID, "runtime-a")
        XCTAssertTrue(chat.isRunning)
        XCTAssertEqual(chat.messages.map(\.id), [row.id])
        XCTAssertEqual(CanonicalChatRuntime.shared.pins[botID], "stored-b")

        CanonicalChatRuntime.shared.pins[botID] = "stored-a"
        model.rollbackCanonicalKickoffIfOwned(lease)
        XCTAssertNil(chat.sessionID)
        XCTAssertNil(chat.storedSessionID)
        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNil(CanonicalChatRuntime.shared.pins[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
    }

    @MainActor
    func testCanonicalKickoffClaimBeforeAdoptionCanBeCancelledWithoutLeakingOwner() {
        let model = AppModel()
        let botID = "pre-adopt"
        let chat = model.chat(for: botID)
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: false)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id

        XCTAssertTrue(model.rollbackCanonicalKickoffIfOwned(lease))
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(chat.sessionID)
        XCTAssertTrue(chat.messages.isEmpty)
    }

    @MainActor
    func testCanonicalTapCannotFastReturnWhileKickoffAcceptanceIsAmbiguous() async {
        let model = AppModel()
        let botID = "bot"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        CanonicalChatRuntime.shared.pins[botID] = "stored"
        XCTAssertTrue(model.canonicalTapCanFastReturn(
            botID: botID, chat: chat, canonical: "stored"))

        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        XCTAssertFalse(model.canonicalTapCanFastReturn(
            botID: botID, chat: chat, canonical: "stored"),
            "the tap must continue through authoritative resume/hydration")
        XCTAssertFalse(model.canonicalTapShouldUnbind(
            botID: botID, chat: chat, canonical: nil),
            "a missing local pin must not detach the ambiguous session before resume")
        XCTAssertEqual(model.ambiguousCanonicalKickoffOwning(botID: botID, chat: chat), lease)

        var didResume = false
        var didHydrate = false
        let authoritative = ChatMessage(author: .bot, text: "authoritative intro", rowID: 1)
        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: {
                didResume = true
                return LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                ]))
            },
            hydrate: { _ in
                didHydrate = true
                chat.messages = [authoritative]
            },
            accepts: { true })

        XCTAssertTrue(didResume)
        XCTAssertTrue(didHydrate)
        XCTAssertEqual(chat.messages, [authoritative])
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.ambiguousKickoffs[botID])
        CanonicalChatRuntime.shared.pins[botID] = nil
    }

    @MainActor
    func testAmbiguousKickoffRejectsMismatchedDurableResumeIdentity() async {
        let model = AppModel()
        let botID = "bot-mismatch"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored-owned"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-old", storedID: "stored-owned",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        var didHydrate = false

        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime-rotated"),
                    "stored_session_id": .string("stored-foreign"),
                ]))
            },
            hydrate: { _ in didHydrate = true },
            accepts: { true })

        XCTAssertFalse(didHydrate)
        XCTAssertEqual(chat.sessionID, "runtime-old")
        XCTAssertEqual(chat.storedSessionID, "stored-owned")
        XCTAssertEqual(CanonicalChatRuntime.shared.kickoffs[botID], lease.id)
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease)
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
    }

    @MainActor
    func testReconnectGenerationDoesNotPruneAmbiguousTranscriptFence() {
        let botID = "fenced"
        let fence = TranscriptActionFence(
            operationID: UUID(), sessionID: "runtime", storedID: "stored",
            gatewayID: "gateway", profile: "profile", generation: 10)
        ChatRuntime.shared.transcriptFences[botID] = fence
        ChatRuntime.shared.pruneTranscriptState(botID: botID, generation: 11)
        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID], fence)
        XCTAssertFalse(fence.acceptsAuthoritativeHydration(
            gatewayID: "other", profile: "profile", storedID: "stored",
            generation: 11, currentGeneration: 11))
        XCTAssertFalse(fence.acceptsAuthoritativeHydration(
            gatewayID: "gateway", profile: "profile", storedID: "stored",
            generation: 10, currentGeneration: 11))
        XCTAssertTrue(fence.acceptsAuthoritativeHydration(
            gatewayID: "gateway", profile: "profile", storedID: "stored",
            generation: 11, currentGeneration: 11))
        ChatRuntime.shared.transcriptFences[botID] = nil
    }

    @MainActor
    func testLateSubmitResultAfterGenerationChangeFencesSameDurableTarget() {
        let model = AppModel()
        let botID = "gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "new-runtime"
        chat.storedSessionID = "stored"
        let lease = TranscriptActionLease(
            id: UUID(), botID: botID, sessionID: "old-runtime", storedID: "stored",
            gatewayID: "gateway", profile: "worker", generation: 10,
            chatID: ObjectIdentifier(chat), optimisticID: UUID(), baseline: [])

        model.fenceTranscriptActionIfDurableTargetStillOwned(lease)

        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID]?.operationID, lease.id)
        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID]?.storedID, "stored")
        ChatRuntime.shared.transcriptFences[botID] = nil
    }

    @MainActor
    func testAdoptRetiresDifferentStoredFenceAndUnroutesOldRuntimeSID() {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "old-runtime"
        chat.storedSessionID = "old-stored"
        LiveRuntime.shared.gatewayID = "gateway"
        LiveRuntime.shared.sessionToBot["old-runtime"] = botID
        ChatRuntime.shared.transcriptFences[botID] = TranscriptActionFence(
            operationID: UUID(), sessionID: "old-runtime", storedID: "old-stored",
            gatewayID: "gateway", profile: botID,
            generation: LiveRuntime.shared.generation)
        let live = LiveSession(.object([
            "session_id": .string("new-runtime"),
            "stored_session_id": .string("new-stored"),
        ]))

        model.adopt(live, storedID: "new-stored", botID: botID,
                    sourceGatewayID: "gateway")

        XCTAssertNil(LiveRuntime.shared.sessionToBot["old-runtime"])
        XCTAssertEqual(LiveRuntime.shared.sessionToBot["new-runtime"], botID)
        XCTAssertNil(ChatRuntime.shared.transcriptFences[botID])
        LiveRuntime.shared.sessionToBot["new-runtime"] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testStopQueueCleanupPredicateIsExactInterruptedSession() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        model.enqueuePrompt("old", botID: "bot", sessionID: "session-old")
        model.enqueuePrompt("current", botID: "bot", sessionID: "session-current")
        model.removeQueuedPrompts(botID: "bot", sessionID: "session-current")
        XCTAssertEqual(model.promptQueue.map(\.text), ["old"])
        XCTAssertEqual(ChatRuntime.shared.queuedBindings[model.promptQueue[0].id]?.sessionID,
                       "session-old")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
    }

    @MainActor
    func testStopApprovalCleanupRequiresExactProfileBotAndDurableSession() {
        let model = AppModel()
        let gateway = "gateway"
        let sid = "colliding-runtime"
        let botA = "gateway::alpha"
        let botB = "gateway::beta"
        let routeA = GatewayBotRoute(gatewayID: gateway, profile: "alpha")
        let routeB = GatewayBotRoute(gatewayID: gateway, profile: "beta")
        let chat = model.chat(for: botA)
        chat.sessionID = "replacement"
        chat.storedSessionID = "stored-replacement"
        let lease = StopTurnLease(
            botID: botA, route: routeA, sessionID: sid,
            storedID: "stored-a", chatID: ObjectIdentifier(chat))
        let targets: [(String, ApprovalResponseTarget)] = [
            ("exact", ApprovalResponseTarget(
                bot: routeA, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "exact", storedID: "stored-a", botID: botA)),
            ("other-profile", ApprovalResponseTarget(
                bot: routeB, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "other-profile", storedID: "stored-a", botID: botB)),
            ("other-stored", ApprovalResponseTarget(
                bot: routeA, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "other-stored", storedID: "stored-b", botID: botA)),
        ]
        for (id, target) in targets { LiveRuntime.shared.approvalTargets[id] = target }
        model.approvals = targets.map { id, target in
            Approval(id: id, botID: target.bot == routeA ? botA : botB, kind: .command,
                     title: id, target: "", subject: "", body: "", why: "", age: "now")
        }
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "exact",
                           sessionID: sid, botID: botA, question: "A",
                           profile: "alpha", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "other-profile",
                           sessionID: sid, botID: botB, question: "B",
                           profile: "beta", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "other-stored",
                           sessionID: sid, botID: botA, question: "C",
                           profile: "alpha", storedID: "stored-b"),
        ]

        model.applyStopCompletion(lease, note: "Stopped")

        XCTAssertNil(LiveRuntime.shared.approvalTargets["exact"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["other-profile"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["other-stored"])
        XCTAssertEqual(Set(model.approvals.map(\.id)), ["other-profile", "other-stored"])
        XCTAssertEqual(Set(ApprovalBridges.shared.prompts.map(\.requestID)),
                       ["other-profile", "other-stored"])
        for (id, _) in targets { LiveRuntime.shared.approvalTargets[id] = nil }
        model.approvals = []
        ApprovalBridges.shared.prompts = []
    }

    @MainActor
    func testStopCleanupDoesNotCrossGatewayWithCollidingRuntimeSessionID() {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "same-runtime"
        chat.storedSessionID = "stored-a"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = "gateway-a"
        model.enqueuePrompt("A", botID: botID, sessionID: "same-runtime")
        let lateA = model.beginQueuedSubmission(botID: botID, sessionID: "same-runtime")
        let routeA = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let routeB = GatewayBotRoute(gatewayID: "gateway-b", profile: botID)
        let lease = StopTurnLease(
            botID: botID, route: routeA, sessionID: "same-runtime",
            storedID: "stored-a", chatID: ObjectIdentifier(chat))

        LiveRuntime.shared.gatewayID = "gateway-b"
        chat.storedSessionID = "stored-b"
        model.enqueuePrompt("B", botID: botID, sessionID: "same-runtime")
        LiveRuntime.shared.approvalTargets["approval-a"] = ApprovalResponseTarget(
            bot: routeA,
            session: GatewaySessionRoute(gatewayID: "gateway-a", sessionID: "same-runtime"),
            requestID: "a", storedID: "stored-a", botID: botID)
        LiveRuntime.shared.approvalTargets["approval-b"] = ApprovalResponseTarget(
            bot: routeB,
            session: GatewaySessionRoute(gatewayID: "gateway-b", sessionID: "same-runtime"),
            requestID: "b", storedID: "stored-b", botID: botID)
        model.approvals = [
            Approval(id: "approval-a", botID: botID, kind: .command, title: "A", target: "",
                     subject: "", body: "", why: "", age: "now"),
            Approval(id: "approval-b", botID: botID, kind: .command, title: "B", target: "",
                     subject: "", body: "", why: "", age: "now"),
        ]
        model.applyStopCompletion(lease, note: "Stopped A")
        model.acceptQueuedSubmission(lateA, text: "late A")

        XCTAssertEqual(model.promptQueue.map(\.text), ["B"])
        let remaining = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(remaining.flatMap { ChatRuntime.shared.queuedBindings[$0]?.route?.gatewayID },
                       "gateway-b")
        XCTAssertNil(LiveRuntime.shared.approvalTargets["approval-a"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["approval-b"])
        XCTAssertEqual(model.approvals.map(\.id), ["approval-b"])
        XCTAssertEqual(chat.messages.filter { $0.text == "Stopped A" }.count, 0)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.approvalTargets["approval-b"] = nil
        model.approvals = []
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testDelayedStopCompletionCannotMutateReplacementSession() async {
        let model = AppModel()
        let botID = "gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("queued for A", botID: botID, sessionID: "runtime-a")
        let lateA = model.beginQueuedSubmission(botID: botID, sessionID: "runtime-a")
        model.enqueuePrompt("queued for B", botID: botID, sessionID: "runtime-b")
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let approvalA = "gateway::approval-a"
        let approvalB = "gateway::approval-b"
        LiveRuntime.shared.approvalTargets[approvalA] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: "gateway", sessionID: "runtime-a"),
            requestID: "approval-a", storedID: "stored-a", botID: botID)
        LiveRuntime.shared.approvalTargets[approvalB] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: "gateway", sessionID: "runtime-b"),
            requestID: "approval-b", storedID: "stored-b", botID: botID)
        model.approvals = [
            Approval(id: approvalA, botID: botID, kind: .command, title: "A", target: "",
                     subject: "", body: "", why: "", age: "now"),
            Approval(id: approvalB, botID: botID, kind: .command, title: "B", target: "",
                     subject: "", body: "", why: "", age: "now"),
        ]
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .clarify, gatewayID: "gateway", requestID: "ticket-a",
                           sessionID: "runtime-a", botID: botID, question: "A?",
                           profile: "worker", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: "gateway", requestID: "ticket-b",
                           sessionID: "runtime-b", botID: botID, question: "B?",
                           profile: "worker", storedID: "stored-b"),
        ]
        let lease = StopTurnLease(
            botID: botID, route: route,
            sessionID: "runtime-a", storedID: "stored-a",
            chatID: ObjectIdentifier(chat))
        let gate = TranscriptStopBarrier()
        let delayed = Task { @MainActor in
            _ = await gate.load()
        model.applyStopCompletion(lease, note: "Stopped A")
        }
        await gate.waitUntilEntered()
        chat.sessionID = "runtime-b"
        chat.storedSessionID = "stored-b"
        chat.messages = [ChatMessage(author: .bot, text: "B owns this transcript")]
        await gate.release()
        await delayed.value

        XCTAssertEqual(chat.messages.map(\.text), ["B owns this transcript"])
        XCTAssertFalse(model.stopCompletionIsOwned(lease))
        XCTAssertEqual(model.promptQueue.map(\.text), ["queued for B"],
                      "a proven stop cleans captured A even after the UI binds B")
        model.acceptQueuedSubmission(lateA, text: "late A acknowledgement")
        XCTAssertEqual(model.promptQueue.map(\.text), ["queued for B"],
                       "cleared pending A cannot be recreated by its late ack")
        XCTAssertNil(LiveRuntime.shared.approvalTargets[approvalA])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalB])
        XCTAssertEqual(model.approvals.map(\.id), [approvalB])
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.requestID), ["ticket-b"])
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.approvalTargets[approvalB] = nil
        model.approvals = []
        ApprovalBridges.shared.prompts = []
    }

    func testPromptMutationFailureSeparatesRefusalFromAmbiguousTransport() {
        XCTAssertFalse(PromptMutationFailure.isAmbiguous(
            GatewayError(code: 409, message: "refused")))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(
            GatewayError(code: -5, message: "timeout")))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(URLError(.networkConnectionLost)))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(
            AckValidationError(operation: "prompt")))
    }

    func testReconciliationCarriesOnlyPostBaselineDeltasNeverWholeSnapshot() {
        let oldUser = ChatMessage(author: .user, text: "old", rowID: 1)
        let oldBot = ChatMessage(author: .bot, text: "old answer", rowID: 2)
        let optimistic = ChatMessage(author: .user, text: "edited")
        var changedBot = oldBot
        changedBot.text = "old answer plus a newer delta"
        let freshTool = ChatMessage(author: .bot, text: "", isStreaming: true)

        let newer = TranscriptActionReconciliation.newerRows(
            current: [oldUser, changedBot, optimistic, freshTool],
            baseline: [oldUser, oldBot], optimisticID: optimistic.id)

        XCTAssertEqual(newer.map(\.id), [changedBot.id, freshTool.id])
        XCTAssertFalse(newer.contains(where: { $0.id == oldUser.id }))
        XCTAssertFalse(newer.contains(where: { $0.id == optimistic.id }))
    }
}

private actor TranscriptStopBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func load() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
#endif

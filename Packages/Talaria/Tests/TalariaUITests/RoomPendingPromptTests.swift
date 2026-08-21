#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class RoomPendingPromptTests: XCTestCase {
    func testSnapshotCarriesPendingFieldsAndClarifyWinsOverApproval() {
        let route = GatewayBotRoute(gatewayID: "home", profile: "research")
        let roomID = RoomID(rawValue: uuid("00000000-0000-0000-0000-000000000001"))
        let attempt = roomAttempt(route: route)
        let approval = ApprovalRequest([
            "request_id": "approval-1",
            "description": "Run it?",
            "command": "git status",
            "choices": ["once", "deny"],
        ], sessionID: "wrong-old-runtime")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime-now", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "clarify-1",
                "question": "Which branch?",
                "choices": ["main", "release"],
            ],
            pendingApproval: approval)

        XCTAssertTrue(snapshot.awaitingUser)
        let prompt = snapshot.pendingPrompt(roomID: roomID, route: route, attempt: attempt)
        XCTAssertEqual(prompt?.kind, .clarify)
        XCTAssertEqual(prompt?.key, RoomPendingPromptKey(roomID: roomID, route: route))
        XCTAssertEqual(prompt?.attemptID, attempt.id)
        XCTAssertEqual(prompt?.threadID, attempt.threadID)
        XCTAssertEqual(prompt?.epoch, attempt.epoch)
        XCTAssertEqual(prompt?.runtimeSessionID, "runtime-now")
        XCTAssertEqual(prompt?.requestID, "clarify-1")
        XCTAssertEqual(prompt?.question, "Which branch?")
        XCTAssertEqual(prompt?.choices, ["main", "release"])
        XCTAssertFalse(prompt?.isBatchClarify ?? true)
    }

    func testMalformedOuterClarifyDoesNotFallThroughToInnerApproval() {
        let route = GatewayBotRoute(gatewayID: "home", profile: "research")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingClarify: ["question": "Missing its request id"],
            pendingApproval: ApprovalRequest([
                "request_id": "approval-1", "choices": ["once", "deny"],
            ], sessionID: "runtime"))

        XCTAssertFalse(snapshot.awaitingUser)
        XCTAssertNil(snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                            attempt: roomAttempt(route: route)))
    }

    func testBatchQuestionsNormalizeQidOrIdAndAllMultiSelectSpellings() {
        let route = GatewayBotRoute(gatewayID: "lab", profile: "planner")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingClarify: [
                "request_id": "batch-1",
                "questions": [
                    ["qid": "q-snake", "question": "Pick tags",
                     "choices": ["red, blue", "green"], "multi_select": true],
                    ["id": "q-camel", "question": "Pick checks",
                     "choices": ["lint", "test"], "multiSelect": true],
                    ["qid": "q-hyphen", "question": "Pick targets",
                     "choices": ["iOS", "macOS"], "multi-select": true],
                ],
            ])
        let prompt = snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                            attempt: roomAttempt(route: route))

        XCTAssertTrue(snapshot.awaitingUser)
        XCTAssertEqual(prompt?.questions.map(\.questionID), ["q-snake", "q-camel", "q-hyphen"])
        XCTAssertEqual(prompt?.questions.map(\.multiSelect), [true, true, true])
        XCTAssertEqual(prompt?.questions.first?.choices, ["red, blue", "green"])
        XCTAssertTrue(prompt?.isBatchClarify ?? false)
    }

    func testBatchReplayAnswersExposeLockedProgressWithoutAcceptingUnknownValues() throws {
        let route = GatewayBotRoute(gatewayID: "lab", profile: "planner")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingClarify: [
                "request_id": "batch-locked",
                "questions": [
                    ["qid": "first", "question": "First"],
                    ["id": "second", "question": "Second", "multi_select": true],
                ],
                // Hermes sends the original answer text, including an empty
                // string for an intentionally skipped per-question response.
                "answers": [
                    "first": "accepted text",
                    "second": "",
                    "other-room-question": "must not surface",
                    "malformed": ["not", "a", "string"],
                ],
            ])
        let prompt = try XCTUnwrap(snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                                          attempt: roomAttempt(route: route)))

        XCTAssertEqual(prompt.lockedAnswersByQuestionID, ["first": "accepted text", "second": ""])
        XCTAssertEqual(prompt.lockedQuestionIDs, Set(["first", "second"]))
        XCTAssertEqual(prompt.acceptedQuestionIDs, Set(["first", "second"]))
        XCTAssertTrue(prompt.hasLockedQuestions)
        XCTAssertTrue(prompt.isQuestionLocked(prompt.questions[0]))
        XCTAssertTrue(prompt.isQuestionLocked(prompt.questions[1]))
        XCTAssertEqual(prompt.lockedAnswer(for: "first"), "accepted text")
        XCTAssertEqual(prompt.lockedAnswer(for: "second"), "")
        XCTAssertNil(prompt.lockedAnswer(for: "other-room-question"))

        // New responses still contain only the new question's reply; replayed
        // answer text never rides a later wire request.
        let response = try prompt.clarifyResponse(selections: ["green"], questionID: "second")
        XCTAssertEqual(response.params, [
            "request_id": "batch-locked",
            "question_id": "second",
            "answer": "[\"green\"]",
        ])
        XCTAssertNil(response.params["answers"])
    }

    func testMalformedBatchCannotBecomePartiallyAddressablePrompt() {
        let route = GatewayBotRoute(gatewayID: "lab", profile: "planner")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingClarify: [
                "request_id": "batch-1",
                "questions": [
                    ["qid": "q1", "question": "First"],
                    ["question": "No address"],
                ],
            ])

        XCTAssertFalse(snapshot.awaitingUser)
        XCTAssertNil(snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                            attempt: roomAttempt(route: route)))
    }

    func testApprovalDefaultsToOnceAndDenyWhenGatewayOmitsUsableChoices() {
        let route = GatewayBotRoute(gatewayID: "home", profile: "ops")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingApproval: ApprovalRequest([
                "request_id": "approval-1",
                "description": "Run migration",
                "command": "./migrate",
                "choices": ["unknown"],
            ], sessionID: "runtime"))
        let prompt = snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                            attempt: roomAttempt(route: route))

        XCTAssertTrue(snapshot.awaitingUser)
        XCTAssertEqual(prompt?.kind, .approval)
        XCTAssertEqual(prompt?.approvalChoices.map(\.rawValue), ["once", "deny"])
        XCTAssertEqual(prompt?.choices, ["once", "deny"])
    }

    func testResponseWiresAreSourceQualifiedAndPreserveMultiSelectJSON() throws {
        let route = GatewayBotRoute(gatewayID: "remote", profile: "ops")
        let approval = try RoomPendingPrompt.approvalResponse(
            route: route, sessionID: "runtime-2", requestID: "approval-2", choice: .always)
        XCTAssertEqual(approval.route, route)
        XCTAssertEqual(approval.method, "approval.respond")
        XCTAssertEqual(approval.params, [
            "session_id": "runtime-2",
            "request_id": "approval-2",
            "choice": "always",
        ])
        XCTAssertEqual(RoomPendingPrompt.resolvedApprovalCount(in: ["resolved": 2]), 2)
        XCTAssertEqual(RoomPendingPrompt.resolvedApprovalCount(in: ["resolved": "2"]), 0)

        let clarify = try RoomPendingPrompt.clarifyResponse(
            route: route, requestID: "clarify-2", selections: ["red, blue", "green"],
            questionID: "q2")
        XCTAssertEqual(clarify.route, route)
        XCTAssertEqual(clarify.method, "clarify.respond")
        XCTAssertEqual(clarify.params, [
            "request_id": "clarify-2",
            "question_id": "q2",
            "answer": "[\"red, blue\",\"green\"]",
        ])
        XCTAssertNil(clarify.params["session_id"])

        let single = try RoomPendingPrompt.clarifyResponse(
            route: route, requestID: "clarify-3", answer: "typed response")
        XCTAssertEqual(single.params, [
            "request_id": "clarify-3",
            "answer": "typed response",
        ])
        XCTAssertNil(single.params["question_id"])
    }

    func testPromptResponseRejectsWrongQuestionAndEmptyRequiredIDs() throws {
        let route = GatewayBotRoute(gatewayID: "home", profile: "ops")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: true,
            pendingClarify: [
                "request_id": "batch-1",
                "questions": [["id": "q1", "question": "Pick", "multiSelect": true]],
            ])
        let prompt = try XCTUnwrap(snapshot.pendingPrompt(roomID: RoomID(), route: route,
                                                          attempt: roomAttempt(route: route)))

        XCTAssertThrowsError(try prompt.clarifyResponse(answer: "x")) { error in
            XCTAssertEqual(error as? RoomPendingPromptError, .unknownQuestionID)
        }
        XCTAssertThrowsError(try prompt.clarifyResponse(selections: ["x"], questionID: "other")) { error in
            XCTAssertEqual(error as? RoomPendingPromptError, .unknownQuestionID)
        }
        XCTAssertThrowsError(try RoomPendingPrompt.approvalResponseParameters(
            sessionID: "runtime", requestID: " \n", choice: .once)) { error in
            XCTAssertEqual(error as? RoomPendingPromptError, .missingRequestID)
        }
    }

    private func roomAttempt(route: GatewayBotRoute) -> RoomAttempt {
        RoomAttempt(id: RoomAttemptID(rawValue: uuid("00000000-0000-0000-0000-000000000010")),
                    threadID: RoomThreadID(rawValue: uuid("00000000-0000-0000-0000-000000000011")),
                    member: route, epoch: 7, promptText: "room turn",
                    storedSessionID: "stored", runtimeSessionID: "runtime")
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
#endif

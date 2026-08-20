#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptSessionRaceTests: XCTestCase {
    @MainActor
    func testEmptyResumeAndFailedRESTPreserveSendBehindSharedAttach() async throws {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "race-gateway::worker"
        let chat = model.chat(for: botID)
        let barrier = TranscriptFallbackBarrier()

        let attach = Task<String, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: true,
                fallback: { await barrier.load() },
                accepts: { true })
            return "runtime-session"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
            ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
            ChatRuntime.shared.submitWatchdogs[botID] = nil
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "keep this optimistic send", to: botID)

        XCTAssertEqual(chat.messages.map(\.text), ["keep this optimistic send"])
        XCTAssertTrue(LiveRuntime.shared.attachTasks[botID] == attach)

        // nil models the REST fallback failing after an empty resume ack.
        await barrier.release(nil)
        _ = try await attach.value
        await Task.yield()

        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "keep this optimistic send"
        }))
    }

    @MainActor
    func testTypingOnlyTurnSteersInsteadOfSubmittingNewPrompt() async {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "typing-gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "deadbeef"
        chat.isRunning = false
        chat.isTyping = true

        model.sendOrSteer(text: "adjust the running answer", to: botID)

        XCTAssertFalse(chat.isRunning, "submit path must not run while isTyping promises steer")
        XCTAssertTrue(chat.isTyping)
        XCTAssertEqual(chat.messages.last?.author, .user)
        XCTAssertEqual(chat.messages.last?.text, "adjust the running answer")
        await Task.yield()
    }

    @MainActor
    func testPrimaryOfflineTypingTurnUsesNormalEchoAndComposeQueue() {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "deadbeef"
        chat.isTyping = true

        model.sendOrSteer(text: "send after reconnect", to: botID)

        XCTAssertEqual(chat.messages.map(\.text), ["send after reconnect"])
        XCTAssertEqual(model.composeQueue.count, 1)
        XCTAssertEqual(model.composeQueue.first?.botID, botID)
        XCTAssertEqual(model.composeQueue.first?.text, "send after reconnect")
        XCTAssertFalse(chat.isRunning)
    }

    @MainActor
    func testDelayedHydrationMergesLiveAssistantDeltaOverStaleREST() async throws {
        let chat = ChatState(messages: [
            ChatMessage(author: .bot, text: "Hel", isStreaming: true),
        ])
        let barrier = TranscriptFallbackBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: false,
                fallback: { await barrier.load() },
                accepts: { true })
        }

        await barrier.waitUntilEntered()
        chat.messages[0].text += "lo"
        let stale: JSONValue = ["messages": [
            ["role": "user", "text": "Earlier question", "row_id": 10],
            ["role": "assistant", "text": "Hel", "row_id": 11],
        ]]
        await barrier.release(stale)
        try await hydration.value

        XCTAssertEqual(chat.messages.map(\.text), ["Earlier question", "Hello"])
        XCTAssertTrue(chat.messages[1].isStreaming)
        XCTAssertEqual(chat.messages[1].rowID, 11)
    }

    func testHydrationNeverCollapsesAssistantAcrossANewerUserTurn() {
        let history = [ChatMessage(author: .bot, text: "Hel", rowID: 4)]
        let current = [
            ChatMessage(author: .user, text: "A different turn"),
            ChatMessage(author: .bot, text: "Hello from the new turn", isStreaming: true),
        ]

        let merged = TranscriptHydrationMerge.merge(
            history: history, baseline: [], current: current, clearWhenEmpty: false)

        XCTAssertEqual(merged.map(\.text),
                       ["Hel", "A different turn", "Hello from the new turn"])
    }

    func testPostBaselineRepeatedUserTextDoesNotCollapseIntoStaleHistory() {
        let stale = ChatMessage(author: .user, text: "retry", rowID: 5)
        let optimistic = ChatMessage(author: .user, text: "retry")

        let merged = TranscriptHydrationMerge.merge(
            history: [stale], baseline: [], current: [optimistic],
            clearWhenEmpty: true)

        XCTAssertEqual(merged.map(\.text), ["retry", "retry"])
        XCTAssertEqual(merged.map(\.id), [stale.id, optimistic.id])
    }

    func testStaleSameSessionPagePreservesLatestCompletedTurn() {
        let oldUser = ChatMessage(author: .user, text: "old question", rowID: 1)
        let oldBot = ChatMessage(author: .bot, text: "old answer", rowID: 2)
        let latestUser = ChatMessage(author: .user, text: "latest question", rowID: 3)
        let latestBot = ChatMessage(author: .bot, text: "latest answer", rowID: 4)
        let current = [oldUser, oldBot, latestUser, latestBot]

        let merged = TranscriptHydrationMerge.merge(
            history: [oldUser, oldBot], baseline: current, current: current,
            clearWhenEmpty: false)

        XCTAssertEqual(merged.map(\.text), current.map(\.text))
    }

    @MainActor
    func testSupersededSelectionGenerationRejectsDelayedHydrationWrite() async throws {
        let botID = "selection-\(UUID().uuidString)"
        let runtime = SessionsRuntime.shared
        let first = runtime.beginOpen(botID: botID)
        let chat = ChatState()
        let barrier = TranscriptFallbackBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: true,
                fallback: { await barrier.load() },
                accepts: { runtime.acceptsOpen(botID: botID, generation: first) })
        }

        await barrier.waitUntilEntered()
        _ = runtime.beginOpen(botID: botID)
        chat.messages = [ChatMessage(author: .bot, text: "new selection wins")]
        await barrier.release(["messages": [
            ["role": "assistant", "text": "stale selection"],
        ]])

        do {
            try await hydration.value
            XCTFail("superseded hydration unexpectedly committed")
        } catch is CancellationError {
            // Expected: the new selection owns the transcript.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(chat.messages.map(\.text), ["new selection wins"])
    }

    @MainActor
    func testCancelledAttachQueuesIntentWhenOptimisticRowStillOwnsBinding() async {
        let model = AppModel()
        model.mode = .live
        let botID = "cancelled-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "survive reconnect", to: botID)
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<20 {
            if model.composeQueue.contains(where: {
                $0.botID == botID && $0.text == "survive reconnect"
            }) { break }
            await Task.yield()
        }

        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "survive reconnect"
        }))
        XCTAssertTrue(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "survive reconnect"
        }))
    }

    @MainActor
    func testCancelledTypingAttachQueuesCorrectionInsteadOfSubmittingOrDropping() async {
        let model = AppModel()
        model.mode = .live
        let botID = "cancelled-typing-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        chat.isTyping = true
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "preserve this correction", to: botID)
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<20 {
            if model.composeQueue.contains(where: {
                $0.botID == botID && $0.text == "preserve this correction"
            }) { break }
            await Task.yield()
        }

        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "preserve this correction"
        }))
        XCTAssertTrue(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "preserve this correction"
        }))
    }

    @MainActor
    func testCancelledAttachDoesNotQueueAfterExplicitTranscriptSupersession() async {
        let model = AppModel()
        model.mode = .live
        let botID = "superseded-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored-a"
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "belongs to a", to: botID)
        chat.messages = []
        chat.storedSessionID = "stored-b"
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "belongs to a"
        }))
    }

    @MainActor
    func testHiddenSessionFailuresStaySilentButUnexpectedErrorsReachDiagnostics() {
        let supervisor = ConnectionSupervisor.shared
        let unsupported = "hidden-unsupported-\(UUID().uuidString)"
        let vanished = "hidden-vanished-\(UUID().uuidString)"
        let http404 = "hidden-http404-\(UUID().uuidString)"
        let failed = "hidden-failed-\(UUID().uuidString)"
        let nonGateway404 = "hidden-nongateway-\(UUID().uuidString)"
        defer {
            for id in [unsupported, vanished, http404, failed, nonGateway404] {
                supervisor.diagnostics[id] = nil
            }
        }

        OwnedSessionHidingFailure.record(
            GatewayError(code: -32_601, message: "method not found"),
            gatewayID: unsupported)
        OwnedSessionHidingFailure.record(
            GatewayError(code: GatewayError.storedSessionGone, message: "row vanished"),
            gatewayID: vanished)
        XCTAssertNil(supervisor.diagnostics[unsupported])
        XCTAssertNil(supervisor.diagnostics[vanished])

        OwnedSessionHidingFailure.record(
            GatewayError(code: 404, message: "ordinary HTTP failure"),
            gatewayID: http404)
        XCTAssertNotNil(supervisor.diagnostics[http404]?.lastError)

        OwnedSessionHidingFailure.record(
            GatewayError(code: -3, message: "transport unavailable"),
            gatewayID: failed)
        XCTAssertNotNil(supervisor.diagnostics[failed]?.lastError)

        // Only a GatewayError carrying the two contract codes is benign.
        OwnedSessionHidingFailure.record(
            NSError(domain: "test", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "ordinary failure"]),
            gatewayID: nonGateway404)
        XCTAssertNotNil(supervisor.diagnostics[nonGateway404]?.lastError)
    }
}

private actor TranscriptFallbackBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<JSONValue?, Never>?

    func load() async -> JSONValue? {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release(_ value: JSONValue?) {
        releaseContinuation?.resume(returning: value)
        releaseContinuation = nil
    }
}
#endif

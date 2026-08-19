#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class BotModeMetaMutationGateTests: XCTestCase {
    func testSameProfileWaitsUntilReadMergeWriteOwnerReleases() async {
        let gate = BotModeMetaMutationGate()
        let route = GatewayBotRoute(gatewayID: "mac", profile: "default")
        let acquired = await gate.acquire(route)
        XCTAssertTrue(acquired)

        var secondEntered = false
        let waiter = Task { @MainActor in
            if await gate.acquire(route) {
                secondEntered = true
                gate.release(route)
            }
        }
        await Task.yield()
        XCTAssertFalse(secondEntered)

        gate.release(route)
        await waiter.value
        XCTAssertTrue(secondEntered)
    }

    func testDifferentGatewayProfileDoesNotShareTheMutationQueue() async {
        let gate = BotModeMetaMutationGate()
        let first = GatewayBotRoute(gatewayID: "mac", profile: "default")
        let second = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        let firstAcquired = await gate.acquire(first)
        XCTAssertTrue(firstAcquired)

        let secondAcquired = await gate.acquire(second)
        XCTAssertTrue(secondAcquired)
        gate.release(second)
        gate.release(first)
    }

    func testCancelledMiddleWaiterNeverExecutesAndDoesNotWedgeNext() async {
        let gate = BotModeMetaMutationGate()
        let route = GatewayBotRoute(gatewayID: "mac", profile: "default")
        let acquired = await gate.acquire(route)
        XCTAssertTrue(acquired)

        var cancelledEntered = false
        var finalEntered = false
        let cancelled = Task { @MainActor in
            if await gate.acquire(route) {
                cancelledEntered = true
                gate.release(route)
            }
        }
        await Task.yield()
        let final = Task { @MainActor in
            if await gate.acquire(route) {
                finalEntered = true
                gate.release(route)
            }
        }
        await Task.yield()

        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(cancelledEntered)
        XCTAssertFalse(finalEntered)

        gate.release(route)
        await final.value
        XCTAssertTrue(finalEntered)
    }

    func testCancellationAfterGrantReleasesOwnershipForNextMutation() async {
        let gate = BotModeMetaMutationGate.shared
        let route = GatewayBotRoute(gatewayID: "grant-\(UUID().uuidString)", profile: "default")
        let acquired = await gate.acquire(route)
        XCTAssertTrue(acquired)
        let model = AppModel()
        var cancelledRan = false
        let cancelled = Task { @MainActor in
            try? await model.withBotModeMetaMutation(route: route) { cancelledRan = true }
        }
        while gate.queuedWaiterCount(for: route) == 0 { await Task.yield() }

        // Resume the waiter and cancel before MainActor schedules its
        // continuation. The wrapper must install its release defer before it
        // observes cancellation.
        gate.release(route)
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(cancelledRan)

        let nextAcquired = await gate.acquire(route)
        XCTAssertTrue(nextAcquired)
        gate.release(route)
    }
}
#endif

import Foundation
import XCTest
@testable import TalariaUI

@MainActor
final class AdvancedTerminalCoordinatorTests: XCTestCase {
    func testAttachmentTokensAreStableScopedRotatableAndRemovable() {
        let suite = "AdvancedTerminalCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GatewayPTYAttachmentStore(defaults: defaults)

        let first = store.token(gatewayID: "a|b", profile: "default", resume: nil)
        XCTAssertEqual(first, store.token(gatewayID: "a|b", profile: "default", resume: nil))
        XCTAssertNotEqual(first, store.token(gatewayID: "a", profile: "b|default", resume: nil))
        XCTAssertNotEqual(first, store.token(gatewayID: "a|b", profile: "default", resume: "session"))

        let rotated = store.rotate(gatewayID: "a|b", profile: "default", resume: nil)
        XCTAssertNotEqual(first, rotated)
        XCTAssertEqual(rotated, store.token(gatewayID: "a|b", profile: "default", resume: nil))

        store.remove(gatewayID: "a|b")
        XCTAssertNotEqual(rotated, store.token(gatewayID: "a|b", profile: "default", resume: nil))
    }

    func testDetachedTTLRequiresExplicitDecisionAtSafetyBoundary() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AdvancedTerminalCoordinator.needsResumeDecision(
            backgroundedAt: start,
            now: start.addingTimeInterval(AdvancedTerminalCoordinator.detachedSessionSafetyWindow - 1)
        ))
        XCTAssertTrue(AdvancedTerminalCoordinator.needsResumeDecision(
            backgroundedAt: start,
            now: start.addingTimeInterval(AdvancedTerminalCoordinator.detachedSessionSafetyWindow)
        ))
    }

    func testRepeatedInactiveSignalPreservesOriginalDetachTime() {
        let coordinator = AdvancedTerminalCoordinator()
        let start = Date(timeIntervalSince1970: 2_000)
        coordinator.setForeground(false, now: start)
        coordinator.setForeground(false, now: start.addingTimeInterval(1_700))
        coordinator.setForeground(true, now: start.addingTimeInterval(1_741))
        XCTAssertTrue(coordinator.requiresResumeDecision)
    }
}

import Foundation
import XCTest
@testable import TalariaUI

@MainActor
final class AdvancedTerminalCoordinatorTests: XCTestCase {
    func testInitialSessionLaunchWaitsForExactSourceAndNeverLeaksResumeAfterSwitch() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "default",
            initialResume: "durable-session-a"
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "other",
            knownProfiles: ["other"]
        ))
        XCTAssertFalse(binding.hasBoundInitialTarget)

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: "durable-session-a"
        ))
        XCTAssertTrue(binding.hasBoundInitialTarget)

        // `resume` is a durable Hermes session identifier, not a one-shot
        // bearer. Recreating the Terminal tab on the same proven source must
        // reattach the same session.
        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: "durable-session-a"
        ))

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "other",
            knownProfiles: ["other"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-b", profile: "other", resume: nil
        ))
        XCTAssertTrue(binding.hasLeftInitialTarget)

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
    }

    func testResumeWithoutExactInitialSourceFailsClosed() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: nil,
            initialProfile: nil,
            initialResume: "unscoped-session"
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ))
    }

    func testOrdinaryPinnedGatewayWaitsForFreshProfileAuthority() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: nil,
            initialResume: nil
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ))
        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: nil,
            knownProfiles: []
        ))
        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: []
        ))
        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
    }

    func testExplicitPickerTransitionClearsResumeBeforeWorkspaceChanges() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "alpha",
            initialResume: "session-a"
        )
        _ = binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "alpha",
            knownProfiles: ["alpha", "beta"]
        )

        binding.clearResumeForSourceChange()

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "beta",
            knownProfiles: ["alpha", "beta"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "beta", resume: nil
        ))
    }

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

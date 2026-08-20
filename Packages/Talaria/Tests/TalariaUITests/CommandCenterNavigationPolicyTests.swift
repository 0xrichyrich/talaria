#if canImport(XCTest)
import XCTest
@testable import TalariaUI

final class CommandCenterNavigationPolicyTests: XCTestCase {
    func testSettingsExposesExactlyOneCommandCenterModalEntry() {
        let entries = SettingsDestination.allCases.filter(\.presentsCommandCenter)

        XCTAssertEqual(entries, [.workspace])
        XCTAssertEqual(entries[0].title, "Command Center")
        XCTAssertNotEqual(entries[0].title, "Files & Git")
        XCTAssertEqual(SettingsDestination.operations.title, "Gateway Operations")
        XCTAssertFalse(SettingsDestination.operations.presentsCommandCenter)
    }

    func testCommandCenterRemainsDiscoverableByWorkspaceSearchTerms() {
        let destination = SettingsDestination.workspace
        let searchable = "\(destination.title) \(destination.subtitle) \(destination.keywords)"
            .lowercased()

        for term in ["command center", "projects", "files", "git", "review",
                     "commands", "system", "workspace", "terminal"] {
            XCTAssertTrue(searchable.contains(term), "Missing Settings search term: \(term)")
        }
    }

    func testContextualCommandCenterRequestPrefersExplicitRosterSource() {
        XCTAssertEqual(
            WorkspaceCommandCenterRequest.resolve(
                explicit: "homelab", active: "primary", available: ["primary", "homelab"]),
            "homelab"
        )
        XCTAssertNil(
            WorkspaceCommandCenterRequest.resolve(
                explicit: "removed", active: "primary", available: ["primary", "homelab"])
        )
    }

    func testSettingsCommandCenterRequestUsesActiveThenAvailableSource() {
        XCTAssertEqual(
            WorkspaceCommandCenterRequest.resolve(
                explicit: nil, active: "homelab", available: ["primary", "homelab"]),
            "homelab"
        )
        XCTAssertEqual(
            WorkspaceCommandCenterRequest.resolve(
                explicit: nil, active: nil, available: ["primary", "homelab"]),
            "primary"
        )
        XCTAssertNil(
            WorkspaceCommandCenterRequest.resolve(explicit: nil, active: nil, available: [])
        )
    }

    func testCommandCenterEntryIsLiveOnlyEvenWhenSavedGatewaysExist() {
        XCTAssertFalse(WorkspaceCommandCenterRequest.allows(mode: .demo))
        XCTAssertTrue(WorkspaceCommandCenterRequest.allows(mode: .live))
    }

    @MainActor
    func testDemoRequestFailsClosedBeforeResolvingSavedGateway() {
        let model = AppModel()
        XCTAssertFalse(model.requestCommandCenter(gatewayID: "saved-gateway"))
    }
}
#endif

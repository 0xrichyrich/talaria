#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class RosterRoomIntegrationTests: XCTestCase {
    func testForeignOnlyRosterNeverShowsAddGatewayEmptyState() {
        XCTAssertFalse(RosterRoomPolicy.showsEmpty(primaryBots: 0, rooms: 0,
                                                    foreignBots: 1, isSearching: false))
        XCTAssertTrue(RosterRoomPolicy.showsEmpty(primaryBots: 0, rooms: 0,
                                                   foreignBots: 0, isSearching: false))
    }

    func testRoomSearchMatchesNameMemberHandleTitleAndSource() {
        let room = RoomRecord(name: "Launch Crew", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "research"),
                       title: "Ada", handle: "research-lab", sourceLabel: "Homelab")
        ])
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "launch"))
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "ada"))
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "research-lab"))
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "homelab"))
        XCTAssertFalse(RosterRoomPolicy.matches(room, needle: "finance"))
    }

    func testMetadataOutboxStatusRemainsActionableAfterRoomRowDisappears() {
        XCTAssertEqual(RoomMetadataOutboxPolicy.status(pendingCount: 0, lastError: "offline"),
                       .clear)
        XCTAssertEqual(RoomMetadataOutboxPolicy.status(pendingCount: 3, lastError: nil),
                       .waiting(count: 3))
        XCTAssertEqual(RoomMetadataOutboxPolicy.status(pendingCount: 2,
                                                       lastError: "Gateway offline"),
                       .retryRequired(count: 2, message: "Gateway offline"))
    }
}
#endif

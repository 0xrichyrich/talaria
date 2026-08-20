#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class CommandCenterContractTests: XCTestCase {
    func testCommandCenterParsesRestartUpdateAndUsageContracts() {
        let restart = GatewayCommandAction(.object([
            "ok": .bool(true), "pid": .number(42), "name": .string("gateway-restart")
        ]), fallbackName: "gateway-restart")
        XCTAssertEqual(restart.name, "gateway-restart")
        XCTAssertTrue(restart.ok)
        XCTAssertEqual(restart.pid, 42)

        let check = GatewayCommandAction(.object([
            "install_method": .string("git"),
            "can_apply": .bool(true),
            "update_available": .bool(true),
            "behind": .number(3),
            "message": .string("3 commits behind"),
        ]), fallbackName: "hermes-update")
        XCTAssertTrue(check.canApply)
        XCTAssertTrue(check.updateAvailable)
        XCTAssertEqual(check.behind, 3)

        let usage = GatewayUsageSnapshot(.object([
            "period_days": .number(7),
            "totals": .object([
                "total_sessions": .number(4),
                "total_api_calls": .number(11),
                "total_input": .number(100),
                "total_output": .number(20),
                "total_estimated_cost": .number(1.5),
            ]),
            "by_model": .array([
                .object(["model": .string("gpt-5.6-sol"),
                         "input_tokens": .number(80),
                         "output_tokens": .number(20)]),
                .object(["model": .string(""),
                         "input_tokens": .number(9)]),
            ]),
        ]), days: 90)
        XCTAssertEqual(usage.days, 7)
        XCTAssertEqual(usage.sessions, 4)
        XCTAssertEqual(usage.apiCalls, 11)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.estimatedCost, 1.5, accuracy: 0.01)
        XCTAssertEqual(usage.topModels.map { $0.name }, ["gpt-5.6-sol"])
        XCTAssertEqual(usage.topModels.first?.tokens, 100)

        let status = GatewayStatus(.object([
            "gateway_running": .bool(true),
            "active_agents": .number(2),
            "active_sessions": .number(5),
            "version": .string("v0.20.3"),
        ]))
        XCTAssertTrue(status.gatewayRunning)
        XCTAssertEqual(status.activeAgents, 2)
        XCTAssertEqual(status.activeSessions, 5)
        XCTAssertEqual(status.version, "v0.20.3")
    }
}
#endif

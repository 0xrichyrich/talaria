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

    func testMaintenanceParsesCuratorMemoryAndDebugShareContracts() {
        let curator = GatewayCuratorStatus(.object([
            "enabled": .bool(true),
            "paused": .bool(true),
            "last_run_at": .string("2026-08-19T20:00:00Z"),
        ]))
        XCTAssertTrue(curator.enabled)
        XCTAssertTrue(curator.paused)
        XCTAssertFalse(curator.isActive)
        XCTAssertEqual(curator.lastRunAt, "2026-08-19T20:00:00Z")

        let memory = GatewayMemoryStoreStatus(.object([
            "active": .string("built-in"),
            "builtin_files": .object([
                "memory": .number(2048),
                "user": .number(0),
            ]),
        ]))
        XCTAssertEqual(memory.active, "built-in")
        XCTAssertEqual(memory.memoryBytes, 2048)
        XCTAssertEqual(memory.userBytes, 0)

        let share = GatewayDebugShare(.object([
            "ok": .bool(true),
            "redacted": .bool(true),
            "auto_delete_seconds": .number(21600),
            "urls": .object([
                "summary": .string("https://paste.example/a"),
                "logs": .string("https://paste.example/b"),
                "empty": .string(""),
            ]),
            "failures": .object([
                "nous": .string("offline"),
            ]),
        ]))
        XCTAssertTrue(share.ok)
        XCTAssertEqual(share.urls.map { $0.key }, ["logs", "summary"])
        XCTAssertEqual(share.failures.map { $0.key }, ["nous"])
        XCTAssertEqual(share.autoDeleteSeconds, 21600)

        let reset = GatewayMemoryResetResult(.object([
            "ok": .bool(true),
            "deleted": .array([.string("MEMORY.md"), .string("USER.md")]),
        ]))
        XCTAssertTrue(reset.ok)
        XCTAssertEqual(reset.deleted, ["MEMORY.md", "USER.md"])
    }

    func testWorkspaceParsesFilesAndGitContracts() {
        let listing = GatewayFileListing(.object([
            "path": .string("/tmp/work"),
            "parent": .string("/tmp"),
            "locked_root": .string("/tmp"),
            "entries": .array([
                .object(["name": .string("src"), "path": .string("/tmp/work/src"),
                         "is_directory": .bool(true)]),
                .object(["name": .string("README.md"), "path": .string("/tmp/work/README.md"),
                         "is_directory": .bool(false), "size": .number(12)]),
            ]),
        ]))
        XCTAssertEqual(listing.path, "/tmp/work")
        XCTAssertEqual(listing.parent, "/tmp")
        XCTAssertEqual(listing.entries.map { $0.name }, ["src", "README.md"])
        XCTAssertTrue(listing.entries[0].isDirectory)

        let git = GatewayGitStatus(.object([
            "branch": .string("main"),
            "ahead": .number(1),
            "behind": .number(0),
            "staged": .number(2),
            "unstaged": .number(1),
            "untracked": .number(3),
            "changed": .number(4),
            "files": .array([
                .object(["path": .string("Packages/Talaria/Package.swift")]),
            ]),
        ]))
        XCTAssertEqual(git.branch, "main")
        XCTAssertEqual(git.ahead, 1)
        XCTAssertEqual(git.changed, 4)
        XCTAssertEqual(git.files, ["Packages/Talaria/Package.swift"])
    }

    func testWorkspaceParsesProjectsContract() {
        let list = GatewayProjectList(.object([
            "active_id": .string("p1"),
            "projects": .array([
                .object([
                    "id": .string("p1"),
                    "name": .string("Talaria"),
                    "primary_path": .string("/Users/joshua/talaria"),
                    "archived": .bool(false),
                ]),
                .object([
                    "id": .string("p2"),
                    "name": .string("Scratch"),
                    "folders": .array([.object(["path": .string("/tmp/scratch")])]),
                ]),
            ]),
        ]))
        XCTAssertEqual(list.activeID, "p1")
        XCTAssertEqual(list.projects.map { $0.name }, ["Talaria", "Scratch"])
        XCTAssertTrue(list.projects[0].isActive)
        XCTAssertEqual(list.projects[1].path, "/tmp/scratch")
        XCTAssertFalse(list.projects[1].isActive)
    }
}
#endif

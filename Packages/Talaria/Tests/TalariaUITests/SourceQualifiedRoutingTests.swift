#if canImport(XCTest)
import XCTest
import TalariaKit
@testable import TalariaUI

@MainActor
final class SourceQualifiedRoutingTests: XCTestCase {
    override func tearDown() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = nil
        runtime.sessionToBot.removeAll()
        runtime.routedSessionToBot.removeAll()
        runtime.approvalSessions.removeAll()
        runtime.routedApprovalSessions.removeAll()
        SessionsRuntime.shared.resetPrimaryScope()
        SessionsRuntime.shared.resetRoutedScope(gatewayID: "homelab")
        super.tearDown()
    }

    func testSameRuntimeSessionIDRoutesByGateway() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "primary"),
                       "default")
        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "homelab"),
                       "homelab::researcher")
        XCTAssertNil(model.botID(forSession: "deadbeef", sourceGatewayID: "unknown"))
    }

    func testRemoteDeltaCannotMutateCollidingPrimaryChat() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        let event = GatewayEvent(type: "message.delta", sessionID: "deadbeef",
                                 payload: .object(["text": .string("remote answer")]))
        model.handle(event: event, sourceGatewayID: "homelab")

        XCTAssertTrue(model.chat(for: "default").messages.isEmpty)
        XCTAssertEqual(model.chat(for: "homelab::researcher").messages.last?.text,
                       "remote answer")
    }

    func testForeignOpenKeepsQualifiedIdentity() async {
        let model = AppModel()
        let entry = ForeignRosterEntry(gatewayID: "homelab",
                                       connectionLabel: "Homelab",
                                       connectionKind: .tailscale,
                                       profile: "researcher",
                                       handle: "researcher")

        await model.openForeignBot(entry)

        XCTAssertEqual(model.openBotID, "homelab::researcher")
        XCTAssertEqual(model.selectedTab, .home)
    }

    func testPrimaryResetPreservesRemoteSessionRouting() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["aaaaaaaa"] = "default"
        let remote = GatewaySessionRoute(gatewayID: "homelab", sessionID: "bbbbbbbb")
        runtime.routedSessionToBot[remote] = "homelab::researcher"
        runtime.workingBotIDs = ["default", "homelab::researcher"]

        runtime.resetSessionState()

        XCTAssertTrue(runtime.sessionToBot.isEmpty)
        XCTAssertEqual(runtime.routedSessionToBot[remote], "homelab::researcher")
        XCTAssertEqual(runtime.workingBotIDs, ["homelab::researcher"])
    }

    func testRemoteSessionTitleCannotPatchCollidingPrimaryStoredID() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        model.chat(for: "default").storedSessions = [
            SessionSummary(id: "same-row", title: "Primary", when: "now", messageCount: 1),
        ]
        model.chat(for: "homelab::researcher").storedSessions = [
            SessionSummary(id: "same-row", title: "Remote", when: "now", messageCount: 1),
        ]

        let event = GatewayEvent(type: "session.title", sessionID: "deadbeef",
                                 payload: .object([
                                    "session_id": .string("same-row"),
                                    "title": .string("Remote renamed"),
                                 ]))
        model.applySessionTitle(event, sourceGatewayID: "homelab")

        XCTAssertEqual(model.chat(for: "default").storedSessions[0].title, "Primary")
        XCTAssertEqual(model.chat(for: "homelab::researcher").storedSessions[0].title,
                       "Remote renamed")
        XCTAssertNil(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "default", sessionID: "same-row")])
        XCTAssertEqual(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "homelab::researcher", sessionID: "same-row")],
                       "Remote renamed")
    }

    func testRemoteCompletionPrunesOnlyExactGatewaySessionRoute() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        runtime.approvalSessions["primary-approval"] = "deadbeef"
        runtime.routedApprovalSessions["remote-approval"] = GatewaySessionRoute(
            gatewayID: "homelab", sessionID: "deadbeef")
        model.approvals = [
            approval(id: "primary-approval", botID: "default"),
            approval(id: "remote-approval", botID: "homelab::researcher"),
        ]

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("")])) ,
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.approvals.map(\.id), ["primary-approval"])
        XCTAssertEqual(runtime.approvalSessions["primary-approval"], "deadbeef")
        XCTAssertNil(runtime.routedApprovalSessions["remote-approval"])
    }

    func testUnmappedRemoteApprovalCannotFallbackToPrimaryBot() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.defaultBotID = "default"

        model.handle(event: approvalEvent(requestID: "orphaned", sessionID: "deadbeef"),
                     sourceGatewayID: "homelab")

        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertNil(runtime.approvalSessions["orphaned"])
        XCTAssertNil(runtime.routedApprovalSessions["orphaned"])
    }

    func testApprovalResponseRejectsMixedGatewayOwnership() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.routedApprovalSessions["remote-approval"] = GatewaySessionRoute(
            gatewayID: "homelab", sessionID: "deadbeef")
        let item = approval(id: "remote-approval", botID: "default")

        let target = model.approvalResponseTarget(
            for: item, botRoute: GatewayBotRoute(gatewayID: "primary", profile: "default"))

        XCTAssertNil(target)
    }

    func testApprovalResponseKeepsQualifiedRemoteDestination() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let session = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.routedApprovalSessions["remote-approval"] = session
        let item = approval(id: "remote-approval", botID: "homelab::researcher")
        let bot = GatewayBotRoute(gatewayID: "homelab", profile: "researcher")

        XCTAssertEqual(model.approvalResponseTarget(for: item, botRoute: bot),
                       ApprovalResponseTarget(bot: bot, session: session))
    }

    private func approval(id: String, botID: String) -> Approval {
        Approval(id: id, botID: botID, kind: .command, title: "Run",
                 target: "shell", subject: "echo ok", body: "echo ok",
                 why: "test", age: "now")
    }

    private func approvalEvent(requestID: String, sessionID: String) -> GatewayEvent {
        GatewayEvent(type: "approval.request", sessionID: sessionID, payload: .object([
            "request_id": .string(requestID),
            "command": .string("echo ok"),
            "description": .string("Run command"),
            "choices": .array([.string("once"), .string("deny")]),
        ]))
    }
}
#endif

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
        MultiGatewayRuntime.shared.routedUnread.removeAll()
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
            payload: .object(["status": .string("complete"), "text": .string("")])),
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

    func testUnreadWatermarksKeepCollidingProfilesInSeparateGatewayScopes() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!

        XCTAssertTrue(store.ingest(["default": 100], openBot: nil, scope: primary).isEmpty)
        XCTAssertTrue(store.ingest(["default": 500], openBot: nil, scope: homelab).isEmpty)
        XCTAssertEqual(store.ingest(["default": 101], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertEqual(store.ingest(["default": 501], openBot: nil, scope: homelab),
                       ["default"])
    }

    func testUnreadAcknowledgeNamesItsGatewayExplicitly() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!
        _ = store.ingest(["default": 100], openBot: nil, scope: primary)
        _ = store.ingest(["default": 100], openBot: nil, scope: homelab)

        store.acknowledge("default", scope: homelab)

        XCTAssertEqual(store.ingest(["default": 200], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertTrue(store.ingest(["default": 200], openBot: nil, scope: homelab).isEmpty)
    }

    func testRemoteUnreadCannotBadgeOrClearCollidingPrimaryBot() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.recordUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
        XCTAssertEqual(model.totalRosterUnread, 1)

        model.recordUnread(for: "default")
        model.clearUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 1)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testRemoteCompletionBadgesOnlyItsQualifiedBot() {
        let model = AppModel()
        model.mode = .live
        model.bots = [.unlisted(id: "default")]
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let route = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.routedSessionToBot[route] = "homelab::default"
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("done")])),
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
    }

    func testOpeningRemoteChatClearsOnlyItsQualifiedUnread() {
        let model = AppModel()
        model.mode = .demo
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 2
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        MultiGatewayRuntime.shared.routedUnread[remote] = 3

        model.openChat(botID: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 2)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testUnreadCountSurvivesGatewayRoleTransitionsExactlyOnce() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 3
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")

        model.preservePrimaryUnreadForGatewaySwitch()

        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[route], 3)
        model.bots = []
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 3)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[route])
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 0)
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

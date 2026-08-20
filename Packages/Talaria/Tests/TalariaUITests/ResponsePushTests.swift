#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI
import TalariaTheme

final class ResponsePushTests: XCTestCase {
    func testResponseWireKindDecodesWithExactIdentity() {
        let payload: [AnyHashable: Any] = [
            PushPayloadKey.kind: "response",
            PushPayloadKey.gatewayID: "homelab",
            PushPayloadKey.bot: "inbox",
            PushPayloadKey.title: "Agent reply ready",
            PushPayloadKey.body: "The draft is ready.",
            PushPayloadKey.sessionID: "stored-42",
            PushPayloadKey.deeplink: "talaria://bot/inbox?session_id=stored-42&gateway_id=homelab",
        ]

        let decoded = PushPayloadDecoder.decode(payload)

        XCTAssertEqual(decoded?.wireKind, "response")
        XCTAssertEqual(decoded?.kind, .response)
        XCTAssertEqual(decoded?.gatewayID, "homelab")
        XCTAssertEqual(decoded?.bot, "inbox")
        XCTAssertEqual(decoded?.sessionID, "stored-42")
        XCTAssertEqual(decoded?.deeplink?.scheme, "talaria")
        XCTAssertEqual(decoded?.deeplink?.host, "bot")
        let query = URLComponents(url: decoded!.deeplink!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "session_id" })?.value, "stored-42")
        XCTAssertEqual(query?.first(where: { $0.name == "gateway_id" })?.value, "homelab")
    }

    func testLongTaskWireNameStillUsesTaskDisplayKind() {
        let decoded = PushPayloadDecoder.decode([
            PushPayloadKey.kind: "long_task",
            PushPayloadKey.bot: "ops",
        ])

        XCTAssertEqual(decoded?.kind, .task)
        XCTAssertEqual(decoded?.wireKind, "long_task")
    }

    func testUnknownOrEmptyWireKindFailsClosed() {
        XCTAssertNil(PushPayloadDecoder.decode([PushPayloadKey.kind: "future_kind"]))
        XCTAssertNil(PushPayloadDecoder.decode([PushPayloadKey.kind: " "]))
        XCTAssertNil(PushPayloadDecoder.decode([PushPayloadKey.bot: "inbox"]))
    }

    func testResponseDestinationQualifiesSourceAndKeepsStoredSession() {
        let payload = PushNotificationPayload(
            wireKind: "response", kind: .response, gatewayID: "homelab", bot: "inbox",
            title: nil, body: nil, approvalRequestID: nil, sessionID: "stored-42",
            deeplink: nil)

        XCTAssertEqual(PushRouteResolver.destination(
            for: payload, knownGatewayIDs: ["primary", "homelab"],
            activeGatewayID: "primary"),
            PushRouteDestination(botID: "homelab::inbox", storedSessionID: "stored-42",
                                 gatewayID: "homelab"))
    }

    func testResponseDestinationUsesBareActiveBotWithoutCrossSource() {
        let payload = PushNotificationPayload(
            wireKind: "response", kind: .response, gatewayID: "primary", bot: "inbox",
            title: nil, body: nil, approvalRequestID: nil, sessionID: "stored-42",
            deeplink: nil)

        XCTAssertEqual(PushRouteResolver.destination(
            for: payload, knownGatewayIDs: ["primary", "homelab"],
            activeGatewayID: "primary")?.botID, "inbox")
        let foreign = PushRouteResolver.destination(
            for: PushNotificationPayload(
                wireKind: "response", kind: .response, gatewayID: "attacker",
                bot: "inbox", title: nil, body: nil, approvalRequestID: nil,
                sessionID: "stored-42", deeplink: nil),
            knownGatewayIDs: ["primary", "homelab"], activeGatewayID: "primary")
        XCTAssertNil(foreign)
    }

    func testResponseWithoutStoredSessionHasNoDestination() {
        let payload = PushNotificationPayload(
            wireKind: "response", kind: .response, gatewayID: "primary", bot: "inbox",
            title: nil, body: nil, approvalRequestID: nil, sessionID: nil, deeplink: nil)

        // The caller requires this field before opening a response push. A
        // missing session must never fall back to the bot's canonical chat.
        XCTAssertNil(PushRouteResolver.destination(
            for: payload, knownGatewayIDs: ["primary"], activeGatewayID: "primary"))
    }

    func testResponseCategoryIsDisplayOnlyAndActive() {
        XCTAssertEqual(PushIdentifiers.responseCategory, "TALARIA_RESPONSE")
        XCTAssertEqual(PushNotificationPolicy.category(for: "response"),
                       PushIdentifiers.responseCategory)
        XCTAssertNil(PushNotificationPolicy.category(for: "unknown"))
        XCTAssertEqual(PushNotificationPolicy.interruptionLevel(for: "response"),
                       .active)
        XCTAssertFalse(PushNotificationPolicy.allowsApprovalAction(for: "response"))
        XCTAssertTrue(PushNotificationPolicy.allowsApprovalAction(for: "approval"))
        XCTAssertFalse(PushNotificationPolicy.usesCommunicationStyle(for: "response"))
        XCTAssertTrue(PushNotificationPolicy.usesCommunicationStyle(for: "mention"))
    }

    func testSettingsCopyAndDemoPrefsNameAgentReplies() {
        for theme in [ThemeID.soft, .control, .ink] {
            let copy = CopyPack.pack(for: theme)
            XCTAssertTrue(copy.pushNote.localizedCaseInsensitiveContains("repl"))
            XCTAssertTrue(copy.settingsKindResponse(theme).localizedCaseInsensitiveContains("reply")
                          || copy.settingsKindResponse(theme).localizedCaseInsensitiveContains("answer"))
            XCTAssertTrue(copy.settingsKindResponseSub(theme).localizedCaseInsensitiveContains("session"))
        }

        XCTAssertTrue(DemoData.notificationPrefs.contains { $0.kind == .response })
    }
}
#endif

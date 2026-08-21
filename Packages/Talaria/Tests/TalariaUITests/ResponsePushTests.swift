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
        XCTAssertTrue(PushNotificationPolicy.usesCommunicationStyle(for: "response"))
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

    func testNotificationCommunicationIdentityKeepsRawRouteSeparateFromDisplayName() throws {
        let identity = try XCTUnwrap(NotificationCommunicationIdentity.resolve(
            rawProfile: "default", configuredDisplayName: "Mercury",
            gatewayID: "homelab"))

        XCTAssertEqual(identity.rawProfile, "default")
        XCTAssertEqual(identity.displayName, "Mercury")
        XCTAssertEqual(identity.sourceQualifiedIdentifier, "bot:7:homelabdefault")
        XCTAssertNotEqual(identity.displayName, identity.rawProfile)
    }

    func testNotificationCommunicationIdentityUsesTruthfulFallbacksPerSource() throws {
        let primary = try XCTUnwrap(NotificationCommunicationIdentity.resolve(
            rawProfile: "default", configuredDisplayName: nil,
            gatewayID: "primary"))
        let foreign = try XCTUnwrap(NotificationCommunicationIdentity.resolve(
            rawProfile: "researcher", configuredDisplayName: " ",
            gatewayID: "foreign"))

        XCTAssertEqual(primary.displayName, "Hermes")
        XCTAssertEqual(primary.rawProfile, "default")
        XCTAssertEqual(foreign.displayName, "researcher")
        XCTAssertEqual(foreign.rawProfile, "researcher")
        XCTAssertNotEqual(primary.sourceQualifiedIdentifier,
                          try XCTUnwrap(NotificationCommunicationIdentity.resolve(
                            rawProfile: "default", configuredDisplayName: nil,
                            gatewayID: "foreign")).sourceQualifiedIdentifier)
    }

    func testResponseCommunicationRestampPreservesExactPresentationContract() throws {
        let identity = try XCTUnwrap(NotificationCommunicationIdentity.resolve(
            rawProfile: "default", configuredDisplayName: "Skynet",
            gatewayID: "homelab"))
        let presentation = ResponseNotificationPresentation.resolve(
            identity: identity, body: "The exact answer body.")

        XCTAssertEqual(presentation.title, "Skynet")
        XCTAssertEqual(presentation.body, "The exact answer body.")
        XCTAssertEqual(presentation.threadIdentifier, "default",
                       "friendly/source display metadata must not rewrite raw thread identity")
        XCTAssertEqual(presentation.categoryIdentifier, PushIdentifiers.responseCategory)
        XCTAssertEqual(presentation.interruptionLevel, .active)
    }

    func testNotificationAvatarPayloadAcceptsOnlyBoundedMatchingInlineImage() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let decoded = NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: [
                "mime": "image/png",
                "data": png.base64EncodedString(),
            ],
        ])

        XCTAssertEqual(decoded?.mimeType, "image/png")
        XCTAssertEqual(decoded?.data, png)
        XCTAssertLessThanOrEqual(decoded?.data.count ?? .max,
                                 NotificationAvatarPayload.maximumDecodedBytes)
    }

    func testNotificationAvatarMalformedMissingOrURLPayloadFallsBackToAppIcon() {
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0x00])
        let truncatedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let hugeDimensions = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAQAAAAQR6qsAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let oversized = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: 0, count: NotificationAvatarPayload.maximumDecodedBytes)

        XCTAssertNil(NotificationAvatarPayload.decode([:]))
        XCTAssertNil(NotificationAvatarPayload.decode(["bot_avatar_url": "https://example.invalid/a.png"]))
        XCTAssertNil(NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: ["mime": "image/svg+xml", "data": "PHN2Zy8+"],
        ]))
        XCTAssertNil(NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: [
                "mime": "image/png", "data": jpegHeader.base64EncodedString(),
            ],
        ]))
        XCTAssertNil(NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: [
                "mime": "image/png", "data": oversized.base64EncodedString(),
            ],
        ]))
        XCTAssertNil(NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: [
                "mime": "image/png", "data": truncatedPNG.base64EncodedString(),
            ],
        ]))
        XCTAssertNil(NotificationAvatarPayload.decode([
            NotificationAvatarPayload.key: [
                "mime": "image/png", "data": hugeDimensions.base64EncodedString(),
            ],
        ]))
        XCTAssertTrue(PushNotificationPolicy.usesCommunicationStyle(for: "response"))
    }
}
#endif

import Foundation
import XCTest
@testable import TalariaUI

final class GatewayTerminalRendererPolicyTests: XCTestCase {
    func testSoftKeysEmitVTSequences() {
        XCTAssertEqual(GatewayTerminalInputPolicy.softKeyBytes(.escape, controlArmed: false), [0x1b])
        XCTAssertEqual(GatewayTerminalInputPolicy.softKeyBytes(.tab, controlArmed: false), [0x09])
        XCTAssertEqual(GatewayTerminalInputPolicy.softKeyBytes(.arrowUp, controlArmed: false), [0x1b, 0x5b, 0x41])
        XCTAssertEqual(GatewayTerminalInputPolicy.softKeyBytes(.arrowLeft, controlArmed: true), [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44])
        XCTAssertNil(GatewayTerminalInputPolicy.softKeyBytes(.control, controlArmed: false))
    }

    func testControlLatchTransformsASCIIButDoesNotCorruptUTF8() {
        XCTAssertEqual(GatewayTerminalInputPolicy.applyingControl(to: [0x63][...], armed: true), [0x03])
        XCTAssertEqual(GatewayTerminalInputPolicy.applyingControl(to: [0x5b][...], armed: true), [0x1b])
        XCTAssertEqual(GatewayTerminalInputPolicy.applyingControl(to: [0xc3, 0xa9][...], armed: true), [0xc3, 0xa9])
        XCTAssertEqual(GatewayTerminalInputPolicy.applyingControl(to: [0x63][...], armed: false), [0x63])
    }

    func testChunkIdentityPreventsDuplicateTerminalFeed() {
        let id = UUID()
        let chunk = GatewayTerminalChunk(id: id, bytes: Data([1, 2, 3]))
        var state = GatewayTerminalRendererState()

        XCTAssertEqual(state.bytesToFeed(for: chunk).map(Array.init), [1, 2, 3])
        XCTAssertNil(state.bytesToFeed(for: chunk))
        XCTAssertEqual(
            state.bytesToFeed(for: GatewayTerminalChunk(id: UUID(), bytes: Data([1, 2, 3]))).map(Array.init),
            [1, 2, 3]
        )
    }

    func testResizeRejectsInvalidAndDuplicateDimensions() {
        var state = GatewayTerminalRendererState()
        XCTAssertNil(state.resizeToEmit(columns: 0, rows: 24))
        XCTAssertEqual(state.resizeToEmit(columns: 80, rows: 24).map { [$0.0, $0.1] }, [80, 24])
        XCTAssertNil(state.resizeToEmit(columns: 80, rows: 24))
        XCTAssertEqual(state.resizeToEmit(columns: 100, rows: 24).map { [$0.0, $0.1] }, [100, 24])
    }

    func testLinkPolicyAllowsWebAndMailButRejectsProcessLikeSchemes() {
        XCTAssertEqual(GatewayTerminalLinkPolicy.url(for: "https://example.com/path")?.host, "example.com")
        XCTAssertEqual(GatewayTerminalLinkPolicy.url(for: "mailto:hello@example.com")?.scheme, "mailto")
        XCTAssertNil(GatewayTerminalLinkPolicy.url(for: "file:///etc/passwd"))
        XCTAssertNil(GatewayTerminalLinkPolicy.url(for: "ssh://host"))
        XCTAssertNil(GatewayTerminalLinkPolicy.url(for: "not a link"))
    }
}

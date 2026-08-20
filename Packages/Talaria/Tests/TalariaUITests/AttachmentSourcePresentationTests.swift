#if canImport(XCTest)
import XCTest
@testable import TalariaUI

final class AttachmentSourcePresentationTests: XCTestCase {
    func testChatSourceSheetPresentsAllExplicitAttachmentChoices() {
        let options = AttachmentSourcePresentation.options(allowsPaste: true)

        XCTAssertEqual(AttachmentSourcePresentation.title, "Add to message")
        XCTAssertEqual(options.map(\.action), [.photos, .files, .pasteImage])
        XCTAssertEqual(options.map(\.title), ["Photo Library", "Files", "Paste Image"])
        XCTAssertEqual(options.first?.detail, "Choose up to 6 photos")
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumRowHeight, 44)
    }

    func testRoomSourceSheetExcludesClipboardWithoutChangingOtherSources() {
        let options = AttachmentSourcePresentation.options(allowsPaste: false)

        XCTAssertEqual(options.map(\.action), [.photos, .files])
        XCTAssertFalse(options.contains { $0.action == .pasteImage })
        XCTAssertTrue(options.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }
}
#endif

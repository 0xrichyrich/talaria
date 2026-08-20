#if canImport(XCTest)
import XCTest
@testable import TalariaUI

final class AttachmentSourcePresentationTests: XCTestCase {
    func testSourceSheetPresentsEverySupportedAttachmentChoice() {
        let options = AttachmentSourcePresentation.options(
            supportsPhotoLibrary: true,
            allowsPaste: true
        )

        XCTAssertEqual(AttachmentSourcePresentation.title, "Add to message")
        XCTAssertEqual(options.map(\.action), [.photos, .files, .pasteImage])
        XCTAssertEqual(options.map(\.title), ["Photo Library", "Files", "Paste Image"])
        XCTAssertEqual(options.first?.detail, "Choose up to 6 photos")
        XCTAssertGreaterThanOrEqual(AttachmentSourcePresentation.minimumRowHeight, 44)
    }

    func testSourceSheetHidesPhotoLibraryWhenThePresenterCannotOpenIt() {
        let options = AttachmentSourcePresentation.options(allowsPaste: true)

        XCTAssertEqual(options.map(\.action), [.files, .pasteImage])
        XCTAssertFalse(options.contains { $0.action == .photos })
        XCTAssertEqual(options.map(\.title), ["Files", "Paste Image"])
    }

    func testSourceSheetLeavesFilesWhenNoOptionalSourceIsAvailable() {
        let options = AttachmentSourcePresentation.options(
            supportsPhotoLibrary: false,
            allowsPaste: false
        )

        XCTAssertEqual(options.map(\.action), [.files])
        XCTAssertFalse(options.contains { $0.action == .photos })
        XCTAssertFalse(options.contains { $0.action == .pasteImage })
        XCTAssertTrue(options.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }
}
#endif

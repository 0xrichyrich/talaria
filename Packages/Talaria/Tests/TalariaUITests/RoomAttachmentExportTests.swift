#if canImport(XCTest)
import XCTest
@testable import TalariaUI

final class RoomAttachmentExportTests: XCTestCase {
    func testSanitizesPathAndRestoresDeclaredTypeExtension() {
        XCTAssertEqual(
            RoomAttachmentExport.sanitizedFileName(
                "../../Quarterly:Plan.exe", mediaType: "application/pdf"),
            "Quarterly-Plan.pdf")
        XCTAssertEqual(
            RoomAttachmentExport.sanitizedFileName(
                #"C:\private\photo.PNG"#, mediaType: "image/png"),
            "photo.PNG")
    }

    func testPreparedExportRetainsNameBytesAndCleansDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "talaria-room-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let payload = Data("named attachment".utf8)

        let export = try RoomAttachmentExport.prepare(
            data: payload, fileName: "report", mediaType: "application/pdf",
            baseDirectory: base)

        XCTAssertEqual(export.fileURL.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: export.fileURL), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.directoryURL.path))
        export.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.directoryURL.path))
    }
}
#endif

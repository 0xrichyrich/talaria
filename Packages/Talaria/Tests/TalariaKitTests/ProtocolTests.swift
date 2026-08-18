#if canImport(XCTest)
import XCTest
@testable import TalariaKit

// XCTest is unavailable on toolchain-only (no Xcode) hosts; the same
// assertions run everywhere via `swift run talaria-verify`.
final class ProtocolXCTests: XCTestCase {
    func testAll() throws {
        try ProtocolChecks.runAll()
    }
}
#endif

#if canImport(XCTest)
import XCTest
@testable import TalariaTheme

final class MotionPolicyTests: XCTestCase {
    func testMotionVocabularyUsesFourDeliberateBeats() {
        XCTAssertEqual(TalariaMotionTokens.Pace.allCases.map(\.rawValue),
                       [0.15, 0.25, 0.30, 0.35])
        XCTAssertEqual(TalariaMotionTokens.duration(.fast), 0.15)
        XCTAssertEqual(TalariaMotionTokens.duration(.quick), 0.25)
        XCTAssertEqual(TalariaMotionTokens.duration(.standard), 0.30)
        XCTAssertEqual(TalariaMotionTokens.duration(.deliberate), 0.35)
    }

    func testReducedMotionEliminatesSpatialMovement() {
        XCTAssertEqual(TalariaMotionTokens.pushOffset(reducedMotion: true), 0)
        XCTAssertEqual(TalariaMotionTokens.pushOffset(reducedMotion: false), 10)
        XCTAssertNil(TalariaMotionTokens.spatialAnimation(.standard,
                                                    reducedMotion: true))
        XCTAssertNotNil(TalariaMotionTokens.spatialAnimation(.standard,
                                                       reducedMotion: false))
    }

    func testReducedMotionKeepsOnlyShortOpacityFeedback() {
        XCTAssertNotNil(TalariaMotionTokens.opacityAnimation(.deliberate,
                                                       reducedMotion: true))
        XCTAssertNotNil(TalariaMotionTokens.opacityAnimation(.deliberate,
                                                       reducedMotion: false))
    }
}
#endif

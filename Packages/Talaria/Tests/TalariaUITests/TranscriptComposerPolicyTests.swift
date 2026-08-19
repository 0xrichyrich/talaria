#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaTheme
@testable import TalariaUI

final class TranscriptComposerPolicyTests: XCTestCase {
    @MainActor
    func testTranscriptPreferenceDefaultsPersistsAndResetsLocally() {
        let suite = "talaria.tests.transcript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = TalariaSettingsStore(defaults: defaults)
        XCTAssertEqual(first.transcriptDetail, .quiet)
        first.transcriptDetail = .advanced
        XCTAssertEqual(TalariaSettingsStore(defaults: defaults).transcriptDetail, .advanced)

        first.resetToDefaults()
        XCTAssertEqual(first.transcriptDetail, .quiet)
        XCTAssertEqual(defaults.string(forKey: TalariaSettingsStore.transcriptDetailKey), "quiet")
    }

    func testQuietPresentationHidesAllToolDetails() {
        let calls = [
            ToolCall(id: "running", name: "read", context: "", state: .running),
            ToolCall(id: "done", name: "search", context: "", state: .done),
            ToolCall(id: "failed", name: "terminal", context: "", state: .failed),
        ]
        let quiet = TranscriptPresentationPolicy(detail: .quiet)
        XCTAssertTrue(quiet.visibleToolCalls(calls).isEmpty)
        XCTAssertFalse(quiet.showsReasoning(isLive: true))
        XCTAssertTrue(quiet.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: true))
    }

    func testAdvancedPresentationShowsAllDetailWithoutDuplicateLiveAvatar() {
        let calls = [
            ToolCall(id: "done", name: "search", context: "", state: .done),
            ToolCall(id: "failed", name: "terminal", context: "", state: .failed),
        ]
        let advanced = TranscriptPresentationPolicy(detail: .advanced)
        XCTAssertEqual(advanced.visibleToolCalls(calls), calls)
        XCTAssertTrue(advanced.showsReasoning(isLive: false))
        XCTAssertTrue(advanced.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: false))
        XCTAssertFalse(advanced.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: true))
    }

    func testIdleAvatarKeepsIndependentBreatheAndGazeMotionWithoutWorkState() {
        let first = FacePose.at(.idle, t: 0, phase: 0)
        let later = FacePose.at(.idle, t: 1.25, phase: 0.8)
        XCTAssertFalse(first.working)
        XCTAssertFalse(later.working)
        XCTAssertNotEqual(first.roll, later.roll)
        XCTAssertNotEqual(first.gazeX, later.gazeX)
        XCTAssertNotEqual(first.gazeY, later.gazeY)
        XCTAssertEqual(first.eyeScale, 1)
        XCTAssertGreaterThan(FacePose.at(.work, t: 0).eyeScale, 1)
    }

    func testComposerAllocatesFullEditorWidthAndAccessibleControls() {
        for width: CGFloat in [320, 375, 430] {
            XCTAssertEqual(
                ChatComposerLayoutPolicy.editorWidth(containerWidth: width, horizontalInsets: 14),
                width - 28
            )
        }
        XCTAssertGreaterThanOrEqual(ChatComposerLayoutPolicy.controlHitTarget, 44)
        XCTAssertEqual(ChatComposerLayoutPolicy.maxEditorLines(isAccessibilitySize: false), 6)
        XCTAssertEqual(ChatComposerLayoutPolicy.maxEditorLines(isAccessibilitySize: true), 4)
        XCTAssertNil(ChatComposerLayoutPolicy.animation(reducedMotion: true, duration: 0.2))
        XCTAssertNotNil(ChatComposerLayoutPolicy.animation(reducedMotion: false, duration: 0.2))
        XCTAssertEqual(TranscriptMotionPolicy.toolSpinnerDegrees(spinning: true,
                                                                 reducedMotion: true), 45)
        XCTAssertEqual(TranscriptMotionPolicy.toolSpinnerDegrees(spinning: true,
                                                                 reducedMotion: false), 360)
    }

    func testComposerActionMatrixPreservesSubmitSteerSlashAndStop() {
        XCTAssertEqual(action("   ", attachments: 0, running: false), .disabled)
        XCTAssertEqual(action("", attachments: 1, running: false), .submit)
        XCTAssertEqual(action("/", attachments: 0, running: false), .palette)
        XCTAssertEqual(action("/help", attachments: 0, running: false), .slash)
        XCTAssertEqual(action("", attachments: 0, running: true), .stop)
        XCTAssertEqual(action("more detail", attachments: 0, running: true), .steer)
        XCTAssertEqual(action("", attachments: 1, running: true), .stop)
    }

    private func action(_ draft: String, attachments: Int,
                        running: Bool) -> ChatComposerAction {
        ChatComposerActionPolicy.action(draft: draft, attachmentCount: attachments,
                                        isTurnRunning: running)
    }
}
#endif

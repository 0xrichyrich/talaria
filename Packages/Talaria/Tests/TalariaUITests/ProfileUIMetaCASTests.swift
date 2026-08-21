#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class ProfileUIMetaCASTests: XCTestCase {
    func testProfilesListDistinguishesLegacyOmissionFromCASRevisionZero() throws {
        let rows = try GatewayClient.decodeProfileRows([
            .object(["name": "legacy"]),
            .object(["name": "fresh", "ui_meta_revisions": .object([:])]),
            .object([
                "name": "existing",
                "ui_meta_revisions": .object(["hermes-bots-groups": 4]),
            ]),
        ])

        XCTAssertNil(rows[0].uiMetaRevisions)
        XCTAssertEqual(rows[1].uiMetaRevisions, [:])
        XCTAssertEqual(rows[2].uiMetaRevisions, ["hermes-bots-groups": 4])
    }

    func testProfilesListRejectsEveryMalformedRevisionShape() {
        let malformed: [JSONValue] = [
            .bool(true),
            .number(1.5),
            .number(-1),
            .number(Double(Int.max)),
        ]
        for revision in malformed {
            XCTAssertThrowsError(try GatewayClient.decodeProfileRows([
                .object([
                    "name": "default",
                    "ui_meta_revisions": .object(["shared-room": revision]),
                ]),
            ]))
        }
        XCTAssertThrowsError(try GatewayClient.decodeProfileRows([
            .object(["name": "default", "ui_meta_revisions": .array([])]),
        ]))
    }

    func testProfileEditEncodesExactPerKeyCASPreconditions() {
        let edit = ProfileEdit(
            uiMeta: .object([
                "hermes-bots": .object(["title": "Ops"]),
                "talaria": .null,
            ]),
            uiMetaExpectedRevisions: ["hermes-bots": 7, "talaria": 2])

        XCTAssertTrue(edit.isWireValid)
        XCTAssertEqual(
            edit.params(name: "default")["ui_meta_expected_revisions"]?.objectValue?
                .compactMapValues(\.intValue),
            ["hermes-bots": 7, "talaria": 2])
    }

    func testProfileEditRejectsIncompleteNegativeAndUnrepresentablePreconditions() {
        let patch: JSONValue = .object(["shared-room": .object([:])])
        XCTAssertFalse(ProfileEdit(
            uiMeta: patch,
            uiMetaExpectedRevisions: [:]).isWireValid)
        XCTAssertFalse(ProfileEdit(
            uiMeta: patch,
            uiMetaExpectedRevisions: ["other": 0]).isWireValid)
        XCTAssertFalse(ProfileEdit(
            uiMeta: patch,
            uiMetaExpectedRevisions: ["shared-room": -1]).isWireValid)
        XCTAssertFalse(ProfileEdit(
            uiMeta: patch,
            uiMetaExpectedRevisions: ["shared-room": Int.max]).isWireValid)
        // This integer itself fits exactly in Double, but its required +1
        // acknowledgement does not.
        XCTAssertFalse(ProfileEdit(
            uiMeta: patch,
            uiMetaExpectedRevisions: ["shared-room": 9_007_199_254_740_992]).isWireValid)
    }

    func testDetailedConfigureResultConfirmsOnlyExactIncrement() {
        let result = configureResult(
            applied: true,
            revisions: .object(["shared-room": 8]))

        XCTAssertEqual(result.applied, ["ui_meta": true])
        XCTAssertEqual(result.uiMetaRevisions, ["shared-room": 8])
        XCTAssertNil(result.uiMetaConflicts)
        XCTAssertFalse(result.hasMalformedUIMetaCASFields)
        XCTAssertTrue(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7], result: result))

        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 6], result: result))
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: [:], result: result))
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7, "other": 0], result: result))
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": Int.max], result: result))
    }

    func testDetailedParsingPreservesLegacyAppliedBooleanProjection() {
        let result = ProfileConfigureResult(.object([
            "applied": .object([
                "description": true,
                "skills": false,
                "future_section": true,
                "future_metadata": .object([:]),
            ]),
        ]))

        XCTAssertEqual(result.applied, [
            "description": true,
            "skills": false,
            "future_section": true,
        ])
        XCTAssertTrue(result.hasMalformedUIMetaCASFields)
    }

    func testConflictResponseIsTypedAndAlwaysFailsClosed() {
        let result = configureResult(
            applied: false,
            revisions: .object(["shared-room": 8]),
            conflicts: .object([
                "shared-room": .object(["expected": 7, "actual": 8]),
            ]))

        XCTAssertEqual(result.applied, ["ui_meta": false])
        XCTAssertEqual(result.uiMetaRevisions, ["shared-room": 8])
        XCTAssertEqual(result.uiMetaConflicts, [
            "shared-room": ProfileUIMetaConflict(expected: 7, actual: 8),
        ])
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7], result: result))

        let contradictory = configureResult(
            applied: true,
            revisions: .object(["shared-room": 8]),
            conflicts: .object([:]))
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7], result: contradictory))
    }

    func testMalformedConfigureCASFieldsAlwaysFailClosed() {
        let malformedRevisions: [JSONValue] = [
            .bool(true),
            .number(1.5),
            .number(-1),
            .number(Double(Int.max)),
        ]
        for revision in malformedRevisions {
            let result = configureResult(
                applied: true,
                revisions: .object(["shared-room": revision]))
            XCTAssertTrue(result.hasMalformedUIMetaCASFields)
            XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
                expectedRevisions: ["shared-room": 7], result: result))
        }

        let missingRevision = configureResult(applied: true)
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7], result: missingRevision))

        let malformedConflict = configureResult(
            applied: true,
            revisions: .object(["shared-room": 8]),
            conflicts: .object([
                "shared-room": .object(["expected": true, "actual": 8]),
            ]))
        XCTAssertTrue(malformedConflict.hasMalformedUIMetaCASFields)
        XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
            expectedRevisions: ["shared-room": 7], result: malformedConflict))

        for malformed in malformedRevisions.dropFirst() {
            let result = configureResult(
                applied: false,
                revisions: .object(["shared-room": 8]),
                conflicts: .object([
                    "shared-room": .object(["expected": 7, "actual": malformed]),
                ]))
            XCTAssertTrue(result.hasMalformedUIMetaCASFields)
            XCTAssertFalse(ProfileUIMetaCASPolicy.confirmsCommit(
                expectedRevisions: ["shared-room": 7], result: result))
        }
    }

    private func configureResult(applied: Bool,
                                 revisions: JSONValue? = nil,
                                 conflicts: JSONValue? = nil) -> ProfileConfigureResult {
        var fields: [String: JSONValue] = ["ui_meta": .bool(applied)]
        if let revisions { fields["ui_meta_revisions"] = revisions }
        if let conflicts { fields["ui_meta_conflicts"] = conflicts }
        return ProfileConfigureResult(.object(["applied": .object(fields)]))
    }
}
#endif

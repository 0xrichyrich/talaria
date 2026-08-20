#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class ArtifactOperationsRemediationTests: XCTestCase {
    @MainActor
    func testArtifactCacheSeparatesIdenticalPathsByExactGatewayProfileAndSession() {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let first = ArtifactProvenance(gatewayID: "gateway-a", profile: "worker",
                                       sessionID: "session-1", value: "/tmp/output.png")
        let second = ArtifactProvenance(gatewayID: "gateway-b", profile: "worker",
                                        sessionID: "session-1", value: "/tmp/output.png")
        let third = ArtifactProvenance(gatewayID: "gateway-a", profile: "worker",
                                       sessionID: "session-2", value: "/tmp/output.png")
        func publish(_ body: ArtifactBody, _ source: ArtifactProvenance) {
            let lease = store.acquire(for: source) { Task { body } }
            store.finish(body, lease: lease, for: source)
        }
        publish(.binary(Data([0xA]), mime: "application/octet-stream"), first)
        publish(.binary(Data([0xB]), mime: "application/octet-stream"), second)
        publish(.binary(Data([0xC]), mime: "application/octet-stream"), third)

        XCTAssertEqual(store.body(for: first)?.data, Data([0xA]))
        XCTAssertEqual(store.body(for: second)?.data, Data([0xB]))
        XCTAssertEqual(store.body(for: third)?.data, Data([0xC]))
    }

    func testMediaRequestsKeepSessionAndOAuthSecretsOutOfURL() throws {
        let base = try XCTUnwrap(URL(string: "https://gateway.example/base/"))
        let session = try GatewayREST.authenticatedMediaRequest(
            baseURL: base, credential: .sessionToken("session-secret"), path: "/tmp/movie.mp4")
        XCTAssertFalse(try XCTUnwrap(session.url?.absoluteString).contains("session-secret"))
        XCTAssertEqual(session.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "session-secret")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(session.url),
                                     resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["path"])

        let tokens = TokenSet(accessToken: "oauth-secret", refreshToken: "refresh",
                              expiresAt: 4_000_000_000, provider: "nous", userID: nil)
        let oauth = try GatewayREST.authenticatedMediaRequest(
            baseURL: base, credential: .oauth(tokens), path: "/tmp/audio.m4a")
        XCTAssertFalse(try XCTUnwrap(oauth.url?.absoluteString).contains("oauth-secret"))
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "Authorization"),
                       "Bearer oauth-secret")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(oauth.url),
                                     resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["path"])
    }

    func testGatewayOperationsRequireCanApplyAndExactAcceptedReceipt() throws {
        let unavailable = GatewayCommandAction(.object([
            "can_apply": .bool(false), "update_available": .bool(true),
            "update_command": .string("docker pull hermes"),
        ]))
        XCTAssertFalse(GatewayOperationsPolicy.canApplyUpdate(unavailable))
        XCTAssertTrue(GatewayOperationsPolicy.canApplyUpdate(GatewayCommandAction(.object([
            "can_apply": .bool(true),
        ]))))

        let accepted = try GatewayOperationsPolicy.acceptedReceipt(.object([
            "ok": .bool(true), "name": .string("hermes-update"), "pid": .number(42),
        ]), expectedName: "hermes-update")
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.name, "hermes-update")
        XCTAssertEqual(accepted.pid, 42)

        for malformed: JSONValue in [
            .object(["name": .string("hermes-update"), "pid": .number(42)]),
            .object(["ok": .bool(true), "name": .string("other"), "pid": .number(42)]),
            .object(["ok": .bool(true), "name": .string("hermes-update")]),
            .object(["ok": .bool(true), "name": .string("hermes-update"), "pid": .number(0)]),
        ] {
            XCTAssertThrowsError(try GatewayOperationsPolicy.acceptedReceipt(
                malformed, expectedName: "hermes-update"))
        }
        XCTAssertTrue(GatewayOperationsPolicy.isAmbiguous(
            GatewayError(code: -5, message: "timeout")))
        XCTAssertFalse(GatewayOperationsPolicy.isAmbiguous(
            GatewayError(code: 409, message: "refused")))
        XCTAssertTrue(GatewayOperationsPolicy.shouldFence(
            postStarted: true, error: CancellationError()))
        XCTAssertFalse(GatewayOperationsPolicy.shouldFence(
            postStarted: false, error: CancellationError()))
    }

    func testEveryBackgroundOperationRequiresExactActionPIDReceipts() throws {
        for name in ["doctor", "security-audit", "backup", "curator-run",
                     "gateway-restart", "hermes-update"] {
            let accepted = try GatewayOperationsPolicy.acceptedReceipt(.object([
                "ok": .bool(true), "name": .string(name), "pid": .number(91),
            ]), expectedName: name)
            XCTAssertEqual(accepted.pid, 91)

            let running = try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(91), "running": .bool(true),
            ]), expectedName: name, expectedPID: 91)
            XCTAssertTrue(running.running)
            XCTAssertThrowsError(try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(92), "running": .bool(true),
            ]), expectedName: name, expectedPID: 91),
            "a replacement PID must never satisfy the accepted action poll")
            XCTAssertThrowsError(try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(91), "running": .bool(false),
            ]), expectedName: name, expectedPID: 91),
            "terminal status needs an explicit exit code")
        }
    }

    func testSynchronousOperationFamiliesRequireSemanticReceipts() throws {
        XCTAssertNoThrow(try GatewayOperationsPolicy.requireOKReceipt(.object([
            "ok": .bool(true),
        ]), operation: "Config update"))
        for malformed: JSONValue in [
            .object([:]), .object(["ok": .bool(false)]),
            .object(["ok": .string("true")]),
        ] {
            XCTAssertThrowsError(try GatewayOperationsPolicy.requireOKReceipt(
                malformed, operation: "Config update"))
        }
        XCTAssertTrue(GatewayOperationsPolicy.shouldFence(
            postStarted: true,
            error: AckValidationError(operation: "Config update")),
            "a malformed 2xx config response cannot release the no-replay fence")

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireBooleanReceipt(.object([
            "ok": .bool(true), "paused": .bool(true),
        ]), operation: "Curator pause", field: "paused", expected: true))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireBooleanReceipt(.object([
            "ok": .bool(true), "paused": .bool(false),
        ]), operation: "Curator pause", field: "paused", expected: true))

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireMemoryResetReceipt(.object([
            "ok": .bool(true), "deleted": .array([.string("memory")]),
        ])))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireMemoryResetReceipt(.object([
            "ok": .bool(true),
        ])))

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireDebugShareReceipt(.object([
            "ok": .bool(true), "urls": .object([:]), "failures": .object([:]),
            "redacted": .bool(true), "auto_delete_seconds": .number(3_600),
        ])))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireDebugShareReceipt(.object([
            "ok": .bool(true), "urls": .object([:]), "failures": .object([:]),
            "redacted": .bool(false), "auto_delete_seconds": .number(3_600),
        ])))
    }

    @MainActor
    func testConfigMutationUsesPersistentCrossSurfaceMaintenanceAdmission() {
        let maintenance = GatewayMaintenanceRuntime.shared
        let workspace = WorkspaceRuntime.shared
        maintenance.acknowledge()
        _ = workspace.begin(gatewayID: "gateway-a")
        defer {
            maintenance.acknowledge()
            _ = workspace.begin(gatewayID: nil)
        }
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(maintenance.begin(source: source, action: "config-agent.max_turns"))
        maintenance.markUncertain(source: source, action: "config-agent.max_turns")

        _ = workspace.begin(gatewayID: "gateway-b")

        XCTAssertEqual(maintenance.fence, GatewayMaintenanceFence(
            source: source, action: "config-agent.max_turns", outcome: .uncertain))
        XCTAssertNil(workspace.claimMutation())
        XCTAssertFalse(maintenance.begin(source: source, action: "doctor"))
    }

    @MainActor
    func testMaintenanceFenceSurvivesScopeChangesAndBlocksAcceptedOrAmbiguousReplay() {
        let runtime = GatewayMaintenanceRuntime.shared
        runtime.acknowledge()
        defer { runtime.acknowledge() }
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")

        XCTAssertTrue(runtime.begin(source: source, action: "hermes-update"))
        runtime.accept(source: source, action: "hermes-update", pid: 0)
        XCTAssertEqual(runtime.fence?.outcome, .pending)
        runtime.accept(source: source, action: "hermes-update", pid: 77)
        XCTAssertEqual(runtime.fence,
                       GatewayMaintenanceFence(source: source, action: "hermes-update",
                                               outcome: .accepted(pid: 77)))
        XCTAssertFalse(runtime.begin(source: source, action: "gateway-restart"),
                       "an accepted update must block an overlapping restart")

        runtime.acknowledge()
        XCTAssertTrue(runtime.begin(source: source, action: "gateway-restart"))
        runtime.markUncertain(source: source, action: "gateway-restart")
        XCTAssertFalse(runtime.fence?.source.matches(gatewayID: "gateway-b", profile: nil) == true)
        XCTAssertTrue(runtime.fence?.source.matches(gatewayID: "gateway-a", profile: "worker") == true,
                      "the ambiguous fence must survive navigating away and back")
        XCTAssertFalse(runtime.begin(source: source, action: "hermes-update"))
    }

    func testDelayedMaintenanceClientResolutionRejectsScopeFlipBeforePost() {
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(GatewayOperationsPolicy.canIssuePost(
            source: source, capturedScopeKey: "gateway-a\u{1f}worker", capturedGeneration: 4,
            currentGatewayID: "gateway-a", currentProfile: "worker",
            currentScopeKey: "gateway-a\u{1f}worker", currentGeneration: 4))
        XCTAssertFalse(GatewayOperationsPolicy.canIssuePost(
            source: source, capturedScopeKey: "gateway-a\u{1f}worker", capturedGeneration: 4,
            currentGatewayID: "gateway-b", currentProfile: "worker",
            currentScopeKey: "gateway-b\u{1f}worker", currentGeneration: 5),
            "a scope flip while client resolution is suspended must prevent the POST")
    }

    @MainActor
    func testArtifactSweepIdentitySeparatesTwoSourcesWithSameProfilePathAndSession() {
        let row: JSONValue = .object([
            "role": .string("tool"), "tool_name": .string("image_generate"),
            "content": .string("MEDIA: /tmp/output.png"),
            "timestamp": .number(1_700_000_000),
        ])
        let first = AppModel.artifacts(in: [row], botID: "worker", sessionID: "same-session",
                                       sessionTitle: "render", sessionStart: nil,
                                       sourceGatewayID: "gateway-a")
        let second = AppModel.artifacts(in: [row], botID: "worker", sessionID: "same-session",
                                        sessionTitle: "render", sessionStart: nil,
                                        sourceGatewayID: "gateway-b")
        XCTAssertEqual(first.first?.botID, "worker")
        XCTAssertNotEqual(first.first?.id, second.first?.id)
        XCTAssertNotEqual(
            AppModel.artifactSourceKey(gatewayID: "gateway-a", botID: "worker",
                                       value: "/tmp/output.png"),
            AppModel.artifactSourceKey(gatewayID: "gateway-b", botID: "worker",
                                       value: "/tmp/output.png"))
        let sourceRoute = GatewayBotRoute(gatewayID: "gateway-a", profile: "worker")
        let foreignRoute = GatewayBotRoute(gatewayID: "gateway-b", profile: "worker")
        XCTAssertEqual(AppModel.artifactSweepProfile(route: sourceRoute,
                                                      sourceGatewayID: "gateway-a"), "worker")
        XCTAssertNil(AppModel.artifactSweepProfile(route: foreignRoute,
                                                    sourceGatewayID: "gateway-a"))
    }

    @MainActor
    func testArtifactFetchWaitersCancelOnlyTheSoleUnderlyingFetch() async {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let source = ArtifactProvenance(gatewayID: "gateway", profile: "worker",
                                        sessionID: "session", value: "/tmp/video.mp4")
        let task = Task<ArtifactBody, Never> {
            while !Task.isCancelled { await Task.yield() }
            return .unavailable(.notLive)
        }
        let first = store.acquire(for: source) { task }
        let second = store.acquire(for: source) { task }
        XCTAssertEqual(store.inflightWaiterCount(for: source), 2)
        store.release(first, cancelIfLast: true)
        XCTAssertEqual(store.inflightWaiterCount(for: source), 1)
        XCTAssertFalse(task.isCancelled)
        store.release(second, cancelIfLast: true)
        XCTAssertEqual(store.inflightWaiterCount(for: source), 0)
        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    @MainActor
    func testInlineDataCapAndOwnedShareCleanup() throws {
        let exactBytes = ArtifactStore.maxFetchBytes
        let exactEncoded = String(repeating: "A", count: ((exactBytes + 2) / 3) * 4)
        XCTAssertTrue(AppModel.dataURLFitsArtifactLimit("data:image/png;base64,\(exactEncoded)"))
        XCTAssertFalse(AppModel.dataURLFitsArtifactLimit(
            "data:image/png;base64,\(exactEncoded)AAAA"))
        let mediaFixture = "data:image/png;base64,\(exactEncoded)AAAA"
        if case .unavailable(.tooLarge) = AppModel.boundedArtifactDataURL(mediaFixture) {
            // Expected: `/api/media` is rejected before its oversized base64 is decoded.
        } else {
            XCTFail("oversized /api/media data URL must fail closed")
        }

        let staged = try TalariaExportBox.write(Data("share".utf8), named: "report.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        TalariaExportBox.removeOwned(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        let cachedMedia = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-test-\(UUID().uuidString)")
        try Data("media".utf8).write(to: cachedMedia)
        TalariaExportBox.removeOwned(cachedMedia)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMedia.path),
                      "share cleanup must never delete cached media")
        try FileManager.default.removeItem(at: cachedMedia)
    }
}
#endif

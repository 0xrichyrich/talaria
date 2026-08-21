#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class ExactStoredSessionNavigationTests: XCTestCase {
    private func route(gateway: String = "primary", profile: String = "inbox",
                       session: String = "stored-42") throws -> ExactStoredSessionRoute {
        try XCTUnwrap(ExactStoredSessionRoute(
            gatewayID: gateway, profile: profile, storedSessionID: session))
    }

    func testColdLaunchRequestWaitsForRestoreThenOpensExactlyOnce() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var restored = false
        var opened: [ExactStoredSessionRoute] = []
        var failures: [String] = []

        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false,
            execute: { request in
                guard restored else { return .deferred }
                opened.append(request.route)
                return .opened
            },
            reject: { _, message in failures.append(message) }), .started)
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(queue.pending?.route, exact)
        XCTAssertTrue(opened.isEmpty)
        restored = true
        queue.nudge()
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(opened, [exact])
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
        XCTAssertTrue(failures.isEmpty)
    }

    func testColdLaunchResponseNotificationDoesNotUseTransientDemoMode() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://cold-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Cold push",
            credential: .sessionToken("cold-push-token")))
        let exact = try route(gateway: saved.id)
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        var attempts = 0
        model.exactStoredSessionSourceReadinessOverride = { _ in
            attempts += 1
            guard model.launchWorldRestoreCompleted, model.mode == .live else {
                return false
            }
            return true
        }
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        // AppModel deliberately initializes in `.demo` while launch restore
        // chooses a real saved world. That transient value is not permission
        // to use openStoredSession's canned-world path.
        XCTAssertEqual(model.mode, .demo)
        XCTAssertFalse(model.demoDataLoaded)
        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: exact.gatewayID,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: URL(string: "talaria://bot/inbox?session_id=stored-42&gateway_id=\(saved.id)")),
            in: model,
            knownGatewayIDs: [exact.gatewayID])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 0,
                       "launch-pending route must not cross the source boundary")
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertNil(model.openBotID, "cold response must not mutate demo navigation")
        XCTAssertTrue(model.chats.isEmpty, "cold response must not create a demo/shadow chat")
        XCTAssertTrue(authoritativeOpens.isEmpty)

        model.mode = .live
        model.completeLaunchWorldRestore()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testOfflineColdTapRetriesExactSavedSourceAfterNetworkRestores() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://offline-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Offline push",
            credential: .sessionToken("offline-push-token")))
        let exact = try route(gateway: saved.id)
        var networkAvailable = false
        var dialAttempts = 0
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        model.exactStoredSessionSourceReadinessOverride = { requested in
            XCTAssertEqual(requested.gatewayID, saved.id,
                           "retry must dial only the stamped saved source")
            dialAttempts += 1
            guard networkAvailable else { throw URLError(.notConnectedToInternet) }
            model.mode = .live
            return true
        }
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(dialAttempts, 0, "launch restore owns the first connection pass")

        // The launch pass exhausted this saved source while offline. Its
        // completion immediately attempts the retained route's exact source.
        model.completeLaunchWorldRestore()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(dialAttempts, 1)
        XCTAssertTrue(authoritativeOpens.isEmpty)
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)

        networkAvailable = true
        model.retryExactStoredSessionNavigation()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(dialAttempts, 2)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testAdoptedExactLiveSourceOpensOnceWhenInitialRosterRefreshTimesOut() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let runtime = LiveRuntime.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://adopted-push-\(UUID().uuidString).example"))
        let fallbackURL = try XCTUnwrap(URL(
            string: "https://fallback-push-\(UUID().uuidString).example"))
        let credential = GatewayCredential.sessionToken("adopted-push-token")
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Adopted push",
            credential: credential))
        let fallback = try XCTUnwrap(registry.upsert(
            urlString: fallbackURL.absoluteString,
            name: "Must not fallback",
            credential: .sessionToken("fallback-push-token")))
        let exact = try route(gateway: saved.id)
        let client = GatewayClient(baseURL: baseURL, credential: credential)
        let previousBaseURL = runtime.baseURL
        let previousGatewayID = runtime.gatewayID
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        var refreshObservedExactAdoption = false
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionOpenOverride = nil
            model.client = nil
            runtime.baseURL = previousBaseURL
            runtime.gatewayID = previousGatewayID
            runtime.monitorTask?.cancel()
            runtime.monitorTask = nil
            registry.remove(id: saved.id)
            registry.remove(id: fallback.id)
        }

        // Retain the cold route without allowing its first attempt to cross the
        // launch/source boundary. No source-readiness override is installed.
        model.openExactStoredSession(exact, origin: .notification)
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertNil(model.exactStoredSessionSourceReadinessOverride)
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertTrue(authoritativeOpens.isEmpty)

        model.launchWorldRestoreCompleted = true
        model.client = client
        model.mode = .live
        runtime.baseURL = baseURL

        do {
            try await model.finishConnectedGatewayAdoption(
                client, baseURL: baseURL, credential: credential,
                rosterRefresh: {
                    let adopted = await registry.clientPool.client(for: saved.id)
                    refreshObservedExactAdoption = model.activeGatewayID == saved.id
                        && adopted.map(ObjectIdentifier.init) == ObjectIdentifier(client)
                    throw GatewayError(code: -5, message: "RPC timed out")
                })
            XCTFail("the injected ancillary roster timeout must propagate")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -5)
        }

        // The adoption-boundary nudge survives the thrown ancillary refresh.
        // It proves production readiness from the saved live source and opens
        // through the exact route seam once; no alternate saved source is used.
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertTrue(refreshObservedExactAdoption)
        XCTAssertEqual(model.activeGatewayID, saved.id)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
        let fallbackClient = await registry.clientPool.client(for: fallback.id)
        XCTAssertNil(fallbackClient)

        model.retryExactStoredSessionNavigation()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(authoritativeOpens, [exact], "later nudges must not double-open")

        await registry.clientPool.disconnect(gatewayID: saved.id)
    }

    func testSupervisedReconnectSuccessReplaysDeferredRouteExactlyOnce() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://supervised-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Supervised push",
            credential: .sessionToken("supervised-push-token")))
        let exact = try route(gateway: saved.id)
        var reconnected = false
        var opens: [ExactStoredSessionRoute] = []
        model.mode = .live
        model.launchWorldRestoreCompleted = true
        model.exactStoredSessionSourceReadinessOverride = { _ in reconnected }
        model.exactStoredSessionOpenOverride = { opens.append($0) }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertTrue(opens.isEmpty)

        reconnected = true
        model.exactStoredSessionSourceDidReconnect()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(opens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testPeriodicSecondaryReconnectReplaysOnlyMatchingForeignRoute() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://foreign-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Foreign push",
            credential: .sessionToken("foreign-push-token")))
        let exact = try route(gateway: saved.id)
        var secondaryReady = false
        var attempts = 0
        var opens: [ExactStoredSessionRoute] = []
        model.mode = .live
        model.launchWorldRestoreCompleted = true
        model.exactStoredSessionSourceReadinessOverride = { _ in
            attempts += 1
            return secondaryReady
        }
        model.exactStoredSessionOpenOverride = { opens.append($0) }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 1)

        model.exactStoredSessionSecondarySourcesDidRefresh(["unrelated-source"])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 1, "unrelated enumeration must not retry the route")

        secondaryReady = true
        model.exactStoredSessionSecondarySourcesDidRefresh([saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testRPCTimeoutDefersAndNextNudgeReplaysOnce() async throws {
        XCTAssertTrue(ExactStoredSessionRouteRetryPolicy.isTransient(
            GatewayError(code: -5, message: "RPC timed out")))
        XCTAssertFalse(ExactStoredSessionRouteRetryPolicy.isTransient(
            GatewayError(code: 401, message: "Unauthorized")))

        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var attempts = 0
        var opens = 0
        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false,
            execute: { _ in
                attempts += 1
                if attempts == 1 {
                    let timeout = GatewayError(code: -5, message: "RPC timed out")
                    return ExactStoredSessionRouteRetryPolicy.isTransient(timeout)
                        ? .deferred : .rejected(timeout.localizedDescription)
                }
                opens += 1
                return .opened
            },
            reject: { _, message in XCTFail("timeout must remain retryable: \(message)") })
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(queue.pending?.route, exact)

        queue.nudge()
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testDuplicateURLAndNotificationDelegateCoalesceAcrossColdRestore() async throws {
        let url = try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42&gateway_id=primary"))
        guard case .storedSession(let exact) = try XCTUnwrap(TalariaDeepLink(url: url)) else {
            return XCTFail("expected exact stored-session route")
        }
        let queue = ExactStoredSessionRouteQueue()
        var ready = false
        var opens = 0
        let execute: ExactStoredSessionRouteQueue.Execute = { _ in
            guard ready else { return .deferred }
            opens += 1
            return .opened
        }
        let reject: ExactStoredSessionRouteQueue.Reject = { _, _ in
            XCTFail("duplicate route must not reject")
        }

        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false, execute: execute, reject: reject), .started)
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: true),
            alreadyVisible: false, execute: execute, reject: reject), .duplicate)

        ready = true
        queue.nudge()
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
    }

    func testActiveAndForeignRosterKeysPreserveSameExactAuthority() throws {
        let primary = try route(gateway: "primary", profile: "same", session: "collision")
        let foreign = try route(gateway: "homelab", profile: "same", session: "collision")

        XCTAssertEqual(primary.rosterID(activeGatewayID: "primary"), "same")
        XCTAssertEqual(foreign.rosterID(activeGatewayID: "primary"), "homelab::same")
        XCTAssertEqual(primary.botRoute,
                       GatewayBotRoute(gatewayID: "primary", profile: "same"))
        XCTAssertEqual(foreign.botRoute,
                       GatewayBotRoute(gatewayID: "homelab", profile: "same"))
        XCTAssertNotEqual(primary, foreign,
                          "colliding profile/session ids on two gateways are distinct routes")
    }

    func testLatestDistinctRouteSupersedesAndCancelsOlderOpen() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let first = try route(session: "stored-old")
        let second = try route(gateway: "homelab", session: "stored-new")
        var firstStarted = false
        var opened: [ExactStoredSessionRoute] = []
        let execute: ExactStoredSessionRouteQueue.Execute = { request in
            if request.route == first {
                firstStarted = true
                do {
                    try await Task.sleep(for: .seconds(30))
                    opened.append(request.route)
                    return .opened
                } catch {
                    return .deferred
                }
            }
            opened.append(request.route)
            return .opened
        }
        let reject: ExactStoredSessionRouteQueue.Reject = { _, message in
            XCTFail("unexpected rejection: \(message)")
        }

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: first, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false, execute: execute, reject: reject)
        while !firstStarted { await Task.yield() }
        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: second, origin: .deepLink, waitsForLaunchRestore: false),
            alreadyVisible: false, execute: execute, reject: reject)
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(opened, [second])
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testReconnectNudgeDuringCancellationIsNotLostOrDoubleOpened() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var attempts = 0
        var firstAttemptStarted = false
        var opens = 0

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false,
            execute: { _ in
                attempts += 1
                if attempts == 1 {
                    firstAttemptStarted = true
                    await Task.yield()
                    return .deferred
                }
                opens += 1
                return .opened
            },
            reject: { _, message in XCTFail("unexpected rejection: \(message)") })
        while !firstAttemptStarted { await Task.yield() }
        queue.nudge()
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testUnknownOrDeletedSourceRejectsWithoutOpening() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route(gateway: "deleted")
        var rejection: (ExactStoredSessionRoute, String)?

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false,
            execute: { _ in
                .rejected("That response came from a gateway that is no longer saved.")
            },
            reject: { route, message in rejection = (route, message) })
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(rejection?.0, exact)
        XCTAssertTrue(rejection?.1.contains("no longer saved") == true)
        XCTAssertNil(queue.pending)
        XCTAssertEqual(queue.completedOpenCount, 0)
    }

    func testUnknownAndMissingCredentialRejectBeforeAnyConnectionRetry() async throws {
        let unknownModel = AppModel()
        unknownModel.launchWorldRestoreCompleted = true
        var sourceAttempts = 0
        unknownModel.exactStoredSessionSourceReadinessOverride = { _ in
            sourceAttempts += 1
            return true
        }
        unknownModel.openExactStoredSession(
            try route(gateway: "definitely-not-saved"), origin: .deepLink)
        await unknownModel.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(sourceAttempts, 0)
        XCTAssertNil(unknownModel.exactStoredSessionRouteQueue.pending)
        XCTAssertEqual(unknownModel.exactStoredSessionRouteQueue.completedOpenCount, 0)

        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://signed-out-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Signed out push",
            credential: nil))
        let signedOutModel = AppModel()
        signedOutModel.launchWorldRestoreCompleted = true
        signedOutModel.exactStoredSessionSourceReadinessOverride = { _ in
            sourceAttempts += 1
            return true
        }
        defer {
            unknownModel.exactStoredSessionSourceReadinessOverride = nil
            signedOutModel.exactStoredSessionSourceReadinessOverride = nil
            registry.remove(id: saved.id)
            ToastBus.shared.clear()
        }

        signedOutModel.openExactStoredSession(
            try route(gateway: saved.id), origin: .notification)
        await signedOutModel.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(sourceAttempts, 0)
        XCTAssertNil(signedOutModel.exactStoredSessionRouteQueue.pending)
        XCTAssertEqual(signedOutModel.exactStoredSessionRouteQueue.completedOpenCount, 0)
        XCTAssertNil(signedOutModel.openBotID)
    }

    func testFreshProfileAuthorityRejectsStaleDeletedAndAmbiguousProfiles() throws {
        let exact = try route(profile: "researcher")
        XCTAssertNoThrow(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["default", "researcher"]))
        XCTAssertThrowsError(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["default"])) { error in
                XCTAssertEqual(error as? ExactStoredSessionRouteAuthorityError,
                               .missingProfile(exact))
            }
        XCTAssertThrowsError(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["Researcher", "researcher"])) { error in
                XCTAssertEqual(error as? ExactStoredSessionRouteAuthorityError,
                               .invalidProfileInventory)
        }
    }

    func testSameStoredIDAckFromWrongProfileFailsClosedAcrossABA() throws {
        let exact = try route(profile: "researcher", session: "same-stored-key")
        XCTAssertNoThrow(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "researcher"))

        XCTAssertThrowsError(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "default")) { error in
                XCTAssertEqual(error as? ExactStoredSessionResumeAckAuthorityError,
                               .profileMismatch)
            }
        XCTAssertThrowsError(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "")) { error in
                XCTAssertEqual(error as? ExactStoredSessionResumeAckAuthorityError,
                               .profileMismatch)
        }
    }

    func testExactOpenAuthorityFailuresPreserveVisibleChatTranscriptAndUnread() async throws {
        let model = AppModel()
        let gatewayID = "foreign-exact-transaction-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://exact-transaction.example")),
            credential: .sessionToken("unused-test-token"))
        let sentinelClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://sentinel-events.example")),
            credential: .sessionToken("unused-sentinel-token"))
        let sentinelHandler = await sentinelClient.addEventHandler { _ in }
        let sentinelPump = Task<Void, Never> {}
        let eventRuntime = MultiGatewayRuntime.shared
        eventRuntime.routedEventGenerations[gatewayID] = 41
        eventRuntime.routedEvents[gatewayID] = .init(
            client: sentinelClient, handlerID: sentinelHandler, pump: sentinelPump)
        eventRuntime.routedUnread[route] = 7
        let approvalID = "approval-exact-transaction"
        LiveRuntime.shared.approvalTargets[approvalID] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: "approval-runtime"),
            requestID: "approval-wire")
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)
        let previous = ChatState(messages: [
            ChatMessage(author: .bot, text: "keep the visible transcript"),
        ])
        previous.sessionID = "visible-runtime"
        previous.storedSessionID = "visible-stored"
        let targetChat = ChatState(messages: [
            ChatMessage(author: .bot, text: "keep the target transcript too"),
        ])
        targetChat.sessionID = "target-old-runtime"
        targetChat.storedSessionID = "target-old-stored"
        model.mode = .live
        model.openBotID = "visible"
        model.chats["visible"] = previous
        model.chats[target] = targetChat
        model.bots = [Bot(
            id: target, job: "", shape: .circle, hue: .violet, unread: 7)]
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-exact-transaction"
        defer {
            sentinelPump.cancel()
            eventRuntime.routedEvents[gatewayID] = nil
            eventRuntime.routedEventGenerations[gatewayID] = nil
            eventRuntime.routedUnread[route] = nil
            LiveRuntime.shared.approvalTargets[approvalID] = nil
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "wrong-runtime"))
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "right-runtime"))
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    XCTFail("a wrong-profile ACK must fail before the second authority check")
                },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("wrong-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string("default")]),
                    ]))
                })
            XCTFail("wrong-profile resume must be rejected")
        } catch {
            XCTAssertTrue(error is AckValidationError)
        }

        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertTrue(model.chats["visible"] === previous)
        XCTAssertEqual(previous.messages.map(\.text), ["keep the visible transcript"])
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertTrue(eventRuntime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(sentinelClient)
        } == true)
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 41)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    throw ExactStoredSessionRouteAuthorityError.missingProfile(
                        try XCTUnwrap(ExactStoredSessionRoute(
                            gatewayID: gatewayID, profile: profile,
                            storedSessionID: "wanted-stored")))
                },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("right-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ]))
                })
            XCTFail("post-resume profile deletion must be rejected")
        } catch {
            XCTAssertTrue(error is ExactStoredSessionRouteAuthorityError)
        }

        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertTrue(model.chats["visible"] === previous)
        XCTAssertEqual(previous.messages.map(\.text), ["keep the visible transcript"])
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertTrue(eventRuntime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(sentinelClient)
        } == true)
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 41)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {},
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("right-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ]))
                },
                catchUpResumeForTesting: {
                    (LiveSession(.object([
                        "session_id": .string("wrong-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string("default")]),
                    ])), 20)
                })
            XCTFail("a catch-up mismatch must reject transactionally")
        } catch {
            XCTAssertTrue(error is AckValidationError)
        }
        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertTrue(eventRuntime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(sentinelClient)
        } == true)
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 41)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])

        await sentinelClient.removeEventHandler(sentinelHandler)
        await pool.disconnect(gatewayID: gatewayID)
    }

    func testExactOpenRejectsMissingDurableAckWithoutBackfill() async throws {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "missing-durable", profile: "researcher")
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://missing-durable.example")),
            credential: .sessionToken("unused-test-token"))
        var postAuthorityCalled = false

        do {
            _ = try await model.openStoredSessionAwaiting(
                "requested-stored", botID: route.qualifiedID,
                route: route, client: client,
                validateBeforeBinding: { postAuthorityCalled = true },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("runtime-without-durable-ack"),
                        "info": .object(["profile_name": .string("researcher")]),
                    ]))
                })
            XCTFail("an omitted durable ACK must never be backfilled from the request")
        } catch let error as AckValidationError {
            XCTAssertTrue(error.localizedDescription.contains("durable session identity"))
        }
        XCTAssertFalse(postAuthorityCalled)
        XCTAssertNil(model.openBotID)
        XCTAssertTrue(model.chats.isEmpty)
    }

    func testExactOpenPublishesOnlyAfterResumeAndFreshProfileAuthority() async throws {
        let model = AppModel()
        let gatewayID = "foreign-exact-positive-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://exact-positive.example")),
            credential: .sessionToken("unused-test-token"))
        let previous = ChatState(messages: [
            ChatMessage(author: .bot, text: "old visible transcript"),
        ])
        let targetChat = ChatState(messages: [
            ChatMessage(author: .bot, text: "old target transcript"),
        ])
        let otherRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "other")
        let otherTarget = otherRoute.qualifiedID
        let otherChat = ChatState(messages: [])
        targetChat.sessionID = "old-runtime"
        targetChat.storedSessionID = "old-stored"
        model.mode = .live
        model.openBotID = "visible"
        model.chats["visible"] = previous
        model.chats[target] = targetChat
        model.bots = [
            Bot(id: target, job: "", shape: .circle, hue: .violet, unread: 5),
            Bot(id: otherTarget, job: "", shape: .circle, hue: .blue),
        ]
        model.chats[otherTarget] = otherChat
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-exact-positive"
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)
        LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "other-runtime")] = otherTarget
        let initialEventGeneration = MultiGatewayRuntime.shared
            .routedEventGenerations[gatewayID, default: 0]
        MultiGatewayRuntime.shared.routedUnread[route] = 5
        var observedBeforeResume = false
        var observedBeforeAuthority = false
        var validationCount = 0
        let opened: Bool
        do {
            opened = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    validationCount += 1
                    observedBeforeAuthority = model.openBotID == "visible"
                        && targetChat.messages.map(\.text) == ["old target transcript"]
                        && MultiGatewayRuntime.shared.routedUnread[route] == 5
                    if validationCount == 1 {
                        await client.emitEventForTesting(GatewayEvent(
                            type: "message.complete", sessionID: "new-runtime",
                            payload: .object([
                                "text": .string("post-snapshot response"),
                                "status": .string("complete"),
                            ]), inboundSequence: 11))
                    }
                },
                catchUpResumeForTesting: {
                    observedBeforeResume = model.openBotID == "visible"
                        && targetChat.messages.map(\.text) == ["old target transcript"]
                        && MultiGatewayRuntime.shared.routedUnread[route] == 5
                    await client.emitEventForTesting(GatewayEvent(
                        type: "message.complete", sessionID: "other-runtime",
                        payload: .object([
                            "text": .string("other before snapshot"),
                            "status": .string("complete"),
                        ]), inboundSequence: 4))
                    // This frame precedes the response boundary and is already
                    // represented by the returned snapshot, so replaying it
                    // would duplicate the completed message.
                    await client.emitEventForTesting(GatewayEvent(
                        type: "message.complete", sessionID: "new-runtime",
                        payload: .object([
                            "text": .string("snapshot response"),
                            "status": .string("complete"),
                        ]), inboundSequence: 9))
                    return (LiveSession(.object([
                        "session_id": .string("new-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "messages": .array([
                            .object(["role": .string("assistant"),
                                     "text": .string("snapshot response")]),
                        ]),
                        "info": .object(["profile_name": .string(profile)]),
                    ])), 10)
                })
        } catch {
            await model.removeRoutedEventSubscription(gatewayID: gatewayID)
            await pool.disconnect(gatewayID: gatewayID)
            MultiGatewayRuntime.shared.routedUnread[route] = nil
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "other-runtime"))
            LiveRuntime.shared.gatewayID = oldGatewayID
            throw error
        }

        XCTAssertTrue(opened)
        XCTAssertTrue(observedBeforeResume)
        XCTAssertTrue(observedBeforeAuthority)
        XCTAssertEqual(model.openBotID, target)
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.sessionID, "new-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "wanted-stored")
        for _ in 0..<20 where targetChat.messages.count < 2 { await Task.yield() }
        XCTAssertEqual(targetChat.messages.map(\.text),
                       ["snapshot response", "post-snapshot response"])
        XCTAssertEqual(otherChat.messages.map(\.text), ["other before snapshot"],
                       "a pre-resume event for another session must not be dropped")
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[route])
        XCTAssertEqual(previous.messages.map(\.text), ["old visible transcript"])
        XCTAssertEqual(
            MultiGatewayRuntime.shared.routedEventGenerations[gatewayID],
            initialEventGeneration + 1,
            "one staged swap owns one new routed-event generation")
        XCTAssertTrue(MultiGatewayRuntime.shared.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(client)
        } == true)
        XCTAssertEqual(
            LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "new-runtime")], target)

        await model.removeRoutedEventSubscription(gatewayID: gatewayID)
        await pool.disconnect(gatewayID: gatewayID)
        MultiGatewayRuntime.shared.routedUnread[route] = nil
        LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "other-runtime"))
        LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "new-runtime"))
        LiveRuntime.shared.gatewayID = oldGatewayID
    }

    func testLifecycleMutationDuringFinalPoolFenceCannotPublish() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let gatewayID = "foreign-fence-race-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let baseURL = try XCTUnwrap(URL(
            string: "https://fence-race-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Fence race",
            credential: .sessionToken("fence-race-token")))
        let client = GatewayClient(
            baseURL: baseURL,
            credential: .sessionToken("fence-race-token"))
        let pool = registry.clientPool
        await pool.adopt(client, for: gatewayID)
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: baseURL,
            credential: .sessionToken("fence-race-token"))
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldHook = SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting
        model.mode = .live
        model.chats[target] = ChatState(messages: [
            ChatMessage(author: .bot, text: "old transcript"),
        ])
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        LiveRuntime.shared.gatewayID = "primary-fence-race"
        SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = {
            // This bumps the captured route generation while the pool actor
            // query is in flight. The post-await fence must reject the stale
            // resume before it can commit its prepared handler.
            try? await model.activateProfileLifecycleRoute(
                gatewayID: gatewayID, profile: profile)
        }
        defer {
            SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = oldHook
            LiveRuntime.shared.gatewayID = oldGatewayID
            registry.remove(id: saved.id)
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {},
                catchUpResumeForTesting: {
                    (LiveSession(.object([
                        "session_id": .string("fence-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ])), 10)
                },
                sourceSnapshot: snapshot)
            XCTFail("a lifecycle mutation during the final pool fence must reject the open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(model.openBotID)
        XCTAssertNil(MultiGatewayRuntime.shared.routedEvents[gatewayID])
        XCTAssertNil(MultiGatewayRuntime.shared.routedEventGenerations[gatewayID])
        await pool.disconnect(gatewayID: gatewayID)
    }

    func testDeepLinkParserRetainsUnknownSourceForVisibleAuthorityFailure() throws {
        let url = try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42&gateway_id=not-saved-yet"))
        XCTAssertEqual(TalariaDeepLink(url: url), .storedSession(try route(
            gateway: "not-saved-yet", profile: "inbox", session: "stored-42")))

        let qualified = try XCTUnwrap(URL(
            string: "talaria://bot/homelab::inbox?session_id=stored-43"))
        XCTAssertEqual(TalariaDeepLink(url: qualified), .storedSession(try route(
            gateway: "homelab", profile: "inbox", session: "stored-43")))
    }

    func testDeepLinkParserRejectsAmbiguousOrNonExactRoutes() throws {
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/homelab::inbox?session_id=stored-42&gateway_id=other"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox/extra?session_id=stored-42&gateway_id=homelab"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=a&session_id=b&gateway_id=homelab"))))
    }
}
#endif

import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class WorkspaceProjectsProfileScopeTests: XCTestCase {
    func testSameGatewayPoolReplacementRejectsCapturedWorkspaceConnection() async throws {
        let url = try XCTUnwrap(URL(string: "https://gateway.example"))
        let credential = GatewayCredential.sessionToken("test-token")
        let first = GatewayClient(baseURL: url, credential: credential)
        let second = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in first }

        let captured = try await pool.connectWithGeneration(
            gatewayID: "gateway-a", baseURL: url, credential: credential
        )
        await pool.adopt(second, for: "gateway-a")

        let stillCurrent = await pool.isCurrent(captured, for: "gateway-a")
        XCTAssertFalse(stillCurrent,
                       "a G1 completion must not publish after G2 replaces the same gateway id")
        await pool.disconnectAll()
    }

    func testDelayedPoolReplacementWaitsForProjectPublicationLease() async throws {
        let url = try XCTUnwrap(URL(string: "https://leased-projects.example"))
        let credential = GatewayCredential.sessionToken("test-token")
        let first = GatewayClient(baseURL: url, credential: credential)
        let second = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: "gateway-a")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "gateway-a", baseURL: url, credential: credential
        )
        let acquired = await pool.acquireLease(captured, for: "gateway-a")
        let lease = try XCTUnwrap(acquired)

        let replacement = Task { await pool.adopt(second, for: "gateway-a") }
        await Task.yield()
        let currentWhileLeased = await pool.isCurrent(captured, for: "gateway-a")
        XCTAssertTrue(currentWhileLeased,
                      "publication owns the old slot until its final state mutation")

        await pool.release(lease)
        await replacement.value
        let currentAfterRelease = await pool.isCurrent(captured, for: "gateway-a")
        XCTAssertFalse(currentAfterRelease,
                       "the delayed replacement wins only after publication releases the slot")
        await pool.disconnectAll()
    }

    @MainActor
    func testProjectPublicationFinishesBeforeReleaseAndRejectsLaterSourceSwitch() async throws {
        let url = try XCTUnwrap(URL(string: "https://publish-fence.example"))
        let credential = GatewayCredential.sessionToken("test-token")
        let first = GatewayClient(baseURL: url, credential: credential)
        let second = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: "gateway-a")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "gateway-a", baseURL: url, credential: credential
        )
        let acquiredLease = await pool.acquireLease(captured, for: "gateway-a")
        let lease = try XCTUnwrap(acquiredLease)

        let runtime = WorkspaceRuntime.shared
        let route = GatewayWorkspaceRoute(gatewayID: "gateway-a", profile: "worker")
        let generation = runtime.begin(gatewayID: route.gatewayID, profile: route.rawProfile)
        runtime.profiles = [WorkspaceProfileSource(profile: route.rawProfile)]
        let listing = HermesProjectListing(.object([
            "projects": .array([.object([
                "id": .string("project-a"), "name": .string("Project A"),
                "archived": .bool(false),
            ])]),
            "active_id": .string("project-a"),
        ]))
        let tree = try XCTUnwrap(HermesProjectTree(.object([
            "id": .string("project-a"), "label": .string("Project A"),
            "sessionCount": .number(0), "previewSessions": .array([]),
        ])))
        let snapshot = WorkspaceProjectSnapshot(
            listing: listing, tree: [tree], discoveredRoots: [], scopedSessionCount: 0
        )

        let replacement = Task { await pool.adopt(second, for: route.gatewayID) }
        await Task.yield()
        let currentBeforePublication = await pool.isCurrent(captured, for: route.gatewayID)
        XCTAssertTrue(currentBeforePublication)
        XCTAssertTrue(runtime.publishProjectSnapshot(snapshot, route: route,
                                                     generation: generation),
                      "the final state mutation occurs while the captured pool slot is leased")
        XCTAssertEqual(runtime.activeProjectID, "project-a")

        await pool.release(lease)
        await replacement.value
        _ = runtime.begin(gatewayID: "gateway-b", profile: "worker")
        runtime.profiles = [WorkspaceProfileSource(profile: "worker")]
        XCTAssertFalse(runtime.publishProjectSnapshot(snapshot, route: route,
                                                      generation: generation),
                       "a completion cannot publish into a source selected after release")
        XCTAssertTrue(runtime.projects.isEmpty)
        _ = runtime.begin(gatewayID: nil, profile: nil)
        await pool.disconnectAll()
    }

    func testFreshProfileAuthorityRejectsRemoteRenameAndDeleteWithoutFallback() throws {
        let route = GatewayWorkspaceRoute(gatewayID: "gateway-a", profile: "worker raw")
        let original = [profile("worker raw"), profile("default", isDefault: true)]
        XCTAssertEqual(try WorkspaceProjectScope.requireCurrent(route, in: original),
                       ["worker raw", "default"])

        XCTAssertThrowsError(try WorkspaceProjectScope.requireCurrent(
            route, in: [profile("worker renamed"), profile("default", isDefault: true)]
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
        XCTAssertThrowsError(try WorkspaceProjectScope.requireCurrent(
            route, in: [profile("default", isDefault: true)]
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
    }

    func testPostResponseProfileDeletionCannotPublishCollidingLaunchProjectSelection() throws {
        let route = GatewayWorkspaceRoute(gatewayID: "gateway-a", profile: "worker")
        let collidingProjectID = "shared-project-id"
        var publishedActiveID: String?

        do {
            // Hermes c1e25 can answer an unknown explicit profile from its
            // launch profile. Even when that profile contains the same project
            // id and therefore echoes a superficially valid acknowledgement,
            // the fresh post-response inventory must reject publication.
            publishedActiveID = try WorkspaceProjectSelectionProof.validatedActiveID(
                collidingProjectID,
                selectedProjectID: collidingProjectID,
                route: route,
                postResponseProfiles: [profile("default", isDefault: true)]
            )
            XCTFail("a launch-profile collision must not authorize local selection publication")
        } catch {
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
        XCTAssertNil(publishedActiveID)

        XCTAssertEqual(try WorkspaceProjectSelectionProof.validatedActiveID(
            collidingProjectID,
            selectedProjectID: collidingProjectID,
            route: route,
            postResponseProfiles: [profile("worker"), profile("default", isDefault: true)]
        ), collidingProjectID)
    }

    func testExactProfileScopedProjectsRequestShapes() throws {
        let route = try XCTUnwrap(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "worker alpha",
            knownProfiles: ["default", "worker alpha"]
        ))

        let expectedProfile: JSONValue = .string("worker alpha")
        let list = try WorkspaceProjectRequest.list(in: route)
        XCTAssertEqual(list.method, "projects.list")
        XCTAssertEqual(list.params, .object(["profile": expectedProfile]))

        let discovery = try WorkspaceProjectRequest.discoverRepos(in: route)
        XCTAssertEqual(discovery.method, "projects.discover_repos")
        XCTAssertEqual(discovery.params, .object([
            "profile": expectedProfile,
            "scan": .bool(true),
        ]))

        let tree = try WorkspaceProjectRequest.tree(in: route)
        XCTAssertEqual(tree.method, "projects.tree")
        XCTAssertEqual(tree.params, .object([
            "profile": expectedProfile,
            "preview_limit": .number(3),
            "session_limit": .number(5_000),
        ]))

        let sessions = try WorkspaceProjectRequest.projectSessions(id: "project-1", in: route)
        XCTAssertEqual(sessions.method, "projects.project_sessions")
        XCTAssertEqual(sessions.params, .object([
            "profile": expectedProfile,
            "project_id": .string("project-1"),
            "session_limit": .number(5_000),
        ]))

        for method in [
            "projects.create", "projects.update", "projects.add_folder",
            "projects.remove_folder", "projects.set_primary", "projects.archive",
            "projects.delete", "projects.set_active",
        ] {
            let write = try WorkspaceProjectRequest.write(
                method, fields: ["id": .string("project-1")], in: route
            )
            XCTAssertEqual(write.params["profile"], expectedProfile, "\(method) must preserve the raw profile")
            XCTAssertEqual(write.params["id"], .string("project-1"))
        }
    }

    func testDiscoveryPlanPrecedesProfileScopedTree() throws {
        let route = try XCTUnwrap(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "worker",
            knownProfiles: ["worker"]
        ))
        let plan = try WorkspaceProjectSnapshotRequests(in: route)

        XCTAssertEqual(plan.ordered.map(\.method), [
            "projects.discover_repos", "projects.list", "projects.tree",
        ])
        XCTAssertEqual(plan.discovery.params, .object([
            "profile": .string("worker"), "scan": .bool(true),
        ]))
        XCTAssertEqual(plan.tree.params["profile"], .string("worker"))
    }

    func testTwoProfilesStayIsolatedAndSessionRowsUseRequestedRawProfile() throws {
        let worker = try XCTUnwrap(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "worker",
            knownProfiles: ["worker", "reviewer"]
        ))
        let reviewer = try XCTUnwrap(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "reviewer",
            knownProfiles: ["worker", "reviewer"]
        ))
        XCTAssertNotEqual(worker.id, reviewer.id)
        XCTAssertNotEqual(try WorkspaceProjectRequest.tree(in: worker).params,
                          try WorkspaceProjectRequest.tree(in: reviewer).params)

        let response = treeResponse(project: overviewProject(
            id: "project-1", sessionCount: 1,
            previews: [sessionRow(id: "session-1", profile: "untrusted-response-profile")]
        ))
        let workerTree = try HermesProjectTree.scopedList(from: response, profile: worker.rawProfile)
        let reviewerTree = try HermesProjectTree.scopedList(from: response, profile: reviewer.rawProfile)

        XCTAssertEqual(workerTree.first?.previews.first?.profile, "worker")
        XCTAssertEqual(reviewerTree.first?.previews.first?.profile, "reviewer")
        XCTAssertNotEqual(workerTree.first?.previews.first?.id, reviewerTree.first?.previews.first?.id)
        XCTAssertNil(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "unknown", knownProfiles: ["worker", "reviewer"]
        ))
        XCTAssertNil(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "   ", knownProfiles: ["worker", "reviewer"]
        ))
        XCTAssertThrowsError(try WorkspaceProjectRequest.tree(
            in: GatewayWorkspaceRoute(gatewayID: "gateway-a", profile: "   ")
        ))

        // A lifecycle rename/delete removes the exact old route from the
        // source inventory; it must not be silently rewritten to `default`.
        XCTAssertNil(WorkspaceProjectScope.route(
            gatewayID: "gateway-a", rawProfile: "worker", knownProfiles: ["renamed"]
        ))
    }

    func testProjectPayloadFailsClosedForMalformedDiscoveryOnlyAndSaturatedResults() throws {
        XCTAssertThrowsError(try HermesProjectTree.scopedList(from: .object([
            "projects": .array([]),
            "active_id": .null,
        ]), profile: "worker"))

        XCTAssertThrowsError(try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": .null]), projectID: "discovered-only", profile: "worker"
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 404)
        }

        XCTAssertThrowsError(try HermesProjectTree.scopedList(
            from: treeResponse(project: overviewProject(id: "project-1", sessionCount: 5_000,
                                                         previews: [])),
            profile: "worker"
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 501)
        }

        let tooManyScopedIDs = (0..<WorkspaceProjectSessionWindowPolicy.maximumRows).map {
            JSONValue.string("session-\($0)")
        }
        XCTAssertThrowsError(try HermesProjectTree.scopedList(
            from: treeResponse(
                project: overviewProject(id: "project-1", sessionCount: 4_999, previews: []),
                scopedIDs: tooManyScopedIDs
            ), profile: "worker"
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 501)
        }

        let saturatedRows = (0..<WorkspaceProjectSessionWindowPolicy.maximumRows).map {
            sessionRow(id: "session-\($0)", profile: nil)
        }
        XCTAssertThrowsError(try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": hydratedProject(
                id: "project-1", sessionCount: saturatedRows.count, sessions: saturatedRows
            )]),
            projectID: "project-1", profile: "worker"
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 501)
        }

        XCTAssertThrowsError(try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": hydratedProject(
                id: "project-1", sessionCount: 1, sessions: []
            )]),
            projectID: "project-1", profile: "worker"
        ))

        XCTAssertThrowsError(try HermesProjectTree.scopedList(
            from: treeResponse(
                project: overviewProject(id: "project-1", sessionCount: 2, previews: []),
                scopedIDs: [.string("only-one-authoritative-id")]
            ), profile: "worker"
        ), "project counts without an equal global scoped-id witness are partial")

        let discoveredOnly: JSONValue = .object([
            "id": .string("/work/discovered"),
            "label": .string("discovered"),
            "path": .string("/work/discovered"),
            "isAuto": .bool(true),
            "isNoProject": .bool(false),
            "sessionCount": .number(42),
            "previewSessions": .array([]),
            "repos": .array([.object([
                "id": .string("/work/discovered"),
                "path": .string("/work/discovered"),
                "sessionCount": .number(42),
                "groups": .array([]),
            ])]),
        ])
        let discoveryProof = try HermesProjectTree.scopedProof(
            from: .object([
                "projects": .array([discoveredOnly]),
                "active_id": .null,
                "scoped_session_ids": .array([]),
            ]),
            profile: "worker"
        )
        XCTAssertEqual(discoveryProof.scopedSessionCount, 0,
                       "disk-history discovery counts are not stored-session window authority")
    }

    func testArchiveAndDeleteAcceptLegalStaleActivePointerButProveTargetOutcome() throws {
        let archived = try HermesProjectListing(
            validatingArchiveAcknowledgement: .object([
                "projects": .array([
                    .object([
                        "id": .string("active-project"), "name": .string("Archived"),
                        "archived": .bool(true),
                    ]),
                    .object([
                        "id": .string("visible-project"), "name": .string("Visible"),
                        "archived": .bool(false),
                    ]),
                ]),
                // c1e25 leaves project_meta untouched after archive.
                "active_id": .string("active-project"),
            ]),
            id: "active-project", restore: false
        )
        XCTAssertNil(archived.activeID,
                     "an archived pointer is not a visible active selection")

        let restored = try HermesProjectListing(
            validatingArchiveAcknowledgement: .object([
                "projects": .array([.object([
                    "id": .string("active-project"), "name": .string("Restored"),
                    "archived": .bool(false),
                ])]),
                "active_id": .string("active-project"),
            ]),
            id: "active-project", restore: true
        )
        XCTAssertEqual(restored.activeID, "active-project")

        let deleted = try HermesProjectListing(
            validatingDeleteAcknowledgement: .object([
                "projects": .array([.object([
                    "id": .string("survivor"), "name": .string("Survivor"),
                    "archived": .bool(false),
                ])]),
                // c1e25 also leaves this stale after hard delete.
                "active_id": .string("active-project"),
            ]),
            id: "active-project"
        )
        XCTAssertNil(deleted.activeID)

        let listedButNotInTree = HermesProjectListing(.object([
            "projects": .array([.object([
                "id": .string("visible-project"), "archived": .bool(false),
            ])]),
            "active_id": .string("visible-project"),
        ]))
        XCTAssertEqual(listedButNotInTree.activeID, "visible-project")
        XCTAssertNil(WorkspaceProjectSnapshot(
            listing: listedButNotInTree, tree: [], discoveredRoots: [],
            scopedSessionCount: 0
        ).listing.activeID,
        "a list pointer absent from the fresh visible project tree is not selectable")

        XCTAssertThrowsError(try HermesProjectListing(
            validatingArchiveAcknowledgement: .object([
                "projects": .array([.object([
                    "id": .string("active-project"), "archived": .bool(false),
                ])]),
                "active_id": .string("active-project"),
            ]),
            id: "active-project", restore: false
        ), "an archive acknowledgement must prove the target became archived")
        XCTAssertThrowsError(try HermesProjectListing(
            validatingDeleteAcknowledgement: .object([
                "projects": .array([.object([
                    "id": .string("active-project"), "archived": .bool(false),
                ])]),
                "active_id": .string("active-project"),
            ]),
            id: "active-project"
        ), "a delete acknowledgement must prove the target is absent")
        XCTAssertThrowsError(try HermesProjectListing(
            validatingDeleteAcknowledgement: .object([
                "projects": .array([]), "active_id": .bool(true),
            ]),
            id: "active-project"
        ), "the legal stale-pointer case does not weaken active_id type validation")
    }

    func testStaleTreeActivePointerDoesNotWeakenFreshScopedIDProof() throws {
        var response = try XCTUnwrap(treeResponse(project: overviewProject(
            id: "project-1", sessionCount: 1,
            previews: [sessionRow(id: "session-1", profile: nil)]
        )).objectValue)
        response["active_id"] = .string("archived-or-deleted")
        let proof = try HermesProjectTree.scopedProof(
            from: .object(response), profile: "worker"
        )
        XCTAssertEqual(proof.projects.map(\.id), ["project-1"])
        XCTAssertEqual(proof.scopedSessionCount, 1)
        XCTAssertEqual(proof.scopedSessionIDs, ["session-1"])

        response["active_id"] = .number(7)
        XCTAssertThrowsError(try HermesProjectTree.scopedProof(
            from: .object(response), profile: "worker"
        ), "malformed active metadata still fails closed")

        response["active_id"] = .string("archived-or-deleted")
        response["scoped_session_ids"] = .array([])
        XCTAssertThrowsError(try HermesProjectTree.scopedProof(
            from: .object(response), profile: "worker"
        ), "stale active metadata must not bypass the fresh scoped-id witness")
    }

    func testCachedPreviewNavigationRequiresFreshHydratedMembership() throws {
        let overview = try HermesProjectTree.scopedList(
            from: treeResponse(project: overviewProject(
                id: "project-1", sessionCount: 1,
                previews: [sessionRow(id: "session-1", profile: nil)]
            )), profile: "worker"
        )
        let cached = try XCTUnwrap(overview.first?.previews.first)
        let hydrated = try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": hydratedProject(
                id: "project-1", sessionCount: 1,
                sessions: [sessionRow(id: "session-1", profile: nil)]
            )]), projectID: "project-1", profile: "worker"
        )
        let freshProof = WorkspaceProjectTreeProof(projects: overview,
                                                   scopedSessionCount: 1,
                                                   scopedSessionIDs: ["session-1"])
        XCTAssertEqual(try WorkspaceProjectDrillInProof.validate(
            projectID: "project-1", beforeHydration: freshProof,
            afterHydration: freshProof, hydrated: hydrated
        ).id, "project-1")
        XCTAssertEqual(try WorkspaceProjectDrillInProof.validatedNavigation(
            cached: cached, in: hydrated
        ).storedID, "session-1")

        let removed = try XCTUnwrap(HermesProjectSessionPreview(.object([
            "id": .string("removed-session"), "profile": .string("worker"),
        ])))
        XCTAssertThrowsError(try WorkspaceProjectDrillInProof.validatedNavigation(
            cached: removed, in: hydrated
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 404)
        }
    }

    func testPostHydrationTreeSaturationCannotUseEarlierUnsaturatedProof() throws {
        let beforeHydration = try HermesProjectTree.scopedProof(
            from: treeResponse(project: overviewProject(
                id: "project-1", sessionCount: 1,
                previews: [sessionRow(id: "session-1", profile: nil)]
            )), profile: "worker"
        )
        XCTAssertEqual(beforeHydration.projects.first?.sessionCount, 1)

        // Model a later authoritative tree reaching the global 5,000-row
        // boundary after the screen painted its cached overview. Drill-in must
        // evaluate this fresh tree, never the earlier one.
        let saturatedFresh = try XCTUnwrap(HermesProjectTree(.object([
            "id": .string("project-1"),
            "sessionCount": .number(5_000),
            "previewSessions": .array([]),
        ])))
        let hydrated = try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": hydratedProject(
                id: "project-1", sessionCount: 1,
                sessions: [sessionRow(id: "session-1", profile: nil)]
            )]), projectID: "project-1", profile: "worker"
        )
        XCTAssertThrowsError(try WorkspaceProjectDrillInProof.validate(
            projectID: "project-1",
            beforeHydration: beforeHydration,
            afterHydration: WorkspaceProjectTreeProof(
                projects: [saturatedFresh], scopedSessionCount: 5_000,
                scopedSessionIDs: Set((0..<5_000).map { "session-\($0)" })
            ),
            hydrated: hydrated
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 501)
        }
    }

    func testPostHydrationTreeRejectsEqualSizedScopedIdentityChange() throws {
        let before = try HermesProjectTree.scopedProof(
            from: treeResponse(project: overviewProject(
                id: "project-1", sessionCount: 1,
                previews: [sessionRow(id: "session-1", profile: nil)]
            )), profile: "worker"
        )
        let hydrated = try HermesProjectTree.scopedProjectSessions(
            from: .object(["project": hydratedProject(
                id: "project-1", sessionCount: 1,
                sessions: [sessionRow(id: "session-1", profile: nil)]
            )]), projectID: "project-1", profile: "worker"
        )
        var after = before
        after.scopedSessionIDs = ["different-session"]

        XCTAssertThrowsError(try WorkspaceProjectDrillInProof.validate(
            projectID: "project-1", beforeHydration: before,
            afterHydration: after, hydrated: hydrated
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
    }

    @MainActor
    func testConcurrentProfileSelectionFencesOldProjectPublication() {
        let runtime = WorkspaceRuntime.shared
        let gateway = "concurrent-\(UUID().uuidString)"
        let workerGeneration = runtime.begin(gatewayID: gateway, profile: "worker")
        runtime.profiles = [WorkspaceProfileSource(profile: "worker")]
        let workerRoute = GatewayWorkspaceRoute(gatewayID: gateway, profile: "worker")
        XCTAssertTrue(runtime.matches(workerRoute, workerGeneration))

        _ = runtime.begin(gatewayID: gateway, profile: "reviewer")
        runtime.profiles = [WorkspaceProfileSource(profile: "reviewer")]
        XCTAssertFalse(runtime.matches(workerRoute, workerGeneration),
                       "an old profile completion cannot overwrite a concurrent selection")
        _ = runtime.begin(gatewayID: nil, profile: nil)
    }

    private func treeResponse(project: JSONValue,
                              scopedIDs: [JSONValue] = [.string("session-1")]) -> JSONValue {
        .object([
            "projects": .array([project]),
            "active_id": .string("project-1"),
            "scoped_session_ids": .array(scopedIDs),
        ])
    }

    private func overviewProject(id: String, sessionCount: Int, previews: [JSONValue]) -> JSONValue {
        .object([
            "id": .string(id),
            "label": .string("Project"),
            "path": .string("/work/project"),
            "color": .null,
            "icon": .null,
            "isAuto": .bool(false),
            "isNoProject": .bool(false),
            "sessionCount": .number(Double(sessionCount)),
            "lastActive": .number(10),
            "totalTokens": .number(2),
            "totalCostUsd": .number(0.25),
            "repos": .array([
                .object([
                    "id": .string("/work/project"),
                    "label": .string("project"),
                    "path": .string("/work/project"),
                    "sessionCount": .number(Double(sessionCount)),
                    "groups": .array([
                        .object([
                            "id": .string("main"),
                            "label": .string("main"),
                            "path": .string("/work/project"),
                            "isMain": .bool(true),
                            "isKanban": .bool(false),
                            "sessions": .array([]),
                        ]),
                    ]),
                ]),
            ]),
            "previewSessions": .array(previews),
        ])
    }

    private func hydratedProject(id: String, sessionCount: Int, sessions: [JSONValue]) -> JSONValue {
        .object([
            "id": .string(id),
            "label": .string("Project"),
            "path": .string("/work/project"),
            "color": .null,
            "icon": .null,
            "isAuto": .bool(false),
            "isNoProject": .bool(false),
            "sessionCount": .number(Double(sessionCount)),
            "lastActive": .number(10),
            "totalTokens": .number(2),
            "totalCostUsd": .number(0.25),
            "repos": .array([
                .object([
                    "id": .string("/work/project"),
                    "label": .string("project"),
                    "path": .string("/work/project"),
                    "sessionCount": .number(Double(sessionCount)),
                    "groups": .array([
                        .object([
                            "id": .string("main"),
                            "label": .string("main"),
                            "path": .string("/work/project"),
                            "isMain": .bool(true),
                            "isKanban": .bool(false),
                            "sessions": .array(sessions),
                        ]),
                    ]),
                ]),
            ]),
            "previewSessions": .array([]),
        ])
    }

    private func sessionRow(id: String, profile: String?) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "title": .string("Session \(id)"),
            "preview": .string("Preview"),
            "last_active": .number(10),
        ]
        if let profile { row["profile"] = .string(profile) }
        return .object(row)
    }

    private func profile(_ name: String, isDefault: Bool = false) -> HermesProfile {
        HermesProfile(.object([
            "name": .string(name), "is_default": .bool(isDefault),
        ]))
    }
}

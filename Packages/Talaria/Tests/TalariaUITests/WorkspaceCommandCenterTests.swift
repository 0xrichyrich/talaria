import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class WorkspaceCommandCenterTests: XCTestCase {
    func testWorkspaceRouteDoesNotCollideAcrossGatewayOrProfile() {
        let a = GatewayWorkspaceRoute(gatewayID: "mini", profile: "default")
        let b = GatewayWorkspaceRoute(gatewayID: "lab", profile: "default")
        let c = GatewayWorkspaceRoute(gatewayID: "mini", profile: "worker")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, c.id)
    }

    func testManagedFileListingRequiresLockedCanonicalFence() throws {
        let listing = try ManagedFileListing(validatingManaged: .object([
            "path": .string("/workspace"),
            "parent": .null,
            "root": .string("/workspace"),
            "locked_root": .string("/workspace"),
            "can_change_path": .bool(false),
            "entries": .array([
                .object(["name": .string("src"), "path": .string("/workspace/src"),
                         "is_directory": .bool(true), "size": .number(0)]),
                .object(["name": .string("README.md"), "path": .string("/workspace/README.md"),
                         "is_directory": .bool(false), "size": .number(42),
                         "mime_type": .string("text/markdown")]),
            ]),
        ]))
        XCTAssertEqual(listing.path, "/workspace")
        XCTAssertEqual(listing.lockedRoot, "/workspace")
        XCTAssertFalse(listing.canChangePath)
        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[1].mimeType, "text/markdown")

        XCTAssertThrowsError(try ManagedFileListing(validatingManaged: .object([
            "path": .string("/workspace"), "root": .string("/workspace"),
            "locked_root": .string("/workspace"), "entries": .array([
                .object(["name": .string("escape"), "path": .string("/outside/escape"),
                         "is_directory": .bool(false)]),
            ]),
        ])))
        XCTAssertThrowsError(try ManagedFileListing(validatingManaged: .object([
            "path": .string("/Users/me"), "root": .null, "locked_root": .null,
            "entries": .array([]),
        ])))
    }

    func testManagedFileBodyRejectsNonBase64AndDecodesBytes() throws {
        let body = try ManagedFileBody(validatingManaged: .object([
            "name": .string("note.txt"), "path": .string("/root/note.txt"),
            "size": .number(5), "root": .string("/root"),
            "locked_root": .string("/root"),
            "mime_type": .string("text/plain"),
            "data_url": .string("data:text/plain;base64,aGVsbG8="),
        ]), requestedPath: "/root/note.txt")
        XCTAssertEqual(String(data: body.bytes, encoding: .utf8), "hello")
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "data_url": .string("data:text/plain,secret"),
        ])))
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "size": .number(6), "mime_type": .string("text/plain"),
            "data_url": .string("data:text/plain;base64,aGVsbG8="),
        ])))
    }

    func testManagedFileByteLimitUsesDecodedBytes() throws {
        XCTAssertTrue(WorkspaceFileSizePolicy.allows(
            byteCount: WorkspaceFileSizePolicy.maximumBytes
        ))
        XCTAssertFalse(WorkspaceFileSizePolicy.allows(
            byteCount: WorkspaceFileSizePolicy.maximumBytes + 1
        ))
        let oversized = Data(repeating: 0x61,
                             count: WorkspaceFileSizePolicy.maximumBytes + 1)
        XCTAssertThrowsError(try ManagedFileBody(.object([
            "mime_type": .string("application/octet-stream"),
            "data_url": .string("data:application/octet-stream;base64,\(oversized.base64EncodedString())"),
        ]))) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 413)
        }
    }

    func testProjectAndGitFixturesDecodeWithoutInventingIdentity() {
        let projects = HermesProjectListing(.object([
            "active_id": .string("p_1"),
            "projects": .array([.object([
                "id": .string("p_1"), "slug": .string("app"), "name": .string("App"),
                "primary_path": .string("/work/app"), "archived": .bool(false),
                "folders": .array([.object([
                    "path": .string("/work/app"), "label": .null, "is_primary": .bool(true),
                ])]),
            ])]),
        ]))
        XCTAssertEqual(projects.activeID, "p_1")
        XCTAssertEqual(projects.projects.first?.primaryPath, "/work/app")
        XCTAssertEqual(projects.projects.first?.folders.first?.id, "/work/app")

        let status = HermesGitStatus(.object([
            "branch": .string("feature"), "defaultBranch": .string("main"),
            "ahead": .number(2), "behind": .number(1), "added": .number(8), "removed": .number(3),
            "files": .array([.object([
                "path": .string("Sources/App.swift"), "staged": .bool(true),
                "unstaged": .bool(true), "untracked": .bool(false), "conflicted": .bool(false),
            ])]),
        ]))
        let review = HermesGitFile(.object([
            "path": .string("Sources/App.swift"), "status": .string("M"),
            "staged": .bool(true), "added": .number(8), "removed": .number(3),
        ]))
        XCTAssertEqual(status.branch, "feature")
        XCTAssertEqual(status.files.first?.path, "Sources/App.swift")
        XCTAssertEqual(review.added, 8)
        XCTAssertTrue(review.staged)
    }

    func testProcessFixtureUsesHermesSessionIDAsKillAuthority() {
        let process = HermesProcess(.object([
            "session_id": .string("proc_123"), "command": .string("pytest"),
            "status": .string("running"),
        ]))
        XCTAssertEqual(process.id, "proc_123")
        XCTAssertEqual(process.command, "pytest")
    }

    func testWorkspacePathFenceRejectsParentsAndCatchAllRoots() {
        let roots = WorkspacePathFence.safeRoots([
            "/work/app", "/", "C:/", "/work/app/", #"\\server\share"#,
        ])
        XCTAssertEqual(roots, ["/work/app"])
        XCTAssertTrue(WorkspacePathFence.contains("/work/app/Sources/App.swift", in: roots))
        XCTAssertTrue(WorkspacePathFence.isRoot("/work/app", in: roots))
        XCTAssertFalse(WorkspacePathFence.contains("/work/application/secret", in: roots))
        XCTAssertFalse(WorkspacePathFence.contains("/work/app/../../etc/passwd", in: roots))
        XCTAssertEqual(WorkspacePathFence.normalized(#"\\server\share\repo"#), "//server/share/repo")
        XCTAssertTrue(WorkspacePathFence.contains(#"\\server\share\repo\Sources"#,
                                                   in: [#"\\server\share\repo"#]))
        XCTAssertTrue(WorkspacePathFence.contains(#"c:\WORK\app\Sources"#,
                                                   in: [#"C:\work\App"#]))
        XCTAssertNil(WorkspacePathFence.normalized(#"\\server\share\..\secret"#))
        XCTAssertNil(WorkspacePathFence.normalized(#"C:relative\file"#))
    }

    func testRemoteParentsPreserveWindowsDriveAndUNCRootSemantics() {
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"C:\work\app\Sources"#), "C:/work/app")
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"C:\work"#), "C:/")
        XCTAssertNil(WorkspaceRemotePath.parent(of: #"C:\"#))
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"\\server\share\repo\Sources"#),
                       "//server/share/repo")
        XCTAssertEqual(WorkspaceRemotePath.parent(of: #"\\server\share\repo"#),
                       "//server/share")
        XCTAssertNil(WorkspaceRemotePath.parent(of: #"\\server\share"#))
    }

    func testProjectFilesystemListingUsesCamelCaseAndFiltersSecrets() {
        let listing = ManagedFileListing(.object([
            "entries": .array([
                .object(["name": .string("Sources"), "path": .string("/work/app/Sources"),
                         "isDirectory": .bool(true)]),
                .object(["name": .string(".env"), "path": .string("/work/app/.env"),
                         "isDirectory": .bool(false)]),
                .object(["name": .string("auth.json"), "path": .string("/work/app/auth.json"),
                         "isDirectory": .bool(false)]),
            ]),
        ]), source: .project, requestedPath: "/work/app")
        XCTAssertEqual(listing.source, .project)
        XCTAssertEqual(listing.entries.map(\.name), ["Sources"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.parent, "/work")
    }

    func testCommandDispatchParsesEveryPortableDirective() throws {
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("exec"), "output": .string("done"),
        ])), .exec("done"))
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("plugin"), "output": .string("unsafe"),
        ])), .plugin("unsafe"))
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("alias"), "target": .string("goal"),
        ])), .alias("goal"))
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("skill"), "name": .string("review"),
            "message": .string("model scaffold"), "display": .string("/review"),
        ])), .skill(name: "review", message: "model scaffold", display: "/review"))
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("send"), "message": .string("model body"),
            "display": .string("/goal ship"), "notice": .string("Goal set"),
        ])), .send(message: "model body", notice: "Goal set", display: "/goal ship"))
        XCTAssertEqual(try HermesCommandDispatch(.object([
            "type": .string("prefill"), "message": .string("restore me"),
        ])), .prefill(message: "restore me", notice: nil))
        XCTAssertThrowsError(try HermesCommandDispatch(.object(["type": .string("picker")])))
        XCTAssertThrowsError(try HermesCommandDispatch(.object(["type": .string("exec")])))
        XCTAssertThrowsError(try HermesCommandDispatch(.object([
            "type": .string("skill"), "message": .string("missing identity"),
        ])))
    }

    func testCommandPolicyRejectsUntrustedOriginsAndDestructiveSemantics() {
        let safe = HermesCommand(name: "/status", summary: "", origin: .builtIn)
        XCTAssertEqual(WorkspaceCommandPolicy.disposition(for: safe, argument: ""), .readOnly)
        guard case .unsupported = WorkspaceCommandPolicy.disposition(for: safe, argument: "extra")
        else { return XCTFail("read-only commands must reject arguments") }

        for origin in [HermesCommandOrigin.quickCommand, .unclassified] {
            let command = HermesCommand(name: "/status", summary: "", origin: origin)
            guard case .unsupported = WorkspaceCommandPolicy.disposition(for: command, argument: "")
            else { return XCTFail("untrusted catalog origins must be blocked") }
        }
        for name in ["retry", "undo", "goal", "moa"] {
            let command = HermesCommand(name: name, summary: "", origin: .builtIn)
            guard case .unsupported = WorkspaceCommandPolicy.disposition(for: command, argument: "ship")
            else { return XCTFail("state-changing semantic command /\(name) must be blocked") }
        }

        let skill = HermesCommand(name: "/review", summary: "", origin: .skill)
        XCTAssertEqual(WorkspaceCommandPolicy.disposition(for: skill, argument: "this"),
                       .recoverablePromptDraft)
        XCTAssertNil(WorkspaceCommandPolicy.catalogCommand(named: "manual", in: [safe, skill]))
        XCTAssertTrue(WorkspaceCommandPolicy.isCatalogEligible(safe))
        XCTAssertTrue(WorkspaceCommandPolicy.isCatalogEligible(skill))
        XCTAssertFalse(WorkspaceCommandPolicy.isCatalogEligible(
            HermesCommand(name: "/status", summary: "", origin: .quickCommand)
        ))
        XCTAssertFalse(WorkspaceCommandPolicy.isCatalogEligible(
            HermesCommand(name: "/undo", summary: "", origin: .builtIn)
        ))
    }

    func testUpdateCheckRequiresCanApplyAndPreservesRecommendedCommand() throws {
        let blocked = try HermesUpdateCheck(.object([
            "can_apply": .bool(false),
            "update_command": .string("docker pull example/hermes:latest"),
            "message": .string("Update the managed image."),
        ]))
        XCTAssertFalse(blocked.canApply)
        XCTAssertEqual(blocked.recommendedCommand, "docker pull example/hermes:latest")
        XCTAssertEqual(blocked.message, "Update the managed image.")
        XCTAssertThrowsError(try HermesUpdateCheck(.object([
            "update_available": .bool(true),
        ])))
    }

    func testMalformedSuccessAcknowledgementsAreAmbiguousButRefusalsAreDefinite() {
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            AckValidationError(operation: "Create project")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: 409, message: "ok:false")
        ))
        XCTAssertEqual(AppModel.WorkspaceSystemAction.curator.expectedActionName, "curator-run")
        XCTAssertEqual(AppModel.WorkspaceSystemAction.updateHermes.expectedActionName,
                       "hermes-update")
        XCTAssertNil(AppModel.WorkspaceSystemAction.debugShare.expectedActionName)
        XCTAssertThrowsError(try HermesProjectListing(
            validatingAcknowledgement: .object(["ok": .bool(true)]),
            operation: "Delete project"
        )) { error in
            XCTAssertTrue(error is AckValidationError)
        }
    }

    func testOverlappingSameNameActionCannotCompleteOrPublishFirstBackup() {
        let acknowledgementA = JSONValue.object([
            "name": .string("backup"), "pid": .number(101),
            "archive": .string("/backups/a.zip"),
        ])
        let terminalStatusB = JSONValue.object([
            "name": .string("backup"), "pid": .number(202),
            "running": .bool(false), "exit_code": .number(0),
        ])

        let state = WorkspaceActionPollPolicy.classify(
            terminalStatusB,
            acceptedName: acknowledgementA["name"]?.stringValue ?? "",
            acceptedPID: acknowledgementA["pid"]?.intValue ?? -1
        )
        XCTAssertEqual(state, .untrackable(observedName: "backup", observedPID: 202))

        var publishedArchive: String?
        if case .terminal(exitCode: 0) = state {
            publishedArchive = acknowledgementA["archive"]?.stringValue
        }
        XCTAssertNil(publishedArchive,
                     "a replacement PID must never complete or publish action A's archive")
        XCTAssertEqual(
            WorkspaceActionPollPolicy.classify(
                .object(["name": .string("backup"), "running": .bool(false),
                         "exit_code": .number(0)]),
                acceptedName: "backup", acceptedPID: 101
            ),
            .untrackable(observedName: "backup", observedPID: nil)
        )

        XCTAssertEqual(
            WorkspaceActionPollPolicy.classify(
                .object(["name": .string("backup"), "pid": .number(101),
                         "running": .bool(false), "exit_code": .number(0)]),
                acceptedName: "backup", acceptedPID: 101
            ),
            .terminal(exitCode: 0)
        )
    }

    func testGitReviewMergePreservesMixedIndexAndWorkingTreeState() {
        let status = HermesGitStatus(.object([
            "files": .array([.object([
                "path": .string("App.swift"), "staged": .bool(true), "unstaged": .bool(true),
            ])]),
        ]))
        let review = HermesGitFile(.object([
            "path": .string("App.swift"), "status": .string("M"),
            "added": .number(4), "removed": .number(2),
        ]))
        let merged = WorkspaceGitMerge.detailed([review], status: status)
        XCTAssertEqual(merged.first?.added, 4)
        XCTAssertTrue(merged.first?.staged == true)
        XCTAssertTrue(merged.first?.unstaged == true)
    }

    @MainActor
    func testWorkspaceMutationOwnerCannotBeStrandedByReadGeneration() {
        let runtime = WorkspaceRuntime.shared
        runtime.mutationOwner = nil; runtime.mutationBusy = false
        let owner = runtime.claimMutation()
        XCTAssertNotNil(owner)
        XCTAssertNil(runtime.claimMutation(), "rapid selection/mutation must not issue a second write")
        runtime.gitRequest &+= 1
        runtime.fileRequest &+= 1
        runtime.releaseMutation(try! XCTUnwrap(owner))
        XCTAssertFalse(runtime.mutationBusy)
        XCTAssertNotNil(runtime.claimMutation())
        if let current = runtime.mutationOwner { runtime.releaseMutation(current) }
    }

    @MainActor
    func testSameGatewayRefreshClearsEveryPublishedCapabilityAndSnapshot() {
        let runtime = WorkspaceRuntime.shared
        runtime.gatewayID = "lab"
        runtime.projects = [HermesProject(.object([
            "id": .string("p1"), "name": .string("stale"),
        ]))]
        runtime.commands = [HermesCommand(name: "/status", summary: "", origin: .builtIn)]
        runtime.capability = ["projects": true, "files": true, "git": true,
                              "commands": true, "system": true]
        runtime.systemStatus = .object(["ready": .bool(true)])
        runtime.gitStatus = HermesGitStatus(.object(["branch": .string("old")]))
        runtime.fileRoots = ["/old"]
        runtime.processTargetID = "old-target"
        runtime.processesTargetID = "old-target"
        runtime.processes = [HermesProcess(.object(["session_id": .string("old-process")]))]
        let oldGeneration = runtime.generation

        let generation = runtime.begin(gatewayID: "lab")

        XCTAssertGreaterThan(generation, oldGeneration)
        XCTAssertTrue(runtime.projects.isEmpty)
        XCTAssertTrue(runtime.commands.isEmpty)
        XCTAssertNil(runtime.systemStatus)
        XCTAssertNil(runtime.gitStatus)
        XCTAssertTrue(runtime.fileRoots.isEmpty)
        XCTAssertNil(runtime.processTargetID)
        XCTAssertNil(runtime.processesTargetID)
        XCTAssertTrue(runtime.processes.isEmpty)
        for key in ["projects", "projectActivity", "managedFiles", "files",
                    "projectFiles", "roots", "git", "commands", "system",
                    "usage", "memory", "curator"] {
            XCTAssertEqual(runtime.capability[key], false, "stale capability: \(key)")
        }
        XCTAssertFalse(runtime.matches("lab", oldGeneration))
        _ = runtime.begin(gatewayID: nil)
    }

    @MainActor
    func testManagedTextRemainsReadOnlyUntilAtomicCASExistsAndCountsUTF8() async {
        let model = AppModel()
        do {
            _ = try await model.saveManagedText(path: "/managed/note.txt", source: .managed,
                                                original: Data(), updated: "draft")
            XCTFail("separate GET+POST must not be presented as conflict-safe")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch { XCTFail("unexpected error: \(error)") }

        let multiByteOverflow = String(
            repeating: "é", count: WorkspaceFileSizePolicy.maximumBytes / 2 + 1
        )
        do {
            _ = try await model.saveManagedText(path: "/managed/note.txt", source: .managed,
                                                original: Data(), updated: multiByteOverflow)
            XCTFail("outbound UTF-8 bytes must be capped")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 413)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testProcessDiscriminatorIncludesEveryAuthorityDimension() {
        let target = WorkspaceProcessTarget(
            route: GatewayBotRoute(gatewayID: "homelab", profile: "research"),
            title: "Research", sessionID: "runtime-42", botID: "bot",
            storedSessionID: "stored"
        )
        XCTAssertEqual(target.discriminator,
                       "gateway homelab · profile @research · session runtime-42")
    }

    @MainActor
    func testProjectSessionNavigationClosesOuterCommandCenterAfterOpen() throws {
        let model = AppModel()
        let session = try XCTUnwrap(HermesProjectSessionPreview(.object([
            "id": .string("stored-1"), "profile": .string("research"),
            "title": .string("Investigation"),
        ])))
        var closeCount = 0

        XCTAssertTrue(WorkspaceProjectSessionNavigation.open(
            session, gatewayID: "lab", model: model, close: { closeCount += 1 }
        ))
        XCTAssertEqual(closeCount, 1)
        XCTAssertNotNil(model.openBotID)

        XCTAssertFalse(WorkspaceProjectSessionNavigation.open(
            session, gatewayID: "", model: model, close: { closeCount += 1 }
        ))
        XCTAssertEqual(closeCount, 1, "failed navigation must not dismiss the current surface")
    }

    @MainActor
    func testProcessRowsRemainBoundToExactSelectedTarget() {
        let runtime = WorkspaceRuntime.shared
        let processA = HermesProcess(.object([
            "session_id": .string("process-a"), "command": .string("one"),
        ]))
        let processB = HermesProcess(.object([
            "session_id": .string("process-b"), "command": .string("two"),
        ]))

        let requestA = runtime.resetProcesses(targetID: "target-a")
        XCTAssertTrue(runtime.publishProcesses([processA], targetID: "target-a",
                                               request: requestA))
        XCTAssertTrue(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-a", processesTargetID: runtime.processesTargetID
        ))

        let requestB = runtime.resetProcesses(targetID: "target-b")
        XCTAssertTrue(runtime.processes.isEmpty)
        XCTAssertNil(runtime.processesTargetID)
        XCTAssertFalse(runtime.publishProcesses([processA], targetID: "target-a",
                                                request: requestA))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-b", processesTargetID: runtime.processesTargetID
        ))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: nil, processesTargetID: "target-a"
        ))

        XCTAssertTrue(runtime.publishProcesses([processB], targetID: "target-b",
                                               request: requestB))
        XCTAssertEqual(runtime.processes.map(\.id), ["process-b"])
        XCTAssertTrue(WorkspaceCommandSurfacePolicy.ownsProcesses(
            selectedTargetID: "target-b", processesTargetID: runtime.processesTargetID
        ))
        runtime.resetProcesses(targetID: nil)
    }

    func testCommandDispatchSurfaceRequiresAuthoritativeCatalogCapability() {
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: nil))
        XCTAssertFalse(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: false))
        XCTAssertTrue(WorkspaceCommandSurfacePolicy.exposesDispatch(capability: true))
    }

    @MainActor
    func testInitialWorkspaceLoadClearsStaleFilePublication() {
        let runtime = WorkspaceRuntime.shared
        runtime.fileListing = ManagedFileListing(.object([
            "path": .string("/old"), "entries": .array([]),
        ]))
        runtime.fileRoots = ["/old"]
        runtime.fileRootSources = ["/old": .managed]
        let request = runtime.fileRequest
        runtime.clearPublishedFiles()
        XCTAssertNil(runtime.fileListing)
        XCTAssertTrue(runtime.fileRoots.isEmpty)
        XCTAssertTrue(runtime.fileRootSources.isEmpty)
        XCTAssertGreaterThan(runtime.fileRequest, request)
    }

    func testOnlyAmbiguousTransportFailuresFenceMutations() {
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -5, message: "timeout")
        ))
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -7, message: "connection lost")
        ))
        XCTAssertTrue(WorkspaceMutationUncertainty.isAmbiguous(URLError(.timedOut)))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: 409, message: "refused")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(
            GatewayError(code: -3, message: "not connected")
        ))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(URLError(.notConnectedToInternet)))
        XCTAssertFalse(WorkspaceMutationUncertainty.isAmbiguous(AppModel.GatewayRouteError.noRoute))
    }

    func testRemoteBranchWireShapeRetainsWorktreeAuthority() {
        let branch = HermesGitBranch(.object([
            "name": .string("origin/feature"), "isRemote": .bool(true),
            "checkedOut": .bool(false), "worktreePath": .null,
        ]))
        XCTAssertTrue(branch.isRemote)
        XCTAssertNil(branch.worktreePath)
        let checkedOut = HermesGitBranch(.object([
            "name": .string("feature"), "checkedOut": .bool(true),
            "isRemote": .bool(false), "worktreePath": .string("/work/.worktrees/feature"),
        ]))
        XCTAssertEqual(checkedOut.worktreePath, "/work/.worktrees/feature")
    }

    @MainActor
    func testProjectRootMutationInvalidationClearsGitBeforeHydration() {
        let runtime = WorkspaceRuntime.shared
        runtime.gitPath = "/old"
        runtime.gitStatus = HermesGitStatus(.object(["branch": .string("main")]))
        runtime.gitFiles = [HermesGitFile(.object(["path": .string("stale.swift")]))]
        runtime.gitBranches = [HermesGitBranch(.object(["name": .string("main")]))]
        runtime.gitWorktrees = [HermesGitWorktree(.object(["path": .string("/old")]))]
        runtime.capability["git"] = true
        let request = runtime.gitRequest

        let invalidated = runtime.invalidateGit(path: "/new")

        XCTAssertGreaterThan(invalidated, request)
        XCTAssertEqual(runtime.gitPath, "/new")
        XCTAssertNil(runtime.gitStatus)
        XCTAssertTrue(runtime.gitFiles.isEmpty)
        XCTAssertTrue(runtime.gitBranches.isEmpty)
        XCTAssertTrue(runtime.gitWorktrees.isEmpty)
        XCTAssertEqual(runtime.capability["git"], false)
    }

    func testProjectFilesystemContentFailsClosedWithoutRealpathProof() async {
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("unused"))
        do {
            _ = try await client.projectFiles(path: "/work/project")
            XCTFail("project listing must not reach an unproven /api/fs boundary")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            _ = try await client.projectFile(path: "/work/project/link")
            XCTFail("project content must not reach an unproven /api/fs boundary")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 501)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSafeExportNameNeverCreatesNestedOrControlPaths() {
        XCTAssertEqual(WorkspaceExportName.safe("../secret\\name\n.zip", fallback: "backup.zip"),
                       "secret-name-.zip")
    }

    func testBackupDownloadCapRejectsDeclaredOrObservedOverflow() {
        let cap = WorkspaceBackupDownloadPolicy.maximumBytes
        XCTAssertFalse(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: NSURLSessionTransferSizeUnknown, writtenBytes: cap
        ))
        XCTAssertTrue(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: cap + 1, writtenBytes: 0
        ))
        XCTAssertTrue(WorkspaceBackupDownloadPolicy.exceedsLimit(
            expectedBytes: NSURLSessionTransferSizeUnknown, writtenBytes: cap + 1
        ))
    }

    @MainActor
    func testWorkspaceSourceSwitchClearsOwnedBackupExportAndBinding() throws {
        let runtime = WorkspaceRuntime.shared
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: "backup.zip")
        try Data("backup".utf8).write(to: export)

        runtime.gatewayID = "old"
        runtime.backupExportURL = export
        runtime.backupDownloadOwner = UUID()
        runtime.backupDownloadRunning = true
        _ = runtime.begin(gatewayID: "new")

        XCTAssertNil(runtime.backupExportURL)
        XCTAssertNil(runtime.backupDownloadOwner)
        XCTAssertFalse(runtime.backupDownloadRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        _ = runtime.begin(gatewayID: nil)
    }

}

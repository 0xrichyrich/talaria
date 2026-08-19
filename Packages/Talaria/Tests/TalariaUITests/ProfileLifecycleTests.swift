import Foundation
import Testing
import TalariaKit
@testable import TalariaUI

@Suite("Source-qualified profile lifecycle", .serialized)
struct ProfileLifecycleTests {
    @Test func renameRequestCarriesExactRESTMethodPathBodyAndCredential() throws {
        let request = try GatewayREST.profileLifecycleRequest(
            baseURL: #require(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("secret"), profile: "worker one",
            method: "PATCH", newName: "renamed")
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://gateway.example/base/api/profiles/worker%20one")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secret")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == ["new_name": "renamed"])
    }

    @Test func oauthDeleteRequestDoesNotCarryRenameBody() throws {
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 4_000_000_000, provider: "nous", userID: nil)
        let request = try GatewayREST.profileLifecycleRequest(
            baseURL: #require(URL(string: "https://gateway.example")),
            credential: .oauth(tokens), profile: "worker", method: "DELETE")
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test func authoritativeInventoryRequestIsAuthenticatedAndPathPreserving() throws {
        let request = GatewayREST.profileInventoryRequest(
            baseURL: try #require(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("secret"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://gateway.example/base/api/profiles")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secret")
    }

    @Test func authoritativeInventoryRejectsAnyMalformedOrConflictingRow() throws {
        let valid: JSONValue = ["profiles": [
            ["name": "default", "display_name": "Hermes Prime"],
            ["name": "worker"],
        ]]
        #expect(try GatewayREST.decodeProfileNames(valid) == ["default", "worker"])
        let inventory = try GatewayREST.decodeProfileInventory(valid)
        #expect(inventory["default"]?.displayName == "Hermes Prime")
        #expect(inventory["worker"]?.displayName == nil)

        let invalid: [JSONValue] = [
            ["profiles": [["name": "default"], [:]]],
            ["profiles": [["name": "default"], ["name": ""]]],
            ["profiles": [["name": "worker"], ["name": "worker"]]],
            ["profiles": [["name": "worker"], ["name": "Worker"]]],
            ["profiles": [["name": " worker"]]],
        ]
        for value in invalid {
            #expect(throws: GatewayError.self) {
                _ = try GatewayREST.decodeProfileNames(value)
            }
        }
    }

    @Test func disconnectedPoolSentinelFencesRedialUntilReleased() async throws {
        let base = try #require(URL(string: "https://gateway.example"))
        let fallback = GatewayClient(baseURL: base, credential: .sessionToken("fallback"))
        let pool = GatewayClientPool { _, _ in fallback }
        let sentinel = GatewayClient(baseURL: base, credential: .sessionToken("sentinel"))
        await pool.adopt(sentinel, for: "mac")
        let routed = try await pool.connect(gatewayID: "mac", baseURL: base,
                                            credential: .sessionToken("new"))
        #expect(routed === sentinel)
        #expect(!(await routed.isConnected))
    }

    @Test func clientAdmissionRejectsRPCAndRESTBeforeTransportOrNetworkUse() async throws {
        let client = GatewayClient(
            baseURL: try #require(URL(string: "https://gateway.invalid")),
            credential: .sessionToken("unused"))
        await client.setTrafficAdmission { nil }

        do {
            _ = try await client.rpc("profiles.list")
            Issue.record("fenced RPC unexpectedly reached transport")
        } catch let error as GatewayError {
            #expect(error.code == GatewayClient.trafficFenced)
        }

        do {
            _ = try await client.restJSON(path: "api/config", timeout: 1)
            Issue.record("fenced REST unexpectedly reached URLSession")
        } catch let error as GatewayError {
            #expect(error.code == GatewayClient.trafficFenced)
        }
    }

    @Test @MainActor func ordinaryTrafficLeaseExcludesLifecycleForItsEntireAwait() async throws {
        let gatewayID = "lease-\(UUID().uuidString)"
        let lease = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        let concurrentLease = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))

        await lease.release()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await concurrentLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        #expect(ProfileLifecycleTrafficAdmission.acquire(gatewayID) == nil)
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)

        let replacement = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        await replacement.release()
    }

    @Test @MainActor
    func authoritativeReconciliationReopensOwnerReconnectAndDefaultRosterRefresh() async throws {
        let gatewayID = "authoritative-\(UUID().uuidString)"
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))

        // Reconnect and the default-profile roster refresh use the same
        // ordinary client/REST admission as every external caller. Neither is
        // allowed while Hermes' filesystem mutation is unresolved.
        #expect(ProfileLifecycleTrafficAdmission.acquire(gatewayID) == nil)

        let recoveryLease =
            ProfileLifecycleTrafficAdmission.finishAuthoritativeReconciliation(gatewayID)
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        let ownerTraffic = try #require(
            ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        await ownerTraffic.release()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await recoveryLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test @MainActor func completedLeaseCannotReleaseASuccessorLifecycle() async {
        let gatewayID = "successor-\(UUID().uuidString)"
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        let first = ProfileLifecycleExclusiveLease(gatewayID: gatewayID)
        let recoveryLease = first.finishAuthoritativeReconciliation()

        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        first.releaseIfHeld()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await recoveryLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test func retiredARecoveryCannotReplaceLaterBPrimaryOrInFlightSwitch() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 42,
            currentGatewayID: "gateway-b", hasClient: true,
            switchInProgress: false))
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: false,
            switchInProgress: true))
    }

    @Test func retiredPrimaryRecoveryIsAllowedOnlyWhileStillUnclaimed() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        #expect(ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: false,
            switchInProgress: false))
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: "gateway-b", hasClient: true,
            switchInProgress: false))
    }

    @Test func switchingBKeepsRetiredAReconciliationQualifiedDuringNilGatewayWindow() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        let mayRestore = ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: true,
            switchInProgress: true)
        #expect(!mayRestore)

        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "gateway-a", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(
            target: target, canonicalNewName: "renamed",
            currentPrimaryGatewayID: nil,
            restorePrimaryIfUnclaimed: mayRestore)
        #expect(plan.sourceIDs == ["gateway-a::worker"])
        #expect(plan.destinationID == "gateway-a::renamed")
        #expect(!plan.destinationIsPrimary)
    }

    @Test @MainActor func retirementDisconnectExcludesBSwitchUntilCleanupCompletes() {
        let supervisor = ConnectionSupervisor.shared
        let original = supervisor.isReconnecting
        supervisor.isReconnecting = false
        defer { supervisor.isReconnecting = original }

        #expect(ProfileLifecycleSwitchClaim.acquire())
        // This is the exact admission check switchGateway(B) performs while
        // disconnectGateway(A) is suspended in the client-pool await.
        #expect(!ProfileLifecycleSwitchClaim.acquire())
        ProfileLifecycleSwitchClaim.release()

        #expect(ProfileLifecycleSwitchClaim.acquire())
        ProfileLifecycleSwitchClaim.release()
    }

    @Test @MainActor func clientReleasesOrdinaryLeaseOnTransportFailure() async throws {
        let gatewayID = "release-\(UUID().uuidString)"
        let client = GatewayClient(
            baseURL: try #require(URL(string: "https://gateway.invalid")),
            credential: .sessionToken("unused"))
        await client.setTrafficAdmission {
            await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
        }

        do {
            _ = try await client.rpc("profiles.list")
            Issue.record("disconnected test client unexpectedly completed an RPC")
        } catch let error as GatewayError {
            #expect(error.code == -3)
        }

        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test func defaultRenameResponsePreservesCanonicalIdentity() {
        let result = ProfileRenameResult(.object([
            "ok": .bool(true), "name": .string("default"),
            "display_name": .string("Hermes Prime"),
        ]))
        #expect(result?.name == "default")
        #expect(result?.displayName == "Hermes Prime")
    }

    @Test func renameResponseWithoutCanonicalIdentityFailsClosed() {
        #expect(ProfileRenameResult(.object(["ok": .bool(true)])) == nil)
        #expect(ProfileRenameResult(.object(["ok": .bool(true), "name": .string("  ")])) == nil)
    }

    @Test func profileNamePolicyMirrorsHermesReservedNames() {
        for reserved in ["hermes", "default", "test", "tmp", "root", "sudo",
                         "chat", "gateway", "config", "sessions", "profile", "acp"] {
            #expect(!ProfileNamePolicy.validatesNamedProfile(reserved))
        }
        #expect(ProfileNamePolicy.validatesNamedProfile("worker_2"))
        #expect(!ProfileNamePolicy.validatesNamedProfile("Worker"))
        #expect(!ProfileNamePolicy.validatesNamedProfile("../worker"))
    }

    @Test func acceptedSourceOverwritesAnyStaleDestinationCache() {
        var cache = ["old": "source", "new": "stale-destination"]
        ProfileLifecycleCache.moveFirst(&cache, from: ["old", "qualified-old"], to: "new")
        #expect(cache == ["new": "source"])
        var absentSource = ["new": "stale-destination"]
        ProfileLifecycleCache.moveFirst(&absentSource, from: ["old"], to: "new")
        #expect(absentSource.isEmpty)
    }

    @Test func queuedWorkRekeysBeforeReconnectOrIsDroppedOnDelete() {
        var renamed = [(botID: "old", text: "send me"),
                       (botID: "other", text: "leave me")]
        ProfileLifecycleQueue.reconcile(&renamed, sources: ["old", "mac::old"],
                                        destination: "new")
        #expect(renamed.map(\.botID) == ["new", "other"])
        #expect(renamed.map(\.text) == ["send me", "leave me"])

        var deleted = renamed
        ProfileLifecycleQueue.reconcile(&deleted, sources: ["new"], destination: nil)
        #expect(deleted.map(\.botID) == ["other"])
    }

    @Test func mutationPostconditionsResolveCommitFailureAndUncertainty() {
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default", "new"], source: "old", destination: "new") == .committed)
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default", "old"], source: "old", destination: "new") == .notCommitted)
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default"], source: "old", destination: "new") == .indeterminate)
        #expect(ProfileLifecyclePostcondition.delete(
            names: ["default"], source: "old") == .committed)
        #expect(ProfileLifecyclePostcondition.delete(
            names: ["default", "old"], source: "old") == .notCommitted)
    }

    @Test func lostDefaultRenameResponseUsesAuthoritativeDisplayNamePostcondition() {
        let committed = [
            "default": ProfileInventoryEntry(name: "default", displayName: "Hermes Prime"),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: committed, source: "default", requested: "Hermes Prime") == .committed)

        let notCommitted = [
            "default": ProfileInventoryEntry(name: "default", displayName: "Hermes"),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: notCommitted, source: "default", requested: "Hermes Prime") == .notCommitted)

        // Hermes' directory-scan fallback omits display_name. Presence of the
        // canonical default row alone cannot resolve a lost PATCH response.
        let fallback = [
            "default": ProfileInventoryEntry(name: "default", displayName: nil),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: fallback, source: "default", requested: "Hermes Prime") == .indeterminate)
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: [:], source: "default", requested: "Hermes Prime") == .indeterminate)
    }

    @Test func completionFenceRejectsLateOrForeignResults() {
        #expect(ProfileLifecycleCompletionFence.accepts(
            generation: 4, currentGeneration: 4,
            gatewayID: "mac", currentGatewayID: "mac"))
        #expect(!ProfileLifecycleCompletionFence.accepts(
            generation: 3, currentGeneration: 4,
            gatewayID: "mac", currentGatewayID: "mac"))
        #expect(!ProfileLifecycleCompletionFence.accepts(
            generation: 4, currentGeneration: 4,
            gatewayID: "homelab", currentGatewayID: "mac"))
    }

    @Test func idempotentDefaultRenameDoesNotArmNextPickerSuppression() {
        #expect(!ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "default", next: "default"))
        #expect(ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "default", next: "worker"))
        #expect(ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "homelab::default", next: "homelab::worker"))
    }

    @Test func statePlanNeverBorrowsCollidingBareNameAfterGatewaySwitch() {
        let target = ProfileLifecycleTarget(
            rosterID: "default",
            route: GatewayBotRoute(gatewayID: "mac", profile: "default"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: "homelab")
        #expect(plan.sourceIDs == ["mac::default"])
        #expect(plan.destinationID == "mac::renamed")
        #expect(!plan.sourceIDs.contains("default"))
    }

    @Test func statePlanUsesBareKeysOnlyForTheStillOwningPrimary() {
        let target = ProfileLifecycleTarget(
            rosterID: "default",
            route: GatewayBotRoute(gatewayID: "mac", profile: "default"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: "mac")
        #expect(plan.sourceIDs == ["mac::default"])
        #expect(plan.destinationID == "renamed")
        #expect(plan.destinationIsPrimary)
    }

    @Test func deletePlanHasNoDestination() {
        let target = ProfileLifecycleTarget(
            rosterID: "homelab::worker",
            route: GatewayBotRoute(gatewayID: "homelab", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: nil,
                                             currentPrimaryGatewayID: "mac")
        #expect(plan.sourceIDs == ["homelab::worker"])
        #expect(plan.destinationID == nil)
    }

    @Test func disconnectedFormerPrimaryStillScrubsItsCapturedBareKey() {
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: nil,
                                             restorePrimaryIfUnclaimed: true)
        #expect(plan.sourceIDs == ["mac::worker"])
        #expect(plan.destinationID == "renamed")
        #expect(plan.destinationIsPrimary)
    }

    @Test @MainActor func callerParksBareStateBeforePrimaryCanSwitch() throws {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let sourceChat = ChatState(messages: [])
        let staleQualified = ChatState(messages: [])
        model.chats = ["worker": sourceChat, "mac::worker": staleQualified]
        model.composeQueue = [(botID: "worker", text: "source")]

        model.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = "homelab"
        let collidingNewPrimary = ChatState(messages: [])
        model.chats["worker"] = collidingNewPrimary
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: LiveRuntime.shared.gatewayID,
                                             restorePrimaryIfUnclaimed: true)
        ProfileLifecycleCache.moveFirst(&model.chats, from: plan.sourceIDs,
                                        to: try #require(plan.destinationID))

        #expect(model.chats["worker"] === collidingNewPrimary)
        #expect(model.chats["mac::renamed"] === sourceChat)
        #expect(!plan.sourceIDs.contains("worker"))
        LiveRuntime.shared.gatewayID = nil
    }

    @Test @MainActor func failedMutationRestoresBareStateOnlyWithoutNewPrimaryOwner() {
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))

        let reconnecting = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let reconnectingChat = ChatState(messages: [])
        reconnecting.chats["worker"] = reconnectingChat
        reconnecting.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = nil
        reconnecting.restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: true)
        #expect(reconnecting.chats["worker"] === reconnectingChat)
        #expect(reconnecting.chats["mac::worker"] == nil)

        let switched = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let parkedChat = ChatState(messages: [])
        switched.chats["worker"] = parkedChat
        switched.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = "homelab"
        let newPrimaryChat = ChatState(messages: [])
        switched.chats["worker"] = newPrimaryChat
        switched.restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: true)
        #expect(switched.chats["worker"] === newPrimaryChat)
        #expect(switched.chats["mac::worker"] === parkedChat)
        LiveRuntime.shared.gatewayID = nil
    }

    @Test @MainActor func abortScrubsPublishersAndInvalidatesLateCompletions() throws {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let attachment = PendingAttachment(id: "attachment", kind: .image, name: "ghost.png")
        model.chats["worker"] = ChatState(messages: [])
        model.chats["worker"]?.sessionID = "session"
        model.chats["worker"]?.isRunning = true
        model.chats["worker"]?.attachments = [attachment]
        AttachmentRuntime.shared.staged[attachment.id] = .init(paths: ["/ghost"], refText: nil)
        AttachmentRuntime.shared.uploading.insert(attachment.id)
        AttachmentRuntime.shared.chooserBotID = "worker"

        let watchdog = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        ChatRuntime.shared.submitWatchdogs["worker"] = watchdog
        ChatRuntime.shared.turnFloor["worker"] = 4
        LivenessRuntime.shared.unverifiableSince["worker"] = ContinuousClock.now

        let prompt = BlockingPrompt(kind: .secret, gatewayID: "mac", requestID: "request",
                                    sessionID: "session", botID: "worker", question: "secret")
        ApprovalBridges.shared.prompts = [prompt]
        ApprovalBridges.shared.sweptSessions = [
            GatewaySessionRoute(gatewayID: "mac", sessionID: "session"),
        ]
        LiveRuntime.shared.sessionToBot["session"] = "worker"

        let deliveryKey = AppModel.deliveryKey(to: "worker", body: "hello")
        let replyWatch = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        A2ARuntime.shared.watchers[deliveryKey] = replyWatch
        A2ARuntime.shared.watcherGeneration[deliveryKey] = 1
        A2ARuntime.shared.deliveries[deliveryKey] = A2ADelivery(
            to: "worker", queuedBehindRun: false, state: .waiting, at: Date())
        let lifecycle = try #require(model.profileLifecycleGenerationToken(for: "worker"))

        model.abortProfileRuntime(target)

        #expect(watchdog.isCancelled)
        #expect(replyWatch.isCancelled)
        #expect(ChatRuntime.shared.submitWatchdogs["worker"] == nil)
        #expect(ChatRuntime.shared.turnFloor["worker"] == nil)
        #expect(model.chats["worker"]?.attachments.isEmpty == true)
        #expect(model.chats["worker"]?.sessionID == nil)
        #expect(model.chats["worker"]?.isRunning == false)
        #expect(AttachmentRuntime.shared.staged[attachment.id] == nil)
        #expect(!AttachmentRuntime.shared.uploading.contains(attachment.id))
        #expect(AttachmentRuntime.shared.chooserBotID == nil)
        #expect(LivenessRuntime.shared.unverifiableSince["worker"] == nil)
        #expect(ApprovalBridges.shared.prompts.isEmpty)
        #expect(ApprovalBridges.shared.sweptSessions.isEmpty)
        #expect(A2ARuntime.shared.watchers.isEmpty)
        #expect(A2ARuntime.shared.deliveries[deliveryKey] == nil)
        #expect(!model.profileLifecycleAccepts(lifecycle))

        model.activateProfileLifecycleRoute(gatewayID: "mac", profile: "worker")
        let replacementLifecycle = try #require(model.profileLifecycleGenerationToken(for: "worker"))
        #expect(replacementLifecycle != lifecycle)
        #expect(model.profileLifecycleAccepts(replacementLifecycle))
        LiveRuntime.shared.gatewayID = nil
        LiveRuntime.shared.sessionToBot.removeAll()
        A2ARuntime.shared.reset()
        ApprovalBridges.shared.prompts.removeAll()
    }

    @Test @MainActor func unreadLifecycleRekeysSourceMarkOverStaleDestination() throws {
        let suite = "ProfileLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let scope = try #require(URL(string: "https://gateway.example"))
        #expect(store.ingest(["old": 10, "new": 1], openBot: nil, scope: scope).isEmpty)
        store.reconcileProfileLifecycle(profile: "old", newProfile: "new", scope: scope)
        #expect(store.ingest(["new": 10], openBot: nil, scope: scope).isEmpty)
        #expect(store.ingest(["new": 11], openBot: nil, scope: scope) == ["new"])
    }
}

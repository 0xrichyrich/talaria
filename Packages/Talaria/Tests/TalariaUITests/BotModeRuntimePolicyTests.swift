#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

/// Narrow integration checks for the policy that sits between the typed Hermes
/// roster and Bot Mode's UI. These deliberately avoid a transport: the risky
/// regressions are target selection, retry identity, and display-only state.
final class BotModeRuntimePolicyTests: XCTestCase {
    func testExactCanonicalEvidenceUsesRootTitleBeforeLeafTitle() {
        let compressed = profile(
            name: "compressed",
            last: session(id: "durable-root", resolvedID: "live-tip",
                          title: "Renamed leaf", rootTitle: "Bot Chat"))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: compressed.rawLastSession),
                       "durable-root")

        // A root is authoritative when supplied. A leaf named Bot Chat below
        // some other root is not Bot Mode's canonical session.
        let misleadingLeaf = profile(
            name: "misleading",
            last: session(id: "scratch", title: "Bot Chat", rootTitle: "Scratch"))
        XCTAssertNil(CanonicalBotChatEvidence.durableID(in: misleadingLeaf.rawLastSession))

        // Older gateway rows lack root_title, where the old exact title is the
        // compatible proof rather than an arbitrary newest-session lookup.
        let legacy = profile(name: "legacy", last: session(id: "old", title: "Bot Chat"))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: legacy.rawLastSession), "old")

        let padded = profile(
            name: "padded",
            last: session(id: "trimmed", title: "  Bot Chat\n", rootTitle: "   "))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: padded.rawLastSession),
                       "trimmed", "an empty root is absent and title evidence is trimmed")
    }

    func testPinnedSessionPolicyKeepsHistoryButRejectsEmptyTitleDrift() {
        let canonical = profile(
            name: "canonical",
            preferred: session(id: "pin", title: "Bot Chat", messageCount: 0))
        XCTAssertEqual(CanonicalPinnedSessionPolicy.classify(
            canonical.preferredSession, requestedPin: "pin"), .canonical)

        let drifted = profile(
            name: "drifted",
            preferred: session(id: "pin", title: "Auto titled", messageCount: 9))
        XCTAssertEqual(CanonicalPinnedSessionPolicy.classify(
            drifted.preferredSession, requestedPin: "pin"), .historyBearingTitleDrift)

        let stray = profile(
            name: "stray",
            preferred: session(id: "pin", title: "Draft", messageCount: 0))
        XCTAssertEqual(CanonicalPinnedSessionPolicy.classify(
            stray.preferredSession, requestedPin: "pin"), .emptyNonCanonical)
        XCTAssertEqual(CanonicalPinnedSessionPolicy.classify(
            stray.preferredSession, requestedPin: "different"), .inconclusive,
                       "a mismatched reply cannot authorize clearing another pin")
    }

    @MainActor
    func testRosterTriStatePinsExactAndGrandfathersOnlyExactBotChatHistory() {
        let unique = UUID().uuidString.lowercased()
        let legacyID = "legacy-\(unique)"
        let legacyBotChatID = "legacy-bot-chat-\(unique)"
        let goneID = "gone-\(unique)"
        let resolvedID = "resolved-\(unique)"
        let exactID = "exact-\(unique)"
        let runtime = CanonicalChatRuntime.shared
        let live = LiveRuntime.shared
        let model = AppModel()
        let ids = [legacyID, legacyBotChatID, goneID, resolvedID, exactID]
        let previousDefault = live.defaultBotID
        defer {
            live.defaultBotID = previousDefault
            for id in ids {
                runtime.pins.removeValue(forKey: id)
                runtime.grandfatherCandidates.removeValue(forKey: id)
                runtime.dirtyPins.remove(id)
                runtime.writeCount.removeValue(forKey: id)
                runtime.writeStamp.removeValue(forKey: id)
                LiveRuntime.shared.lastSessionByBot.removeValue(forKey: id)
            }
        }

        model.applyRosterAnswer([
            profile(name: legacyID, displayName: "Legacy Friend",
                    last: session(id: "history", title: "Scratch", lastActive: 10)),
        ], pinWrites: [:])
        XCTAssertNil(runtime.grandfatherCandidates[legacyID])
        XCTAssertNil(runtime.pins[legacyID])
        XCTAssertEqual(model.bots.first?.rawDisplayName, "Legacy Friend")

        // A legacy row without root_title can still be grandfathered, but
        // only when its exact leaf title is the canonical Bot Chat title.
        model.applyRosterAnswer([
            profile(name: legacyBotChatID,
                    last: session(id: "old-bot-chat", title: "Bot Chat", lastActive: 11)),
        ], pinWrites: [:])
        XCTAssertEqual(runtime.grandfatherCandidates[legacyBotChatID], "old-bot-chat")
        XCTAssertNil(runtime.pins[legacyBotChatID])

        // An explicit null means the requested preferred target is gone. Its
        // raw newest summary is still useful for roster display, but never
        // becomes a fallback canonical candidate.
        model.applyRosterAnswer([
            profile(name: goneID, last: session(id: "arbitrary-newest", title: "Cron", lastActive: 20),
                    preferred: .null),
        ], pinWrites: [:])
        XCTAssertNil(runtime.pins[goneID])
        XCTAssertNil(runtime.grandfatherCandidates[goneID])

        model.applyRosterAnswer([
            profile(name: resolvedID, last: session(id: "newest", title: "Scratch", lastActive: 30),
                    preferred: session(id: "canonical", title: "Bot Chat", lastActive: 25)),
        ], pinWrites: [:])
        XCTAssertEqual(runtime.pins[resolvedID], "canonical")
        XCTAssertNil(runtime.grandfatherCandidates[resolvedID])

        model.applyRosterAnswer([
            profile(name: exactID,
                    last: session(id: "compressed-root", title: "Tip renamed",
                                  rootTitle: "Bot Chat", lastActive: 40)),
        ], pinWrites: [:])
        XCTAssertEqual(runtime.pins[exactID], "compressed-root")
        XCTAssertNil(runtime.grandfatherCandidates[exactID])
    }

    @MainActor
    func testCanonicalHydrationRetriesOnlyTypedTimeoutOnSameDurableTarget() async throws {
        let chat = ChatState()
        var targets: [String] = []
        let payload: JSONValue = .object([
            "messages": .array([
                .object(["role": .string("assistant"), "text": .string("second read")]),
            ]),
        ])

        try await AppModel.hydrateCanonicalTranscript(
            chat: chat, resumeMessages: [], clearWhenEmpty: true, storedID: "durable-target",
            fallback: { target in
                targets.append(target)
                if targets.count == 1 { throw URLError(.timedOut) }
                return payload
            },
            accepts: { true })

        XCTAssertEqual(targets, ["durable-target", "durable-target"])
        XCTAssertEqual(chat.messages.map(\.text), ["second read"])
    }

    @MainActor
    func testCanonicalHydrationDoesNotRetryUntypedFailure() async {
        let chat = ChatState()
        var targets: [String] = []
        do {
            try await AppModel.hydrateCanonicalTranscript(
                chat: chat, resumeMessages: [], clearWhenEmpty: true, storedID: "durable-target",
                fallback: { target in
                    targets.append(target)
                    throw URLError(.cannotConnectToHost)
                },
                accepts: { true })
            XCTFail("a non-timeout fallback failure must escape")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(targets, ["durable-target"])
    }

    @MainActor
    func testCanonicalHydrationPersistentTimeoutRethrowsOriginalURLFailure() async {
        let chat = ChatState()
        let first = URLError(.timedOut, userInfo: ["attempt": "first"])
        let second = URLError(.timedOut, userInfo: ["attempt": "second"])
        var attempts = 0
        do {
            try await AppModel.hydrateCanonicalTranscript(
                chat: chat, resumeMessages: [], clearWhenEmpty: true,
                storedID: "durable-target",
                fallback: { _ in
                    attempts += 1
                    throw attempts == 1 ? first : second
                },
                accepts: { true })
            XCTFail("a persistent timeout must escape after one retry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertEqual(error.userInfo["attempt"] as? String, "second",
                           "the retry sentinel must not replace the original URL error")
        } catch {
            XCTFail("expected original URLError, got \(type(of: error)): \(error)")
        }
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testWorkerActivityIsLiveButCannotRankOrReorderConversation() {
        let id = "worker-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer { signals.rescope(to: nil) }

        signals.ingest([
            profile(
                name: id,
                last: session(id: "ordinary", title: "Scratch", preview: "older", lastActive: 100),
                preferred: session(id: "preferred", title: "Bot Chat", preview: "preferred", lastActive: 200),
                worker: .object(["last_active": .number(1_000)])),
        ])

        // Preferred wins ordinary conversation time; a much newer worker is
        // intentionally absent from this value and from the ranking key.
        XCTAssertEqual(signals.lastActive[id], 200)
        XCTAssertEqual(signals.previews[id], "preferred")
        XCTAssertEqual(signals.activity(of: id), 200_000)
        XCTAssertTrue(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_149)))
        XCTAssertFalse(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_151)))
    }

    @MainActor
    func testPreferredOwnsPreviewWhileFresherLastOwnsActivityAndUnreadIdentity() {
        let id = "split-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer {
            signals.rescope(to: nil)
            LiveRuntime.shared.lastSessionByBot.removeValue(forKey: id)
        }
        let row = profile(
            name: id,
            last: session(id: "fresh-scratch", title: "Scratch",
                          preview: "unrelated but newer", lastActive: 300),
            preferred: session(id: "forever", title: "Bot Chat",
                               preview: "canonical preview", lastActive: 200,
                               messageCount: 4))
        signals.ingest([row])
        XCTAssertEqual(signals.previews[id], "canonical preview")
        XCTAssertEqual(signals.activityPreviews[id], "unrelated but newer")
        XCTAssertEqual(signals.lastActive[id], 300)

        let model = AppModel()
        model.applyRosterAnswer([row], pinWrites: [:])
        XCTAssertEqual(model.bots.first?.preview, "canonical preview")
        XCTAssertEqual(LiveRuntime.shared.lastSessionByBot[id], "fresh-scratch")
    }

    @MainActor
    func testAuthoritativeEmptyPreferredPreviewClearsStaleRowText() {
        let id = "empty-preview-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        model.bots = [Bot(id: id, job: "", shape: .circle, hue: .violet,
                          preview: "stale canonical words")]
        model.applyRosterAnswer([
            profile(name: id,
                    preferred: session(id: "canonical", title: "Bot Chat",
                                       messageCount: 2)),
        ], pinWrites: [:], requestedPins: [id: "canonical"])
        XCTAssertEqual(model.bots.first?.preview, "Ready when you are.")
        XCTAssertEqual(RosterSignals.shared.previews[id], "")
    }

    @MainActor
    func testWorkerFutureStampCannotStayLiveAndOnlyChangesDisplayAgeWhileLive() {
        let id = "worker-future-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer { signals.rescope(to: nil) }
        signals.ingest([
            profile(name: id,
                    last: session(id: "chat", title: "Scratch", lastActive: 100),
                    worker: .object(["last_active": .number(200)])),
        ])

        XCTAssertEqual(signals.activity(of: id), 100_000,
                       "worker activity never participates in rank/unread recency")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 250))?
            .timeIntervalSince1970, 200,
                       "a live newer worker may improve only the displayed age")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 400))?
            .timeIntervalSince1970, 100,
                       "expired worker activity no longer changes the row age")

        signals.ingest([
            profile(name: id,
                    last: session(id: "chat", title: "Scratch", lastActive: 100),
                    worker: .object(["last_active": .number(10_000)])),
        ])
        XCTAssertFalse(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_000)),
                       "far-future worker stamps are not live forever")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 1_000))?
            .timeIntervalSince1970, 100)
    }

    func testCanonicalPinRoutingNeverSendsQualifiedRemoteKeysToPrimary() {
        let buckets = CanonicalPinRouting.partition([
            "primary": "primary-session",
            "lab::default": "lab-session",
            "home::research": "research-session",
        ])
        XCTAssertEqual(buckets.primary, ["primary": "primary-session"])
        XCTAssertEqual(buckets.routed["lab"], ["default": "lab-session"])
        XCTAssertEqual(buckets.routed["home"], ["research": "research-session"])
    }

    @MainActor
    func testStalePreferredReplyCannotOverwriteOrClearFreshServerPin() {
        let id = "pin-race-\(UUID().uuidString.lowercased())"
        let runtime = CanonicalChatRuntime.shared
        defer {
            runtime.pins.removeValue(forKey: id)
            runtime.grandfatherCandidates.removeValue(forKey: id)
            runtime.dirtyPins.remove(id)
            runtime.writeCount.removeValue(forKey: id)
            runtime.writeStamp.removeValue(forKey: id)
        }
        let model = AppModel()
        runtime.pins[id] = "requested-a"
        let serverB: JSONValue = ["hermes-bots": ["chat": "fresh-b"]]
        model.applyRosterAnswer([
            profile(name: id, preferred: session(id: "requested-a", title: "Bot Chat"),
                    meta: serverB),
        ], pinWrites: [:], requestedPins: [id: "requested-a"])
        XCTAssertEqual(runtime.pins[id], "fresh-b")

        // The same stale request later says its old target is gone. It cannot
        // erase B without proving that B was the pin it asked Hermes about.
        model.applyRosterAnswer([
            profile(name: id, preferred: .null),
        ], pinWrites: [:], requestedPins: [id: "requested-a"])
        XCTAssertEqual(runtime.pins[id], "fresh-b")

        // A null is allowed to clear only the identical request target.
        runtime.pins[id] = "requested-a"
        model.applyRosterAnswer([
            profile(name: id, preferred: .null),
        ], pinWrites: [:], requestedPins: [id: "requested-a"])
        XCTAssertNil(runtime.pins[id])
    }

    @MainActor
    func testStaleEmptyPreferredReplyCannotClearNewerOrDirtyPin() {
        let id = "empty-pin-race-\(UUID().uuidString.lowercased())"
        let runtime = CanonicalChatRuntime.shared
        defer {
            runtime.pins.removeValue(forKey: id)
            runtime.grandfatherCandidates.removeValue(forKey: id)
            runtime.dirtyPins.remove(id)
            runtime.writeCount.removeValue(forKey: id)
            runtime.writeStamp.removeValue(forKey: id)
        }
        let model = AppModel()
        let staleA = profile(
            name: id,
            preferred: session(id: "requested-a", title: "Draft", messageCount: 0))

        runtime.pins[id] = "fresh-b"
        model.applyRosterAnswer([staleA], pinWrites: [:],
                                requestedPins: [id: "requested-a"])
        XCTAssertEqual(runtime.pins[id], "fresh-b")

        runtime.pins[id] = "requested-a"
        runtime.dirtyPins.insert(id)
        model.applyRosterAnswer([staleA], pinWrites: [:],
                                requestedPins: [id: "requested-a"])
        XCTAssertEqual(runtime.pins[id], "requested-a")
        XCTAssertTrue(runtime.dirtyPins.contains(id))
    }

    @MainActor
    func testDirtyPinIgnoresPollIssuedDuringWriteUntilMatchingServerEcho() {
        let id = "dirty-pin-\(UUID().uuidString.lowercased())"
        let runtime = CanonicalChatRuntime.shared
        defer {
            runtime.pins.removeValue(forKey: id)
            runtime.grandfatherCandidates.removeValue(forKey: id)
            runtime.dirtyPins.remove(id)
            runtime.writeCount.removeValue(forKey: id)
            runtime.writeStamp.removeValue(forKey: id)
            LiveRuntime.shared.lastSessionByBot.removeValue(forKey: id)
        }
        let model = AppModel()
        runtime.pins[id] = "new-pin"
        runtime.dirtyPins.insert(id)
        runtime.writeCount[id] = 1

        model.applyRosterAnswer([
            profile(name: id, meta: ["hermes-bots": ["chat": "old-pin"]]),
        ], pinWrites: [id: 1])
        XCTAssertEqual(runtime.pins[id], "new-pin")
        XCTAssertTrue(runtime.dirtyPins.contains(id),
                      "a configure receipt cannot make an in-flight stale poll authoritative")

        model.applyRosterAnswer([
            profile(name: id, meta: ["hermes-bots": ["chat": "new-pin"]]),
        ], pinWrites: [id: 1])
        XCTAssertEqual(runtime.pins[id], "new-pin")
        XCTAssertFalse(runtime.dirtyPins.contains(id),
                       "only the matching profiles.list echo releases local authority")

        // A later snapshot issued after the configure-settle stamp is also
        // authoritative, including a legitimate change from another client.
        runtime.pins[id] = "phone-pin"
        runtime.dirtyPins.insert(id)
        runtime.writeCount[id] = 2
        runtime.noteWrite(id, at: 200)
        model.applyRosterAnswer([
            profile(name: id, meta: ["hermes-bots": ["chat": "pre-write"]]),
        ], pinWrites: [id: 2], snapshotIssuedAt: 199)
        XCTAssertEqual(runtime.pins[id], "phone-pin")
        XCTAssertTrue(runtime.dirtyPins.contains(id))
        model.applyRosterAnswer([
            profile(name: id, meta: ["hermes-bots": ["chat": "desktop-newer"]]),
        ], pinWrites: [id: 2], snapshotIssuedAt: 201)
        XCTAssertEqual(runtime.pins[id], "desktop-newer")
        XCTAssertFalse(runtime.dirtyPins.contains(id))
    }

    @MainActor
    func testRosterRejectsEmptyOddTitlePinButKeepsHistoryBearingTitleDrift() {
        let emptyID = "empty-pin-\(UUID().uuidString.lowercased())"
        let historyID = "history-pin-\(UUID().uuidString.lowercased())"
        let runtime = CanonicalChatRuntime.shared
        defer {
            for id in [emptyID, historyID] {
                runtime.pins.removeValue(forKey: id)
                runtime.grandfatherCandidates.removeValue(forKey: id)
                runtime.dirtyPins.remove(id)
                runtime.writeCount.removeValue(forKey: id)
                runtime.writeStamp.removeValue(forKey: id)
                LiveRuntime.shared.lastSessionByBot.removeValue(forKey: id)
            }
        }
        let model = AppModel()
        model.applyRosterAnswer([
            profile(name: emptyID,
                    preferred: session(id: "stray", title: "Draft", messageCount: 0),
                    meta: ["hermes-bots": ["chat": "stray"]]),
            profile(name: historyID,
                    preferred: session(id: "thread", title: "Auto title", messageCount: 8),
                    meta: ["hermes-bots": ["chat": "thread"]]),
        ], pinWrites: [:], requestedPins: [emptyID: "stray", historyID: "thread"])
        XCTAssertNil(runtime.pins[emptyID])
        XCTAssertEqual(runtime.pins[historyID], "thread")
    }

    @MainActor
    func testHiddenRowsKeepUnreadButSuppressPrimaryActivityToastAndRail() {
        let id = "hidden-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        let previousToastPreference = ActivityToastPref.shared.enabled
        defer {
            ActivityToastPref.shared.set(previousToastPreference)
            ToastBus.shared.clear()
            signals.rescope(to: nil)
        }

        let model = AppModel()
        model.bots = [Bot(id: id, job: "", shape: .circle, hue: .violet)]
        signals.ingest([
            profile(name: id, last: session(id: "chat", title: "Scratch", lastActive: 500)),
        ])
        signals.setHidden(id, true)
        ActivityToastPref.shared.set(true)
        ToastBus.shared.clear()

        model.applyUnreadWatermark([id])

        XCTAssertEqual(model.bots.first?.unread, 1)
        XCTAssertTrue(ToastBus.shared.toasts.isEmpty)
        XCTAssertTrue(model.rankedBots.contains(where: { $0.id == id }),
                      "hidden is display-only, not a roster membership deletion")
        XCTAssertFalse(model.activeNowBots(now: Date(timeIntervalSince1970: 501))
            .contains(where: { $0.id == id }))
    }

    func testShowHiddenIsAPrimaryDisplayOnlyPolicyWithDimmedInspectionRows() {
        XCTAssertFalse(RosterVisibilityPolicy.includesPrimary(hidden: true, showingHidden: false))
        XCTAssertTrue(RosterVisibilityPolicy.includesPrimary(hidden: true, showingHidden: true))
        XCTAssertTrue(RosterVisibilityPolicy.includesPrimary(hidden: false, showingHidden: false))
        XCTAssertEqual(RosterVisibilityPolicy.rowOpacity(hidden: true, showingHidden: true), 0.48)
        XCTAssertEqual(RosterVisibilityPolicy.rowOpacity(hidden: true, showingHidden: false), 1)
        let hidden = Bot(id: "hidden", job: "", shape: .circle, hue: .violet, unread: 3)
        let visible = Bot(id: "visible", job: "", shape: .circle, hue: .blue, unread: 9)
        XCTAssertEqual(RosterVisibilityPolicy.hiddenUnreadCount(
            bots: [hidden, visible], hiddenIDs: ["hidden"]), 3,
                       "the eye control badges only unread hidden rows")
    }

    func testRoomSearchKeepsCapturedFriendlyNameAfterTheRosterChanges() {
        let room = RoomRecord(name: "Launch", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "research"),
                       title: "Analysis", handle: "research-lab", sourceLabel: "Lab",
                       friendlyName: "Research Buddy"),
        ])
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "buddy"))
    }

    @MainActor
    func testRoomMemberCaptureNeverPersistsRenderedFallbackAlias() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "lab", profile: "code_review")
        let generic = Bot(id: route.qualifiedID, job: "", shape: .circle, hue: .green,
                          handleOverride: "code-review-lab",
                          remoteSource: BotSource(profile: route.profile,
                                                  gatewayID: route.gatewayID,
                                                  connectionLabel: "Home Lab"))
        let captured = model.capturedRoomMember(for: generic, route: route,
                                                sourceLabel: "Home Lab")
        XCTAssertNil(captured.title)
        XCTAssertNil(captured.friendlyName)
        XCTAssertNil(captured.rawDisplayName)
        XCTAssertFalse(captured.friendlyMentionNames.contains(generic.displayTitle))

        var explicit = generic
        explicit.title = "Code Friend"
        explicit.rawDisplayName = "Core Reviewer"
        let named = model.capturedRoomMember(for: explicit, route: route,
                                             sourceLabel: "Home Lab")
        XCTAssertEqual(named.title, "Code Friend")
        XCTAssertEqual(named.friendlyName, "Code Friend")
        XCTAssertEqual(named.rawDisplayName, "Core Reviewer")
    }

    @MainActor
    func testForeignRawDisplayNameSurvivesSecondaryAndRosterBotProjection() {
        let rosterProfile = profile(
            name: "research",
            displayName: "Research Buddy",
            last: session(id: "last", title: "Scratch", preview: "ordinary", lastActive: 30),
            preferred: session(id: "preferred", title: "Bot Chat", preview: "canonical",
                               lastActive: 20, messageCount: 2),
            meta: ["hermes-bots": ["chat": "preferred"]])
        let secondary = ConnectionRegistry.secondaryProfile(from: rosterProfile)
        XCTAssertEqual(secondary.rawDisplayName, "Research Buddy")
        XCTAssertEqual(secondary.preview, "canonical")
        XCTAssertEqual(secondary.activityPreview, "ordinary")
        XCTAssertEqual(secondary.lastActive, 30)
        XCTAssertEqual(secondary.pinnedChat, "preferred")
        XCTAssertEqual(secondary.preferredSessionID, "preferred")
        XCTAssertEqual(ConnectionRegistry.secondaryPreferredSessionPins(in: [rosterProfile]),
                       ["research": "preferred"])

        let stalePrecision = profile(
            name: "research",
            preferred: session(id: "old", title: "Bot Chat"),
            meta: ["hermes-bots": ["chat": "preferred"]])
        XCTAssertEqual(ConnectionRegistry.secondaryPrecisionRetryPins(
            in: [stalePrecision], harvestedPins: ["research": "preferred"]),
                       ["research": "preferred"])
        XCTAssertTrue(ConnectionRegistry.secondaryPrecisionRetryPins(
            in: [rosterProfile], harvestedPins: ["research": "preferred"]).isEmpty)

        let entry = ForeignRosterEntry(
            gatewayID: "lab", connectionLabel: "Lab", connectionKind: .lan,
            profile: secondary.name, handle: "research-lab", title: secondary.title,
            rawDisplayName: secondary.rawDisplayName, job: secondary.job,
            shape: secondary.shape, hue: secondary.hue, preview: secondary.preview,
            lastActive: secondary.lastActive, pinnedChat: secondary.pinnedChat,
            preferredSessionID: secondary.preferredSessionID)
        let model = AppModel()
        let bot = model.rosterBot(for: entry)
        XCTAssertEqual(bot.rawDisplayName, "Research Buddy")
        XCTAssertEqual(bot.friendlyMentionName, "Research Buddy")
        let runtime = CanonicalChatRuntime.shared
        let priorPrimary = runtime.pins["research"]
        let priorRouted = runtime.pins[entry.id]
        defer {
            runtime.pins[entry.id] = priorRouted
            runtime.pins["research"] = priorPrimary
            runtime.grandfatherCandidates.removeValue(forKey: entry.id)
        }
        model.hydrateForeignCanonicalPin(entry)
        XCTAssertEqual(runtime.pins["lab::research"], "preferred")
        XCTAssertEqual(runtime.pins["research"], priorPrimary,
                       "a secondary pin must never hydrate the primary profile key")
    }

    func testSecondaryPublicationQuarantinesInitialMismatchWhenPrecisionRetryFails() throws {
        // This is the payload retained by enumerate when its precision retry
        // throws: the profile/cosmetic and activity portions are authenticated,
        // but preferred_session still describes the client's old pin.
        let firstAnswer = profile(
            name: "research",
            displayName: "Research Buddy",
            last: session(id: "latest", title: "Scratch",
                          preview: "fresh independent activity", lastActive: 400),
            preferred: session(id: "old-pin", title: "Bot Chat",
                               preview: "wrong canonical words", lastActive: 300),
            meta: ["hermes-bots": [
                "chat": "new-pin", "title": "Research Lead", "shape": "hexagon",
            ]])

        XCTAssertEqual(ConnectionRegistry.secondaryPrecisionRetryPins(
            in: [firstAnswer], harvestedPins: ["research": "new-pin"]),
                       ["research": "new-pin"])
        let projection = ConnectionRegistry.secondaryRosterProjection(from: [firstAnswer])
        let row = try XCTUnwrap(projection.profiles.first)

        XCTAssertFalse(projection.isCanonicalProjectionComplete)
        XCTAssertEqual(projection.freshness, .stale)
        XCTAssertEqual(row.title, "Research Lead")
        XCTAssertEqual(row.rawDisplayName, "Research Buddy")
        XCTAssertEqual(row.shape, .hexagon)
        XCTAssertEqual(row.pinnedChat, "new-pin",
                       "the authenticated ui_meta pin remains safe routing authority")
        XCTAssertEqual(row.canonicalChatID, "new-pin")
        XCTAssertNil(row.preferredSessionID)
        XCTAssertTrue(row.preview.isEmpty,
                      "an old preferred session must not caption the new canonical pin")
        XCTAssertEqual(row.activityPreview, "fresh independent activity")
        XCTAssertEqual(row.lastActive, 400)
    }

    func testSecondaryPublicationQuarantinesPreferredEvidenceWhenPinChangesOnRetry() throws {
        let firstAnswer = profile(
            name: "research",
            preferred: session(id: "old-pin", title: "Bot Chat"),
            meta: ["hermes-bots": ["chat": "requested-pin"]])
        XCTAssertEqual(ConnectionRegistry.secondaryPrecisionRetryPins(
            in: [firstAnswer], harvestedPins: ["research": "requested-pin"]),
                       ["research": "requested-pin"])

        // While the retry for requested-pin was in flight, another client
        // moved ui_meta to newest-pin. The response resolved the requested
        // identity correctly, but it no longer describes its own final pin.
        let retryAnswer = profile(
            name: "research",
            last: session(id: "ordinary", title: "Scratch",
                          preview: "ordinary activity", lastActive: 200),
            preferred: session(id: "requested-pin", title: "Bot Chat",
                               preview: "superseded canonical words", lastActive: 500),
            meta: ["hermes-bots": ["chat": "newest-pin", "title": "Current Name"]])
        let projection = ConnectionRegistry.secondaryRosterProjection(from: [retryAnswer])
        let row = try XCTUnwrap(projection.profiles.first)

        XCTAssertFalse(projection.isCanonicalProjectionComplete)
        XCTAssertEqual(projection.freshness, .stale)
        XCTAssertEqual(row.title, "Current Name")
        XCTAssertEqual(row.pinnedChat, "newest-pin")
        XCTAssertEqual(row.canonicalChatID, "newest-pin")
        XCTAssertNil(row.preferredSessionID)
        XCTAssertTrue(row.preview.isEmpty)
        XCTAssertEqual(row.activityPreview, "superseded canonical words",
                       "the freshest activity remains valid independently of click identity")
        XCTAssertEqual(row.lastActive, 500)
    }

    func testSecondaryRosterPersistencePayloadContainsNoConversationProjection() throws {
        let canonicalWords = "PRIVATE-CANONICAL-\(UUID().uuidString)"
        let activityWords = "PRIVATE-ACTIVITY-\(UUID().uuidString)"
        let pin = "PRIVATE-PIN-\(UUID().uuidString)"
        let preferred = "PRIVATE-PREFERRED-\(UUID().uuidString)"
        let input = [
            "lab": SecondaryRoster(
                profiles: [SecondaryProfile(
                    name: "research", title: "Safe cosmetic", rawDisplayName: "Safe identity",
                    job: "Safe job", shape: .hexagon, hue: .violet,
                    preview: canonicalWords, activityPreview: activityWords,
                    lastActive: 123, pinnedChat: pin, preferredSessionID: preferred)],
                fetchedAt: Date(timeIntervalSince1970: 456), freshness: .fresh),
        ]

        let sanitized = ConnectionRegistry.sanitizedSecondaryRostersForPersistence(input)
        let payload = try JSONEncoder().encode(sanitized)
        let encoded = try XCTUnwrap(String(data: payload, encoding: .utf8))
        for privateValue in [canonicalWords, activityWords, pin, preferred] {
            XCTAssertFalse(encoded.contains(privateValue),
                           "UserDefaults payload leaked runtime conversation data")
        }

        let decoded = try JSONDecoder().decode([String: SecondaryRoster].self, from: payload)
        let row = try XCTUnwrap(decoded["lab"]?.profiles.first)
        XCTAssertTrue(row.preview.isEmpty)
        XCTAssertNil(row.activityPreview)
        XCTAssertNil(row.pinnedChat)
        XCTAssertNil(row.preferredSessionID)
        XCTAssertEqual(row.title, "Safe cosmetic")
        XCTAssertEqual(row.rawDisplayName, "Safe identity")
        XCTAssertEqual(row.job, "Safe job")
        XCTAssertEqual(row.shape, .hexagon)
        XCTAssertEqual(row.hue, .violet)
        XCTAssertEqual(row.lastActive, 123)
        XCTAssertEqual(decoded["lab"]?.freshness, .fresh)
    }

    func testFriendlyAliasesPreserveSeparatorsFilterReservedAndRequireRenameMetadata() {
        XCTAssertEqual(BotMention.friendlyForms(from: "Code_Review-2"), ["code_review-2"])
        XCTAssertEqual(BotMention.friendlyForms(from: "A ll"), ["a-ll"])
        XCTAssertEqual(BotMention.friendlyForms(from: "Her mes"), ["her-mes"])
        XCTAssertTrue(BotMention.friendlyForms(from: "_private").isEmpty)
        let generic = Bot(id: "code_review", job: "", shape: .circle, hue: .green)
        XCTAssertTrue(generic.friendlyMentionNames.isEmpty)
        XCTAssertFalse(generic.mentionForms.contains("codereview"))
        XCTAssertTrue(generic.mentionForms.contains("code_review"))
    }

    private func profile(name: String, displayName: String? = nil,
                         last: JSONValue? = nil, preferred: JSONValue? = nil,
                         worker: JSONValue? = nil, meta: JSONValue? = nil) -> HermesProfile {
        var raw: [String: JSONValue] = ["name": .string(name)]
        if let displayName { raw["display_name"] = .string(displayName) }
        if let last { raw["last_session"] = last }
        if let preferred { raw["preferred_session"] = preferred }
        if let worker { raw["worker_session"] = worker }
        if let meta { raw["ui_meta"] = meta }
        return HermesProfile(.object(raw))
    }

    private func session(id: String, resolvedID: String? = nil,
                         title: String? = nil, rootTitle: String? = nil,
                         preview: String? = nil,
                         lastActive: Double? = nil,
                         messageCount: Int? = nil) -> JSONValue {
        var raw: [String: JSONValue] = ["id": .string(id)]
        if let resolvedID { raw["resolved_id"] = .string(resolvedID) }
        if let title { raw["title"] = .string(title) }
        if let rootTitle { raw["root_title"] = .string(rootTitle) }
        if let preview { raw["preview"] = .string(preview) }
        if let lastActive { raw["last_active"] = .number(lastActive) }
        if let messageCount { raw["message_count"] = .number(Double(messageCount)) }
        return .object(raw)
    }
}
#endif

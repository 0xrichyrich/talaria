#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class RoomEngineTests: XCTestCase {
    private let alpha = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default"),
                                   title: "Hermes Prime", handle: "hermes", sourceLabel: "Mini")
    private let beta = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "research_lead"),
                                  title: "Research Lead", handle: "research.lead", sourceLabel: "Lab")
    private let gamma = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "ops"),
                                   title: "Operations", handle: "ops")

    func testRoomIdentityAndRouteIdentityRoundTrip() throws {
        let id = RoomID()
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: alpha.route, epoch: 7,
                                  promptText: "exact room prompt", storedSessionID: "stored-a",
                                  runtimeSessionID: "runtime-a",
                                  state: .uncertain)
        let waiting = RoomAttempt(threadID: thread.id, member: beta.route, epoch: 7,
                                  promptText: "wait safely", storedSessionID: "stored-b",
                                  runtimeSessionID: "runtime-b", state: .waiting)
        let room = RoomRecord(id: id, name: "Launch", members: [alpha, beta],
                              threads: [thread], attempts: [attempt, waiting],
                              drives: [RoomDriveState(threadID: thread.id, epoch: 7,
                                                     round: 1, roundMembers: [beta.route],
                                                     nextMemberIndex: 1,
                                                     posted: 2, roundStartPosted: 1,
                                                     status: .running)])
        let restored = try JSONDecoder().decode(RoomRecord.self,
                                                from: JSONEncoder().encode(room))
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.members.map(\.route), [alpha.route, beta.route])
        XCTAssertEqual(restored.attempts.first?.id, attempt.id)
        XCTAssertEqual(restored.attempts.first?.state, .uncertain)
        XCTAssertEqual(restored.attempts.first?.promptAnchor, RoomAttempt.anchor(for: attempt.id))
        XCTAssertEqual(restored.attempts.first?.promptHash, RoomAttempt.hash("exact room prompt"))
        XCTAssertEqual(restored.attempts.first?.storedSessionID, "stored-a")
        XCTAssertEqual(restored.attempts.last?.state, .waiting)
        XCTAssertNoThrow(try RoomEngine.validate(restored))
        XCTAssertEqual(restored.drives.first?.roundStartPosted, 1)
        XCTAssertEqual(restored.drives.first?.roundMembers, [beta.route])
        XCTAssertEqual(RoomEngine.watermarkKey(threadID: thread.id, member: beta.route),
                       "\(thread.id.rawValue.uuidString.lowercased())::lab::research_lead")
    }

    func testTamperedAttemptIdentityFailsValidation() throws {
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: alpha.route, epoch: 1,
                                  promptText: "do the exact work", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", stagedImagePaths: ["queued/image.png"],
                                  state: .accepted, baselineMessageCount: 4)
        let room = RoomRecord(name: "Exact", members: [alpha, beta], threads: [thread],
                              attempts: [attempt])
        let encoded = try JSONEncoder().encode(room)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var attempts = try XCTUnwrap(object["attempts"] as? [[String: Any]])
        attempts[0]["promptHash"] = String(repeating: "0", count: 64)
        object["attempts"] = attempts
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RoomRecord.self, from: tampered)
        XCTAssertThrowsError(try RoomEngine.validate(decoded))
    }

    func testAttemptAttachmentSnapshotMigratesAndFinishedWorkMustReleaseIt() throws {
        let thread = RoomThread()
        let attachment = RoomAttachment(blobID: "blob", fileName: "image.png",
                                        mediaType: "image/png", byteCount: 3,
                                        contentHash: RoomAttachment.hash(Data([1, 2, 3])))
        let attempt = RoomAttempt(threadID: thread.id, member: alpha.route, epoch: 1,
                                  promptText: "with exact image", storedSessionID: "stored",
                                  runtimeSessionID: "runtime",
                                  outboundAttachments: [attachment], state: .waiting)
        let room = RoomRecord(name: "Payload", members: [alpha, beta], threads: [thread],
                              attempts: [attempt], epoch: 1)
        XCTAssertNoThrow(try RoomEngine.validate(room))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(attempt)) as? [String: Any])
        object.removeValue(forKey: "outboundAttachments")
        let legacy = try JSONDecoder().decode(RoomAttempt.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.outboundAttachments, [])

        var terminal = room
        terminal.attempts[0].state = .cancelled
        terminal.attempts[0].finishedAt = Date()
        XCTAssertThrowsError(try RoomEngine.validate(terminal)) {
            XCTAssertEqual($0 as? RoomValidationError, .invalidAttempt)
        }
        terminal.attempts[0].outboundAttachments = []
        XCTAssertNoThrow(try RoomEngine.validate(terminal))
    }

    func testFormerMemberKeepsHistoryButCannotOwnUnfinishedWork() throws {
        let thread = RoomThread()
        let finished = RoomAttempt(threadID: thread.id, member: gamma.route, epoch: 1,
                                   promptText: "historic", storedSessionID: "stored",
                                   runtimeSessionID: "runtime", state: .replied,
                                   finishedAt: Date())
        let historic = RoomEntry(threadID: thread.id, speaker: .member,
                                 memberRoute: gamma.route, speakerName: "Operations",
                                 text: "past answer")
        let room = RoomRecord(name: "History", members: [alpha, beta], formerMembers: [gamma],
                              threads: [thread], entries: [historic], attempts: [finished])
        XCTAssertNoThrow(try RoomEngine.validate(room))

        let waiting = RoomAttempt(threadID: thread.id, member: gamma.route, epoch: 1,
                                  promptText: "new work", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .waiting)
        var invalid = room
        invalid.attempts.append(waiting)
        XCTAssertThrowsError(try RoomEngine.validate(invalid)) {
            XCTAssertEqual($0 as? RoomValidationError, .invalidAttempt)
        }
    }

    func testMemberCountAndDuplicateRoutesFailClosed() {
        XCTAssertThrowsError(try RoomEngine.validate(RoomRecord(name: "One", members: [alpha]))) {
            XCTAssertEqual($0 as? RoomValidationError, .memberCount(1))
        }
        let seven = (0..<7).map {
            RoomMember(route: GatewayBotRoute(gatewayID: "g", profile: "p\($0)"))
        }
        XCTAssertThrowsError(try RoomEngine.validate(RoomRecord(name: "Seven", members: seven)))
        XCTAssertThrowsError(try RoomEngine.validate(RoomRecord(name: "Duplicate", members: [alpha, alpha]))) {
            XCTAssertEqual($0 as? RoomValidationError, .duplicateMember(alpha.route))
        }
        let unsafeHandle = RoomMember(route: GatewayBotRoute(gatewayID: "g", profile: "safe"),
                                      handle: "not mentionable")
        XCTAssertThrowsError(try RoomEngine.validate(
            RoomRecord(name: "Unsafe", members: [alpha, unsafeHandle])
        )) { XCTAssertEqual($0 as? RoomValidationError, .invalidRoute) }
        XCTAssertNoThrow(try RoomEngine.validate(RoomRecord(name: "Six", members: Array(seven.prefix(6)))))
        let overActivity = (0...RoomEngine.activityLimit).map {
            RoomActivity(epoch: 0, kind: .working, at: Date(timeIntervalSince1970: Double($0)))
        }
        XCTAssertThrowsError(try RoomEngine.validate(
            RoomRecord(name: "Unbounded", members: [alpha, beta], activity: overActivity)
        )) { XCTAssertEqual($0 as? RoomValidationError, .invalidBound) }
    }

    func testPassGrammarMatchesHermes() {
        for value in ["", "  ", "pass", "PASS", "(pass)", "pass.", " ( pass ). "] {
            XCTAssertTrue(RoomEngine.isPass(value), value)
        }
        for value in ["pass please", "bypass", "(passed)", "I pass"] {
            XCTAssertFalse(RoomEngine.isPass(value), value)
        }
    }

    func testMentionFormsAndSpecialTokens() {
        let members = [alpha, beta, gamma]
        let exact = RoomEngine.parseMentions("Ask @research.lead and @ops", members: members)
        XCTAssertEqual(exact.mentioned, [beta.route, gamma.route])
        XCTAssertEqual(RoomEngine.parseMentions("@research", members: members).mentioned, [beta.route])
        XCTAssertEqual(RoomEngine.parseMentions("@research-lead", members: members).mentioned, [beta.route])
        XCTAssertTrue(RoomEngine.parseMentions("hello @everyone", members: members).everyone)
        XCTAssertTrue(RoomEngine.parseMentions("hello @all", members: members).everyone)
        XCTAssertTrue(RoomEngine.parseMentions("@user decide", members: members).mentioned.isEmpty)
    }

    func testAmbiguousMentionFormsFailClosedButQualifiedHandlesResolve() {
        let mini = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "ops"),
                              title: "Operations", handle: "ops-mini")
        let lab = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "ops"),
                             title: "Operations", handle: "ops-lab")
        let members = [mini, lab]
        let ambiguous = RoomEngine.parseMentions("@ops and @operations", members: members)
        XCTAssertTrue(ambiguous.ambiguous)
        XCTAssertTrue(ambiguous.mentioned.isEmpty)
        XCTAssertEqual(RoomEngine.parseMentions("@ops-mini", members: members).mentioned,
                       [mini.route])
        XCTAssertEqual(RoomEngine.parseMentions("@ops-lab", members: members).mentioned,
                       [lab.route])

        let thread = RoomThread()
        let entry = RoomEntry(threadID: thread.id, speaker: .user,
                              speakerName: "You", text: "@ops investigate")
        XCTAssertTrue(RoomEngine.responders(entries: [entry], members: members,
                                            threadID: thread.id).isEmpty)
    }

    func testResponderSelectionRecomputesSinceLastUserAndRotates() {
        let members = [alpha, beta, gamma]
        let thread = RoomThread()
        let old = RoomEntry(threadID: thread.id, speaker: .member, memberRoute: gamma.route,
                            speakerName: "ops", text: "@hermes old")
        XCTAssertEqual(RoomEngine.responders(entries: [old], members: members,
                                             threadID: thread.id).map(\.route),
                       members.map(\.route))
        let user = RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                             text: "@research take this")
        XCTAssertEqual(RoomEngine.responders(entries: [old, user], members: members,
                                             threadID: thread.id).map(\.route), [beta.route])
        let pull = RoomEntry(threadID: thread.id, speaker: .member, memberRoute: beta.route,
                             speakerName: "research", text: "@ops can verify")
        XCTAssertEqual(RoomEngine.responders(entries: [old, user, pull], members: members,
                                             threadID: thread.id).map(\.route), [beta.route, gamma.route])

        let broad = RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "hello")
        XCTAssertEqual(RoomEngine.scheduledResponders(entries: [broad], members: members,
                                                      threadID: thread.id, round: 1, posted: 0).map(\.route),
                       [beta.route, gamma.route, alpha.route])
        XCTAssertTrue(RoomEngine.scheduledResponders(entries: [broad], members: members,
                                                     threadID: thread.id, round: 3, posted: 0).isEmpty)
        XCTAssertTrue(RoomEngine.scheduledResponders(entries: [broad], members: members,
                                                     threadID: thread.id, round: 0, posted: 10).isEmpty)
    }

    func testLegacyThreadsUseFifteenMinuteLullAndStableEntryIdentity() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = RoomEntryID()
        let thirdID = RoomEntryID()
        var room = RoomRecord(name: "Legacy", members: [alpha, beta], entries: [
            RoomEntry(id: firstID, speaker: .user, speakerName: "You", text: "one", at: base),
            RoomEntry(speaker: .member, memberRoute: alpha.route, speakerName: "Hermes",
                      text: "two", at: base.addingTimeInterval(899)),
            RoomEntry(id: thirdID, speaker: .user, speakerName: "You", text: "three",
                      at: base.addingTimeInterval(1_800)),
        ])
        XCTAssertTrue(RoomEngine.migrateLegacyThreads(in: &room))
        XCTAssertEqual(room.threads.count, 2)
        XCTAssertEqual(room.entries[0].threadID, room.entries[1].threadID)
        XCTAssertNotEqual(room.entries[1].threadID, room.entries[2].threadID)
        XCTAssertEqual(room.entries[0].threadID?.rawValue, firstID.rawValue)
        XCTAssertEqual(room.entries[2].threadID?.rawValue, thirdID.rawValue)
        XCTAssertFalse(RoomEngine.migrateLegacyThreads(in: &room))
        XCTAssertNoThrow(try RoomEngine.validate(room))
    }

    func testCurrentEpochActivityIsBoundedToFifty() {
        var room = RoomRecord(name: "Work", members: [alpha, beta],
                              activity: [RoomActivity(epoch: 3, kind: .failed)], epoch: 4)
        RoomEngine.recordActivity(RoomActivity(epoch: 3, kind: .delivered), in: &room)
        XCTAssertTrue(room.activity.isEmpty) // stale rows and stale event are both dropped
        for _ in 0..<55 {
            RoomEngine.recordActivity(RoomActivity(epoch: 4, kind: .working), in: &room)
        }
        XCTAssertEqual(room.activity.count, 50)
        XCTAssertTrue(room.activity.allSatisfy { $0.epoch == 4 })
    }

    func testCanonicalGroupsPrecedeLegacyAndProjectionIsOrdered() {
        let canonical = JSONValue.object(["hermes-bots": .object([
            "groups": .array([.string(" A "), .string("B"), .string("A"), .number(4)]),
            "group": .string("legacy"),
        ])])
        XCTAssertEqual(BotModeMeta(uiMeta: canonical)?.groups, ["A", "B"])
        let emptyCanonical = JSONValue.object(["hermes-bots": .object([
            "groups": .string("bad"), "group": .string("legacy"),
        ])])
        XCTAssertEqual(BotModeMeta(uiMeta: emptyCanonical)?.groups, ["legacy"])
        let legacy = JSONValue.object(["hermes-bots": .object(["group": .string(" old ")])])
        XCTAssertEqual(BotModeMeta(uiMeta: legacy)?.groups, ["old"])

        let projection = BotModeMeta.membershipProjection([" First ", "Second", "First", ""])
        XCTAssertEqual(projection["groups"], .array([.string("First"), .string("Second")]))
        XCTAssertEqual(projection["group"], .string("First"))
        XCTAssertEqual(BotModeMeta.membershipProjection([])["group"], .null)
    }

    func testPartialThreadMigrationContinuesExistingThreadAndRepairsSummary() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let threadID = RoomThreadID()
        var room = RoomRecord(name: "Partial", members: [alpha, beta],
                              threads: [RoomThread(id: threadID,
                                                   createdAt: base.addingTimeInterval(10),
                                                   lastActivityAt: base.addingTimeInterval(600))],
                              entries: [
                                RoomEntry(threadID: threadID, speaker: .user,
                                          speakerName: "You", text: "one", at: base),
                                RoomEntry(speaker: .member, memberRoute: alpha.route,
                                          speakerName: "Hermes", text: "two",
                                          at: base.addingTimeInterval(60)),
                              ])

        XCTAssertTrue(RoomEngine.migrateLegacyThreads(in: &room))
        XCTAssertEqual(room.entries[1].threadID, threadID)
        XCTAssertEqual(room.threads.count, 1)
        XCTAssertEqual(room.threads[0].createdAt, base)
        XCTAssertEqual(room.threads[0].lastActivityAt, base.addingTimeInterval(60))
        XCTAssertFalse(RoomEngine.migrateLegacyThreads(in: &room))
        XCTAssertNoThrow(try RoomEngine.validate(room))
    }
}
#endif

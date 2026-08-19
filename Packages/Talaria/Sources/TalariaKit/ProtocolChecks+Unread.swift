import Foundation

// Unread watermarks — desktop `trackInboundActivity` (plugin.js:86-150), pinned.
//
// Not a wire protocol but a parity contract, and the kind that fails silently in
// the direction nobody notices: a watermark bug does not crash, it just makes
// the roster quietly wrong — either badging everything on every cold launch, or
// badging nothing ever. Both look like "no news" to a reader.
//
// Five rules, each with a wrong version that reads as correct:
//
//   * The FIRST answer from a gateway this phone has never listed raises nothing
//     (plugin.js:92-94), but still records every stamp. Seeding that skipped the
//     recording would badge the whole roster on the second poll instead of the
//     first — later, and therefore harder to spot.
//   * The mark advances BEFORE both guards (plugin.js:120-122). It records what
//     was observed, not what was read.
//   * `max(prev, ts)` — never backwards.
//   * `ts > prev`, strictly. Equal stamps are the common case and are silence.
//   * An empty answer is not a statement. Seeding on one would declare a gateway
//     seen that this phone has not actually listed.
//
// The last check replays three snapshots captured off a live gateway
// (hermes-agent 0.20.3, 2026-08-18, `profiles.list {include_sessions: true}`),
// which is the fixture the model was designed against: one bot moving twice from
// a client that was not this phone, one bot with no `last_session` at all, and
// three bots flat.

extension ProtocolChecks {

    static func unreadWatermarks() throws {
        try unreadSeedsSilently()
        try unreadMarkAdvancesBeforeGuards()
        try unreadIsMonotonic()
        try unreadRequiresStrictAdvance()
        try unreadEmptyAnswerSaysNothing()
        try unreadAcknowledgeClearsTheNextPoll()
        try unreadBoundsAreLeastRecent()
        try unreadSurvivesTheProcess()
        try unreadLiveGatewayReplay()
    }

    // MARK: First sight of a gateway (plugin.js:92-94)

    private static func unreadSeedsSilently() throws {
        let first = UnreadWatermarks.fold(UnreadWatermarkScope(),
                                          activity: ["a": 100, "b": 200], now: 1)
        try expect(first.moved.isEmpty, "the first answer from an unseen gateway badges nobody")
        try expect(first.scope.seeded, "…and marks the gateway seen")
        // The recording is the point: a seed that skipped it would badge the
        // whole roster one poll later instead of never.
        try expect(first.scope.marks == ["a": 100, "b": 200],
                   "…while recording every stamp it just declared read")

        let second = UnreadWatermarks.fold(first.scope,
                                           activity: ["a": 100, "b": 201], now: 2)
        try expect(second.moved == ["b"], "the second answer diffs against what the first recorded")
    }

    // MARK: The mark is what was OBSERVED, not what was read (plugin.js:120-122)

    private static func unreadMarkAdvancesBeforeGuards() throws {
        let seeded = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: ["a": 100], now: 1).scope

        // Spared: no badge, but the stamp is still recorded.
        let spared = UnreadWatermarks.fold(seeded, activity: ["a": 500], spared: ["a"], now: 2)
        try expect(spared.moved.isEmpty, "a spared bot does not badge")
        try expect(spared.scope.marks["a"] == 500,
                   "…but its mark still advances, or leaving the chat badges the reply just read")

        let after = UnreadWatermarks.fold(spared.scope, activity: ["a": 500], now: 3)
        try expect(after.moved.isEmpty, "and the same stamp stays silent once the sparing lifts")
    }

    // MARK: Never backwards

    private static func unreadIsMonotonic() throws {
        let high = UnreadWatermarks.fold(UnreadWatermarkScope(seeded: true), activity: ["a": 900], now: 1)
        try expect(high.moved == ["a"], "an advance past a zero mark badges")
        // A compressed lineage, a restored state.db, or a gateway whose clock
        // stepped back.
        let back = UnreadWatermarks.fold(high.scope, activity: ["a": 100], now: 2)
        try expect(back.moved.isEmpty, "a stamp older than the mark is not news")
        try expect(back.scope.marks["a"] == 900, "…and cannot lower the mark")
        // Negative stamps are floored rather than trusted.
        let negative = UnreadWatermarks.fold(UnreadWatermarkScope(seeded: true),
                                             activity: ["a": -5], now: 3)
        try expect(negative.scope.marks["a"] == 0, "a negative stamp floors to zero")
        try expect(negative.moved.isEmpty, "…and never badges")
    }

    // MARK: Strictly greater

    private static func unreadRequiresStrictAdvance() throws {
        let seeded = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: ["a": 100], now: 1).scope
        let repeated = UnreadWatermarks.fold(seeded, activity: ["a": 100], now: 2)
        try expect(repeated.moved.isEmpty, "an unchanged stamp is silence, not news")

        // A bot with no `last_session` reads 0 and can never badge, however many
        // times it is polled.
        var scope = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: ["quiet": 0], now: 1).scope
        for tick in 2...5 {
            let fold = UnreadWatermarks.fold(scope, activity: ["quiet": 0], now: Double(tick))
            try expect(fold.moved.isEmpty, "a bot with no session never badges (poll \(tick))")
            scope = fold.scope
        }
    }

    // MARK: An empty answer is not a statement

    private static func unreadEmptyAnswerSaysNothing() throws {
        let empty = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: [:], now: 1)
        try expect(!empty.scope.seeded,
                   "a torn-down or re-scoping roster must not declare a gateway seen")
        try expect(empty.moved.isEmpty, "…and raises nothing")

        // A roster answer that omits a row keeps that row's mark: upstream drops
        // one only when the profile is deleted (plugin.js:564), and a zeroed mark
        // would badge the bot's entire history when it came back.
        let both = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: ["a": 100, "b": 200], now: 1)
        let partial = UnreadWatermarks.fold(both.scope, activity: ["a": 100], now: 2)
        try expect(partial.scope.marks["b"] == 200, "a row missing from one answer keeps its mark")
        let restored = UnreadWatermarks.fold(partial.scope, activity: ["a": 100, "b": 200], now: 3)
        try expect(restored.moved.isEmpty, "…so its return is not mistaken for new activity")
    }

    // MARK: Acknowledging (plugin.js:3915-3918)

    private static func unreadAcknowledgeClearsTheNextPoll() throws {
        let seeded = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: ["a": 100], now: 1).scope
        // The user opens the chat between polls: the mark jumps to the newest
        // activity this phone has observed, without waiting for a round trip.
        let acked = UnreadWatermarks.acknowledge("a", observed: 400, in: seeded, now: 2)
        try expect(acked.marks["a"] == 400, "acknowledge advances to what was observed")
        let next = UnreadWatermarks.fold(acked, activity: ["a": 400], now: 3)
        try expect(next.moved.isEmpty, "…so the next poll does not re-raise what was just read")

        // It never lowers: an acknowledge carrying a stale observation cannot
        // resurrect traffic the mark has already passed.
        let stale = UnreadWatermarks.acknowledge("a", observed: 10, in: acked, now: 4)
        try expect(stale.marks["a"] == 400, "acknowledge is monotonic too")
    }

    // MARK: Bounds

    private static func unreadBoundsAreLeastRecent() throws {
        var activity: [String: Double] = [:]
        for index in 0..<(UnreadWatermarks.markLimit + 20) {
            activity["bot-\(index)"] = Double(index + 1)
        }
        let folded = UnreadWatermarks.fold(UnreadWatermarkScope(seeded: true),
                                           activity: activity, now: 1)
        try expect(folded.scope.marks.count == UnreadWatermarks.markLimit,
                   "marks are capped at markLimit")
        try expect(folded.scope.marks["bot-0"] == nil, "the oldest stamp is the one dropped")
        try expect(folded.scope.marks["bot-\(UnreadWatermarks.markLimit + 19)"] != nil,
                   "…and the newest survives")

        var scopes: [String: UnreadWatermarkScope] = [:]
        for index in 0..<(UnreadWatermarks.scopeLimit + 3) {
            scopes["gw-\(index)"] = UnreadWatermarkScope(seeded: true, marks: [:],
                                                         touched: Double(index))
        }
        let kept = UnreadWatermarks.evict(scopes)
        try expect(kept.count == UnreadWatermarks.scopeLimit, "gateways are capped at scopeLimit")
        try expect(kept["gw-0"] == nil, "the least recently seen gateway is evicted")
        try expect(kept["gw-\(UnreadWatermarks.scopeLimit + 2)"] != nil,
                   "…and the most recent is kept")
    }

    // MARK: The phone that was asleep

    /// The case the whole model exists for, end to end: marks are written,
    /// the process dies, the scope comes back off disk, and traffic that landed
    /// in between badges from ONE poll.
    ///
    /// The persisted round trip is the part that is easy to get wrong quietly.
    /// `seeded` travels with the marks on purpose (see `UnreadWatermarkScope`),
    /// and a Codable change that dropped it would leave every cold launch
    /// re-seeding — which looks exactly like a calm roster and is in fact the
    /// entire backlog being declared read, once per launch, forever.
    private static func unreadSurvivesTheProcess() throws {
        // Session one: first sight, then a quiet poll.
        let first = UnreadWatermarks.fold(UnreadWatermarkScope(),
                                          activity: ["default": 100, "ez-qa": 200], now: 1)
        let quiet = UnreadWatermarks.fold(first.scope,
                                          activity: ["default": 100, "ez-qa": 200], now: 2)
        try expect(quiet.moved.isEmpty, "nothing moved before the phone slept")

        // The process dies. Everything the next launch knows comes through here.
        let encoded = try JSONEncoder().encode(quiet.scope)
        let restored = try JSONDecoder().decode(UnreadWatermarkScope.self, from: encoded)
        try expect(restored == quiet.scope, "the scope round-trips through storage intact")
        try expect(restored.seeded,
                   "…seeding included, or every cold launch declares the backlog read")

        // Session two, hours later. A cron run and a laptop turn happened while
        // the screen was off; the first poll after launch is the only thing that
        // could ever have seen them.
        let wake = UnreadWatermarks.fold(restored,
                                         activity: ["default": 900, "ez-qa": 200], now: 3)
        try expect(wake.moved == ["default"],
                   "one poll after a cold launch catches what happened while the phone slept")

        // …and it is caught exactly once. A second poll restating the same
        // stamp is silence, which is what keeps a 10 s timer from re-raising a
        // badge the user just cleared.
        let settled = UnreadWatermarks.fold(wake.scope,
                                            activity: ["default": 900, "ez-qa": 200], now: 4)
        try expect(settled.moved.isEmpty, "…and the refresh after it says nothing new")

        // Clearing is deliberate. Reading the chat advances the mark; a refresh
        // on its own never does, which is the property that makes a badge mean
        // "you have not seen this" rather than "this app has not polled yet".
        let read = UnreadWatermarks.acknowledge("default", observed: 900,
                                                in: settled.scope, now: 5)
        let after = UnreadWatermarks.fold(read, activity: ["default": 900, "ez-qa": 200], now: 6)
        try expect(after.moved.isEmpty, "an opened chat stays clear across the next refresh")
        let later = UnreadWatermarks.fold(after.scope,
                                          activity: ["default": 1000, "ez-qa": 200], now: 7)
        try expect(later.moved == ["default"], "…and the next real delivery badges again")
    }

    // MARK: Replay of a real gateway

    /// Three consecutive `profiles.list {include_sessions: true}` answers,
    /// captured 2026-08-18 off hermes-agent 0.20.3. `ez-qa` moved twice inside
    /// four minutes from a client that was not this phone; `default`'s newest
    /// line was a cron delivery; `code-review` had no `last_session` at all.
    /// Nothing else moved.
    private static func unreadLiveGatewayReplay() throws {
        let poll1: [String: Double] = [
            "default": 1787085050.329278,
            "code-review": 0,            // no last_session on any of the 12 polls
            "deepseek": 1787018593.668624,
            "ez-qa": 1787085212.957258,
            "simmy": 1786902827.011681,
        ]
        var poll2 = poll1; poll2["ez-qa"] = 1787085312.02232
        var poll3 = poll2; poll3["ez-qa"] = 1787085321.234668

        let first = UnreadWatermarks.fold(UnreadWatermarkScope(), activity: poll1, now: 1)
        try expect(first.moved.isEmpty, "cold launch against this gateway badges nobody")

        let second = UnreadWatermarks.fold(first.scope, activity: poll2, now: 2)
        try expect(second.moved == ["ez-qa"], "only the bot that actually moved badges")

        let third = UnreadWatermarks.fold(second.scope, activity: poll3, now: 3)
        try expect(third.moved == ["ez-qa"], "…and it badges again on its second move")

        // The cron delivery on `default` is exactly the traffic no event-derived
        // count on this device would ever have seen — so it has to badge the
        // moment it moves, from the poll alone.
        var poll4 = poll3; poll4["default"] = 1787085400
        let fourth = UnreadWatermarks.fold(third.scope, activity: poll4, now: 4)
        try expect(fourth.moved == ["default"], "a cron delivery badges from the roster poll alone")

        // …unless the user is reading it, which is the one exclusion upstream has
        // (plugin.js:129-132).
        var poll5 = poll4; poll5["default"] = 1787085500
        let fifth = UnreadWatermarks.fold(fourth.scope, activity: poll5,
                                          spared: ["default"], now: 5)
        try expect(fifth.moved.isEmpty, "the chat on screen is never badged")
        try expect(fifth.scope.marks["default"] == 1787085500,
                   "…and reading it still advances the mark")

        try expect(third.scope.marks["code-review"] == 0,
                   "a bot with no last_session holds a zero mark throughout")
        try expect(third.scope.marks["simmy"] == 1786902827.011681,
                   "a flat bot's mark is its one stamp, unchanged")
    }
}

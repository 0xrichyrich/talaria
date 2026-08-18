import Foundation

// Roster search — desktop `filterBots` (plugin.js:2960-2981), pinned.
//
// Not a wire protocol but a parity contract, and one that drifts silently: it
// is four one-line predicates and an ordering promise, all of which look
// optional until the day "@hermes" returns nothing or the list reshuffles
// under a thumb. Upstream guards the same rules with `tests/bots-search.test.mjs`
// (BOT-MODE-PARITY §4.9); this is that test, in Swift, on every build.
//
// The three rules worth naming, because each has a wrong version that looks
// right:
//
//   * ONE leading '@' comes off, not all of them (2964) — "@@ops" is a search
//     for a bot literally called "@ops", not for "ops".
//   * The needle matches FOUR fields and no others (2971-2976). `job` and the
//     preview line are excluded upstream on purpose: a preview changes every
//     time the bot speaks, so matching it makes results move while you read.
//   * Filtering NEVER re-ranks (2961-2962). The surviving rows keep the order
//     the roster handed over — pinned first, then recency (Phase B).

extension ProtocolChecks {

    static func rosterSearchSemantics() throws {
        try rosterSearchNeedle()
        try rosterSearchFields()
        try rosterSearchNarrowsWithoutReRanking()
    }

    // MARK: Needle construction (plugin.js:2964)

    private static func rosterSearchNeedle() throws {
        try expect(RosterSearch.needle("  Hermes  ") == "hermes", "needle is trimmed and lowercased")
        try expect(RosterSearch.needle("@hermes") == "hermes", "one leading @ comes off")
        try expect(RosterSearch.needle("@Hermes") == "hermes", "@ strip happens after lowercasing")
        try expect(RosterSearch.needle(" @hermes ") == "hermes", "trim then strip, in that order")
        // `String.replace(/^@/, '')` removes exactly one character.
        try expect(RosterSearch.needle("@@ops") == "@ops", "only ONE @ is stripped")
        // Mid-token '@' is not an anchor: "a@b" is a search for "a@b".
        try expect(RosterSearch.needle("ci@homelab") == "ci@homelab", "only a LEADING @ is stripped")
        try expect(RosterSearch.needle("   ") == "", "whitespace-only query is an empty needle")
        try expect(RosterSearch.needle("@") == "", "a bare @ is an empty needle, not a dead one")
    }

    // MARK: The four fields (plugin.js:2971-2976)

    private static func rosterSearchFields() throws {
        // A desktop-titled bot: the visible name and the profile id differ, so
        // the display-name field is the only one that can find it by sight.
        let titled = Bot(id: "sound-studio-2", job: "audio", shape: .circle, hue: .teal,
                         preview: "rendered the stems", title: "Sound Studio")
        try expect(titled.matchesRosterSearch("sound studio"), "display name matches (2971)")
        try expect(titled.matchesRosterSearch("studio"), "display name matches on a SUBSTRING, not a prefix")
        try expect(titled.matchesRosterSearch("studio-2"), "raw profile id matches (2972)")

        // The primary profile: named `default`, presents as Hermes/@hermes.
        // Both the word people see and the word they type must find it.
        let primary = Bot(id: "default", job: "chief of staff", shape: .circle, hue: .teal)
        try expect(primary.displayTitle == "Hermes" && primary.handle == "hermes",
                   "the primary profile reads Hermes/@hermes")
        try expect(primary.matchesRosterSearch(RosterSearch.needle("@hermes")),
                   "typing @hermes finds the profile named default (2964 + 2973)")
        try expect(primary.matchesRosterSearch("hermes"), "so does typing it bare")
        try expect(primary.matchesRosterSearch("default"), "and so does the raw profile id")

        // A multi-gateway duplicate carries its precomputed `name-device`
        // handle (connection-registry.ts:137); the handle field must see it.
        let disambiguated = Bot(id: "default", job: "", shape: .circle, hue: .teal,
                                handleOverride: "default-homelab")
        try expect(disambiguated.matchesRosterSearch("default-homelab"),
                   "the name-device handle matches (2973)")

        // The device label — "homelab finds every bot living on the Homelab
        // connection" (2974-2976). It is passed in, not carried by the profile.
        try expect(titled.matchesRosterSearch("homelab", connectionLabel: "Homelab"),
                   "connection label matches, case-insensitively (2976)")
        try expect(!titled.matchesRosterSearch("homelab"),
                   "with no label supplied there is nothing to match")

        // Fields desktop deliberately does NOT search. Only the four locals
        // above exist in the filter body.
        try expect(!titled.matchesRosterSearch("audio"), "job/description is NOT a match field")
        try expect(!titled.matchesRosterSearch("stems"), "the preview line is NOT a match field")

        // The identity that makes filterBots a no-op rather than a blank list.
        try expect(titled.matchesRosterSearch(""), "an empty needle matches everything")
    }

    // MARK: Narrowing, never re-ranking (plugin.js:2961-2968)

    private static func rosterSearchNarrowsWithoutReRanking() throws {
        func bot(_ id: String, title: String? = nil) -> Bot {
            Bot(id: id, job: "", shape: .circle, hue: .teal, title: title)
        }
        // Deliberately NOT alphabetical: this is the shape `rankedBots` hands
        // over — pinned first, then recency. Anything that sorts inside the
        // filter shows up here. `press-office` leads on purpose: its match is
        // mid-string, and it sits ahead of two rows that match at the start.
        let roster = [bot("press-office"), bot("zeta"), bot("default"), bot("researcher"),
                      bot("res-copy", title: "Researcher Two"), bot("alpha")]

        let unfiltered = roster.filterBots(needle: "")
        try expect(unfiltered.map(\.id) == roster.map(\.id),
                   "an empty needle returns the roster untouched, in order (2966-2968)")

        let hits = roster.filterBots(needle: "res")
        try expect(hits.map(\.id) == ["press-office", "researcher", "res-copy"],
                   "survivors keep the roster's order — search narrows, it never re-ranks")
        // No scoring and no prefix bonus: the mid-string hit stays ahead of the
        // two prefix hits because that is where the roster put it.
        try expect(hits.first?.id == "press-office",
                   "a mid-string match is NOT demoted below prefix matches")
        // The alphabetical answer, and the wrong one. Pinned in case someone
        // reaches for `sorted()` while "improving" the filter.
        try expect(hits.map(\.id) != roster.filterBots(needle: "res").map(\.id).sorted(),
                   "results are NOT re-sorted by name")

        try expect(roster.filterBots(needle: "nobody").isEmpty,
                   "a needle nothing matches narrows to nothing (the no-match state)")

        // The device label applies to the whole array, the way desktop
        // annotates every row from one source (plugin.js:2337).
        try expect(roster.filterBots(needle: "spark", connectionLabel: "Spark").count == roster.count,
                   "a connection-label needle lists everything on that connection")
    }
}

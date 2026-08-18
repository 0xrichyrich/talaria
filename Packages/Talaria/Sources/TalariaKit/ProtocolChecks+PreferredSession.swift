import Foundation

// The `preferred_session` tri-state, pinned to observed wire shapes.
//
// This check exists because the distinction it guards cannot be exercised
// against the gateway the app actually talks to today. Verified 2026-08-18
// against the maintainer's live gateway (0.20.3, `/api/ws`): `profiles.list`
// returns rows keyed exactly `name, path, is_default, model, provider,
// description, skill_count, last_session, ui_meta, has_avatar` — byte-identical
// with and without `preferred_session_ids`, and identical again when the pin
// sent is a session id that does not exist. That backend simply has no
// `preferred_session` handler (`grep -c preferred_session
// tui_gateway/methods_profiles.py` → 0), so only the *absent* branch is
// reachable live, and absent is the branch that must never be read as "the pin
// is dead".
//
// The other two branches are pinned here from the real shapes upstream's
// `_preferred_session_row` (tui_gateway/methods_profiles.py:63-130) produces,
// captured by running that function's own body against the maintainer's real
// per-profile `state.db` on the same date:
//
//   default      / 20260815_133046_e88359 → a full row, resolved_id == id
//   code-review  / 20260812_231043_5987e7 → a full row for a profile whose
//                                           `last_session` comes back **null**
//   default      / 00000000_000000_deadbe → None, i.e. JSON `null`
//
// The `code-review` case is the one that justifies the whole round trip: that
// profile's roster row carries no `last_session` at all, so without the pin it
// previews nothing while the pinned conversation it opens has 36 messages.

extension ProtocolChecks {

    static func preferredSessionParsing() throws {
        // 1. Absent — today's live answer. The pin is innocent.
        let older = """
        {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
         "model":"gpt-5.6-sol","provider":"openai-codex","description":"",
         "skill_count":125,
         "last_session":{"id":"20260815_133046_e88359","title":"Find new bot option in Hermes",
                         "preview":"Message sent to **@ez-qa** with the full GitHub migration brief.",
                         "started_at":1786818646.81803,"last_active":1787078093.2499032,
                         "message_count":132},
         "ui_meta":{"hermes-bots":{"chat":"20260815_133046_e88359"}},
         "has_avatar":true}
        """
        let absent = HermesProfile(try JSONDecoder().decode(JSONValue.self, from: Data(older.utf8)))
        if case .notRequested = absent.preferredSession {} else {
            throw CheckFailure(description: "FAILED: a missing preferred_session must read as notRequested")
        }
        try expect(!absent.preferredSession.isDefinitivelyGone,
                   "a gateway that ignores preferred_session_ids never declares a pin gone")
        // Nothing to fold: the row keeps last_session's own preview.
        try expect(absent.foldingCanonicalPreview().lastSession?.preview?.hasPrefix("Message sent") == true,
                   "absent preferred_session leaves the row untouched")

        // 2. Resolved — the shape `_preferred_session_row` really returns.
        let resolvedRow = """
        {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
         "skill_count":125,
         "last_session":{"id":"20260815_133046_e88359","title":"Find new bot option in Hermes",
                         "preview":"a scratch session's newest line","started_at":1786818646.81803,
                         "last_active":1787078093.2499032,"message_count":132},
         "preferred_session":{"id":"20260815_133046_e88359",
                              "resolved_id":"20260815_133046_e88359",
                              "title":"Find new bot option in Hermes",
                              "preview":"Message sent to **@ez-qa** with the full GitHub migration brief. I’ll relay its ...",
                              "started_at":1786818646.81803,"last_active":1787078075.3138812,
                              "message_count":132},
         "has_avatar":true}
        """
        let resolved = HermesProfile(try JSONDecoder().decode(JSONValue.self,
                                                              from: Data(resolvedRow.utf8)))
        guard case .resolved(let pinned) = resolved.preferredSession else {
            throw CheckFailure(description: "FAILED: a preferred_session summary must read as resolved")
        }
        try expect(pinned.resolvedID == "20260815_133046_e88359", "resolved_id parses")
        let folded = resolved.foldingCanonicalPreview()
        try expect(folded.lastSession?.preview?.hasPrefix("Message sent") == true,
                   "the pin's preview text folds onto the row")
        // Stamps and ranking stay last_session's — any recent activity from any
        // client means the bot is awake (plugin.js:3852-3858).
        try expect(folded.lastSession?.id == "20260815_133046_e88359"
                    && folded.lastSession?.lastActive == 1787078093.2499032,
                   "the fold moves preview text only, never the row's identity or stamps")
        try expect(resolved.rawLastSession?.preview == "a scratch session's newest line",
                   "rawLastSession keeps the untouched wire value")

        // 3. Resolved onto a row with no `last_session` — the real
        //    `code-review` case, where the pin is the only conversation the row
        //    knows about.
        let onlyPin = """
        {"name":"code-review","path":"/Users/administrator/.hermes/profiles/code-review",
         "is_default":false,"skill_count":104,"last_session":null,
         "preferred_session":{"id":"20260812_231043_5987e7",
                              "resolved_id":"20260812_231043_5987e7",
                              "title":"Audit Zcash dev stack security #2",
                              "preview":"Report written and verified at: /tmp/sol-node-stack-review.md REJECT",
                              "started_at":1786594244.09798,"last_active":1786594731.573319,
                              "message_count":36},
         "ui_meta":{"hermes-bots":{"chat":"20260812_231043_5987e7"}},"has_avatar":true}
        """
        let adopted = HermesProfile(try JSONDecoder().decode(JSONValue.self,
                                                             from: Data(onlyPin.utf8)))
            .foldingCanonicalPreview()
        try expect(adopted.lastSession?.id == "20260812_231043_5987e7",
                   "a row with no last_session previews the pin rather than nothing")
        try expect(adopted.lastSession?.messageCount == 36, "and takes its stamps with it")

        // 4. Null — the ONLY answer allowed to re-anchor a canonical chat.
        let goneRow = """
        {"name":"default","path":"/Users/administrator/.hermes","is_default":true,
         "skill_count":125,"last_session":null,"preferred_session":null,"has_avatar":false}
        """
        let gone = HermesProfile(try JSONDecoder().decode(JSONValue.self, from: Data(goneRow.utf8)))
        try expect(gone.preferredSession.isDefinitivelyGone,
                   "an explicit null is the definitive 'that pin is gone'")
        try expect(gone.foldingCanonicalPreview().lastSession == nil,
                   "a gone pin invents no preview")

        // 5. A malformed summary (no `id`) is not evidence the pin survives.
        //    Treated as gone rather than resolved, because `ProfileSessionRef`
        //    could not name a session to open.
        let malformed = """
        {"name":"default","skill_count":0,"preferred_session":{"title":"no id here"}}
        """
        let broken = HermesProfile(try JSONDecoder().decode(JSONValue.self,
                                                            from: Data(malformed.utf8)))
        try expect(broken.preferredSession.session == nil,
                   "a summary with no id resolves to no session")
    }
}

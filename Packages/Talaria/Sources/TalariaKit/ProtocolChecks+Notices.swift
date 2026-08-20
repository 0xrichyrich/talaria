import Foundation

// Notification copy and routing — desktop Bot Mode's ~30 `host.notify` sites.
//
// BOT-PARITY-PLAN Phase D4. Two different kinds of regression are pinned here
// and they fail in opposite directions:
//
//   * **Routing** silently says the wrong thing. The activity toast picks one of
//     two titles from a regex over the roster preview; get the anchor or the
//     case-folding wrong and every cron delivery announces itself as an inbound
//     DM (or none ever does), with nothing on screen looking broken.
//   * **Copy** silently stops being a port. "Cronjob update failed" drifting to
//     "Couldn't update the routine" reads better and is no longer parity — and
//     the only thing that would ever notice is a check holding the plugin's
//     literal beside it.
//
// Every string below is quoted from plugin.js at the cited line. Changing one
// here is a deliberate act; changing one in `BotModeStrings` alone is a failed
// build.

extension ProtocolChecks {

    static func botModeNotices() throws {
        try activityToastRouting()
        try activityToastTruncation()
        try gatewayAgentNotices()
        try foreverChatGuard()
        try noticeCopyTable()
    }

    // MARK: The inbound test (plugin.js:144)

    private static func activityToastRouting() throws {
        // The prefix Talaria's own A2A path writes (AppModelLive+A2A.swift) is
        // the prefix this classifies, so the two halves of the handoff agree.
        try expect(ActivityNotice.isInbound("Message from 🤖 Hermes (@hermes): ship it"),
                   "the delivery prefix reads as an inbound message")
        try expect(ActivityNotice.isInbound("message from someone"),
                   "…case-insensitively, as /i")
        try expect(ActivityNotice.isInbound("  Message from 🤖 x"),
                   "…after the trim upstream does first (plugin.js:143)")

        // Anchored. A preview that merely mentions one is a bot talking ABOUT a
        // message, which is ordinary activity.
        try expect(!ActivityNotice.isInbound("I got a Message from 🤖 Hermes"),
                   "an unanchored match is not a delivery")
        try expect(!ActivityNotice.isInbound("[Cron delivery: markets-close-wrap] …"),
                   "a cron delivery is generic activity, not an inbound DM")
        try expect(!ActivityNotice.isInbound(""), "an empty preview classifies as generic")
    }

    // MARK: The body (plugin.js:147)

    private static func activityToastTruncation() throws {
        let fallback = BotModeStrings.openTheChat
        try expect(ActivityNotice.body("", fallback: fallback) == fallback,
                   "an empty preview falls back rather than showing a blank card")
        try expect(ActivityNotice.body("   \n ", fallback: fallback) == fallback,
                   "…and so does a whitespace-only one")
        try expect(ActivityNotice.body("ship it", fallback: fallback) == "ship it",
                   "a short preview is passed through whole")

        let long = String(repeating: "x", count: 400)
        try expect(ActivityNotice.body(long, fallback: fallback).count == ActivityNotice.previewLimit,
                   "a long preview is clipped to 140")

        // Grapheme-safe where JS slices UTF-16 units: 140 emoji is 280 units
        // upstream, and a cut mid-pair would render a replacement character.
        // Clipping by character can only ever return fewer, never a broken one.
        let emoji = String(repeating: "🤖", count: 200)
        let clipped = ActivityNotice.body(emoji, fallback: fallback)
        try expect(clipped.count == ActivityNotice.previewLimit, "…counting characters, not units")
        try expect(!clipped.unicodeScalars.contains("\u{FFFD}"),
                   "…and never splitting one in half")

        try expect(ActivityNotice.clip(String(repeating: "y", count: 900),
                                       to: ActivityNotice.replyLimit).count == 500,
                   "a relayed A2A reply clips at 500 (plugin.js:2648)")
    }

    // MARK: Gateway-native notice routing (desktop agent-notices.ts)

    private static func gatewayAgentNotices() throws {
        let sticky = NotificationPayload(.object([
            "text": .string("⚠️ Credit access paused · top up to continue"),
            "level": .string("warn"),
            "kind": .string("sticky"),
            "key": .string("credits.depleted")
        ]))
        let first = AgentNoticePolicy.presentation(sticky)
        try expect(first?.title == "Credit access paused", "the CLI severity glyph is stripped")
        try expect(first?.detail == "top up to continue", "middot detail moves to line two")
        try expect(first?.durationMilliseconds == 0, "sticky notices do not auto-dismiss")
        try expect(first?.key == "credits.depleted", "the wire key remains the replacement key")

        let ttl = NotificationPayload(.object([
            "text": .string("✓ Credit access restored"),
            "level": .string("success"),
            "kind": .string("ttl"),
            "ttl_ms": .number(8_000),
            "id": .string("notice-1")
        ]))
        let second = AgentNoticePolicy.presentation(ttl)
        try expect(second?.title == "Credit access restored", "the success glyph is stripped")
        try expect(second?.detail == "", "a notice without middot has no second line")
        try expect(second?.durationMilliseconds == 8_000, "a positive wire TTL is preserved")
        try expect(second?.key == "notice-1", "id is the replacement fallback when key is absent")

        try expect(AgentNoticePolicy.presentation(NotificationPayload(.object([
            "text": .string("  \n ")
        ]))) == nil, "a blank gateway notice renders nothing")
    }

    // MARK: /new in a forever chat (plugin.js:8223-8241)

    private static func foreverChatGuard() throws {
        // The bare forms, in a canonical chat: rewritten.
        for text in ["/new", "/reset", " /New ", "/RESET"] {
            try expect(ForeverChatGuard.resolve(text, isCanonicalChat: true)
                        == .rewritten(ForeverChatGuard.replacement),
                       "\(text) in a forever chat compacts instead of forking")
        }

        // A named session is an explicit ask for a separate one — upstream's
        // `\s*$` is what keeps this working, and dropping it would silently
        // refuse the thing the user spelled out.
        try expect(ForeverChatGuard.resolve("/new nightly-scratch", isCanonicalChat: true)
                    == .run("/new nightly-scratch"),
                   "a NAMED new session is an explicit ask and is honoured")

        // Sessions-mode scratchpads on the same profile keep full /new freedom.
        try expect(ForeverChatGuard.resolve("/new", isCanonicalChat: false) == .run("/new"),
                   "outside the canonical chat, /new is just /new")

        // Everything else passes through untouched, including the command it
        // rewrites TO — a guard that rewrote /compact would loop.
        for text in ["/compact", "/status", "hello", "/newsletter", "/resets"] {
            try expect(ForeverChatGuard.resolve(text, isCanonicalChat: true) == .run(text),
                       "\(text) is not a reset")
        }
    }

    // MARK: The copy table, held beside the plugin's literals

    private static func noticeCopyTable() throws {
        // Roster mutations — plugin.js:4060-4062, 4079-4085, 5038.
        try expect(BotModeStrings.pinned("inbox") == "inbox pinned to top", "plugin.js:4061")
        try expect(BotModeStrings.unpinned("inbox") == "inbox unpinned", "plugin.js:4061")
        try expect(BotModeStrings.duplicating("inbox") == "Duplicating inbox…", "plugin.js:4079")
        try expect(BotModeStrings.duplicated("inbox-2", from: "inbox")
                    == "Created inbox-2 — full copy of inbox", "plugin.js:4083")
        try expect(BotModeStrings.duplicateFailed == "Duplicate failed", "plugin.js:4085")
        try expect(BotModeStrings.updated("inbox") == "inbox updated", "plugin.js:5038")

        // Activity — plugin.js:141-147. The robot is U+1F916, not a look-alike.
        try expect(BotModeStrings.newMessageFor("Hermes") == "🤖 New message for Hermes",
                   "plugin.js:145")
        try expect(BotModeStrings.hasNewActivity("Hermes") == "Hermes has new activity",
                   "plugin.js:145")
        try expect(BotModeStrings.openTheChat == "Open the chat to see it.", "plugin.js:147")

        // notifyError contexts — plugin.js:2659 / 2878 / 6782.
        try expect(BotModeStrings.couldNotReach("Homelab") == "Could not reach Homelab",
                   "plugin.js:2659, 3926, 7808")
        try expect(BotModeStrings.couldNotOpenChat("inbox") == "Could not open inbox’s chat — try again",
                   "plugin.js:2878")
        try expect(BotModeStrings.couldNotOpenSession == "Could not open session", "plugin.js:6782")

        // Remote delivery — plugin.js:2637-2658, with and without a label. The
        // label-less forms are Talaria's: one socket means the delivery is on
        // the gateway the user is already looking at, and naming it would be
        // noise rather than the disambiguation it is upstream.
        try expect(BotModeStrings.messaged("qa", on: "Homelab")
                    == "Messaged @qa on Homelab — will relay the reply here.", "plugin.js:2640")
        try expect(BotModeStrings.messaged("qa", on: nil)
                    == "Messaged @qa — will relay the reply here.",
                   "…and drops the clause when there is no machine to name")
        try expect(BotModeStrings.replyFrom("QA", on: "Homelab") == "🤖 QA (Homelab)",
                   "plugin.js:2647")
        try expect(BotModeStrings.replyFrom("QA", on: nil) == "🤖 QA", "…without a label")
        try expect(BotModeStrings.noReplyYet("qa", on: "Homelab")
                    == "No reply from @qa yet — check its Bot Chat on Homelab.", "plugin.js:2654")
        try expect(BotModeStrings.noReplyYet("qa", on: "")
                    == "No reply from @qa yet — check its Bot Chat.",
                   "…an empty label is the same as none")

        // Routines — plugin.js:6177, 6500.
        try expect(BotModeStrings.cronjobScheduled("Morning wrap") == "Cronjob “Morning wrap” scheduled",
                   "plugin.js:6500")
        try expect(BotModeStrings.cronjobUpdateFailed == "Cronjob update failed", "plugin.js:6177")

        // Profiles — plugin.js:5426, 5651.
        try expect(BotModeStrings.agentCreated("Scout") == "Agent “Scout” created", "plugin.js:5426")
        try expect(BotModeStrings.couldNotCreateProfile == "Could not create the profile yet",
                   "plugin.js:5651")

        // The forever-chat notice — plugin.js:8233-8237.
        try expect(BotModeStrings.canonicalKickoffPrompt == "Hey, tell me about yourself!",
                   "plugin.js:2388")
        try expect(BotModeStrings.neverResetsTitle == "This chat never resets", "plugin.js:8234")
        try expect(BotModeStrings.neverResetsBody
                    == "Bot chats are one continuous conversation — compacting instead. "
                     + "For a throwaway session with this agent, use Sessions mode.",
                   "plugin.js:8236-8237")

        // Avatars — plugin.js:1813.
        try expect(BotModeStrings.avatarGenerationFailed == "Avatar generation failed",
                   "plugin.js:1813")

        // Interpolation is not decoration: a table whose formatters dropped
        // their argument would still pass every equality above if the fixture
        // name were empty, so each one is checked with a name that could not
        // appear by accident.
        try expect(BotModeStrings.pinned("Ω").contains("Ω")
                    && BotModeStrings.couldNotOpenChat("Ω").contains("Ω")
                    && BotModeStrings.agentCreated("Ω").contains("Ω")
                    && BotModeStrings.cronjobScheduled("Ω").contains("Ω")
                    && BotModeStrings.newMessageFor("Ω").contains("Ω")
                    && BotModeStrings.hasNewActivity("Ω").contains("Ω"),
                   "every formatter actually interpolates its subject")
    }
}

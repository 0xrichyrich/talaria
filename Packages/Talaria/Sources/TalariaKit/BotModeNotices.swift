import Foundation

// ── Desktop Bot Mode's notifications, as data ────────────────────────────────
//
// BOT-PARITY-PLAN Phase D4. The plugin narrates roughly thirty moments through
// `host.notify` / `host.notifyError`, and two things about them are contracts
// rather than decoration:
//
//   1. **The routing.** Which of two titles an activity toast wears is decided
//      by a regex over the roster preview (plugin.js:144), and the body is a
//      140-character slice with a fallback for the empty case (plugin.js:147).
//      Getting that wrong is invisible — the toast still appears, it just says
//      the wrong thing about the wrong kind of event.
//   2. **The words.** A parity port whose strings quietly drift is a port that
//      stops being one. Every sentence below is quoted from plugin.js at the
//      cited line, and `ProtocolChecks+Notices.swift` pins each against that
//      literal so an edit has to be deliberate.
//
// Both live in TalariaKit for the reason `RosterSearch`, `BotCosmetics` and
// `ToastQueue` do: this is the half `talaria-verify` can execute on every build.
// `CopyPack` (TalariaTheme) renders the plain voice straight out of the table
// below and writes the other two packs itself — so there is ONE place a ported
// sentence is written down, and the control/ink voices are variations on it
// rather than three independent translations that can disagree about the facts.

// MARK: - Activity toast routing (plugin.js:137-148)

/// The opt-in per-activity toast the roster's watermark can fire.
///
/// Upstream keeps this OFF by default and says why (plugin.js:96-98): "a busy
/// roster (cron runs, bot-to-bot chatter) turns the toasts into a firehose, and
/// the unread badge already carries the signal". The badge is unconditional;
/// only the narration is a preference.
public enum ActivityNotice {

    /// `preview.slice(0, 140)` (plugin.js:147).
    public static let previewLimit = 140

    /// `reply.slice(0, 500)` on the relayed A2A answer (plugin.js:2648).
    public static let replyLimit = 500

    /// `/^Message from/i.test(preview)` (plugin.js:144) — the delivery prefix a
    /// bot writes into another bot's transcript when an agent (not its human)
    /// is talking. It is the same prefix Talaria's own A2A path composes
    /// (`AppModelLive+A2A.swift`: "Message from 🤖 <name> (@<handle>): …"), so
    /// this classifier is reading a marker this app also writes, not guessing
    /// at prose.
    ///
    /// Anchored and case-insensitive, exactly as the regex is: a preview that
    /// merely *mentions* a message from someone, further along the line, is not
    /// an inbound delivery.
    public static func isInbound(_ preview: String) -> Bool {
        preview.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("message from")
    }

    /// The toast body: the preview, clipped, or the fallback when there is
    /// nothing to show — `preview.slice(0, 140) || 'Open the chat to see it.'`
    /// (plugin.js:147). The fallback is passed in because it is the one part of
    /// this that has a voice; the clipping is not.
    public static func body(_ preview: String, fallback: String) -> String {
        let clipped = clip(preview, to: previewLimit)
        return clipped.isEmpty ? fallback : clipped
    }

    /// A slice, trimmed first the way upstream trims before testing
    /// (plugin.js:143).
    ///
    /// Deliberately Character-based where JS's `slice` counts UTF-16 units: a
    /// 140-unit cut can land between the halves of a surrogate pair and produce
    /// a replacement character, and a roster preview is exactly the string most
    /// likely to be carrying an emoji at an arbitrary offset (the delivery
    /// prefix opens with one). Clipping by grapheme is the same rule one step
    /// safer, and it can only ever return FEWER characters than upstream, never
    /// more.
    public static func clip(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

// MARK: - Gateway-native notices (notification.show / notification.clear)

/// The presentation-independent mapping used by every Hermes client for
/// driver notices such as credit usage, depletion and restoration.
public struct AgentNoticePresentation: Sendable, Equatable {
    public var title: String
    public var detail: String
    public var level: String
    /// nil = client default, 0 = sticky, positive = explicit TTL.
    public var durationMilliseconds: Int?
    public var key: String?
}

public enum AgentNoticePolicy {
    /// Map the wire notice to a toast, or nil when it carries no words.
    /// Mirrors desktop's `agent-notices.ts`: strip the CLI severity glyph,
    /// split the first middot-delimited detail onto the second line, use the
    /// key (falling back to id) for replace/clear, and preserve sticky/TTL.
    public static func presentation(_ payload: NotificationPayload) -> AgentNoticePresentation? {
        var text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for prefix in ["• ", "⚠️ ", "⚠ ", "✕ ", "✗ ", "✓ "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }

        let title: String
        let detail: String
        if let split = text.range(of: " · ") {
            title = String(text[..<split.lowerBound])
            detail = String(text[split.upperBound...])
        } else {
            title = text
            detail = ""
        }

        let duration: Int?
        if payload.kind == "sticky" {
            duration = 0
        } else if payload.kind == "ttl", let ttl = payload.ttlMilliseconds, ttl > 0 {
            duration = ttl
        } else {
            duration = nil
        }

        return AgentNoticePresentation(
            title: title,
            detail: detail,
            level: payload.level,
            durationMilliseconds: duration,
            key: payload.key?.nilIfEmpty ?? payload.id?.nilIfEmpty)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - The forever-chat guard (plugin.js:8215-8241)

/// `/new` and `/reset`, intercepted.
///
/// This is the one item in Phase D's notification list that is not copy. Bot
/// Mode's whole promise is that a bot's chat is ONE continuous conversation;
/// `/new` inside it forks that relationship into a scratch session, which is
/// precisely the thing the mode says never happens. Upstream rewrites the draft
/// to `/compact` — same felt effect, fresh working context, same conversation —
/// and toasts to say it did (plugin.js:8218-8241).
///
/// Deliberately narrow, exactly as upstream is: it guards the canonical chat
/// only. A Sessions-mode scratchpad on the same profile keeps full `/new`
/// freedom, because forking a scratch session is what a scratch session is for.
public enum ForeverChatGuard {

    /// What the composer should actually run.
    public enum Verdict: Equatable, Sendable {
        /// Send it as typed.
        case run(String)
        /// It was a reset aimed at a forever chat: run this instead, and say so.
        case rewritten(String)
    }

    /// The command `/new` and `/reset` are rewritten to.
    public static let replacement = "/compact"

    /// `/^\/(new|reset)\s*$/` (plugin.js:8223) — bare, with no argument.
    ///
    /// The trailing `\s*$` is the load-bearing half and the easy one to drop:
    /// `/new nightly-scratch` NAMES a session, which is an explicit ask for a
    /// separate one, and rewriting that to `/compact` would silently refuse a
    /// thing the user spelled out. Only the bare form is ambiguous enough to
    /// mean "clear this".
    public static func isBareReset(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "/new" || trimmed == "/reset"
    }

    /// - Parameters:
    ///   - text: the composer line, as typed.
    ///   - isCanonicalChat: the session this would run against IS the bot's
    ///     pinned forever chat. Upstream computes this as
    ///     `String(currentId) === String(pinnedId)` with both non-null
    ///     (plugin.js:8230) — an unresolved pin is not a match, so a chat that
    ///     has not been opened yet keeps `/new` working.
    public static func resolve(_ text: String, isCanonicalChat: Bool) -> Verdict {
        guard isCanonicalChat, isBareReset(text) else { return .run(text) }
        return .rewritten(replacement)
    }
}

// MARK: - The copy table

/// Desktop Bot Mode's own sentences, quoted. The plain-voice (`soft`) pack
/// renders these verbatim; `control` and `ink` restate them in their own
/// register from the same facts.
///
/// Only strings that are genuine ports live here. A string Talaria invented
/// because it has a surface desktop does not — the once-per-gateway legacy
/// notice, the ledger footnote — stays in `CopyPack`, because pinning an
/// invention against "the plugin's own copy" would be a check that asserts
/// nothing.
public enum BotModeStrings {

    // MARK: Roster mutations

    /// plugin.js:4060-4062 — `${displayName} ${pinned ? 'unpinned' : 'pinned to top'}`
    public static func pinned(_ name: String) -> String { "\(name) pinned to top" }
    public static func unpinned(_ name: String) -> String { "\(name) unpinned" }

    /// plugin.js:4079
    public static func duplicating(_ name: String) -> String { "Duplicating \(name)…" }
    /// plugin.js:4083
    public static func duplicated(_ newID: String, from name: String) -> String {
        "Created \(newID) — full copy of \(name)"
    }
    /// plugin.js:4085
    public static let duplicateFailed = "Duplicate failed"

    /// plugin.js:5038 — `${displayName(bot, { title })} updated`
    public static func updated(_ name: String) -> String { "\(name) updated" }

    // MARK: Activity (plugin.js:141-147)

    /// The inbound-delivery title: `🤖 New message for ${label}`.
    public static func newMessageFor(_ label: String) -> String {
        "\u{1F916} New message for \(label)"
    }
    /// The generic title: `${label} has new activity`.
    public static func hasNewActivity(_ label: String) -> String { "\(label) has new activity" }
    /// The empty-preview body.
    public static let openTheChat = "Open the chat to see it."

    // MARK: Reaching things (host.notifyError contexts)

    /// plugin.js:2659, 3926, 7808 — `Could not reach ${label}`. The one the
    /// roster row's tap needs: a bot on another machine that this app could not
    /// activate says so instead of doing nothing.
    public static func couldNotReach(_ label: String) -> String { "Could not reach \(label)" }

    /// plugin.js:2878 — `Could not open ${name}'s chat — try again`. Upstream's
    /// comment is the load-bearing part: the pin was JUST verified, so a failed
    /// open is transient and nothing is re-anchored on it.
    public static func couldNotOpenChat(_ name: String) -> String {
        "Could not open \(name)’s chat — try again"
    }

    /// plugin.js:6782
    public static let couldNotOpenSession = "Could not open session"

    // MARK: Remote delivery (plugin.js:2637-2658)

    /// plugin.js:2640 — `Messaged @${handle} on ${label} — will relay the reply here.`
    /// The label clause drops when there is no connection label to name, which
    /// is the single-gateway case desktop never has.
    public static func messaged(_ handle: String, on label: String?) -> String {
        guard let label, !label.isEmpty else {
            return "Messaged @\(handle) — will relay the reply here."
        }
        return "Messaged @\(handle) on \(label) — will relay the reply here."
    }

    /// plugin.js:2647 — the relayed reply's title, `\u{1F916} ${name} (${label})`.
    public static func replyFrom(_ name: String, on label: String?) -> String {
        guard let label, !label.isEmpty else { return "\u{1F916} \(name)" }
        return "\u{1F916} \(name) (\(label))"
    }

    /// plugin.js:2654 — `No reply from @${handle} yet — check its Bot Chat on ${label}.`
    public static func noReplyYet(_ handle: String, on label: String?) -> String {
        guard let label, !label.isEmpty else {
            return "No reply from @\(handle) yet — check its Bot Chat."
        }
        return "No reply from @\(handle) yet — check its Bot Chat on \(label)."
    }

    // MARK: Routines (plugin.js:6177, 6500)

    /// plugin.js:6500 — `Cronjob "${title}" scheduled`
    public static func cronjobScheduled(_ title: String) -> String {
        "Cronjob “\(title)” scheduled"
    }
    /// plugin.js:6177
    public static let cronjobUpdateFailed = "Cronjob update failed"

    // MARK: Profiles (plugin.js:5426, 5651)

    /// plugin.js:5426 — `Agent "${displayName}" created`
    public static func agentCreated(_ name: String) -> String { "Agent “\(name)” created" }
    /// plugin.js:5651
    public static let couldNotCreateProfile = "Could not create the profile yet"

    // MARK: The forever-chat guard (plugin.js:8232-8237)

    /// The one entry in this table that is not only copy: `/new` and `/reset`
    /// are rewritten to `/compact` when the session they would fork IS the
    /// bot's canonical chat, and this is what says so.
    public static let canonicalKickoffPrompt = "Hey, tell me about yourself!"
    public static let neverResetsTitle = "This chat never resets"
    public static let neverResetsBody =
        "Bot chats are one continuous conversation — compacting instead. "
        + "For a throwaway session with this agent, use Sessions mode."

    // MARK: Avatars (plugin.js:1813)

    public static let avatarGenerationFailed = "Avatar generation failed"
}

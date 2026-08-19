import Foundation

// ── @mentions: the grammar, the roster resolver, the composer middleware ────
//
// Ported from apps/desktop/src/plugins/hermes-bots/plugin.js:
//
//   isActiveRosterBot       2414-2429   "a bot never @s itself"
//   resolveRosterMentions   2434-2497   prose strip, form map, ambiguity
//   mention autocomplete    7996-8046   prefix-on-handle, cap 8, the meta line
//   mention middleware      8206-8321   the fast gate, the note it appends
//
// This is the pure half — no gateway, no actor, no UI — and it lives in
// TalariaKit rather than beside the delivery code it feeds for the same reason
// `RosterSearch` does: the chat composer, the handoff sheet and the verify
// suite all have to agree on what an @handle is, and `talaria-verify` links
// TalariaKit alone. The rules below are therefore pinned on every build by
// ProtocolChecks+Mentions.swift instead of by memory.
//
// Delivery — canonical chat, attributed submit, reply relay — stays in
// TalariaUI/AppModelLive+A2A.swift, which is where the socket is.

// MARK: - Grammar (plugin.js:2436, 2470)

/// The @handle grammar, ported token for token. Strict on purpose: a false
/// positive here sends a real message to a real agent, so an @ must start a
/// word, the first character must be alphanumeric, dots are not part of a
/// handle, and anything inside code never counts.
public enum BotMention {
    /// `[a-z0-9][a-z0-9_-]*` — the same namespace `NAME_RE` defines for a
    /// profile name (plugin.js:78), which is why the profile name IS the
    /// handle. Underscores are legal even though Talaria's creator does not
    /// offer them: a bot named `code_review` on desktop must stay mentionable.
    static func isHandleBody(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
    }

    /// Text with fenced and inline code replaced by a space, so a handle
    /// inside a snippet never fires a handoff. Done FIRST, before any token
    /// scan (plugin.js:2436).
    ///
    /// Each block collapses to a single SPACE, not to nothing — upstream's
    /// replacement string is `' '` — which is load-bearing twice over: it
    /// keeps `` `x`@ops `` from silently gluing into a word, and it supplies
    /// the whitespace boundary the token regex demands.
    public static func prose(_ text: String) -> String {
        var out = replace(text, pattern: "```[\\s\\S]*?```", with: " ")
        out = replace(out, pattern: "`[^`\\n]*`", with: " ")
        return out
    }

    /// Every @token in prose order, lowercased. Duplicates are kept; the
    /// resolver dedupes by bot, not by token.
    public static func tokens(in text: String) -> [String] {
        let prose = prose(text)
        guard let regex = Self.tokenRegex else { return [] }
        let ns = prose as NSString
        return regex.matches(in: prose, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 2 else { return nil }
                return ns.substring(with: match.range(at: 2)).lowercased()
            }
    }

    /// The cheap gate the middleware runs on every draft before doing any real
    /// work (plugin.js:8244).
    ///
    /// Deliberately on the RAW text, exactly as upstream: the gate is a
    /// whole-message "is there an @ worth thinking about", and a draft that is
    /// nothing but a fenced code block passes it and then resolves to nothing.
    /// Stripping first would be a different (and slower) function.
    public static func mentions(_ text: String) -> Bool {
        guard let regex = Self.tokenRegex else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// The @token the composer is mid-way through typing — the trailing one,
    /// with the same word-boundary rule the resolver uses. `@` on its own
    /// returns an empty token, which offers the whole roster.
    ///
    /// Anchored to the END of the string rather than to the caret: SwiftUI's
    /// `TextField` publishes its text, never its selection.
    public static func activeToken(in text: String) -> (range: Range<String.Index>, token: String)? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex {
            guard text[text.index(before: at)].isWhitespace else { return nil }
        }
        let body = text[text.index(after: at)...]
        guard body.allSatisfy(isHandleBody) else { return nil }
        if let first = body.first, !(first.isLetter || first.isNumber) { return nil }
        return (at..<text.endIndex, body.lowercased())
    }

    /// Replace the token being typed with a chosen handle, leaving one
    /// trailing space so the next word is not swallowed into it.
    public static func complete(_ text: String, range: Range<String.Index>,
                                with handle: String) -> String {
        text.replacingCharacters(in: range, with: "@" + handle + " ")
    }

    /// Append a handle as a new mention (the roster strip's tap).
    public static func append(_ handle: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "@\(handle) " : trimmed + " @\(handle) "
    }

    /// Drop every mention of `handle`, keeping the whitespace that introduced
    /// it so the surrounding prose still reads.
    ///
    /// SCOPED TO THE SPLICE, and to the splice only. A mention sits between
    /// two spaces, so cutting it out leaves both: "hey @ops please" would come
    /// back as "hey  please". The `[ \t]*` therefore belongs to the pattern —
    /// keep the whitespace that INTRODUCED the mention (`$1`), eat the run
    /// behind it — rather than to a whole-draft tidy-up afterwards. Doing it
    /// globally instead (`[ \t]{2,}` → " " over the whole string, which is
    /// what this used to do) flattened every indented line in the draft,
    /// including on the common call where the handle is not present at all.
    /// Code in a handoff draft is a designed-for input (`prose` exists for
    /// exactly that), so mangling it was not an edge case.
    ///
    /// A draft the strip did not touch comes back byte-identical, trailing
    /// blank lines included. Nothing upstream justifies rewriting a draft at
    /// all — plugin.js only ever APPENDS (8319) — so the less this does when
    /// asked to remove a handle that is not there, the better.
    ///
    /// The negative lookahead is what stops `@ops` from eating `@ops-macbook`
    /// (the `@name-device` form is a different handle, and a different bot);
    /// callers therefore have to pass the handle the draft actually holds.
    public static func remove(_ handle: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        let stripped = replace(text, pattern: "(^|\\s)@\(escaped)(?![a-z0-9_-])[ \\t]*",
                               with: "$1", options: [.caseInsensitive])
        guard stripped != text else { return text }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // plugin.js:2473 — the @ must start a word, so `user@host` and `a@b` are
    // not mentions; no dots, unlike the group-room parser at 3104.
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "(^|\\s)@([a-z0-9][a-z0-9_-]*)", options: [.caseInsensitive])

    private static func replace(_ text: String, pattern: String, with template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }
}

// MARK: - What the roster made of the tokens

/// One token that fits more than one bot, and the bots it fits.
///
/// Upstream keeps only the refusal, not its cause: the form map holds `null`
/// and has already forgotten which rows collided (plugin.js:2457-2466). The
/// phone keeps the cause because it is the only way to say the sentence that
/// makes the refusal actionable — "@ops is two bots, name one".
public struct MentionCollision: Sendable, Equatable {
    /// The token as typed, lowercased.
    public var token: String
    /// The bots that answer to it, in roster order.
    public var bots: [Bot]

    public init(token: String, bots: [Bot]) {
        self.token = token
        self.bots = bots
    }

    /// How to name each colliding bot when asking the user to pick one. A bot
    /// whose own @handle is more specific than the token names itself with it,
    /// because that IS the form they have to type (the precomputed
    /// `name-device` handle, connection-registry.ts:137). When the handle is
    /// the ambiguous token itself, only the display name tells them apart.
    public var labels: [String] {
        bots.map { $0.handle.lowercased() == token ? $0.displayTitle : "@" + $0.handle }
    }
}

/// What the roster made of the @tokens in a draft.
public struct MentionResolution: Sendable, Equatable {
    /// Resolved bots, first-mention order, deduped.
    public var bots: [Bot] = []
    /// Tokens whose bare form is shared by more than one bot. Upstream
    /// resolves these to NOTHING rather than guessing, because guessing sends
    /// a real message to the wrong machine (plugin.js:2457-2466).
    public var ambiguous: [String] = []
    /// Tokens no bot answers to. Silently skipped upstream; surfaced here,
    /// quietly, because a phone gives no other feedback that a handle was
    /// mistyped.
    public var unknown: [String] = []
    /// The bots behind each `ambiguous` token, same order.
    public var collisions: [MentionCollision] = []

    public init() {}

    public var isEmpty: Bool { bots.isEmpty && ambiguous.isEmpty && unknown.isEmpty }

    /// Every resolved bot is deliverable. The UI turns each row into a
    /// `GatewayBotRoute` before dispatch, so a foreign row travels through the
    /// retained client for its own source rather than through the primary
    /// socket. This is desktop's local + remote split recombined after Talaria
    /// gained a multi-gateway client pool.
    public var deliverable: [Bot] { bots }

    /// Kept as a source-compatible spelling for surfaces compiled against the
    /// earlier one-socket implementation. A resolved foreign row is no longer
    /// unreachable merely because it lives on another saved gateway.
    public var unreachable: [Bot] { [] }
}

// MARK: - Resolving against the roster (plugin.js:2434-2497)

public enum MentionResolver {

    /// Resolve @handles in a draft against a roster.
    ///
    /// The roster is the UNION — every source's rows in one array, exactly as
    /// upstream passes `cached.profiles` straight through (plugin.js:8256).
    /// That is what makes the duplicate-name rule work at all: the two
    /// `default` rows have to meet in one form map before either can poison
    /// the bare name.
    ///
    /// `speaker` is the bot doing the talking; it is excluded, because a bot
    /// never @s itself (plugin.js:2414 `isActiveRosterBot`).
    public static func resolve(_ text: String, roster: [Bot],
                               speaking speaker: String?) -> MentionResolution {
        guard BotMention.mentions(text) else { return MentionResolution() }

        // The form map: every string that addresses this bot. A form claimed
        // by two different bots is poisoned to nil and STAYS poisoned — a
        // third bot cannot claim it — so the bare name of a duplicated profile
        // stops resolving and the user must type the @name-device form.
        var byForm: [String: Bot] = [:]
        var poisoned: Set<String> = []
        // Every bot that ever offered a form, in roster order. Upstream has no
        // equivalent: it overwrites the map entry with `null` and loses the
        // first claimant. The refusal copy needs both names.
        var claims: [String: [Bot]] = [:]
        for bot in roster {
            // `profileName`, never `id`: upstream registers `bot.name`
            // (2445) beside the handle, and for a foreign row Talaria's `id`
            // is the source-qualified key (2669). Registering the key instead
            // would leave the two duplicated `default` rows claiming nothing
            // in common — the bare name would never be poisoned, and
            // `@default` would quietly reach whichever gateway happens to be
            // live. The bare form is the whole mechanism.
            let name = bot.profileName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !isSpeaker(bot, speaking: speaker) else { continue }
            var forms: Set<String> = [bot.handle.lowercased(), name.lowercased()]
            if let override = bot.handleOverride, !override.isEmpty {
                forms.insert(override.lowercased())
            }
            for form in forms where !form.isEmpty {
                if claims[form]?.contains(where: { $0.id == bot.id }) != true {
                    claims[form, default: []].append(bot)
                }
                if poisoned.contains(form) { continue }
                if let existing = byForm[form] {
                    if existing.id != bot.id {
                        byForm.removeValue(forKey: form)
                        poisoned.insert(form)
                    }
                } else {
                    byForm[form] = bot
                }
            }
        }

        var resolution = MentionResolution()
        var seen: Set<String> = []
        for token in BotMention.tokens(in: text) {
            if poisoned.contains(token) {
                if !resolution.ambiguous.contains(token) {
                    resolution.ambiguous.append(token)
                    resolution.collisions.append(
                        MentionCollision(token: token, bots: claims[token] ?? []))
                }
                continue
            }
            guard let bot = byForm[token] else {
                // `hermes` addresses the primary profile, which is literally
                // named `default` — `Bot.handle` already maps it, so reaching
                // here means no such bot is on this gateway (plugin.js:2476
                // keeps the same guard as a no-op for the same reason).
                if !resolution.unknown.contains(token) { resolution.unknown.append(token) }
                continue
            }
            guard seen.insert(bot.id).inserted else { continue }
            resolution.bots.append(bot)
        }
        return resolution
    }

    /// "A bot never @s itself" (`isActiveRosterBot`, plugin.js:2414-2429).
    ///
    /// Upstream compares the connection id as well as the name. A qualified
    /// speaker can now be a bot on a retained secondary connection, so its
    /// source-qualified roster id identifies itself. A bare speaker remains a
    /// primary bot and therefore cannot suppress a same-named foreign row.
    public static func isSpeaker(_ bot: Bot, speaking speaker: String?) -> Bool {
        guard let speaker, !speaker.isEmpty else { return false }
        if bot.remoteSource != nil {
            return bot.id.caseInsensitiveCompare(speaker) == .orderedSame
        }
        guard GatewayBotRoute(qualifiedID: speaker) == nil else { return false }
        return bot.id.caseInsensitiveCompare(speaker) == .orderedSame
    }
}

// MARK: - The @-autocomplete provider (plugin.js:7996-8046)

/// One row of the @-completion surface — desktop's contributed item
/// (plugin.js:8036-8040) plus the avatar a phone row draws beside it.
///
/// Upstream's `insert` and `display` are the same string (`'@' + handle`), so
/// the two collapse into one field here; the '@' is added by whatever draws or
/// inserts it, because `BotMention.complete` writes its own.
public struct MentionSuggestion: Identifiable, Sendable, Equatable {
    public var id: String { botID }
    public var botID: String
    /// The handle WITHOUT its leading '@'.
    public var handle: String
    /// The secondary line — `MentionCompletions.meta` (plugin.js:8033-8039).
    public var meta: String
    public var shape: AvatarShape
    public var hue: AvatarHue

    public init(botID: String, handle: String, meta: String,
                shape: AvatarShape, hue: AvatarHue) {
        self.botID = botID; self.handle = handle; self.meta = meta
        self.shape = shape; self.hue = hue
    }
}

/// The rules behind the @-completion popover (plugin.js:8006-8043).
///
/// Strict where roster search is forgiving, and the asymmetry is the point:
/// search matches four fields on a substring because it is exploration
/// (`RosterSearch`), completion matches ONE field on a prefix because the
/// token it inserts has to resolve. A completion that offered a bot by its
/// title would insert a string no resolver answers to.
public enum MentionCompletions {

    /// `return items.slice(0, 8)` (plugin.js:8043). Applied AFTER the loop, so
    /// it truncates roster order — it is not a top-8 ranking. There is no sort
    /// anywhere in `provide`.
    public static let limit = 8

    /// The secondary line: `Bot · <display name>`, with ` · <label>` appended
    /// when the row's connection has one (plugin.js:8033-8039). The separator
    /// is U+00B7 with a space on each side, and the leading `Bot` is desktop's
    /// literal — it disambiguates these rows from the path and file
    /// completions other providers contribute into the same popover
    /// (composer/contrib.ts:53-71), so it is a parity string rather than copy,
    /// and is deliberately not themed.
    public static func meta(display: String, connectionLabel: String? = nil) -> String {
        let label = connectionLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        return label.isEmpty ? "Bot · \(display)" : "Bot · \(display) · \(label)"
    }
}

public extension Array where Element == Bot {

    /// `provide(query)` (plugin.js:8006-8043) — synchronous, non-throwing, and
    /// cheap enough to answer per keystroke off the roster already in hand.
    ///
    /// Per row, in upstream's order: skip nameless rows and the speaker
    /// (8023 — a bot never @s itself), take `botHandle` (8027), and keep it
    /// only when the handle STARTS WITH the query (8029). The match is against
    /// the handle alone: never the display title, never the raw profile id
    /// when it differs from the handle — which is why the primary profile is
    /// found by "her" and not by "def" — and never the connection label.
    ///
    /// An empty query offers everyone, because upstream's filter is guarded by
    /// `q &&` (8029); that is what makes a bare "@" list the roster.
    ///
    /// `connectionLabel` annotates the whole array, the way desktop annotates
    /// every row merged from one source (plugin.js:2337), and reaches the
    /// caller only through the meta line — it is not a match field.
    ///
    /// A foreign row overrides it with its OWN label, which is upstream's
    /// actual read: `profile.connectionLabel` off the row (8034), not one
    /// label for the array. In a union roster that difference is what keeps
    /// the two halves apart: `@default-macbook` offers `Bot · Hermes · MacBook`
    /// and `@default-home-lab` offers `Bot · Home Lab · Home Lab`, because the
    /// display half of a foreign `default` is its device label too
    /// (`Bot.displayTitle` rule 1, plugin.js:2941-2943) — the label appears in
    /// both slots, and that is upstream's own output for the row.
    func mentionSuggestions(for query: String, speaking speaker: String?,
                            connectionLabel: String? = nil) -> [MentionSuggestion] {
        let needle = query.lowercased()
        var out: [MentionSuggestion] = []
        for bot in self {
            guard !bot.profileName.trimmingCharacters(in: .whitespaces).isEmpty,
                  !MentionResolver.isSpeaker(bot, speaking: speaker) else { continue }
            let handle = bot.handle
            guard needle.isEmpty || handle.lowercased().hasPrefix(needle) else { continue }
            out.append(MentionSuggestion(
                botID: bot.id, handle: handle,
                meta: MentionCompletions.meta(
                    display: bot.displayTitle,
                    connectionLabel: bot.remoteSource?.connectionLabel ?? connectionLabel),
                shape: bot.shape, hue: bot.hue))
            if out.count == MentionCompletions.limit { break }
        }
        return out
    }
}

// MARK: - The composer middleware (plugin.js:8206-8321)

/// A draft after the middleware has looked at it.
public struct RoutedDraft: Sendable, Equatable {
    /// The text the submit should carry. Upstream never rewrites or strips the
    /// @handles — it only APPENDS a note (plugin.js:8319) — so an untouched
    /// draft here is byte-identical to the one that came in.
    public var text: String
    /// Bots to hand off to, first-mention order. Includes foreign rows: the UI
    /// converts every row to an exact source route before doing wire work.
    public var recipients: [Bot] = []
    /// Tokens that fit more than one bot and were therefore refused. Nothing
    /// was sent to any of them.
    public var refused: [MentionCollision] = []
    /// Compatibility field from the former one-socket implementation. Always
    /// empty now that retained secondary clients can deliver foreign rows.
    public var unreachable: [Bot] = []

    public init(text: String, recipients: [Bot] = [], refused: [MentionCollision] = [],
                unreachable: [Bot] = []) {
        self.text = text
        self.recipients = recipients
        self.refused = refused
        self.unreachable = unreachable
    }
}

/// The pure half of desktop's `mention-middleware` composer registration
/// (plugin.js:8206-8321): decide who a draft addresses and what note the
/// submitted text should carry. Dispatching the handoff is the caller's job
/// (AppModelLive+A2A.swift), the way upstream fires
/// `deliverRemoteRosterMentions` from the same handler.
public enum MentionMiddleware {

    /// Run the middleware over a draft.
    ///
    /// The pipeline is upstream's, in upstream's order: the fast gate on the
    /// raw text (8244), resolution against the roster (8252-8256 → 2434), and
    /// — only when something actually resolved — the appended note (8319).
    /// The desktop local/remote split (8289-8290) is recombined because both
    /// halves are dispatched through exact gateway routes. A draft that mentions nobody,
    /// mentions only unknown handles, or mentions only ambiguous ones comes
    /// back untouched (8285-8287), because a mention must never block or
    /// mangle a send.
    ///
    /// The note names only recipients that resolved. The caller still has to
    /// construct a route descriptor for every row before it returns this text;
    /// if route construction fails, it must fail closed and submit the original
    /// draft rather than promise delivery.
    public static func route(_ text: String, roster: [Bot],
                             speaking speaker: String?) -> RoutedDraft {
        guard BotMention.mentions(text) else { return RoutedDraft(text: text) }
        let resolution = MentionResolver.resolve(text, roster: roster, speaking: speaker)
        let recipients = resolution.bots
        guard !recipients.isEmpty else {
            return RoutedDraft(text: text, refused: resolution.collisions)
        }
        return RoutedDraft(text: text + handoffNote(to: recipients),
                           recipients: recipients,
                           refused: resolution.collisions)
    }

    /// The instruction block appended to the outgoing text.
    ///
    /// Desktop has two, and Talaria takes the second one. The LOCAL block
    /// (8305-8311) tells the current agent to go run `hermes -p … chat …`
    /// itself; the REMOTE block (8312-8317) tells it the opposite — the app
    /// has already delivered the message over the wire, so stand down, do not
    /// shell out, and relay the answer when it arrives. Talaria delivers every
    /// mention over the socket (see the divergence note at the head of
    /// AppModelLive+A2A.swift), so the remote block is the true one and the
    /// local one would be a lie the agent would act on.
    ///
    /// The actor changes from Desktop to Talaria; "Connections" stays literal
    /// in meaning because each recipient is routed through its retained gateway
    /// client. "Do not switch Gateway" is kept as an instruction to the sending
    /// agent: the app already chose every destination and the model must not try
    /// to reproduce that routing itself.
    ///
    /// Not themed. This is an instruction to a model, not copy for a person —
    /// the same reason upstream keeps it a literal.
    public static func handoffNote(to recipients: [Bot]) -> String {
        let handles = recipients.map { "@" + $0.handle }.joined(separator: ", ")
        return "\n\n[@mention — do not hand this off yourself. Talaria is delivering to "
            + handles + " over the gateway in the background. Do not run hermes -p for them "
            + "and do not switch Gateway. Tell the user they were messaged here; when a reply "
            + "lands, relay it attributed to that agent.]"
    }
}

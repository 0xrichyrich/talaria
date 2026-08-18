import SwiftUI
import TalariaKit
import TalariaTheme

// The roster row's second line — the part that makes a list of agents read
// like a messaging app instead of a log viewer.
//
// Two jobs, both ported from desktop Bot Mode (BOT-MODE-PARITY §4.5, §6.3):
//
//   1. **Flatten the markdown.** `profiles.list` hands back the newest
//      user/assistant message verbatim — whitespace-collapsed and cut at 80
//      characters, but otherwise raw (tui_gateway/methods_profiles.py:34-59,
//      `_latest_message_preview`: "agent-delivery prefixes are kept (callers
//      style them)"). A bot that answers with a heading and a bold lead — and
//      on the maintainer's own gateway most of them do, e.g.
//      `## Crypto/AI Pulse · 2026-08-17 ~14:30 UTC · ~last 4h **Tape:** …` —
//      otherwise paints `##` and `**` straight into the row. `stripPreviewMarkdown`
//      (plugin.js:2991-3007) is the desktop answer and this is its port.
//
//   2. **Say who spoke.** A bot-to-bot delivery arrives as
//      `Message from 🤖 comms (@comms): …`. Desktop moves that attribution out
//      of the sentence and into a pill, leaving the message to stand alone
//      (plugin.js:3869-3874 strips, 4019-4036 renders the chip). Without it
//      the row reads like a log line, and you cannot tell WHO messaged the bot
//      without opening it.
//
// The chip leads the line here rather than trailing it as it does on desktop.
// A 390 pt row truncates its preview constantly; a trailing pill is the first
// thing a narrow row squeezes, and the sender is exactly the token that must
// survive truncation. Reading order becomes "🤖 @comms · <message>", which is
// also how every phone messaging app renders a sender in a group thread.

// MARK: - Model

/// A roster preview after flattening and attribution: what to draw, and who
/// said it (`sender` non-nil only for a bot-to-bot delivery).
public struct RosterPreview: Equatable, Sendable {
    public var text: String
    /// The sending bot's handle, lowercased, without the `@`.
    public var sender: String?

    public init(text: String, sender: String? = nil) {
        self.text = text
        self.sender = sender
    }

    public var isFromBot: Bool { sender != nil }
}

// MARK: - Markdown flattening

/// Port of `stripPreviewMarkdown` (plugin.js:2991-3007).
///
/// Same rules, same order, same anchoring: the two line-anchored rules
/// (headings, block quotes) carry `.anchorsMatchLines` because desktop's
/// regexes carry `/m`; every other rule is string-anchored because desktop's
/// are not. `NSRegularExpression`'s defaults match JavaScript's for both `.`
/// (no newlines) and `^` (string start only), so the port is rule-for-rule.
public enum PreviewMarkdown {

    /// Compiled once. Every one of these patterns is a literal, so a failure
    /// here would be a programming error rather than a runtime condition —
    /// a nil regex simply drops that rule instead of taking the roster down.
    private struct Rule {
        let regex: NSRegularExpression?
        let template: String

        init(_ pattern: String, _ template: String,
             options: NSRegularExpression.Options = []) {
            self.regex = try? NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        // Fenced code blocks vanish entirely — a preview is one line, and the
        // contents of a fence are never the sentence you want.
        Rule("```[\\s\\S]*?```", " "),
        // Beyond desktop, and the reason is upstream: the gateway cuts a
        // preview at 80 characters (methods_profiles.py:57), so a fenced
        // answer routinely arrives with an opener and no closer. The rule
        // above cannot pair it, and the inline-code rule below would eat two
        // of the three backticks and leave one — which is how a row ends up
        // reading "``text Start the…". Anything reaching here is unpaired by
        // construction, so the opener and its language tag go.
        Rule("```[a-zA-Z0-9+#-]*", " "),
        Rule("`([^`\\n]*)`", "$1"),
        // Images before links: ![alt](url) is a link pattern with a bang.
        Rule("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        Rule("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
        // Bold before emphasis, and the backreference matters: `**a**` and
        // `__a__` pair, `**a__` does not.
        Rule("(\\*\\*|__)(.*?)\\1", "$2"),
        // Single-marker emphasis only when word-bounded, so `a*b` and
        // snake_case identifiers survive intact.
        Rule("(^|\\s)[*_](\\S(?:.*?\\S)?)[*_](?=\\s|$|[.,;:!?])", "$1$2"),
        Rule("~~(.*?)~~", "$1"),
        // Beyond desktop a third time, and for the third time the reason is the
        // gateway's 80-character cut (methods_profiles.py:57): it severs a
        // `**bold**` run mid-word often enough that an *opener with no partner*
        // is the single most common residue on a real roster — measured at 12
        // of 612 live previews on the maintainer's own gateway, every one of
        // them rendering a literal `**` at the head of the row
        // ("**Closed the HIGH SECURITY DEFINER blocker…"). The pairing rules
        // above cannot help: by construction there is nothing to pair with.
        //
        // Deliberately narrow, because the alternative is eating punctuation
        // that means something. A marker is dropped only when it (a) begins a
        // word — `(^|\s)` … `(?=\S)`, so `2 * 3` and `snake_case` are never
        // touched — and (b) has no partner anywhere after it, so a run this
        // pass already balanced is left exactly as the pairing rules left it.
        // Doubles first: `**x` must lose both stars, not decay into `*x`.
        Rule("(^|\\s)(?:\\*\\*|__)(?![\\s\\S]*(?:\\*\\*|__))(?=\\S)", "$1"),
        Rule("(^|\\s)[*_](?![\\s\\S]*[*_])(?=\\S)", "$1"),
        // Same story for inline code, and it is the *most* common residue of
        // the three: 94 of those 612 live previews end mid-path or mid-SHA
        // with an opener the pairing rule above could not close
        // ("…is clean at HEAD `a844e5…"). Every backtick still standing at
        // this point is unpaired by construction — the rule above consumes
        // them two at a time, left to right — so the last one left has no
        // partner and no meaning. No word-start guard here, because the real
        // ones open after a bracket as often as after a space
        // ("…f2b263a31c5b (`[verified]…").
        Rule("`(?![\\s\\S]*`)", ""),
        Rule("^\\s{0,3}#{1,6}\\s+", "", options: [.anchorsMatchLines]),
        Rule("^\\s{0,3}>\\s?", "", options: [.anchorsMatchLines]),
        // Beyond desktop again: a leading list marker. Desktop never needed
        // it because its preview keeps the heading that introduces the list.
        // Talaria's live path does not — a `message.complete` preview is the
        // assistant's raw text and the roster takes its FIRST LINE, which for
        // a list answer is the first bullet. A row that opens with "- " reads
        // as a broken bullet rather than a sentence; the marker goes and the
        // item stays. Must run before the collapse below, while the line
        // anchors still mean something.
        Rule("^\\s{0,3}(?:[-*+]|\\d{1,3}[.)])\\s+", "", options: [.anchorsMatchLines]),
        // Last, always: one line out of however many went in.
        Rule("\\s+", " "),
    ]

    /// One readable line: no fences, no markers, no runs of whitespace.
    public static func flatten(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var out = text
        for rule in rules {
            guard let regex = rule.regex else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: rule.template)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Row line

/// The preview line: sender chip (bot-to-bot only) + the flattened message.
///
/// Desktop's colour rule comes with it — a delivery from another bot is
/// italic and accent-tinted rather than tertiary grey (plugin.js:4023-4027),
/// because "a bot wrote to your bot" is a different event from "you have a
/// chat here".
public struct RosterPreviewLine: View {
    let preview: RosterPreview
    let theme: ThemePack
    /// The row's own hot tint (mention / approval / working), used when this
    /// preview is not itself a delivery.
    let tint: Color
    let font: Font
    let italic: Bool

    public init(preview: RosterPreview, theme: ThemePack,
                tint: Color, font: Font, italic: Bool) {
        self.preview = preview
        self.theme = theme
        self.tint = tint
        self.font = font
        self.italic = italic
    }

    public var body: some View {
        HStack(spacing: theme.id == .ink ? 5 : 6) {
            if let sender = preview.sender {
                SenderChip(handle: sender, theme: theme)
                    // The chip is the token that must survive a narrow row:
                    // the message truncates around it, never the other way.
                    .layoutPriority(1)
            }
            Text(preview.text)
                .font(font)
                .italic(italic || preview.isFromBot)
                .foregroundStyle(preview.isFromBot ? deliveryTint : tint)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
        }
    }

    /// Control's roster already speaks "someone else is talking about you" in
    /// pink; ink has no second colour and leans on the italic instead.
    private var deliveryTint: Color {
        switch theme.id {
        case .soft: theme.accent
        case .control: theme.color(for: .pink)
        case .ink: theme.ink.opacity(0.75)
        }
    }
}

/// `🤖 @sender`, in each pack's voice (BOT-MODE-PARITY §5.5 recommends the
/// three forms: soft pill, control bracket, ink small-caps).
public struct SenderChip: View {
    let handle: String
    let theme: ThemePack

    public init(handle: String, theme: ThemePack) {
        self.handle = handle
        self.theme = theme
    }

    /// The chip never truncates — it is the token that has to survive — so it
    /// is the chip's own job not to eat the row. Profile names run long
    /// ("silent-sims-purchaser"); the screen reader still gets the full one.
    private var shown: String {
        handle.count > 14 ? String(handle.prefix(13)) + "…" : handle
    }

    public var body: some View {
        Group {
            switch theme.id {
            case .soft:
                HStack(spacing: 3) {
                    Text(verbatim: "🤖").font(theme.body(8.5))
                    Text(verbatim: "@" + shown).font(theme.body(10, weight: .semibold))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.accentFaint, in: Capsule())
            case .control:
                Text(verbatim: "[@" + shown.uppercased() + "]")
                    .font(theme.mono(9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(theme.color(for: .pink))
            case .ink:
                Text(verbatim: "from " + shown)
                    .font(theme.mono(8.5).smallCaps())
                    .tracking(1.2)
                    .foregroundStyle(theme.ink.opacity(0.55))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel(Text(CopyPack.rosterFromBot(handle, theme.id)))
    }
}

// MARK: - Copy

extension CopyPack {

    /// Desktop's chip tooltip: "Last message came from @x (bot-to-bot)"
    /// (plugin.js:4032). Here it is the chip's screen-reader name, because a
    /// phone has no hover.
    static func rosterFromBot(_ handle: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Last message came from @\(handle), bot to bot"
        case .control: "LAST INBOUND FROM @\(handle.uppercased()) — AGENT TO AGENT"
        case .ink: "the last word came from @\(handle), familiar to familiar"
        }
    }

    /// Desktop's empty-preview fallback, "No conversations yet — say hi"
    /// (plugin.js:3873), which Talaria only ever reached with a flat
    /// English placeholder.
    static func rosterNoConversations(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No conversations yet — say hi"
        case .control: "NO TRAFFIC YET — OPEN A CHANNEL"
        case .ink: "nothing written yet — say hello"
        }
    }
}

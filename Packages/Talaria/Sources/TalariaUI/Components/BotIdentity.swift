import SwiftUI
import TalariaKit
import TalariaTheme

// One identity path for the whole app.
//
// Desktop Bot Mode resolves a profile into exactly two stable strings — a
// display title and an @handle — in
// apps/desktop/src/plugins/hermes-bots/plugin.js `displayName()` (2935) and
// `botHandle()` (2406). `Bot.displayTitle` / `.handle` / `.showsHandle`
// (TalariaKit/Models.swift) are that port, and `TalariaVoice` gives them a
// per-theme voice.
//
// Everything user-visible resolves here. Screens used to re-derive the name
// themselves ("@" + profileID, or the id title-cased), which is why the chat
// header could read "Skynet" while the profile sheet behind it read
// "@default" for the same bot — the primary profile is literally named
// `default` and presents as Hermes/@hermes. A screen that only holds an id
// calls `model.identity(_:)` and gets a real Bot; one that already holds an
// optional Bot beside the id calls the `TalariaVoice` overload below.

// MARK: - Resolving a bare profile id

public extension Bot {
    /// Stand-in for a profile with no roster row — a cron entry naming a bot
    /// that lives on another gateway, an approval that arrived before the
    /// roster did. `displayTitle` / `handle` still apply their rules, so
    /// `default` reads Hermes/@hermes here exactly as it does on a real row.
    ///
    /// The face is the name hash, which is `BotCosmetics`' own last resort for
    /// a profile carrying no stored cosmetics — not a fixed circle/teal. A
    /// stand-in is by definition the paint that comes BEFORE the roster row,
    /// and a constant here is a face guaranteed to change the moment the row
    /// arrives: an approval landing ahead of the roster drew a teal circle and
    /// then became a different bot a second later.
    static func unlisted(id: String) -> Bot {
        Bot(id: id, job: "",
            shape: BotCosmetics.derivedShape(forName: id),
            hue: BotCosmetics.derivedHue(forName: id))
    }
}

public extension AppModel {
    /// The single place a bare profile id becomes an identity. The roster row
    /// wins — it carries the desktop-set title and any handle the roster had
    /// to disambiguate across gateways — otherwise an unlisted stand-in.
    func identity(_ botID: String) -> Bot {
        bot(botID) ?? bot(resolvedBotID(botID)) ?? .unlisted(id: botID)
    }

    /// The inverse of the identity path: a token that reached us as a NAME —
    /// an A2A attribution prefix, a deep link, a push payload — mapped back to
    /// the profile id it belongs to.
    ///
    /// Load-bearing because the two are genuinely different strings for the
    /// primary profile: it is named `default` and presents as Hermes/@hermes,
    /// so desktop's handoff prefix says `(@hermes)` (plugin.js:2635) about a
    /// profile no gateway call will accept under that name. Without this,
    /// an inbox row from the primary bot loses its avatar and colour, and
    /// tapping it asks the gateway to open a profile that does not exist.
    ///
    /// Unresolvable tokens come back unchanged: a handoff from a bot on
    /// another gateway is not ours to rename.
    func resolvedBotID(_ token: String) -> String {
        let needle = token.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            .lowercased()
        guard !needle.isEmpty else { return token }
        if let exact = bots.first(where: { $0.id.lowercased() == needle }) { return exact.id }
        if let byHandle = bots.first(where: { $0.handle.lowercased() == needle }) {
            return byHandle.id
        }
        if let byTitle = bots.first(where: { $0.displayTitle.lowercased() == needle }) {
            return byTitle.id
        }
        return token
    }

    /// Themed display name for a call site that only holds a profile id.
    func botName(_ botID: String, _ theme: ThemeID) -> String {
        TalariaVoice.displayName(for: identity(botID), theme)
    }
}

public extension TalariaVoice {
    /// For rows that already carry the resolved Bot next to the id it came
    /// from (approval cards, A2A rows, artifact cards). A nil bot means the
    /// roster has no such profile — never that the id should be printed raw.
    static func displayName(_ bot: Bot?, id: String, _ theme: ThemeID) -> String {
        displayName(for: bot ?? .unlisted(id: id), theme)
    }

    /// "SKYNET" — the shouted meta lines (ink message headers, the voice
    /// screen). Derived from the title, so the primary profile reads HERMES
    /// rather than DEFAULT.
    static func plainUpper(for bot: Bot) -> String {
        bot.displayTitle.uppercased()
    }
}

// MARK: - The Title @handle pair

/// The identity pair every screen renders: the display name, plus the
/// @handle when it adds information (desktop's `showsHandle` — a bot named
/// after its profile would otherwise print its name twice).
///
/// Two type scales, matching where the pair appears: a list/header row and
/// the profile sheet's title.
public struct BotIdentityLabel: View {
    public enum Scale: Sendable { case row, sheet }

    private let bot: Bot
    private let theme: ThemePack
    private let scale: Scale

    public init(bot: Bot, theme: ThemePack, scale: Scale = .row) {
        self.bot = bot
        self.theme = theme
        self.scale = scale
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(TalariaVoice.displayName(for: bot, theme.id))
                .font(titleFont)
                .tracking(theme.id == .ink ? 0.5 : 0)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                // The title survives truncation before the handle does.
                .layoutPriority(1)

            if bot.showsHandle {
                Text(TalariaVoice.handle(for: bot))
                    .font(handleFont)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .layoutPriority(0.5)
            }
        }
    }

    private var titleFont: Font {
        switch (scale, theme.id) {
        case (.row, .soft): theme.body(16, weight: .bold)
        case (.row, .control): theme.body(15, weight: .bold)
        case (.row, .ink): theme.body(19, weight: .bold).smallCaps()
        case (.sheet, .soft): theme.body(20, weight: .heavy)
        case (.sheet, .control): theme.body(18, weight: .heavy)
        case (.sheet, .ink): theme.display(22, weight: .bold).smallCaps()
        }
    }

    private var handleFont: Font {
        switch (scale, theme.id) {
        case (.row, .ink): theme.mono(8.5)
        case (.row, _): theme.mono(10)
        case (.sheet, .ink): theme.mono(9.5)
        case (.sheet, _): theme.mono(11)
        }
    }
}

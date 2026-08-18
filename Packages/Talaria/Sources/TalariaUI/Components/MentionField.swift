import SwiftUI
import TalariaKit
import TalariaTheme

// The composer field that knows about @handles, and the suggestion strip it
// wears — the strip is a type of its own because desktop's provider is
// registered into EVERY composer (plugin.js:7996-7997), and the phone's other
// composer (Screens/ChatView.swift) is a bare `TextField` inside a row of
// buttons that cannot be swapped for this whole control.
//
// Desktop's registration (plugin.js:7998-8043): typing "@rese…" opens a
// popover of roster handles, answered synchronously from the ≤5 s-stale roster
// cache, prefix-matched on the HANDLE only, capped at 8, excluding the bot
// doing the talking.
//
// The mobile shape is a suggestion strip ABOVE the field rather than a
// floating popover — the keyboard owns the bottom of the screen, so a popover
// under the caret would be behind it. Everything else is the port: same
// source (`AppModel.mentionSuggestions`, which is the same synchronous roster
// read), same prefix-on-handle rule, same cap, same self-exclusion, same
// `Bot · <display name>` meta line.
//
// The field publishes text, not selection, so the token being completed is the
// trailing one (`BotMention.activeToken`). That matches how the strip is used
// in practice — you type the handle, you pick it, you keep typing.

public struct MentionField: View {
    private let model: AppModel
    @Binding private var text: String
    private let speaking: String?
    private let placeholder: String
    private let lines: ClosedRange<Int>
    @FocusState private var focused: Bool

    public init(model: AppModel, text: Binding<String>, speaking: String?,
                placeholder: String, lines: ClosedRange<Int> = 4...12) {
        self.model = model
        self._text = text
        self.speaking = speaking
        self.placeholder = placeholder
        self.lines = lines
    }

    private var theme: ThemePack { model.theme.pack }

    /// The @token under the caret, if the draft ends in one.
    private var active: (range: Range<String.Index>, token: String)? {
        BotMention.activeToken(in: text)
    }

    private var suggestions: [MentionSuggestion] {
        guard let active else { return [] }
        return model.mentionSuggestions(for: active.token, speaking: speaking)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let items = suggestions
            if !items.isEmpty {
                MentionSuggestionStrip(theme: theme, items: items, pick: complete)
            }
            field
        }
        // The strip appears and disappears per keystroke; without a transition
        // the field jumps under the thumb.
        .animation(.easeOut(duration: 0.18), value: suggestions.map(\.botID))
    }

    // MARK: Field

    private var field: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(lines)
            .font(fieldFont)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .focused($focused)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(theme.id == .ink ? Color.clear : theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
    }

    // MARK: Suggestions

    /// Replace the token being typed and hand the keyboard straight back —
    /// picking a handle is the middle of a sentence, not the end of one.
    private func complete(with item: MentionSuggestion) {
        guard let active else { return }
        text = BotMention.complete(text, range: active.range, with: item.handle)
        focused = true
    }

    // MARK: Type

    private var radius: CGFloat { theme.inputRadius > 100 ? 14 : theme.inputRadius }

    private var fieldFont: Font {
        switch theme.id {
        case .soft: theme.body(14)
        case .control: theme.mono(12)
        case .ink: theme.body(15.5)
        }
    }
}

// MARK: - The completion surface

/// The @-completion rows, drawn above whichever composer is asking.
///
/// Desktop's popover renders `display` on the first line and `meta` on the
/// second (composer/contrib.ts:53-71); a phone row is 20pt of avatar, the
/// `@handle` in the accent, and the meta line trailing it — one line, because
/// the strip sits between a transcript and a keyboard and there is no room to
/// spend two.
///
/// Empty in, nothing out: an empty roster (or a query nothing starts with)
/// draws no chrome at all, which is upstream's `return []` (8010-8012) — the
/// popover simply stays closed.
public struct MentionSuggestionStrip: View {
    private let theme: ThemePack
    private let items: [MentionSuggestion]
    private let pick: (MentionSuggestion) -> Void

    public init(theme: ThemePack, items: [MentionSuggestion],
                pick: @escaping (MentionSuggestion) -> Void) {
        self.theme = theme
        self.items = items
        self.pick = pick
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button { pick(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "@\(item.handle) — \(item.meta)"))

                    if item.id != items.last?.id {
                        theme.line.frame(height: 1).padding(.leading, 40)
                    }
                }
            }
            .background(theme.id == .ink ? theme.bg : theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.06) : .clear, radius: 6, y: 2)
        }
    }

    /// The handle takes layout priority over the meta line: the token is what
    /// gets inserted, so it is the half that must never be the one truncated.
    private func row(_ item: MentionSuggestion) -> some View {
        HStack(spacing: 9) {
            AvatarView(shape: item.shape, hue: item.hue, size: 20, theme: theme)
            Text(verbatim: "@" + item.handle)
                .font(handleFont)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.meta)
                .font(metaFont)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var radius: CGFloat { theme.inputRadius > 100 ? 14 : theme.inputRadius }

    private var handleFont: Font {
        switch theme.id {
        case .soft: theme.mono(12, weight: .semibold)
        case .control: theme.mono(11, weight: .bold)
        case .ink: theme.mono(11)
        }
    }

    private var metaFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(12.5)
        }
    }
}

// MARK: - Recipient chips

/// The resolved recipients of a draft, rendered from what the roster actually
/// made of its @tokens. Ambiguity refuses rather than guesses, so a poisoned
/// handle appears as an instruction, not a recipient (plugin.js:2455-2462).
public struct MentionRecipients: View {
    private let model: AppModel
    private let resolution: MentionResolution
    private let remove: (Bot) -> Void

    public init(model: AppModel, resolution: MentionResolution,
                remove: @escaping (Bot) -> Void) {
        self.model = model
        self.resolution = resolution
        self.remove = remove
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Chips are the DELIVERABLE half only (desktop's `localMentions`,
    /// plugin.js:8289). A bot on another gateway resolved — that is what the
    /// `@name-device` form is for — but this app holds one socket and cannot
    /// carry to it, so it appears as a notice below rather than as a recipient
    /// the send is about to include.
    private var chips: [Bot] { resolution.deliverable }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chips.isEmpty {
                Text(copy.mentionRecipients(theme.id))
                    .font(labelFont)
                    .tracking(theme.id == .soft ? 0.5 : 1.5)
                    .textCase(theme.id == .ink ? nil : .uppercase)
                    .foregroundStyle(theme.faint)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(chips) { bot in
                            Button { remove(bot) } label: {
                                HStack(spacing: 6) {
                                    AvatarView(shape: bot.shape, hue: bot.hue, size: 16,
                                               theme: theme)
                                    Text(verbatim: "@" + bot.handle)
                                        .font(chipFont)
                                        .foregroundStyle(theme.color(for: bot.hue))
                                    Text(verbatim: "×")
                                        .font(theme.mono(11, weight: .bold))
                                        .foregroundStyle(theme.faint)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .chipShell(theme)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: "@\(bot.handle)"))
                            .accessibilityHint(Text(copy.mentionRemoveHint(theme.id)))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            ForEach(resolution.ambiguous, id: \.self) { token in
                notice(copy.mentionAmbiguous(theme.id, token: token), tone: theme.warn)
            }
            ForEach(resolution.unreachable) { bot in
                notice(copy.mentionElsewhere(theme.id, handle: bot.handle,
                                             label: bot.remoteSource?.connectionLabel ?? ""),
                       tone: theme.warn)
            }
            ForEach(resolution.unknown, id: \.self) { token in
                notice(copy.mentionUnknown(theme.id, token: token), tone: theme.faint)
            }
        }
    }

    private func notice(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(noticeFont)
            .italic(theme.id == .ink)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var labelFont: Font {
        theme.id == .control ? theme.mono(9.5, weight: .bold) : theme.body(11, weight: .bold)
    }

    private var chipFont: Font {
        switch theme.id {
        case .soft: theme.mono(11.5, weight: .semibold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.mono(11)
        }
    }

    private var noticeFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

extension CopyPack {
    func mentionRemoveHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove this recipient"
        case .control: "DROP FROM ROUTE"
        case .ink: "strike from the carriage"
        }
    }
}

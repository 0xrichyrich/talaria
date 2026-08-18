import SwiftUI
import WidgetKit
import ActivityKit
import TalariaKit
import TalariaTheme
#if canImport(UIKit)
import UIKit
#endif

// The "<bot> is working" Live Activity — lock-screen card + Dynamic Island.
//
// Recreates the design prototype's island pill: black pill, the bot's avatar
// chip in its hue with two eye bars, and a phosphor mm:ss elapsed clock.
// Tapping anywhere deep-links into that bot's chat (talaria://bot/<id>).
//
// Like the prototype, the activity chrome is theme-independent (the island is
// always the black-glass terminal look with the phosphor clock); the current
// theme still supplies the avatar hue palette, eye color and the pending-chip
// copy so the bot reads the same as it does in-app.
//
// The avatar reuses TalariaTheme's AvatarSilhouette shape but draws its own
// static eyes: AvatarView's blink/scan loops rely on long-lived @State
// animation drivers that the WidgetKit render server doesn't run.

// MARK: - Theme resolution (out-of-process)

/// The extension can't see the app's `UserDefaults.standard`, so the theme
/// choice is read from the app group when the app mirrors it there (key
/// literal matches `ThemeManager.storageKey`, which is main-actor bound),
/// falling back to this process's defaults, then soft.
private let themeStorageKey = "talaria-theme"
private let appGroupID = "group.bot.talaria.ios"

private func widgetThemeID() -> ThemeID {
    let stored = UserDefaults(suiteName: appGroupID)?.string(forKey: themeStorageKey)
        ?? UserDefaults.standard.string(forKey: themeStorageKey)
    return stored.flatMap(ThemeID.init(rawValue:)) ?? .soft
}

/// The island clock is phosphor green in every theme — the control pack's
/// accent token, never a literal hex.
private var phosphor: Color { ThemePack.control.accent }

/// IBM Plex Mono when the extension bundle registers it; otherwise the system
/// monospaced design stands in (a proportional fallback would break the
/// terminal look).
private func monoFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    #if canImport(UIKit)
    if UIFont(name: "IBMPlexMono-SemiBold", size: size) != nil
        || UIFont(name: "IBMPlexMono", size: size) != nil {
        return ThemePack.control.mono(size, weight: weight)
    }
    #endif
    return .system(size: size, weight: weight, design: .monospaced)
}

/// Themed bot display name — the extension's copy of the app's one identity
/// rule (`TalariaVoice.displayName(for:)`): the title when it says something
/// the handle doesn't, or when ink is speaking (ink names its familiars); the
/// "@handle" otherwise. Kept as a function rather than a shared call because
/// the widget holds attributes, not a `Bot`.
///
/// `title` is absent on an activity started by a build older than the field;
/// the handle alone is then the best available identity.
private func displayName(_ attributes: BotWorkAttributes, themeID: ThemeID) -> String {
    let handle = attributes.botName
    guard let title = attributes.botTitle?.trimmingCharacters(in: .whitespaces),
          !title.isEmpty else {
        return themeID == .ink
            ? (handle.isEmpty ? handle : handle.prefix(1).uppercased() + handle.dropFirst())
            : "@" + handle
    }
    return title.lowercased() != handle.lowercased() || themeID == .ink ? title : "@" + handle
}

// MARK: - Static avatar

/// The avatar language without the animations: silhouette in the bot's hue,
/// two open eyes at the shape's resting eye line.
struct StaticAvatarView: View {
    var shape: AvatarShape
    var hue: AvatarHue
    var size: CGFloat
    var theme: ThemePack

    private var eyeWidth: CGFloat { size * 0.115 }
    private var eyeHeight: CGFloat { size * 0.21 }
    /// Mirrors AvatarView's per-shape eye line (triangle rides lower).
    private var eyeOffsetY: CGFloat {
        switch shape {
        case .triangle: size * 0.14
        case .pentagon: size * 0.04
        default: 0
        }
    }

    var body: some View {
        ZStack {
            AvatarSilhouette(shape)
                .fill(theme.color(for: hue))
            HStack(spacing: eyeWidth) {
                eye
                eye
            }
            .offset(y: eyeOffsetY)
        }
        .frame(width: size, height: size)
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: min(theme.eyeCornerRadius, eyeWidth / 2))
            .fill(theme.eyeColor)
            .frame(width: eyeWidth, height: eyeHeight)
    }
}

// MARK: - Shared pieces

/// Phosphor elapsed clock. `Text(timerInterval:)` ticks in the render server
/// without pushes; the far-future bound just needs to outlive any real stint.
private struct ElapsedClock: View {
    var startedAt: Date
    var size: CGFloat = 11

    var body: some View {
        Text(timerInterval: startedAt...startedAt.addingTimeInterval(48 * 3600),
             countsDown: false)
            .font(monoFont(size: size))
            .foregroundStyle(phosphor)
            .shadow(color: phosphor.opacity(0.6), radius: 3)
            .multilineTextAlignment(.trailing)
    }
}

/// "1 PENDING" / "1 HOLD" / wax-seal dot + numeral (ink's pendChip is the
/// seal, its copy string is empty) — approvals blocking on the user.
private struct PendingChip: View {
    var count: Int
    var theme: ThemePack
    var copy: CopyPack

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.warn)
                .frame(width: 6, height: 6)
            Text(copy.pendChip.isEmpty ? "\(count)" : "\(count) \(copy.pendChip)")
                .font(monoFont(size: 10, weight: .semibold))
                .foregroundStyle(theme.warn)
        }
    }
}

// MARK: - Lock screen / banner presentation

private struct BotWorkLockScreenView: View {
    let context: ActivityViewContext<BotWorkAttributes>

    var body: some View {
        let themeID = widgetThemeID()
        let theme = ThemePack.pack(for: themeID)
        let copy = CopyPack.pack(for: themeID)
        // Text sits on the fixed black card — the control pack is its palette.
        let terminal = ThemePack.control

        HStack(spacing: 12) {
            StaticAvatarView(shape: context.attributes.shape,
                             hue: context.attributes.hue,
                             size: 42, theme: theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(context.attributes, themeID: themeID))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(terminal.ink)
                Text(context.state.task)
                    .font(.system(size: 12.5))
                    .foregroundStyle(terminal.sub)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                ElapsedClock(startedAt: context.state.startedAt, size: 13)
                if context.state.pendingApprovals > 0 {
                    PendingChip(count: context.state.pendingApprovals,
                                theme: terminal, copy: copy)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - The Live Activity

struct BotWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BotWorkAttributes.self) { context in
            BotWorkLockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(phosphor)
                .widgetURL(context.attributes.deepLinkURL)
        } dynamicIsland: { context in
            let themeID = widgetThemeID()
            let theme = ThemePack.pack(for: themeID)
            let copy = CopyPack.pack(for: themeID)
            let hueColor = theme.color(for: context.attributes.hue)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StaticAvatarView(shape: context.attributes.shape,
                                     hue: context.attributes.hue,
                                     size: 38, theme: theme)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedClock(startedAt: context.state.startedAt, size: 13)
                        .padding(.trailing, 4)
                        .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(context.attributes, themeID: themeID))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ThemePack.control.ink)
                        Text(context.state.task)
                            .font(.system(size: 12))
                            .foregroundStyle(ThemePack.control.sub)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.pendingApprovals > 0 {
                        PendingChip(count: context.state.pendingApprovals,
                                    theme: ThemePack.control, copy: copy)
                            .padding(.top, 4)
                    }
                }
            } compactLeading: {
                // The prototype pill's 22px avatar chip with two eye bars.
                StaticAvatarView(shape: context.attributes.shape,
                                 hue: context.attributes.hue,
                                 size: 22, theme: theme)
                    .padding(.leading, 2)
            } compactTrailing: {
                ElapsedClock(startedAt: context.state.startedAt, size: 10.5)
                    .frame(maxWidth: 52)
            } minimal: {
                StaticAvatarView(shape: context.attributes.shape,
                                 hue: context.attributes.hue,
                                 size: 21, theme: theme)
            }
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(hueColor)
        }
    }
}

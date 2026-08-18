import SwiftUI
import TalariaKit
import TalariaTheme

// Settings → Appearance: the three theme packs, text size, and motion.
//
// Theme switching already exists (Connections → Appearance and the roster's
// cycle glyph both write `ThemeManager.themeID`), so this reuses
// `ThemeSwatchCard` rather than drawing a second set of swatches.
//
// Text size and motion are new, and both are built to *honor the system first*:
// the shipped value of each is "follow the device", and the overrides exist
// only because a phone in a pocket and a phone on a desk are different rooms.
//
// The live preview under the picker is not decoration. Talaria's type comes
// from three different font families across the packs, so rather than claim in
// prose what will and will not resize, the section shows the actual roster row
// at the chosen setting and lets it speak.

struct AppearanceSettingsSection: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var store: TalariaSettingsStore { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(theme: theme, title: copy.appearance, footnote: nil) {
                HStack(spacing: 8) {
                    ForEach(ThemeID.allCases, id: \.self) { id in
                        ThemeSwatchCard(id: id, current: theme, showsTagline: true) {
                            let animation: Animation? = store.prefersReducedMotion(system: systemReduceMotion)
                                ? nil : .easeInOut(duration: 0.25)
                            withAnimation(animation) { model.theme.themeID = id }
                        }
                    }
                }
            }

            SettingsSection(theme: theme, title: copy.settingsTextSizeSec(theme.id),
                            footnote: copy.settingsTextSizeNote(theme.id)) {
                SettingsGroup(theme: theme) {
                    SettingsToggleRow(theme: theme,
                                      title: copy.settingsFollowSystem(theme.id),
                                      subtitle: copy.settingsFollowSystemNote(theme.id),
                                      isOn: store.textSize == .system) {
                        // Leaving "follow system" lands on the standard step
                        // rather than the smallest, so the first tap does not
                        // shrink the app.
                        store.textSize = store.textSize == .system ? .large : .system
                    }
                    if store.textSize != .system {
                        TextSizeScale(theme: theme, selection: store.textSize) { store.textSize = $0 }
                            .modifier(SettingsRowChrome(theme: theme, isLast: false))
                    }
                    TypePreview(theme: theme, copy: copy)
                        .modifier(SettingsRowChrome(theme: theme, isLast: true))
                }
            }

            SettingsSection(theme: theme, title: copy.settingsMotionSec(theme.id),
                            footnote: copy.settingsMotionNote(theme.id,
                                                              systemReduced: systemReduceMotion)) {
                SettingsSegmented(
                    theme: theme,
                    options: [
                        (TalariaSettingsStore.MotionPreference.system, copy.settingsMotionSystem(theme.id)),
                        (.reduced, copy.settingsMotionReduced(theme.id)),
                        (.full, copy.settingsMotionFull(theme.id)),
                    ],
                    selection: store.motion) { store.motion = $0 }
            }
        }
    }
}

// MARK: - Text size scale

/// Five steps rendered as the letter A at the size each one produces — the
/// control shows its own effect, so no label has to describe it.
private struct TextSizeScale: View {
    var theme: ThemePack
    var selection: TalariaSettingsStore.TextSize
    var pick: (TalariaSettingsStore.TextSize) -> Void

    private let steps: [(size: TalariaSettingsStore.TextSize, point: CGFloat)] = [
        (.small, 11), (.medium, 13), (.large, 15), (.larger, 18), (.largest, 22),
    ]

    var body: some View {
        HStack(spacing: theme.id == .ink ? 0 : 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Button { pick(step.size) } label: {
                    Text(verbatim: "A")
                        // fixedSize so the scale itself never rescales with the
                        // very setting it is choosing.
                        .font(.system(size: step.point,
                                      weight: step.size == selection ? .bold : .regular))
                        .foregroundStyle(step.size == selection ? selectedInk : theme.sub)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(step.size == selection ? selectedFill : Color.clear)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(step.size == selection ? selectedBorder : theme.line,
                                                    lineWidth: 1))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(Int(step.point))"))
                .accessibilityAddTraits(step.size == selection ? [.isSelected] : [])
            }
        }
        .dynamicTypeSize(.large)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : theme.buttonRadius, style: .continuous)
    }

    private var selectedInk: Color {
        theme.id == .ink ? theme.bg : theme.accentFg
    }

    private var selectedFill: Color {
        theme.id == .ink ? theme.ink : theme.accent
    }

    private var selectedBorder: Color {
        theme.id == .control ? theme.accent : .clear
    }
}

// MARK: - Preview

/// A roster row in miniature, drawn with the pack's real fonts so the text-size
/// setting is judged by what it does rather than by a promise.
private struct TypePreview: View {
    var theme: ThemePack
    var copy: CopyPack

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AvatarView(shape: .hexagon, hue: .violet, size: 34, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.settingsPreviewName(theme.id))
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                Text(copy.settingsPreviewLine(theme.id))
                    .font(SettingsType.rowSubtitle(theme))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.sub)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - App-level text size

/// Applies the Appearance text-size override to a view tree. Settings applies
/// it to itself so the picker is live; the app's root view adopts it in one
/// line so the override reaches every screen:
///
///     TalariaRootView(model: model).talariaTextSize(model)
///
/// `.system` inherits the environment untouched, which is what the device's own
/// Dynamic Type setting already provides.
public struct TalariaTextSize: ViewModifier {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public func body(content: Content) -> some View {
        if let size = model.settings.textSize.dynamicTypeSize {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

public extension View {
    func talariaTextSize(_ model: AppModel) -> some View {
        modifier(TalariaTextSize(model: model))
    }
}

// MARK: - App-level motion

/// Publishes the Appearance motion preference, merged with the device's own
/// reduce-motion setting, as `\.talariaReducedMotion` (TalariaTheme/Motion.swift
/// — it lives down there so the theme layer's animated views can read it too).
public struct TalariaMotion: ViewModifier {
    private let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel) { self.model = model }

    public func body(content: Content) -> some View {
        content.environment(\.talariaReducedMotion,
                            model.settings.prefersReducedMotion(system: systemReduceMotion))
    }
}

public extension View {
    func talariaMotion(_ model: AppModel) -> some View {
        modifier(TalariaMotion(model: model))
    }
}

// MARK: - Copy

extension CopyPack {

    func settingsTextSizeSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Text size"
        case .control: "TYPE SCALE"
        case .ink: "THE HAND"
        }
    }

    func settingsTextSizeNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Talaria follows your device's text size. Turn that off to set an app-only size — the row below shows exactly what changes."
        case .control: "TYPE FOLLOWS THE DEVICE SETTING BY DEFAULT. OVERRIDE IS APP-LOCAL. SAMPLE ROW BELOW IS LIVE."
        case .ink: "The hand follows your device unless you set it here. The line below is written in it."
        }
    }

    func settingsFollowSystem(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Follow system text size"
        case .control: "FOLLOW DEVICE SCALE"
        case .ink: "as the device is set"
        }
    }

    func settingsFollowSystemNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Set in Settings › Display & Brightness › Text Size"
        case .control: "SOURCE: IOS DISPLAY & BRIGHTNESS → TEXT SIZE"
        case .ink: "kept in the device's own settings"
        }
    }

    func settingsPreviewName(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Skynet"
        case .control: "SKYNET"
        case .ink: "Skynet"
        }
    }

    func settingsPreviewLine(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading the overnight digest · 4m 12s"
        case .control: "▸ READING OVERNIGHT DIGEST · 04:12"
        case .ink: "reading the night's digest — 4 minutes gone"
        }
    }

    func settingsMotionSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Motion"
        case .control: "MOTION"
        case .ink: "MOVEMENT"
        }
    }

    /// States what the device currently says, so "Follow system" is never a
    /// mystery setting.
    func settingsMotionNote(_ t: ThemeID, systemReduced: Bool) -> String {
        switch t {
        case .soft:
            return systemReduced
                ? "Your device asks for reduced motion, so entrances and pulses are held still."
                : "Your device allows full motion. Reduce it here to still the entrances, pulses and sprite loops."
        case .control:
            return systemReduced
                ? "DEVICE REPORTS REDUCE-MOTION = ON. ENTRANCES AND PULSES DAMPED."
                : "DEVICE REPORTS REDUCE-MOTION = OFF. OVERRIDE HERE TO DAMP ENTRANCES AND PULSES."
        case .ink:
            return systemReduced
                ? "Your device asks for stillness, and the pages keep it."
                : "Your device permits movement. Ask for stillness here and the pages will keep it."
        }
    }

    func settingsMotionSystem(_ t: ThemeID) -> String {
        switch t {
        case .soft: "System"
        case .control: "DEVICE"
        case .ink: "as set"
        }
    }

    func settingsMotionReduced(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reduced"
        case .control: "DAMPED"
        case .ink: "still"
        }
    }

    func settingsMotionFull(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Full"
        case .control: "FULL"
        case .ink: "alive"
        }
    }
}

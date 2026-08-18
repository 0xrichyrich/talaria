import SwiftUI
import TalariaKit

// The Talaria theme system. Three first-class themes — soft / control / ink —
// switchable at runtime and persisted. Each is a token pack (colors, type,
// radii, borders, glows, motion) plus a copy pack (Approvals/Holds/Seals…).
// Ported from the `packs()` / `copy()` methods of the design prototype.

public enum ThemeID: String, CaseIterable, Codable, Sendable {
    case soft, control, ink

    public var displayName: String {
        switch self {
        case .soft: "Soft"
        case .control: "Control"
        case .ink: "Ink"
        }
    }

    public var tagline: String {
        switch self {
        case .soft: "WARM · ROUNDED · FRIENDLY"
        case .control: "OLED · PHOSPHOR · TELEMETRY"
        case .ink: "PARCHMENT · SEALS · FAMILIARS"
        }
    }
}

/// How list rows render per theme: soft = floating cards, control = terminal
/// panels, ink = a ruled ledger with separator lines and no card chrome.
public enum RowStyle: Sendable { case card, terminal, ledger }

/// Tab bar treatment: soft = floating capsule pill, control = edge-to-edge
/// terminal bar with tick marks, ink = double-rule ledger footer with numerals.
public enum TabBarStyle: Sendable { case floatingPill, terminal, doubleRule }

/// Body/display type families per theme.
public enum TypeFamily: Sendable { case system, plexMono, cormorant }

public struct ThemePack: Identifiable, Sendable {
    public let id: ThemeID

    // MARK: Colors
    public let statusBarDark: Bool
    public let bg: Color
    public let panel: Color
    public let inset: Color
    public let ink: Color
    public let sub: Color
    public let faint: Color
    public let line: Color
    public let lineStrong: Color
    public let accent: Color
    public let accentFg: Color
    public let accentFaint: Color
    public let danger: Color
    public let warn: Color
    public let ok: Color
    /// Avatar palette per hue (differs per theme).
    public let palette: [AvatarHue: Color]

    // MARK: Typography
    public let bodyFamily: TypeFamily
    public let monoFamily: TypeFamily
    /// Ink renders titles in small caps serif; others use weighty sans.
    public let smallCapsTitles: Bool

    // MARK: Geometry
    public let rowRadius: CGFloat
    public let cardRadius: CGFloat
    public let buttonRadius: CGFloat
    /// Capsule inputs/chips in soft; small radii elsewhere.
    public let inputRadius: CGFloat
    public let chipIsCapsule: Bool
    /// Icon-button silhouette: 0.5 = circle; otherwise pt radius / 44.
    public let iconCornerFraction: CGFloat

    // MARK: Effects & structure
    public let rowStyle: RowStyle
    public let tabBarStyle: TabBarStyle
    public let showsKicker: Bool
    /// Phosphor glow radius applied to accent/avatar chrome (0 = none).
    public let glowRadius: CGFloat
    public let avatarGlowRadius: CGFloat

    // MARK: Avatar language
    public let eyeColor: Color
    public let eyeCornerRadius: CGFloat

    public init(id: ThemeID, statusBarDark: Bool, bg: Color, panel: Color, inset: Color,
                ink: Color, sub: Color, faint: Color, line: Color, lineStrong: Color,
                accent: Color, accentFg: Color, accentFaint: Color,
                danger: Color, warn: Color, ok: Color, palette: [AvatarHue: Color],
                bodyFamily: TypeFamily, monoFamily: TypeFamily, smallCapsTitles: Bool,
                rowRadius: CGFloat, cardRadius: CGFloat, buttonRadius: CGFloat,
                inputRadius: CGFloat, chipIsCapsule: Bool, iconCornerFraction: CGFloat,
                rowStyle: RowStyle, tabBarStyle: TabBarStyle, showsKicker: Bool,
                glowRadius: CGFloat, avatarGlowRadius: CGFloat,
                eyeColor: Color, eyeCornerRadius: CGFloat) {
        self.id = id; self.statusBarDark = statusBarDark
        self.bg = bg; self.panel = panel; self.inset = inset
        self.ink = ink; self.sub = sub; self.faint = faint
        self.line = line; self.lineStrong = lineStrong
        self.accent = accent; self.accentFg = accentFg; self.accentFaint = accentFaint
        self.danger = danger; self.warn = warn; self.ok = ok; self.palette = palette
        self.bodyFamily = bodyFamily; self.monoFamily = monoFamily; self.smallCapsTitles = smallCapsTitles
        self.rowRadius = rowRadius; self.cardRadius = cardRadius; self.buttonRadius = buttonRadius
        self.inputRadius = inputRadius; self.chipIsCapsule = chipIsCapsule
        self.iconCornerFraction = iconCornerFraction
        self.rowStyle = rowStyle; self.tabBarStyle = tabBarStyle; self.showsKicker = showsKicker
        self.glowRadius = glowRadius; self.avatarGlowRadius = avatarGlowRadius
        self.eyeColor = eyeColor; self.eyeCornerRadius = eyeCornerRadius
    }

    public func color(for hue: AvatarHue) -> Color {
        palette[hue] ?? palette[.teal] ?? accent
    }

    // MARK: Fonts

    public func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(bodyFamily, size: size, weight: weight)
    }

    public func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(monoFamily, size: size, weight: weight)
    }

    /// Display/title font; ink callers pair this with small caps.
    public func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        smallCapsTitles ? font(.cormorant, size: size, weight: .semibold) : font(bodyFamily, size: size, weight: weight)
    }

    private func font(_ family: TypeFamily, size: CGFloat, weight: Font.Weight) -> Font {
        switch family {
        case .system:
            return .system(size: size, weight: weight)
        case .plexMono:
            let name: String = switch weight {
            case .bold, .heavy, .black: "IBMPlexMono-Bold"
            case .semibold: "IBMPlexMono-SemiBold"
            case .medium: "IBMPlexMono-Medium"
            default: "IBMPlexMono"
            }
            return .custom(name, size: size)
        case .cormorant:
            return .custom("CormorantGaramond", size: size)
        }
    }
}

// MARK: - Hex color support

public extension Color {
    /// `Color(hex: 0x45FFA8)` — exact token values from the design packs.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

import SwiftUI
import TalariaKit

// The three packs, values lifted 1:1 from the design prototype's packs().

public extension ThemePack {

    static func pack(for id: ThemeID) -> ThemePack {
        switch id {
        case .soft: .soft
        case .control: .control
        case .ink: .ink
        }
    }

    /// Warm · rounded · friendly. System type, floating cards, capsule chrome.
    static let soft = ThemePack(
        id: .soft,
        statusBarDark: false,
        bg: Color(hex: 0xF4F2ED),
        panel: Color(hex: 0xFFFFFF),
        inset: Color(hex: 0xF7F5F1),
        ink: Color(hex: 0x171410),
        sub: Color(hex: 0x171410, opacity: 0.55),
        faint: Color(hex: 0x171410, opacity: 0.40),
        line: Color(hex: 0x171410, opacity: 0.08),
        lineStrong: Color(hex: 0x171410, opacity: 0.20),
        accent: Color(hex: 0x6C55E0),
        accentFg: Color(hex: 0xFFFFFF),
        accentFaint: Color(hex: 0x6C55E0, opacity: 0.40),
        danger: Color(hex: 0xB4472A),
        warn: Color(hex: 0xB4472A),
        ok: Color(hex: 0x3E8E5A),
        palette: [
            .teal: Color(hex: 0x3AA99F), .violet: Color(hex: 0x7A5AF8),
            .amber: Color(hex: 0xE0952F), .green: Color(hex: 0x4CAF6E),
            .pink: Color(hex: 0xE36BA8), .blue: Color(hex: 0x4E8FE8),
            .gateway: Color(hex: 0x8A8577),
        ],
        bodyFamily: .system,
        monoFamily: .system, // ui-monospace in the design; system monospaced digits suffice
        smallCapsTitles: false,
        rowRadius: 20, cardRadius: 18, buttonRadius: 12,
        inputRadius: 999, chipIsCapsule: true, iconCornerFraction: 0.5,
        rowStyle: .card, tabBarStyle: .floatingPill, showsKicker: false,
        glowRadius: 0, avatarGlowRadius: 0,
        eyeColor: Color(hex: 0x171410), eyeCornerRadius: 3
    )

    /// OLED · phosphor · telemetry. IBM Plex Mono labels, glows, hard edges.
    static let control = ThemePack(
        id: .control,
        statusBarDark: true,
        bg: Color(hex: 0x050705),
        panel: Color(hex: 0x0B0F0C),
        inset: Color(hex: 0x070A08),
        ink: Color(hex: 0xEAF4EC),
        sub: Color(hex: 0xEAF4EC, opacity: 0.50),
        faint: Color(hex: 0xEAF4EC, opacity: 0.35),
        line: Color(hex: 0x5EFFB2, opacity: 0.09),
        lineStrong: Color(hex: 0x5EFFB2, opacity: 0.20),
        accent: Color(hex: 0x45FFA8),
        accentFg: Color(hex: 0x06150C),
        accentFaint: Color(hex: 0x45FFA8, opacity: 0.40),
        danger: Color(hex: 0xFF6B5A),
        warn: Color(hex: 0xFFB454),
        ok: Color(hex: 0x45FFA8),
        palette: [
            .teal: Color(hex: 0x2EE6C8), .violet: Color(hex: 0x9D7BFF),
            .amber: Color(hex: 0xFFB454), .green: Color(hex: 0x45FFA8),
            .pink: Color(hex: 0xFF7AC2), .blue: Color(hex: 0x58B6FF),
            .gateway: Color(hex: 0x7E8C82),
        ],
        bodyFamily: .system,
        monoFamily: .plexMono,
        smallCapsTitles: false,
        rowRadius: 10, cardRadius: 10, buttonRadius: 6,
        inputRadius: 8, chipIsCapsule: false, iconCornerFraction: 8.0 / 44.0,
        rowStyle: .terminal, tabBarStyle: .terminal, showsKicker: true,
        glowRadius: 8, avatarGlowRadius: 14,
        eyeColor: Color(hex: 0x06150C), eyeCornerRadius: 1.5
    )

    /// Parchment · seals · familiars. Cormorant Garamond, ruled ledger, square chrome.
    static let ink = ThemePack(
        id: .ink,
        statusBarDark: false,
        bg: Color(hex: 0xF2EBDC),
        panel: Color(hex: 0xEFE6D2),
        inset: Color(hex: 0xEFE6D2),
        ink: Color(hex: 0x241D12),
        sub: Color(hex: 0x241D12, opacity: 0.60),
        faint: Color(hex: 0x241D12, opacity: 0.45),
        line: Color(hex: 0x241D12, opacity: 0.15),
        lineStrong: Color(hex: 0x241D12, opacity: 0.35),
        accent: Color(hex: 0xA63C22),
        accentFg: Color(hex: 0xF2EBDC),
        accentFaint: Color(hex: 0xA63C22, opacity: 0.40),
        danger: Color(hex: 0xA63C22),
        warn: Color(hex: 0xA07A2E),
        ok: Color(hex: 0x4E6E3E),
        palette: [
            .teal: Color(hex: 0x4A7A6C), .violet: Color(hex: 0x5D5080),
            .amber: Color(hex: 0xA07A2E), .green: Color(hex: 0x66713F),
            .pink: Color(hex: 0x96536B), .blue: Color(hex: 0x4C6890),
            .gateway: Color(hex: 0x7A7260),
        ],
        bodyFamily: .cormorant,
        monoFamily: .plexMono,
        smallCapsTitles: true,
        rowRadius: 0, cardRadius: 0, buttonRadius: 0,
        inputRadius: 2, chipIsCapsule: false, iconCornerFraction: 0.5,
        rowStyle: .ledger, tabBarStyle: .doubleRule, showsKicker: true,
        glowRadius: 0, avatarGlowRadius: 0,
        eyeColor: Color(hex: 0xF2EBDC), eyeCornerRadius: 3
    )
}

import SwiftUI
import TalariaKit

/// Runtime theme switching with persistence, mirroring the prototype's
/// `localStorage: talaria-theme`. Switch from the header glyph, Connections →
/// Appearance, or onboarding step 4.
@MainActor
@Observable
public final class ThemeManager {
    public static let storageKey = "talaria-theme"

    public var themeID: ThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Self.storageKey) }
    }

    public var pack: ThemePack { ThemePack.pack(for: themeID) }
    public var copy: CopyPack { CopyPack.pack(for: themeID) }

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        self.themeID = stored.flatMap(ThemeID.init(rawValue:)) ?? .soft
    }

    /// Cycle order used by the header glyph: soft → control → ink → soft.
    public func cycle() {
        let all = ThemeID.allCases
        let idx = all.firstIndex(of: themeID) ?? 0
        themeID = all[(idx + 1) % all.count]
    }
}

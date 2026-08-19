import SwiftUI
import TalariaKit

/// Runtime theme switching with persistence, mirroring the prototype's
/// `localStorage: talaria-theme`. Switch from the header glyph, Connections →
/// Appearance, or onboarding step 4.
@MainActor
@Observable
public final class ThemeManager {
    public static let storageKey = "talaria-theme"
    /// Release app and widget share the selected theme through this suite.
    /// Debug device installs deliberately omit the App Group entitlement, so
    /// they continue using process-local defaults and the widget's soft fallback.
    public static let appGroupID = "group.bot.talaria.ios"

    public var themeID: ThemeID {
        didSet {
            UserDefaults.standard.set(themeID.rawValue, forKey: Self.storageKey)
            #if os(iOS) && !DEBUG
            UserDefaults(suiteName: Self.appGroupID)?
                .set(themeID.rawValue, forKey: Self.storageKey)
            #endif
        }
    }

    public var pack: ThemePack { ThemePack.pack(for: themeID) }
    public var copy: CopyPack { CopyPack.pack(for: themeID) }

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        self.themeID = stored.flatMap(ThemeID.init(rawValue:)) ?? .soft
        #if os(iOS) && !DEBUG
        // Seed the extension on first launch as well as after later changes.
        UserDefaults(suiteName: Self.appGroupID)?
            .set(themeID.rawValue, forKey: Self.storageKey)
        #endif
    }

    /// Cycle order used by the header glyph: soft → control → ink → soft.
    public func cycle() {
        let all = ThemeID.allCases
        let idx = all.firstIndex(of: themeID) ?? 0
        themeID = all[(idx + 1) % all.count]
    }
}

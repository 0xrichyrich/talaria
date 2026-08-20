import SwiftUI

// One bool for "damp the motion", read by every animated Talaria view.
//
// SwiftUI's `\.accessibilityReduceMotion` is read-only, so the app's own
// Appearance override (Settings → Motion, which can ask for stillness on a
// device that allows movement, or the reverse) cannot be published through it.
// This key is what carries the merged answer instead: TalariaUI's
// `.talariaMotion(model)` sets it once at the root, folding the device setting
// and the app preference together, and a view downstream reads one bool without
// having to know — or care — which of the two asked.
//
// The default is `false`, not the system value: a view rendered outside the
// app root (an Xcode preview, a detached sheet) then animates exactly as it did
// before this key existed, rather than silently freezing.

public struct TalariaReducedMotionKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    var talariaReducedMotion: Bool {
        get { self[TalariaReducedMotionKey.self] }
        set { self[TalariaReducedMotionKey.self] = newValue }
    }
}

/// Talaria's small, shared motion vocabulary. Keeping these four beats in one
/// place stops navigation, controls and transient UI from each inventing a
/// slightly different tempo.
public enum TalariaMotionTokens {
    public enum Pace: Double, CaseIterable, Sendable {
        case fast = 0.15
        case quick = 0.25
        case standard = 0.30
        case deliberate = 0.35
    }

    public static func duration(_ pace: Pace) -> Double { pace.rawValue }

    /// Spatial changes snap when motion is reduced. This is the animation for
    /// offsets, scale, resizing and matched-geometry movement.
    public static func spatialAnimation(_ pace: Pace,
                                        reducedMotion: Bool) -> Animation? {
        reducedMotion ? nil : .easeOut(duration: pace.rawValue)
    }

    /// A short cross-fade remains available in reduced-motion mode; opacity
    /// communicates state without moving the interface under the user.
    public static func opacityAnimation(_ pace: Pace,
                                        reducedMotion: Bool) -> Animation? {
        reducedMotion ? .linear(duration: Pace.fast.rawValue)
                      : .easeOut(duration: pace.rawValue)
    }

    public static func pushOffset(reducedMotion: Bool) -> CGFloat {
        reducedMotion ? 0 : 10
    }

    public static func pushTransition(reducedMotion: Bool) -> AnyTransition {
        guard !reducedMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: pushOffset(reducedMotion: false)).combined(with: .opacity),
            removal: .offset(x: -8).combined(with: .opacity)
        )
    }

    public static func verticalOverlayTransition(edge: Edge,
                                                 reducedMotion: Bool) -> AnyTransition {
        guard !reducedMotion else { return .opacity }
        let y: CGFloat = edge == .top ? -10 : 10
        return .offset(y: y).combined(with: .opacity)
    }

    /// Both symbols occupy the same fixed slot; only the glyph changes.
    public static func iconSwapTransition(reducedMotion: Bool) -> AnyTransition {
        reducedMotion ? .opacity
            : .asymmetric(
                insertion: .offset(y: 4).combined(with: .opacity),
                removal: .offset(y: -4).combined(with: .opacity)
            )
    }
}

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

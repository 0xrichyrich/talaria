import CoreGraphics
import SwiftUI
import TalariaKit
import TalariaTheme

// The animated pet sprite — the one view that actually draws petdex pixels.
//
// Everything expensive already happened before this view exists: `PetSpriteSheet`
// decoded the atlas once, baked it into a bitmap and sliced every row into
// frames (AppModelLive+Pets keeps exactly one decoded copy per revision and
// shares it). So a sprite view is a reference to that sheet plus an index —
// which is what makes a dozen of them on a roster affordable.
//
// The animation is a `TimelineView(.periodic)` driving a `Canvas`, not an
// `Image` per frame:
//
//   * `.periodic` ticks at the sheet's own frame interval (`loopMs / frames`,
//     ~180 ms), not at display rate. A `.animation` schedule would wake this
//     view 60 times a second to show the same frame five times running.
//   * The frame index is derived from the timeline's date rather than kept in
//     `@State`, so every sprite on screen steps in lockstep, nothing
//     accumulates drift, and a view that scrolls away and back rejoins the
//     same cadence instead of restarting.
//   * `Canvas` draws the `CGImage` with `.none` interpolation. These are
//     hand-pixelled sprites; bilinear smoothing turns them to mush the moment
//     they are scaled at all.

public struct PetSpriteView: View {

    /// The two surfaces a pet appears on. Both derive their drawn size from
    /// the sheet's own frame aspect, so an atlas with different geometry is
    /// still framed correctly.
    public enum Size: Sendable, Equatable {
        /// Roster companion — Bot Mode's `petMode` marker, grown into a real
        /// sprite: small enough to sit against a 46pt avatar without crowding
        /// the row.
        case companion
        /// Gallery hero, hatch reveal, preview card.
        case hero(CGFloat)

        var nominalHeight: CGFloat {
            switch self {
            case .companion: 20
            case .hero(let height): height
            }
        }

        /// How far `display.pet.scale` may move this surface. A roster row's
        /// geometry is fixed, so its band is tight; a hero can breathe.
        /// A hero's ceiling is what its stage can hold without a pet's head
        /// leaving the card, so the band is deliberately narrower than the
        /// engine's 0.1…3.0 — the numeric readout beside the slider carries
        /// the exact value, and the roster is where a big pet reads as big.
        var scaleBand: ClosedRange<CGFloat> {
            switch self {
            case .companion: 0.78...1.3
            case .hero: 0.55...1.25
            }
        }
    }

    private let sheet: PetSpriteSheet
    private let state: PetState
    private let scale: Double
    private let size: Size
    /// Freeze on the first frame — used by the picker's static rows.
    private let paused: Bool

    /// A stable schedule origin. `from: .now` would mint a *new* schedule on
    /// every body evaluation — and the roster re-evaluates every second for its
    /// elapsed timers — so the timeline would restart under a walking sprite.
    /// The drawn frame is still derived from absolute time, so sprites started
    /// at different moments stay in step with each other.
    @State private var epoch = Date()

    public init(sheet: PetSpriteSheet, state: PetState = .idle,
                scale: Double = Pet.defaultScale, size: Size = .companion,
                paused: Bool = false) {
        self.sheet = sheet
        self.state = state
        self.scale = scale
        self.size = size
        self.paused = paused
    }

    // MARK: - Geometry

    /// `display.pet.scale` multiplies *native frame pixels* on the desktop,
    /// where a 208px frame at the 0.33 default lands at a comfortable ~69
    /// device pixels. A phone's points are not those pixels — drawn literally,
    /// the same pet would be a 69pt slab beside a 46pt avatar — so scale is
    /// applied relatively: against each surface's nominal size, and clamped to
    /// that surface's band. A 3.0 pet visibly dominates its hero without
    /// tearing a roster row apart, and moving the slider still moves the pet.
    private var drawnHeight: CGFloat {
        let relative = CGFloat(Pet.clampScale(scale) / Pet.defaultScale)
        let band = size.scaleBand
        return size.nominalHeight * min(band.upperBound, max(band.lowerBound, relative))
    }

    private var drawnWidth: CGFloat {
        drawnHeight * max(0.25, min(4, sheet.frameAspect))
    }

    // MARK: - Body

    public var body: some View {
        // Resolved once per state change, not once per tick: `frames(for:)`
        // walks the alias chain and trims padding frames.
        let frames = sheet.frames(for: state)
        let interval = sheet.frameInterval(for: state)

        Group {
            if frames.count > 1, !paused {
                TimelineView(.periodic(from: epoch, by: interval)) { context in
                    canvas(frames, index: Self.frameIndex(at: context.date,
                                                          interval: interval,
                                                          count: frames.count))
                }
            } else {
                canvas(frames, index: 0)
            }
        }
        .frame(width: drawnWidth, height: drawnHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func canvas(_ frames: [CGImage], index: Int) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            guard frames.indices.contains(index) else { return }
            context.draw(Image(decorative: frames[index], scale: 1).interpolation(.none),
                         in: CGRect(origin: .zero, size: canvasSize))
        }
    }

    /// Wall-clock frame index, so every sprite on screen shows the same frame
    /// of the same state at the same moment.
    static func frameIndex(at date: Date, interval: Double, count: Int) -> Int {
        guard count > 1, interval > 0 else { return 0 }
        let ticks = Int((date.timeIntervalSinceReferenceDate / interval).rounded(.down))
        return ((ticks % count) + count) % count
    }
}

// MARK: - Roster companion

/// The mascot that keeps a working bot company on the roster — Bot Mode's
/// `petMode`, which the prototype drew as a 9px blinking marker pinned to the
/// avatar's corner.
///
/// It renders nothing at all until that profile's pet is loaded, and the load
/// itself is lazy: the first time a bot is drawn with one of these, one
/// `pet.info.meta` runs, and the sheet usually comes straight out of the
/// shared cache because the other bots wear the same pet.
public struct PetCompanionView: View {
    private let model: AppModel
    private let bot: Bot

    public init(model: AppModel, bot: Bot) {
        self.model = model
        self.bot = bot
    }

    private var theme: ThemePack { model.theme.pack }

    public var body: some View {
        Group {
            if let active = model.activePet(for: bot.id) {
                PetSpriteView(sheet: active.sheet,
                              state: model.petState(for: bot),
                              scale: active.pet.scale,
                              size: .companion)
                    // Control's phosphor bleed reaches the mascot too; the
                    // other two packs leave it as flat pixels.
                    .shadow(color: theme.glowRadius > 0 ? theme.color(for: bot.hue).opacity(0.5) : .clear,
                            radius: theme.glowRadius > 0 ? 5 : 0)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7),
                   value: model.pets(for: bot.id).isRenderable)
        .task(id: bot.id) { await model.ensurePet(for: bot.id) }
    }
}

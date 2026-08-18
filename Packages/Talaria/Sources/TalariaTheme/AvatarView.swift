import SwiftUI
import TalariaKit

// The Bot Mode avatar language: a geometric silhouette × hue with a live face.
//
// Upstream calls this the "math face" — nothing about it is a static asset. The
// body breathes, the eyes drift and blink, and a working bot leans into its
// work with three dots pulsing under its chin. All of it is a pure function of
// one shared timebase (`FaceClock`), which is what lets a long roster animate
// for the cost of a single `TimelineView`.
//
// Division of labour with the host, worth stating because it is easy to get
// wrong twice:
//
//   * Upstream rotates the whole SVG by `pose.tilt` about a 50%/70% origin
//     (plugin.js:1091) — that is the *sway*, ±1° idle. Talaria's roster already
//     owns that outer rotation (`RosterView.AvatarSway`), where it also has to
//     cover stored photo portraits, which have no face to animate. This view
//     therefore does NOT re-apply it; doubling it would turn breathing into a
//     wobble.
//   * Everything inside the face is this view's: the body's own `roll`
//     (upstream rolls the outline's points, not the eyes — which is what makes
//     it read as a head rather than a spinning sticker), the projection squash,
//     the gaze, the eye size, the blink, and the chin dots.
//
// A host that wants both channels on one clock can drop its outer sway and let
// `FaceClock.swayPhase(for:)` — the canonical per-bot offset — drive it instead.

public struct AvatarSilhouette: Shape, Sendable {
    public var kind: AvatarShape

    public init(_ kind: AvatarShape) { self.kind = kind }

    public func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }
        switch kind {
        case .circle:
            return Circle().path(in: rect)
        case .squircle:
            return RoundedRectangle(cornerRadius: rect.width * 0.38, style: .continuous).path(in: rect)
        case .hexagon:
            return polygon([pt(25, 4), pt(75, 4), pt(98, 50), pt(75, 96), pt(25, 96), pt(2, 50)])
        case .triangle:
            return polygon([pt(50, 6), pt(97, 94), pt(3, 94)])
        case .diamond:
            return polygon([pt(50, 2), pt(98, 50), pt(50, 98), pt(2, 50)])
        case .pentagon:
            return polygon([pt(50, 2), pt(98, 38), pt(79, 97), pt(21, 97), pt(2, 38)])
        }
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for point in points.dropFirst() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }
}

/// Vertical eye centering differs per silhouette (triangle rides lower);
/// ported from EYE_TOP, expressed as an offset from center in avatar-heights.
/// Upstream keeps the same table per shape (plugin.js:788-802) and, crucially,
/// applies it from the *first* paint so eyes never jump on the first tick.
private func eyeOffsetFraction(for shape: AvatarShape) -> CGFloat {
    switch shape {
    case .triangle: 0.14
    case .pentagon: 0.04
    default: 0
    }
}

public struct AvatarView: View {
    public var shape: AvatarShape
    public var hue: AvatarHue
    public var size: CGFloat
    public var isWorking: Bool
    public var theme: ThemePack
    /// Stable key for this bot's place in the sway cycle. `nil` falls back to
    /// the appearance, so two identical-looking placeholder faces still agree
    /// with each other and differ from the rest of the roster.
    public var identity: String?

    @Environment(\.talariaReducedMotion) private var reducedMotion
    @Environment(\.talariaLiveBots) private var liveBots

    /// Below this the face is drawn once and never animated.
    ///
    /// Not a compromise — a measurement. At 16 pt the eye is 3.4 pt tall, so a
    /// blink moves it 0.27 pt (under one pixel at 3×), the gaze travels 1.4 pt
    /// and a chin dot is 0.9 pt across. Seating a dozen inline chips on the
    /// clock to render sub-pixel motion is pure cost. The roster (46 pt), chat
    /// header (36 pt) and mention list (20 pt) are all above the line; the
    /// 13–16 pt attribution glyphs in Artifacts and the agent inbox are below
    /// it.
    public static let motionFloor: CGFloat = 20

    public init(shape: AvatarShape, hue: AvatarHue, size: CGFloat,
                isWorking: Bool = false, theme: ThemePack, identity: String? = nil) {
        self.shape = shape; self.hue = hue; self.size = size
        self.isWorking = isWorking; self.theme = theme; self.identity = identity
    }

    public init(bot: Bot, size: CGFloat, theme: ThemePack) {
        self.init(shape: bot.shape, hue: bot.hue, size: size,
                  isWorking: bot.status == .working, theme: theme, identity: bot.id)
    }

    /// The work pose's two clauses (plugin.js:3852-3856). `isWorking` is the
    /// first — a turn this app watched start. `talariaLiveBots` is the second —
    /// a bot that spoke inside the 90 s liveness window, which is the only way
    /// a cron run, the laptop or the CLI ever shows up on a face. A host that
    /// publishes neither still gets a correct idle face, never a wrong one.
    private var mood: FaceMood {
        if isWorking { return .work }
        if let identity, liveBots.contains(identity) { return .work }
        return .idle
    }

    private var phaseKey: String { identity ?? "\(shape.rawValue).\(hue.rawValue)" }

    public var body: some View {
        if reducedMotion || size < Self.motionFloor {
            // Damped, or too small to resolve: one pose, held. `FacePose.damped`
            // keeps the working tells (lean, big eyes, staggered chin dots) so
            // "this bot is busy" survives motion being switched off.
            AvatarFace(pose: .damped(mood), shape: shape, hue: hue,
                       size: size, theme: theme, animatesBlink: false)
        } else {
            LiveFace(mood: mood, phase: FaceClock.swayPhase(for: phaseKey),
                     shape: shape, hue: hue, size: size, theme: theme)
        }
    }
}

// MARK: - Clock-driven face

/// A face seated on the shared clock.
///
/// Deliberately two views. This one holds the seat and hosts the driver, and
/// its body reads nothing that changes per tick, so it is evaluated only when
/// the bot's mood or the clock's cadence changes. `AvatarFace` is the half that
/// reads `FaceClock.shared.t` and therefore re-renders on the beat. Collapsing
/// them would put the single `TimelineView` inside a view that rebuilds 15×/s,
/// which is how a driver ends up re-arming its own schedule.
private struct LiveFace: View {
    var mood: FaceMood
    var phase: Double
    var shape: AvatarShape
    var hue: AvatarHue
    var size: CGFloat
    var theme: ThemePack

    @State private var ticket = 0

    @ViewBuilder private var face: some View {
        // Two different views, not one with a flag: a working face reads the
        // clock's continuous `t`, an idle face reads only its one blink bit.
        // Keeping them apart is what stops a single working bot from dragging
        // nineteen idle neighbours onto a 15 fps stream.
        if mood == .work {
            WorkingFace(phase: phase, shape: shape, hue: hue, size: size, theme: theme)
        } else {
            IdleFace(shape: shape, hue: hue, size: size, theme: theme)
        }
    }

    var body: some View {
        face
            .background { DriverSlot(ticket: ticket) }
            .onAppear {
                // Re-appearing without a matching disappear (a re-entered tab)
                // must not leak a second seat.
                if ticket == 0 { ticket = FaceClock.shared.take(working: mood == .work) }
            }
            .onDisappear {
                FaceClock.shared.resign(ticket)
                ticket = 0
            }
            .onChange(of: mood) { _, now in
                FaceClock.shared.setWorking(ticket, now == .work)
            }
    }
}

/// Renders the one `TimelineView` if this seat was elected to drive, and
/// nothing at all otherwise — including when the clock is parked, which is why
/// a backgrounded app or an empty roster schedules no work whatsoever.
private struct DriverSlot: View {
    var ticket: Int

    var body: some View {
        let clock = FaceClock.shared
        if ticket != 0, clock.driverTicket == ticket, let cadence = clock.cadence {
            FaceClockDriver(cadence: cadence)
        }
    }
}

/// A bot mid-turn. The one kind of face with a genuinely continuous pose —
/// lean, gaze, chin dots — so it reads the clock's `t` stream and re-renders on
/// every tick.
private struct WorkingFace: View {
    var phase: Double
    var shape: AvatarShape
    var hue: AvatarHue
    var size: CGFloat
    var theme: ThemePack

    var body: some View {
        AvatarFace(pose: .at(.work, t: FaceClock.shared.t, phase: phase),
                   shape: shape, hue: hue, size: size, theme: theme,
                   animatesBlink: true)
    }
}

/// A bot at rest. Reads exactly one property of the clock — the shared blink —
/// so it wakes twice per 3.2 s no matter what its neighbours are doing, and
/// takes no phase offset because it has no continuous channel to offset: the
/// idle sway belongs to the container (see the header note).
private struct IdleFace: View {
    var shape: AvatarShape
    var hue: AvatarHue
    var size: CGFloat
    var theme: ThemePack

    var body: some View {
        var pose = FacePose.idleRest
        pose.blink = FaceClock.shared.idleBlink
        return AvatarFace(pose: pose, shape: shape, hue: hue, size: size,
                          theme: theme, animatesBlink: true)
    }
}

// MARK: - Rendering one pose

/// Pure paint: a pose in, a face out. No timers, no state — so it renders
/// identically from the clock, from a damped hold, or from a test.
private struct AvatarFace: View {
    var pose: FacePose
    var shape: AvatarShape
    var hue: AvatarHue
    var size: CGFloat
    var theme: ThemePack
    var animatesBlink: Bool

    private var fill: Color { theme.color(for: hue) }
    private var eyeWidth: CGFloat { size * 0.115 }
    private var eyeHeight: CGFloat { size * 0.21 }

    /// The plugin's face box is 40 units wide; every geometric constant below
    /// is quoted in those units and divided here, so the port reads against
    /// plugin.js without arithmetic in between.
    private func units(_ v: Double) -> CGFloat { size * CGFloat(v) / 40 }

    var body: some View {
        ZStack {
            silhouette
            eyes
            chinDots
        }
        .frame(width: size, height: size)
    }

    /// `projectFacePoint`'s foreshortening (plugin.js:973-982). The factors are
    /// tiny by construction — a 19° turn only squashes to 0.986 — and that is
    /// the point: upstream's head-turn is a subtle horizontal compression, not
    /// a rotation. Kept as the formula rather than an impression of it.
    private var silhouette: some View {
        let sx = 0.74 + 0.26 * abs(cos(pose.turn * .pi / 180))
        let sy = 0.8 + 0.2 * abs(cos(pose.tilt * .pi / 180))
        return AvatarSilhouette(shape)
            .fill(fill)
            .shadow(color: theme.avatarGlowRadius > 0 ? fill.opacity(0.5) : .clear,
                    radius: theme.avatarGlowRadius * size / 44)
            .scaleEffect(x: sx, y: sy)
            // Body only: the eyes stay level while the head rolls under them.
            // Zero for an idle face by construction — see the header note on
            // who owns the sway.
            .rotationEffect(.degrees(pose.roll))
    }

    private var eyes: some View {
        HStack(spacing: eyeWidth) {
            eye
            eye
        }
        .offset(x: units(pose.gazeX),
                y: size * eyeOffsetFraction(for: shape) + units(pose.gazeY))
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: min(theme.eyeCornerRadius, eyeWidth / 2))
            .fill(theme.eyeColor)
            .frame(width: eyeWidth, height: eyeHeight)
            // Scale rather than resize: the eye never participates in layout,
            // so growing it while working costs nothing. Upstream's working
            // pupil is `ry` 2.6 against idle's 2.3 (plugin.js:1362).
            .scaleEffect(y: pose.blink ? 0.08 : pose.eyeScale, anchor: .center)
            // Scoped to `blink` alone: the lid eases, the working eye-growth
            // lands with the rest of the pose. Upstream cuts hard between two
            // opacities; a soft lid reads better on a rounded-rect eye, and
            // 75 ms fits twice inside even the 180 ms idle shut.
            .animation(animatesBlink ? .easeInOut(duration: 0.075) : nil, value: pose.blink)
    }

    /// Three dots pulsing in sequence below the chin — upstream's clearest
    /// at-a-glance "thinking" cue, drawn at `cy 41.2` in a 40×44 box
    /// deliberately taller than wide to hold them (plugin.js:1376-1383). They
    /// sit just below the avatar's own square, exactly as they sit below the
    /// 40×40 body upstream; nothing here reflows to make room, so a bot
    /// starting a turn never nudges its row.
    @ViewBuilder private var chinDots: some View {
        if pose.dot0 > 0 || pose.dot1 > 0 || pose.dot2 > 0 {
            HStack(spacing: units(3.6 - 2.3)) {
                dot(pose.dot0)
                dot(pose.dot1)
                dot(pose.dot2)
            }
            .offset(y: units(41.2 - 20))
        }
    }

    private func dot(_ opacity: Double) -> some View {
        Circle()
            .fill(fill)
            .frame(width: units(2.3), height: units(2.3))
            .opacity(opacity)
    }
}

// MARK: - Working ring

/// Pulsing ring shown around a working bot's avatar.
public struct WorkingPulse: View {
    public var color: Color
    public var lineWidth: CGFloat
    @State private var animate = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(color: Color, lineWidth: CGFloat = 2) {
        self.color = color; self.lineWidth = lineWidth
    }

    public var body: some View {
        Circle()
            .stroke(color, lineWidth: lineWidth)
            // Damped, the ring becomes a plain static marker rather than
            // disappearing: "bot is working" still has to read at a glance.
            .scaleEffect(reducedMotion ? 1 : (animate ? 1.5 : 0.9))
            .opacity(reducedMotion ? 0.35 : (animate ? 0 : 0.5))
            // A repeating implicit animation, not a clock seat: this one has no
            // state to sample, so the render server can own it outright and the
            // main actor is never woken for it.
            .animation(reducedMotion
                        ? .default
                        : .easeOut(duration: 1.9).repeatForever(autoreverses: false),
                       value: animate)
            .onAppear { animate = !reducedMotion }
            .onChange(of: reducedMotion) { _, reduced in animate = !reduced }
    }
}

// MARK: - Portrait vs face
//
// Whether a stored profile asset is a real picture or a 160 px raster of this
// very face is a fact about the wire bytes, not about drawing, so it lives in
// `TalariaKit/AvatarArtwork.swift` next to the rest of the profile contract.
// One copy: the roster's fetch path and `talaria-verify` both read it there.

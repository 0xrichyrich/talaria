import SwiftUI
import TalariaKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// One clock for every face in the app.
//
// Bot Mode's avatars are not decorated stills: the plugin repaints every mounted
// face from a single `requestAnimationFrame` loop, so "what is this bot doing"
// is legible from motion alone (plugin.js:1109-1289, `startFaceClock`). The
// loop is shared for a reason the plugin states outright — a roster can mount
// hundreds of faces, so it caps itself at 15 fps, skips faces an
// IntersectionObserver says are off-screen, and *parks itself entirely* when
// zero faces are mounted or zero are visible. Its cost model: a disabled plugin
// or an empty roster costs zero frames.
//
// Talaria used to do the opposite. Every `AvatarView` owned a
// `while !Task.isCancelled { sleep; blink }` loop of its own, so a 40-row roster
// woke the main actor 40 times on 40 unrelated schedules, and the only thing
// stopping them was the view leaving the tree. This file is the port of
// desktop's answer, in SwiftUI's own vocabulary:
//
//   * ONE `TimelineView` exists at a time, hosted by whichever face was mounted
//     first (`driverTicket`). Every other face just reads `t`.
//   * Faces mount/unmount seats on appear/disappear. A `List`/`LazyVStack` row
//     scrolling out of view unmounts its seat, which is the IntersectionObserver
//     analogue for free; `RootView` rebuilds `tabContent` under
//     `.id(model.selectedTab)`, so leaving the roster tab tears the rows down
//     and unmounts every seat with them.
//   * Zero seats, or an inactive app, means no `TimelineView` is rendered at
//     all — not a paused one. Nothing is scheduled and nothing is woken.
//   * Cadence follows demand: 15 fps (desktop's own number) while any face is
//     working, and **no periodic ticks whatsoever** when the whole roster is
//     idle — just the two instants per 3.2 s where the shared blink shuts and
//     opens. See `Cadence`.
//
// Everything a face draws is a pure function of `FaceClock.shared.t`, so a bot's
// pose is reproducible, testable without a view, and identical on every surface
// that shows the same bot at the same instant.
//
// The one thing the clock deliberately does NOT carry is the idle sway. An idle
// face moves ±1.2° over a 7.4 s cycle; sampling that on the main actor to move
// a 46 pt avatar by a tenth of a point is the definition of a bad trade, and
// measuring it proved the point — a 4 fps idle clock cost *more* than the
// per-avatar loops it replaced. It is a repeating implicit animation instead,
// owned by the render server, phase-offset per bot, and free. Which leaves the
// blink as the only thing an idle roster asks the main actor for: 0.625 wakes
// per second, shared across every face on screen.

// MARK: - The two moods

/// Bot Mode has exactly two moods and deliberately no more
/// (BOT-MODE-PARITY §4.2, plugin.js:998-1025). Anything richer — "waiting on an
/// approval", "errored" — is carried by the row's chrome, never by the face.
public enum FaceMood: String, Sendable {
    /// Barely-there breathing. Blinks once every 3.2 s.
    case idle
    /// Leaning into the work: wider sway, drifting gaze, bigger eyes, three
    /// pulsing chin dots, and twice the blink rate.
    case work
}

/// A face's complete state at one instant.
///
/// Angles are degrees; `gazeX`/`gazeY` are in the plugin's 40-unit face box so
/// the port stays auditable against plugin.js line by line — `AvatarView`
/// divides by 40 to reach points. Blink is a hard boolean because desktop's is:
/// the eye is open or it is shut, and the *interval* is what carries state.
public struct FacePose: Equatable, Sendable {
    /// Yaw. Rendered as horizontal foreshortening, not rotation — matching
    /// `projectFacePoint`'s `sx = 0.74 + 0.26·|cos(turn)|` (plugin.js:975).
    public var turn: Double
    /// Pitch. Foreshortens vertically, and upstream additionally rotates the
    /// whole SVG by it (plugin.js:1091). See `AvatarView` for who owns that
    /// rotation on iOS.
    public var tilt: Double
    /// In-plane roll of the *body only* — the eyes do not roll with it, which
    /// is what makes a rolling face read as a head rather than a spinning
    /// sticker (plugin.js:970-980 rolls the ring points before projection).
    public var roll: Double
    /// Horizontal gaze drift, face-box units. Idle bots stare straight ahead.
    public var gazeX: Double
    /// Vertical gaze drift, face-box units. Negative is downward — a working
    /// bot reads slightly down, like reading.
    public var gazeY: Double
    /// Eyes shut this instant.
    public var blink: Bool
    /// Chin-dot opacities, 0.7 rad apart so they chase each other left to
    /// right. Zero unless working.
    public var dot0: Double
    public var dot1: Double
    public var dot2: Double

    public init(turn: Double, tilt: Double, roll: Double,
                gazeX: Double, gazeY: Double, blink: Bool,
                dot0: Double, dot1: Double, dot2: Double) {
        self.turn = turn; self.tilt = tilt; self.roll = roll
        self.gazeX = gazeX; self.gazeY = gazeY; self.blink = blink
        self.dot0 = dot0; self.dot1 = dot1; self.dot2 = dot2
    }

    /// Working eyes are visibly larger — `ry` 2.6 against idle's 2.3
    /// (plugin.js:1362). One of the four tells that stack while a bot works.
    public var eyeScale: Double { dot0 > 0 || dot1 > 0 || dot2 > 0 ? 2.6 / 2.3 : 1 }

    /// A 1:1 port of `facePose(mood, t)` (plugin.js:998-1025). Every constant
    /// is upstream's; none are rounded or "tuned".
    ///
    /// `phase` shifts the *continuous* channels only — sway, gaze and chin dots
    /// — so a roster does not breathe in unison. It deliberately does NOT shift
    /// the blink: upstream blinks every face on one beat, and keeping that beat
    /// shared is what makes "this one blinks twice as often" readable at a
    /// glance instead of looking like noise.
    public static func at(_ mood: FaceMood, t: Double, phase: Double = 0) -> FacePose {
        let s = t + phase
        switch mood {
        case .work:
            let d = s * 2.6
            return FacePose(
                turn: -11 + sin(s * 0.48) * 8,
                tilt: sin(s * 0.42) * 8 + sin(s * 1.1) * 1.6,
                roll: sin(s * 0.75) * 4.2,
                gazeX: sin(s * 0.55) * 3.6,
                gazeY: -1.6 + sin(s * 0.38) * 2,
                // 190 ms shut every 1.45 s — twice as often as idle.
                blink: t.truncatingRemainder(dividingBy: 1.45) > 1.26,
                dot0: 0.2 + 0.8 * max(0, sin(d)),
                dot1: 0.2 + 0.8 * max(0, sin(d - 0.7)),
                dot2: 0.2 + 0.8 * max(0, sin(d - 1.4)))
        case .idle:
            return FacePose(
                turn: sin(s * 0.5) * 1.5,
                tilt: sin(s * 0.27),
                roll: sin(s * 0.85) * 1.2,
                gazeX: 0,
                gazeY: 0,
                // 180 ms shut every 3.2 s.
                blink: t.truncatingRemainder(dividingBy: 3.2) > 3.02,
                dot0: 0, dot1: 0, dot2: 0)
        }
    }

    /// An idle face with its eyes open and no sway baked in.
    ///
    /// The idle sway is not sampled from the clock — it is a repeating implicit
    /// animation on the render server (see `AvatarView`), because ±1.2° over a
    /// 7.4 s cycle is not worth a main-actor wake. So an idle face's clocked
    /// state is exactly one bit: the blink.
    public static let idleRest = FacePose(turn: 0, tilt: 0, roll: 0,
                                          gazeX: 0, gazeY: 0, blink: false,
                                          dot0: 0, dot1: 0, dot2: 0)

    // Upstream's idle sway is `roll: sin(t·0.85)·1.2` — ±1.2° over a 7.4 s
    // cycle. It used to be re-exported here as a pair of constants said to keep
    // "the animated version and the sampled version" from drifting apart, but
    // nothing read them, so they guaranteed nothing: the container that
    // actually animates the sway (`RosterView.AvatarSway`) runs ±1.5° with a
    // 6.2 s autoreversing duration — a 12.4 s cycle. Two constants that no
    // caller consults cannot hold an invariant, and stating one they do not
    // hold is worse than stating nothing. The numbers stay here as prose; the
    // decision about which sway the roster should breathe on is a product call,
    // not something a re-export can settle.

    /// The pose a face holds when motion is damped.
    ///
    /// "Reduced motion" cannot mean "reduced information": a working bot still
    /// has to read as working with the clock switched off, which is the whole
    /// argument for the chin dots existing. So the damped work pose is a real
    /// sample of the work animation rather than a neutral rest — `t = 0.6`,
    /// where the lean is a settled -8.7°, the eyes are enlarged, and the three
    /// dots sit at a descending 1.00 / 0.81 / 0.33 that reads as mid-sequence.
    /// (Upstream's own static render samples `t = 0`, where all three dots are
    /// an identical 0.2 — correct for a face that is about to start moving,
    /// wrong for one that never will.)
    public static func damped(_ mood: FaceMood) -> FacePose {
        switch mood {
        case .idle:
            return FacePose(turn: 0, tilt: 0, roll: 0, gazeX: 0, gazeY: 0,
                            blink: false, dot0: 0, dot1: 0, dot2: 0)
        case .work:
            var pose = FacePose.at(.work, t: 0.6)
            pose.blink = false
            return pose
        }
    }
}

// MARK: - The clock

/// The single face clock. `FaceClock.shared` is the only instance; `AvatarView`
/// is its only client.
@MainActor
@Observable
public final class FaceClock {
    public static let shared = FaceClock()

    /// Seconds since the clock first woke. The input a *working* face reads —
    /// its pose is continuous, so it needs the stream.
    public private(set) var t: Double = 0

    /// The shared idle blink, on upstream's beat: shut for 180 ms every 3.2 s.
    ///
    /// A separate stored property from `t`, and that separation is the whole
    /// point. `@Observable` tracks reads per property, so an idle face that
    /// reads only this one is *not* invalidated by the 15 fps stream a single
    /// working neighbour needs. Nineteen idle bots beside one working bot cost
    /// nineteen wakes per 1.6 s, not nineteen at 15 fps.
    public private(set) var idleBlink: Bool = false

    /// Which seat is currently hosting the one `TimelineView`. Changes only
    /// when the driving face mounts or unmounts, so reading it does not tie a
    /// view to the tick.
    public private(set) var driverTicket: Int = 0

    /// The schedule every face agrees on, or `nil` when the clock is parked and
    /// no `TimelineView` should exist anywhere.
    public private(set) var cadence: Cadence?

    @ObservationIgnored private var seats: [Int: Bool] = [:]   // ticket → isWorking
    @ObservationIgnored private var nextTicket = 1
    @ObservationIgnored private var origin = Date()
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var hostVisible = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() { observeAppState() }

    // MARK: Seats

    /// Take a seat on the clock. Call from `onAppear`; the returned ticket is
    /// the handle for `resign` and for `driverTicket` comparison.
    ///
    /// A face that does not want motion — damped, or too small for any of it to
    /// resolve — must not take a seat at all. That is what keeps the clock
    /// parked rather than merely quiet.
    public func take(working: Bool) -> Int {
        let ticket = nextTicket
        nextTicket += 1
        if seats.isEmpty {
            // First face of a session: restart the timebase so `t` is small and
            // the blink beat starts clean rather than resuming a phase from
            // whenever the app last had a roster on screen.
            origin = Date()
            t = 0
            idleBlink = false
        }
        seats[ticket] = working
        recompute()
        return ticket
    }

    /// Give the seat up. Call from `onDisappear` — a row scrolling out of a
    /// `List`, or the roster tab being replaced.
    public func resign(_ ticket: Int) {
        guard ticket != 0, seats.removeValue(forKey: ticket) != nil else { return }
        recompute()
    }

    /// A seated face started or stopped working. Only the cadence cares.
    public func setWorking(_ ticket: Int, _ working: Bool) {
        guard ticket != 0, let was = seats[ticket], was != working else { return }
        seats[ticket] = working
        recompute()
    }

    // MARK: Dormancy

    /// Explicit host control, for a container that stays mounted while it is
    /// not on screen (a `TabView` page, a sheet's backdrop). Nothing calls this
    /// today — `RootView` rebuilds its tab content under
    /// `.id(model.selectedTab)`, so seats unmount on their own — but a host
    /// that starts keeping tabs alive can park the clock in one line instead of
    /// discovering a background animation later.
    public func setHostVisible(_ visible: Bool) {
        guard hostVisible != visible else { return }
        hostVisible = visible
        recompute()
    }

    /// Advance the clock. Called only by the elected driver's `TimelineView`.
    public func advance(to date: Date) {
        let next = date.timeIntervalSince(origin)
        // A `TimelineView` re-renders for reasons other than its schedule
        // (a parent body change); only real forward motion is a tick.
        guard next > t else { return }
        t = next
        // Written only when it flips, so idle faces wake twice per 3.2 s even
        // while `t` is streaming at 15 fps for a working neighbour.
        let shut = next.truncatingRemainder(dividingBy: FaceSchedule.blinkPeriod)
            > FaceSchedule.blinkCloses
        if shut != idleBlink { idleBlink = shut }
    }

    // MARK: Cadence

    /// The tick schedule, chosen from demand. Equatable so a face can read it
    /// without re-arming the `TimelineView` on every frame.
    public struct Cadence: Equatable, Sendable {
        /// Seconds between periodic ticks, or `nil` for **no periodic ticks at
        /// all** — the schedule then emits nothing but the blink edges.
        public var interval: Double?
        /// Clock epoch, so the schedule and the pose agree on `t`.
        public var origin: Date

        public init(interval: Double?, origin: Date) {
            self.interval = interval
            self.origin = origin
        }
    }

    /// Desktop's cap: "15fps is smooth at avatar scale and bounds SVG/DOM
    /// churn" (plugin.js:1231). Earned only by a face with a continuous pose to
    /// sample — a lean, a drifting gaze, three chasing chin dots.
    private static let workingFPS: Double = 15

    /// Low Power Mode is the user asking for less of exactly this.
    private static let lowPowerFPS: Double = 8

    private func recompute() {
        let working = seats.contains { $0.value }
        let awake = !seats.isEmpty && appIsActive && hostVisible
        guard awake else {
            if cadence != nil { cadence = nil }
            if driverTicket != 0 { driverTicket = 0 }
            return
        }
        // No working face means nothing continuous to sample: the idle sway is
        // a render-server animation and the gaze does not move, so the only
        // main-actor work an idle roster has left is opening and shutting its
        // eyes. That is two ticks per 3.2 s, for the whole screen.
        let interval: Double? = working
            ? 1 / (ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? Self.lowPowerFPS : Self.workingFPS)
            : nil
        let next = Cadence(interval: interval, origin: origin)
        if cadence != next { cadence = next }

        // The oldest live seat drives. Stable while it stays mounted, so the
        // one `TimelineView` is not torn down and rebuilt as rows scroll.
        let driver = seats.keys.min() ?? 0
        if driverTicket != driver { driverTicket = driver }
    }

    // MARK: App state

    private func observeAppState() {
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (FaceClock) -> Void) {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
            observers.append(token)
        }

        // Desktop pauses on hidden, minimized *and* unfocused. Resign-active is
        // the phone's equivalent of unfocused: the app switcher, the
        // notification shade, a pulled-down Control Center. There is nothing to
        // animate behind any of them.
        #if canImport(UIKit) && !os(watchOS)
        on(UIApplication.willResignActiveNotification) { $0.setAppActive(false) }
        on(UIApplication.didBecomeActiveNotification) { $0.setAppActive(true) }
        #elseif canImport(AppKit)
        on(NSApplication.didResignActiveNotification) { $0.setAppActive(false) }
        on(NSApplication.didBecomeActiveNotification) { $0.setAppActive(true) }
        #endif
        on(NSNotification.Name.NSProcessInfoPowerStateDidChange) { $0.recompute() }
    }

    private func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        recompute()
    }

    // MARK: Per-bot phase

    /// A bot's stable place in the sway cycle.
    ///
    /// Upstream paints every face from one `t` with no offset, so a desktop
    /// roster breathes in perfect unison. On a phone the roster is the whole
    /// screen and that unison reads as a single object pulsing rather than a
    /// list of agents, so each bot gets a fixed offset instead.
    ///
    /// The span is one full period of the slowest idle channel (`turn`, at
    /// `sin(t·0.5)` → 4π s), so two bots can land anywhere in the cycle
    /// relative to each other. FNV-1a over UTF-8, the same hash family
    /// upstream seeds its sigils with (plugin.js:610-616), so the offset is
    /// stable across launches, devices and platforms: a bot always starts on
    /// the same beat.
    public static func swayPhase(for id: String) -> Double {
        var h: UInt32 = 2166136261
        for byte in id.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return Double(h % 100_000) / 100_000 * (4 * .pi)
    }
}

// MARK: - Schedule

/// The clock's `TimelineSchedule`: the exact instants the shared blink shuts
/// and opens, plus a periodic cadence when some face has a continuous pose to
/// sample.
///
/// The blink edges are always pinned, in both cadences. At 15 fps a 66 ms
/// sampling grid would smear the 180 ms idle blink into anything from 114 to
/// 246 ms depending on where it landed; pinning costs two extra entries per
/// 3.2 s and makes upstream's cadence exact instead of approximate. With no
/// periodic cadence at all, those two entries *are* the schedule.
public struct FaceSchedule: TimelineSchedule, Sendable {
    /// Idle blink cycle length, and the instant within it that the eyes shut
    /// (plugin.js:1020, `t % 3.2 > 3.02`).
    static let blinkPeriod: Double = 3.2
    static let blinkCloses: Double = 3.02

    var cadence: FaceClock.Cadence

    public init(_ cadence: FaceClock.Cadence) { self.cadence = cadence }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // `.lowFrequency` is the system saying it will not paint often — an
        // always-on display, or a severely throttled app. Blinks still land;
        // the continuous stream is not worth queueing.
        let interval: Double? = cadence.interval.map {
            mode == .lowFrequency ? 1 : Swift.max($0, 1.0 / 120)
        }
        return Entries(origin: cadence.origin,
                       cursor: startDate.timeIntervalSince(cadence.origin),
                       interval: interval)
    }

    public struct Entries: Sequence, IteratorProtocol {
        var origin: Date
        var cursor: Double
        var interval: Double?

        /// Two float hazards, both found by running this schedule rather than
        /// reading it:
        ///
        /// 1. Landing *exactly* on a blink edge. `9.42 % 3.2` comes back as
        ///    3.0199999999999996, which still reads as "before the close edge",
        ///    so the same instant is proposed again and the schedule stalls
        ///    there instead of moving to 9.6. Biasing the cursor forward by
        ///    `epsilon` before the modulo resolves "at an edge" as "just past
        ///    it", which is what the caller means.
        /// 2. `Date` cannot represent a 1-ULP nudge. Its storage is seconds
        ///    since 2001 — around 8×10⁸ today — where one ULP is ~1.2×10⁻⁷ s,
        ///    so advancing `cursor` by `.nextUp` produces a Date *equal* to the
        ///    previous one. A `TimelineSchedule` that repeats a date spins
        ///    SwiftUI's scheduler. `epsilon` is two orders of magnitude above
        ///    that ULP and far below anything an eye can resolve.
        private static let epsilon = 1e-5

        public mutating func next() -> Date? {
            let ahead = cursor + Self.epsilon
            let period = FaceSchedule.blinkPeriod
            let base = ahead - ahead.truncatingRemainder(dividingBy: period)
            var soonest = ahead - base < FaceSchedule.blinkCloses
                ? base + FaceSchedule.blinkCloses
                : base + period
            if let interval {
                soonest = Swift.min(soonest, (floor(ahead / interval) + 1) * interval)
            }
            cursor = Swift.max(soonest, ahead)
            return origin.addingTimeInterval(cursor)
        }
    }
}

/// The one `TimelineView` in the app. Rendered at zero size by whichever face
/// holds `driverTicket`, and simply absent whenever the clock is parked.
struct FaceClockDriver: View {
    var cadence: FaceClock.Cadence

    var body: some View {
        TimelineView(FaceSchedule(cadence)) { context in
            // The tick is published from an action rather than from the body:
            // mutating the clock while SwiftUI is evaluating this view would be
            // a write during an update pass. `initial` covers the first entry,
            // which `onChange` alone would swallow.
            Color.clear
                .onChange(of: context.date, initial: true) {
                    FaceClock.shared.advance(to: context.date)
                }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The second clause of the work-pose rule

/// Bots the roster considers live right now.
///
/// The work pose is conditional and has exactly two clauses (plugin.js:3852-3856):
/// the active profile *while the gateway is busy*, **or** any bot whose
/// `last_session.last_active` falls inside the 90 s liveness window. Explicitly
/// not "every bot whenever the gateway is busy".
///
/// `Bot.status == .working` carries the first clause — it is set from turn
/// events this app actually saw. The second clause is the one that catches a
/// cron run, the laptop, the CLI or another phone, and it lives in
/// `AppModel.isActiveNow(_:)`, which `TalariaTheme` cannot reach. This key is
/// how a host hands it down. It defaults to empty, so a surface that never sets
/// it degrades to the first clause alone rather than to a wrong pose.
public struct TalariaLiveBotsKey: EnvironmentKey {
    public static let defaultValue: Set<String> = []
}

public extension EnvironmentValues {
    var talariaLiveBots: Set<String> {
        get { self[TalariaLiveBotsKey.self] }
        set { self[TalariaLiveBotsKey.self] = newValue }
    }
}

public extension View {
    /// Publish the roster's liveness window to every face below.
    ///
    /// Pass the ids of bots inside the 90 s window — in Talaria,
    /// `model.roster.filter { model.isActiveNow($0.id) }.map(\.id)`. Faces read
    /// it to complete the two-clause work-pose rule.
    func talariaLiveBots(_ ids: Set<String>) -> some View {
        environment(\.talariaLiveBots, ids)
    }
}

import Foundation
import TalariaKit

// Drives the "<bot> is working" Live Activity (lock screen + Dynamic Island)
// from AppModel state. Mirrors the prototype's island pill: it appears while
// any bot is working, shows the avatar + phosphor elapsed clock, and taps
// deep-link into that bot's chat (talaria://bot/<id>).
//
// Policy (from the design map): one activity per bot, at most one concurrent
// activity overall, preferring the most recently started working bot; ends
// when the roster goes idle.

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@MainActor
public final class LiveActivityController {

    public static let shared = LiveActivityController()

    /// Mirrors the prototype's `liveActivity` tweak. Setting this false ends
    /// any running activity and stops new ones from starting.
    public var isEnabled: Bool = true {
        didSet { if isEnabled != oldValue { sync() } }
    }

    private weak var model: AppModel?
    private var activity: Activity<BotWorkAttributes>?
    private var lastState: BotWorkAttributes.ContentState?
    /// When each bot was first seen working — "most recent" is decided here.
    private var workingSince: [String: Date] = [:]
    private var attached = false

    public init() {}

    // MARK: - Attach / detach

    /// Start mirroring the model. Uses withObservationTracking re-armed on
    /// every change: reads inside `sync()` register dependencies on
    /// `model.bots` / `model.approvals`, so any roster or approval mutation
    /// schedules another pass on the main actor.
    public func attach(to model: AppModel) {
        // Idempotent: the app target attaches at launch and the root view
        // re-attaches on appear; re-arming for the same model would stack a
        // second observation chain.
        if attached, self.model === model { return }
        self.model = model
        attached = true
        adoptOrEndOrphans()
        arm()
    }

    /// Stop observing and tear down any running activity.
    public func detach() {
        attached = false
        model = nil
        workingSince = [:]
        stopActivity()
    }

    private func arm() {
        guard attached, let model else { return }
        withObservationTracking {
            self.sync(reading: model)
        } onChange: { [weak self] in
            // onChange fires on willSet; hop to the main actor so the next
            // pass reads settled values, then re-arm.
            Task { @MainActor [weak self] in
                guard let self, self.attached else { return }
                self.arm()
            }
        }
    }

    // MARK: - Sync

    private func sync() {
        guard let model else { return }
        sync(reading: model)
    }

    private func sync(reading model: AppModel) {
        let working = model.workingBots
        let pending = model.pendingApprovalCount()

        // Track when each bot began working; drop the ones that stopped.
        let now = Date()
        let workingIDs = Set(working.map(\.id))
        for bot in working where workingSince[bot.id] == nil {
            workingSince[bot.id] = now
        }
        workingSince = workingSince.filter { workingIDs.contains($0.key) }

        guard isEnabled, !working.isEmpty else {
            stopActivity()
            return
        }

        // Cap 1 concurrent: feature the most recently started working bot;
        // ties (e.g. everything seen at attach) break toward roster order,
        // matching the prototype's `bots.find(b => b.working)`.
        let featured = working
            .enumerated()
            .sorted { a, b in
                let ta = workingSince[a.element.id] ?? .distantPast
                let tb = workingSince[b.element.id] ?? .distantPast
                if ta != tb { return ta > tb }
                return a.offset < b.offset
            }
            .first!.element

        if let activity, activity.attributes.botID == featured.id {
            updateActivity(task: taskLine(for: featured), pendingApprovals: pending)
        } else {
            startActivity(for: featured, pendingApprovals: pending)
        }
    }

    /// The island's task line; falls back to the bot's job when the runtime
    /// hasn't labeled the turn yet.
    private func taskLine(for bot: Bot) -> String {
        bot.task ?? bot.job
    }

    // MARK: - Public start / update / stop

    /// Start (or replace) the single concurrent activity for `bot`.
    public func startActivity(for bot: Bot, pendingApprovals: Int) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Dedupe: never a second activity for the same bot.
        if let activity, activity.attributes.botID == bot.id { return }
        stopActivity()

        let attributes = BotWorkAttributes(
            botID: bot.id, botName: bot.id, shape: bot.shape, hue: bot.hue)
        let state = BotWorkAttributes.ContentState(
            task: taskLine(for: bot),
            startedAt: Date().addingTimeInterval(-Double(bot.minutesElapsed) * 60),
            pendingApprovals: pendingApprovals)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastState = state
        } catch {
            // Denied / budget exhausted — the in-app surfaces still cover it.
            activity = nil
            lastState = nil
        }
    }

    /// Push new dynamic content into the running activity (no-op when nothing
    /// changed, so observation-driven passes stay cheap).
    public func updateActivity(task: String, pendingApprovals: Int) {
        guard let activity, let previous = lastState else { return }
        var state = previous
        state.task = task
        state.pendingApprovals = pendingApprovals
        guard state != previous else { return }
        lastState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// End the running activity immediately (roster idle, disable, detach).
    public func stopActivity() {
        guard let activity else { return }
        self.activity = nil
        let finalState = lastState
        lastState = nil
        Task {
            let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Launch cleanup

    /// A previous process may have left activities behind. Adopt one so the
    /// next sync can update or end it; end any extras (cap 1 concurrent).
    private func adoptOrEndOrphans() {
        for existing in Activity<BotWorkAttributes>.activities {
            if activity == nil {
                activity = existing
                lastState = existing.content.state
            } else {
                Task { await existing.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}

#else

// macOS / non-ActivityKit builds: a no-op shim so call sites in the app model
// layer don't need their own platform gates.
@MainActor
public final class LiveActivityController {
    public static let shared = LiveActivityController()
    public var isEnabled: Bool = true
    public init() {}
    public func attach(to model: AppModel) {}
    public func detach() {}
    public func stopActivity() {}
}

#endif

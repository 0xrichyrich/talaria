import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

// The four derived surfaces — Routines, Activity, Agent Inbox, Artifacts — on
// live gateway data.
//
// None of them has a dedicated backend. Hermes exposes cron CRUD, session
// lists and transcripts; everything these screens show is folded out of those
// three primitives, exactly the way desktop does it:
//
//  · Routines  → cron.manage list/add/pause/resume/remove, jobs namespaced
//                "[bot:<name>] <title>", scoped per profile when the gateway
//                supports it. Run-now is REST (cron.manage has no run action).
//  · Activity  → an in-process journal fed by the live event stream, the
//                approvals array and the connection monitor, persisted so the
//                tab is not empty on the next launch.
//  · Inbox     → each profile's "Agent Inbox" session, read over the transcript
//                REST and split back into from → to rows by the A2A prefix the
//                CLI handoff writes ("Message from 🤖 <name> (@<handle>): …").
//  · Artifacts → the same transcripts, scanned for produced files, images and
//                links (a port of desktop's artifact-utils.ts extraction).
//
// Every path is live-mode only; demo mode keeps its canned world untouched.

// MARK: - Runtime (side table)

/// Book-keeping the feeds need that `AppModel` (another owner's file) cannot
/// hold. Observable so the screens can render scan state and error lines
/// without those living on the model.
@MainActor
@Observable
final class FeedsRuntime {
    static let shared = FeedsRuntime()

    // Activity journal — newest first, capped at `journalLimit`.
    var journal: [ActivityEntry] = []
    @ObservationIgnored var journalLoaded = false
    @ObservationIgnored var knownApprovals: [String: Approval] = [:]
    /// bot id → last seen roster preview, for inbound-A2A detection.
    @ObservationIgnored var knownPreviews: [String: String] = [:]
    @ObservationIgnored var wasOffline = false
    @ObservationIgnored var routedClient: ObjectIdentifier?
    @ObservationIgnored var eventToken: UUID?
    @ObservationIgnored var trackingStarted = false

    // Routines
    /// routine id → the job as the gateway returned it (canonical id + prompt).
    @ObservationIgnored var cronJobs: [String: CronJobRecord] = [:]
    /// routine id → the profile scope its RPCs must carry (nil = launch store).
    @ObservationIgnored var cronScope: [String: String?] = [:]
    /// True once a scoped list came back with the `scoped` marker.
    var cronPerProfile = false
    var routinesNote = ""
    var routinesError: String?
    var routinesBusy = false
    /// One successful list has landed for this link — a gateway with zero cron
    /// jobs must not re-trigger the initial load on every roster mutation.
    @ObservationIgnored var routinesLoaded = false
    /// Initial-load attempts on this link; a gateway without a cron surface
    /// gets a bounded number of tries, then only manual refreshes.
    @ObservationIgnored var routinesKicks = 0
    @ObservationIgnored var routinesTask: Task<Void, Never>?
    @ObservationIgnored var cronDebounce: Task<Void, Never>?
    @ObservationIgnored var lastRoutinesRefresh: Date?

    // Artifacts
    /// artifact id → the session that produced it.
    @ObservationIgnored var artifactSessions: [String: SessionRef] = [:]
    var artifactsNote = ""
    var artifactsScanning = false
    @ObservationIgnored var artifactsTask: Task<Void, Never>?
    @ObservationIgnored var lastArtifactScan: Date?

    // Agent Inbox
    /// message id → the "Agent Inbox" session it was read from.
    @ObservationIgnored var inboxSessions: [UUID: SessionRef] = [:]
    var inboxNote = ""
    var inboxScanning = false
    @ObservationIgnored var inboxTask: Task<Void, Never>?
    @ObservationIgnored var lastInboxScan: Date?

    static let journalLimit = 200
    static let journalKey = "talaria-activity-journal"

    /// Everything derived from one gateway; dropped when the link changes.
    func resetDerived() {
        cronJobs.removeAll(); cronScope.removeAll(); cronPerProfile = false
        routinesNote = ""; routinesError = nil; lastRoutinesRefresh = nil
        routinesLoaded = false
        artifactSessions.removeAll(); artifactsNote = ""; lastArtifactScan = nil
        inboxSessions.removeAll(); inboxNote = ""; lastInboxScan = nil
        artifactsTask?.cancel(); artifactsTask = nil
        inboxTask?.cancel(); inboxTask = nil
        routinesTask?.cancel(); routinesTask = nil
    }
}

/// Where a derived row came from, so a tap can reopen the exact session.
struct SessionRef: Sendable, Equatable {
    var botID: String
    /// Durable session key (session.resume / REST transcript id).
    var storedID: String
}

/// One journal row. `ActivityItem` carries a display clock string only, so the
/// journal keeps the real instant alongside it for grouping and persistence,
/// plus a dedupe key (approval id, job id, …) so a later event can update the
/// same row instead of appending a second one.
public struct ActivityEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var at: Date
    public var botID: String
    public var kind: ActivityKind
    public var text: String
    public var subtext: String
    public var pending: Bool
    public var key: String?

    public init(id: UUID = UUID(), at: Date = Date(), botID: String, kind: ActivityKind,
                text: String, subtext: String, pending: Bool = false, key: String? = nil) {
        self.id = id; self.at = at; self.botID = botID; self.kind = kind
        self.text = text; self.subtext = subtext; self.pending = pending; self.key = key
    }

    var item: ActivityItem {
        ActivityItem(id: id, time: ActivityEntry.clock.string(from: at), botID: botID,
                     kind: kind, text: text, subtext: subtext, pending: pending)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Activity feed

public extension AppModel {

    /// Start the feed router: restore the persisted journal, subscribe to the
    /// live event stream, and watch the model for the transitions events don't
    /// carry (approvals resolving, the link dropping, the gateway changing).
    ///
    /// Idempotent — every screen in this area calls it on appear, and the app's
    /// root can call it at launch.
    func attachActivityRouter() {
        let runtime = FeedsRuntime.shared
        if !runtime.journalLoaded {
            runtime.journalLoaded = true
            runtime.journal = Self.loadJournal()
            publishActivity()
        }
        guard !runtime.trackingStarted else {
            reconcileFeeds()
            return
        }
        runtime.trackingStarted = true
        runtime.wasOffline = isOffline
        runtime.knownApprovals = Dictionary(uniqueKeysWithValues: approvals.map { ($0.id, $0) })
        reconcileFeeds()
        trackFeedSources()
    }

    /// Append one entry to the journal (and to the visible feed in live mode).
    /// Public so the other areas' event handlers can land their own rows here —
    /// approvals, voice, capabilities, pushes.
    func recordActivity(kind: ActivityKind, botID: String, text: String,
                        subtext: String = "", pending: Bool = false,
                        key: String? = nil, at: Date = Date()) {
        guard !text.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        if !runtime.journalLoaded {
            runtime.journalLoaded = true
            runtime.journal = Self.loadJournal()
        }
        if let key, let idx = runtime.journal.firstIndex(where: { $0.key == key }) {
            // Same subject, new state (an approval answered) — update in place
            // so the ledger keeps one row per event, like desktop's notices.
            runtime.journal[idx].kind = kind
            runtime.journal[idx].text = text
            runtime.journal[idx].subtext = subtext
            runtime.journal[idx].pending = pending
        } else {
            runtime.journal.insert(ActivityEntry(at: at, botID: botID, kind: kind, text: text,
                                                 subtext: subtext, pending: pending, key: key),
                                   at: 0)
            if runtime.journal.count > FeedsRuntime.journalLimit {
                runtime.journal.removeLast(runtime.journal.count - FeedsRuntime.journalLimit)
            }
        }
        Self.saveJournal(runtime.journal)
        publishActivity()
    }

    /// Drop the persisted ledger (Activity's long-press action).
    func clearActivityJournal() {
        FeedsRuntime.shared.journal = []
        Self.saveJournal([])
        publishActivity()
    }

    /// Rebuild `activity` (day groups, newest first) from the journal. Demo
    /// mode keeps DemoData's scripted ledger.
    internal func publishActivity() {
        guard mode == .live else { return }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: FeedsRuntime.shared.journal) {
            calendar.startOfDay(for: $0.at)
        }
        activity = grouped.keys.sorted(by: >).map { day in
            let items = (grouped[day] ?? []).sorted { $0.at > $1.at }.map(\.item)
            return ActivityDay(day: Self.dayLabel(day, calendar: calendar), items: items)
        }
    }

    static func dayLabel(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        let age = calendar.dateComponents([.day], from: day, to: Date()).day ?? 0
        f.dateFormat = age < 7 ? "EEEE" : "d MMM"
        return f.string(from: day)
    }

    static func loadJournal() -> [ActivityEntry] {
        guard let data = UserDefaults.standard.data(forKey: FeedsRuntime.journalKey),
              let rows = try? JSONDecoder().decode([ActivityEntry].self, from: data) else { return [] }
        return rows
    }

    static func saveJournal(_ rows: [ActivityEntry]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: FeedsRuntime.journalKey)
    }

    // MARK: - Model observation (the transitions events don't carry)

    /// One observation cycle over the model state the feeds derive from.
    /// `withObservationTracking` fires once per change, so it re-arms itself.
    private func trackFeedSources() {
        withObservationTracking {
            _ = client
            _ = mode
            _ = isOffline
            _ = approvals
            _ = bots
        } onChange: {
            // onChange runs *before* the mutation lands; hop a turn so the new
            // values are readable.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileFeeds()
                self.trackFeedSources()
            }
        }
    }

    /// Diff the observed state against the last snapshot and journal what
    /// changed; re-subscribe when the gateway link is replaced.
    internal func reconcileFeeds() {
        let runtime = FeedsRuntime.shared

        // Gateway link changed (connect, reconnect, disconnect).
        let identity = client.map { ObjectIdentifier($0) }
        if identity != runtime.routedClient {
            runtime.routedClient = identity
            runtime.resetDerived()
            if let client { subscribe(to: client) }
            publishActivity()
        }
        if client != nil, mode == .live, !isOffline, !runtime.routinesLoaded {
            kickRoutinesRefresh()
        }

        // Link health — the disconnect monitor only flips `isOffline`.
        if isOffline != runtime.wasOffline {
            runtime.wasOffline = isOffline
            let host = LiveRuntime.shared.baseURL?.host() ?? "gateway"
            recordActivity(kind: .gateway, botID: "gateway",
                           text: isOffline ? theme.copy.feedGatewayDown(theme.themeID)
                                           : theme.copy.feedGatewayUp(theme.themeID),
                           subtext: host)
            // A reconnect re-runs the stock (id-less) routine refresh; re-read
            // the jobs afterwards so the canonical ids come back.
            if !isOffline {
                runtime.routinesLoaded = false
                runtime.routinesKicks = 0
                kickRoutinesRefresh()
            }
        }

        // Approvals: raised and resolved, from the array both modes maintain.
        // Demo's canned approvals (and the flush when a real gateway replaces
        // them) are state changes, not events — snapshot without journaling.
        let current = Dictionary(uniqueKeysWithValues: approvals.map { ($0.id, $0) })
        if mode == .live {
            for (id, approval) in current where runtime.knownApprovals[id] == nil {
                recordActivity(kind: .approval, botID: approval.botID,
                               text: theme.copy.feedApprovalRaised(theme.themeID) + " — " + approval.title,
                               subtext: approval.subject.isEmpty ? approval.why : approval.subject,
                               pending: true, key: "approval:" + id)
            }
            for (id, approval) in runtime.knownApprovals where current[id] == nil {
                recordActivity(kind: .approved, botID: approval.botID,
                               text: theme.copy.feedApprovalResolved(theme.themeID) + " — " + approval.title,
                               subtext: approval.subject.isEmpty ? approval.why : approval.subject,
                               pending: false, key: "approval:" + id)
            }
        }
        runtime.knownApprovals = current

        // Inbound A2A traffic, detected the way desktop's Bot Mode does it:
        // a profile whose newest session preview opens with the handoff
        // attribution just received a message from another bot.
        if mode == .live {
            for bot in bots {
                let preview = bot.preview.trimmingCharacters(in: .whitespaces)
                guard runtime.knownPreviews[bot.id] != preview else { continue }
                runtime.knownPreviews[bot.id] = preview
                guard let sender = Self.a2aSender(in: preview) else { continue }
                recordActivity(kind: .mention, botID: bot.id,
                               text: theme.copy.feedMention(theme.themeID) + " @" + sender,
                               subtext: Self.strippedA2A(preview),
                               key: "a2a:\(bot.id):\(Self.stableHash(preview))")
                if let idx = bots.firstIndex(where: { $0.id == bot.id }), !bots[idx].mentionsYou {
                    bots[idx].mentionsYou = true
                }
            }
        }
    }

    /// First routine load after a (re)connect. `client` is assigned before the
    /// socket is up, so the first attempt can land on a dead transport — retry
    /// a couple of times rather than leaving the screen empty until the next
    /// cron.changed.
    private func kickRoutinesRefresh() {
        let runtime = FeedsRuntime.shared
        guard runtime.routinesTask == nil, runtime.routinesKicks < 3 else { return }
        runtime.routinesKicks += 1
        runtime.routinesTask = Task { @MainActor [weak self] in
            defer { FeedsRuntime.shared.routinesTask = nil }
            // Let the connect path finish first: `client` is published before
            // the socket is ready, and the stock refresh writes the same array
            // moments later — this read has to be the one that lands.
            try? await Task.sleep(for: .milliseconds(600))
            for attempt in 0..<3 {
                guard let self, !Task.isCancelled else { return }
                await self.refreshRoutinesLive(force: true)
                if FeedsRuntime.shared.routinesError == nil { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            }
        }
    }

    /// Subscribe to the live event stream for the rows events alone can carry:
    /// finished turns, cron changes, produced files, inbound A2A mentions.
    private func subscribe(to client: GatewayClient) {
        Task { @MainActor in
            let token = await client.addEventHandler { event in
                Task { @MainActor [weak self] in self?.journal(event: event) }
            }
            FeedsRuntime.shared.eventToken = token
        }
    }

    private func journal(event: GatewayEvent) {
        guard mode == .live else { return }
        let botID = LiveRuntime.shared.sessionToBot[event.sessionID]
        switch TypedGatewayEvent(event) {
        case .messageComplete(let payload):
            guard let botID, payload.status != .error else { return }
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let sender = Self.a2aSender(in: text) {
                // A bot relayed another bot's message into this chat.
                recordActivity(kind: .mention, botID: botID,
                               text: theme.copy.feedMention(theme.themeID) + " @" + sender,
                               subtext: Self.strippedA2A(text))
                if let idx = bots.firstIndex(where: { $0.id == botID }) { bots[idx].mentionsYou = true }
            } else if text.lowercased().contains("@you") {
                recordActivity(kind: .mention, botID: botID,
                               text: theme.copy.feedMentionYou(theme.themeID),
                               subtext: Self.previewLine(text))
                if let idx = bots.firstIndex(where: { $0.id == botID }) { bots[idx].mentionsYou = true }
            } else if openBotID != botID {
                // A turn you watched land needs no ledger row; the 200-entry
                // window is for what happened while you were elsewhere.
                recordActivity(kind: .task, botID: botID,
                               text: theme.copy.feedTurnDone(theme.themeID),
                               subtext: Self.previewLine(text))
            }

        case .toolComplete(let tool):
            // Files and images a tool just produced go straight into the
            // artifact index — the transcript sweep would only find them on the
            // next scan.
            guard let botID else { return }
            ingestArtifacts(fromTool: tool, botID: botID, sessionID: event.sessionID)

        case .changed(let what) where what == "cron.changed":
            // The stock router also refreshes routines here; this refresh is
            // debounced so the richer per-profile mapping is the one that
            // lands last.
            FeedsRuntime.shared.cronDebounce?.cancel()
            FeedsRuntime.shared.cronDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                await self.refreshRoutinesLive(force: true)
                self.journalRoutineRuns()
            }

        default:
            break
        }
    }

    /// After a cron.changed refresh, journal every job whose last run is new.
    private func journalRoutineRuns() {
        let runtime = FeedsRuntime.shared
        for routine in routines {
            guard let job = runtime.cronJobs[routine.id], let last = job.lastRun,
                  last.timeIntervalSinceNow > -900 else { continue }
            let status = (job.lastStatus ?? "").lowercased()
            recordActivity(kind: .routine, botID: routine.botID,
                           text: theme.copy.feedRoutineRan(theme.themeID) + " — " + routine.name,
                           subtext: status == "error" ? theme.copy.feedRoutineFailed(theme.themeID)
                                                      : theme.copy.feedRoutineOK(theme.themeID),
                           key: "cron-run:\(job.id):\(Int(last.timeIntervalSince1970))",
                           at: last)
        }
    }
}

// MARK: - Routines (cron)

public extension AppModel {

    /// Live routine list. Reads the launch-profile cron store, then each bot's
    /// own store when the gateway honors `profile` scoping, and attributes
    /// anything unscoped by its "[bot:<name>] " prefix.
    func refreshRoutinesLive(force: Bool = false) async {
        guard mode == .live, let client else { return }
        let runtime = FeedsRuntime.shared
        // One list sweep at a time: a toggle, a cron.changed broadcast and a
        // screen appearing can all land within the same second. `force` skips
        // the idle throttle, never the in-flight guard.
        if runtime.routinesBusy { return }
        if !force, let last = runtime.lastRoutinesRefresh, last.timeIntervalSinceNow > -5 { return }
        runtime.routinesBusy = true
        defer { runtime.routinesBusy = false; runtime.lastRoutinesRefresh = Date() }

        let fallback = LiveRuntime.shared.defaultBotID ?? bots.first?.id ?? "default"
        var jobs: [String: (job: CronJobRecord, botID: String, scope: String?)] = [:]
        var scopedCount = 0
        var failed: String?

        do {
            let listing = try await client.cronJobs(includeDisabled: true)
            for job in listing.jobs where !job.id.isEmpty {
                jobs[job.id] = (job, job.taggedBotID ?? fallback, nil)
            }
        } catch {
            failed = (error as? GatewayError)?.message ?? error.localizedDescription
        }

        // Per-profile stores: only trust the rows when the gateway echoes the
        // scope marker — an older gateway ignores `profile` and would hand the
        // launch store back once per bot.
        for bot in bots.prefix(10) where bot.id != fallback {
            guard let listing = try? await client.cronJobs(profile: bot.id, includeDisabled: true),
                  listing.scopedProfile == bot.id else { continue }
            scopedCount += 1
            for job in listing.jobs where !job.id.isEmpty {
                jobs[job.id] = (job, job.taggedBotID ?? bot.id, bot.id)
            }
        }

        runtime.cronJobs = jobs.mapValues(\.job)
        runtime.cronScope = jobs.mapValues(\.scope)
        runtime.cronPerProfile = scopedCount > 0
        runtime.routinesError = failed
        runtime.routinesLoaded = failed == nil

        routines = jobs.values
            .sorted { ($0.job.nextRun ?? .distantFuture) < ($1.job.nextRun ?? .distantFuture) }
            .map { entry in
                Routine(id: entry.job.id, botID: entry.botID, name: entry.job.displayTitle,
                        schedule: entry.job.schedule,
                        next: entry.job.nextRun.map { Self.relativeNext($0.timeIntervalSince1970) } ?? "",
                        last: Self.lastRunLine(entry.job, theme: theme.themeID),
                        isOn: entry.job.isActive)
            }

        runtime.routinesNote = theme.copy.routinesScopeNote(theme.themeID,
                                                            perProfile: runtime.cronPerProfile,
                                                            count: routines.count)
    }

    /// "ran 07:00 · clean" / "—" before the first fire.
    static func lastRunLine(_ job: CronJobRecord, theme: ThemeID) -> String {
        guard let last = job.lastRun else { return "" }
        let when = shortTime(last.timeIntervalSince1970)
        let status = (job.lastStatus ?? "").lowercased()
        let verb = theme == .ink ? "last kept" : theme == .control ? "LAST" : "ran"
        if status == "error" {
            let bad = theme == .ink ? "failed" : theme == .control ? "FAILED" : "failed"
            return "\(verb) \(when) · \(bad)"
        }
        return "\(verb) \(when)"
    }

    /// Pause / resume — the gateway's real vocabulary. Optimistic, reconciled
    /// against the server's answer (a failure puts the switch back).
    func setRoutineEnabled(_ routine: Routine, enabled: Bool) {
        guard let idx = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[idx].isOn = enabled
        let key = "routine-toggle:\(routine.id)"
        toast(kind: .info,
              title: theme.copy.toastRoutinePaused(routine.name, on: enabled, theme.themeID),
              botID: routine.botID, key: key)
        guard mode == .live, let client else {
            settleToast(key: key)
            return
        }
        Task { @MainActor in
            let runtime = FeedsRuntime.shared
            do {
                try await client.cronSetPaused(jobID: routine.id, paused: !enabled,
                                               profile: runtime.cronScope[routine.id] ?? nil)
                runtime.routinesError = nil
                await refreshRoutinesLive(force: true)
                settleToast(key: key)
            } catch {
                if let i = routines.firstIndex(where: { $0.id == routine.id }) {
                    routines[i].isOn = !enabled
                }
                let reason = (error as? GatewayError)?.message ?? error.localizedDescription
                runtime.routinesError = reason
                toast(kind: .failure,
                      title: theme.copy.toastRoutineUpdateFailed(theme.themeID),
                      message: reason, botID: routine.botID, key: key)
            }
        }
    }

    /// Create a routine for a bot, namespaced "[bot:<name>] <title>".
    ///
    /// Deliberately written to the *launch* profile's cron store rather than the
    /// bot's own: `get_due_jobs` (cron/scheduler.py:6725) reads the store of the
    /// process that ticks, so a job written into another profile's store only
    /// ever fires if that profile runs its own gateway — which a phone talking
    /// to one homelab gateway cannot assume. The run still lands in the bot's
    /// own history through the delegating prompt below, which is the same v2
    /// form desktop writes.
    func createRoutine(botID: String, title: String, schedule: String, prompt: String,
                       repeatCount: Int? = nil, continuity: Bool = false) async throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanPrompt.isEmpty else {
            throw GatewayError(code: -1, message: "a routine needs a name and an instruction")
        }
        guard !cleanTitle.contains("\0"), !cleanPrompt.contains("\0") else {
            throw GatewayError(code: -1, message: "name and instruction cannot contain NUL")
        }
        guard let normalized = HermesSchedule.normalize(schedule) else {
            throw GatewayError(code: -1, message: theme.copy.scheduleHelp(theme.themeID))
        }
        guard mode == .live, let client else {
            throw GatewayError(code: -3, message: "connect a gateway to schedule routines")
        }
        try await client.cronAdd(name: "[bot:\(botID)] \(cleanTitle)",
                                 schedule: normalized,
                                 prompt: routinePrompt(botID: botID, title: cleanTitle,
                                                       instruction: cleanPrompt),
                                 repeatCount: repeatCount,
                                 continuity: continuity)
        await refreshRoutinesLive(force: true)
        recordActivity(kind: .routine, botID: botID,
                       text: theme.copy.feedRoutineAdded(theme.themeID) + " — " + cleanTitle,
                       subtext: normalized)
    }

    /// The stored prompt. The launch profile runs its own routines directly; any
    /// other bot's routine has to re-enter that profile, which is desktop's
    /// marker + CLI relay form (plugin.js `routinePrompt`). The `[bot-mode:
    /// routine:v2]` marker matters: desktop auto-pauses jobs carrying the older
    /// unmarked delegation text.
    internal func routinePrompt(botID: String, title: String, instruction: String) -> String {
        if botID == LiveRuntime.shared.defaultBotID { return instruction }
        return """
        [bot-mode:routine:v2] You are running the scheduled routine "\(title)" for agent '\(botID)'. \
        Execute it AS that agent so the run lands in its own history: run this in the terminal and \
        relay the output:

        hermes -p '\(botID)' chat -c 'Routine: \(title)' -q '[Scheduled routine] \(instruction)'

        If the command fails, report the error instead.
        """
    }

    func deleteRoutine(_ routine: Routine) async throws {
        guard mode == .live, let client else { return }
        try await client.cronRemove(jobID: routine.id,
                                    profile: FeedsRuntime.shared.cronScope[routine.id] ?? nil)
        routines.removeAll { $0.id == routine.id }
        FeedsRuntime.shared.cronJobs.removeValue(forKey: routine.id)
        await refreshRoutinesLive(force: true)
    }

    /// Fire a job now. `cron.manage` has no run action (4016) — the trigger
    /// lives on the REST router, so this needs the gateway's HTTP credential.
    ///
    /// - Returns: true when the run finished before the request returned; false
    ///   when it is still running on the gateway (the normal case for a real
    ///   agent run) so the caller can say "started" rather than "done".
    @discardableResult
    func runRoutineNow(_ routine: Routine) async throws -> Bool {
        guard mode == .live else { return false }
        guard let (base, credential) = gatewayRESTContext() else {
            throw GatewayError(code: -3, message: theme.copy.needsRESTNote(theme.themeID))
        }
        let finished = try await GatewayREST.triggerCronJob(
            baseURL: base, credential: credential, jobID: routine.id,
            profile: FeedsRuntime.shared.cronScope[routine.id] ?? nil)
        recordActivity(kind: .routine, botID: routine.botID,
                       text: theme.copy.feedRoutineTriggered(theme.themeID) + " — " + routine.name,
                       subtext: routine.schedule)
        await refreshRoutinesLive(force: true)
        return finished
    }

    /// Base URL + credential for the REST endpoints the WS surface lacks. The
    /// client keeps its own credential private; the registry holds the same
    /// Keychain copy, refreshed on every connect.
    internal func gatewayRESTContext() -> (URL, GatewayCredential)? {
        guard let base = LiveRuntime.shared.baseURL,
              let gateway = ConnectionRegistry.shared.gateway(forURL: base),
              let credential = ConnectionRegistry.shared.credential(for: gateway) else { return nil }
        return (base, credential)
    }
}

// MARK: - Artifacts (derived from transcripts)

public extension AppModel {

    /// Sweep recent sessions for produced files, images and links. There is no
    /// artifacts RPC — desktop derives the same index client-side from
    /// transcripts, and so does this (artifact-utils.ts parity).
    func refreshArtifacts(force: Bool = false) async {
        guard mode == .live, let client, !bots.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        if runtime.artifactsScanning { return }
        if !force, let last = runtime.lastArtifactScan, last.timeIntervalSinceNow > -120 { return }
        guard let (base, credential) = gatewayRESTContext() else {
            runtime.artifactsNote = theme.copy.needsRESTNote(theme.themeID)
            return
        }

        runtime.artifactsScanning = true
        defer { runtime.artifactsScanning = false; runtime.lastArtifactScan = Date() }

        var found: [Artifact] = []
        var refs: [String: SessionRef] = [:]
        var scanned = 0
        var failures = 0

        // One transcript resident at a time: recent sessions run to thousands
        // of rows and the phone pays for every one of them.
        for bot in bots.prefix(8) {
            // The forever chat is where a bot does most of its work, and it is
            // hidden — scanning without the flag indexes artifacts from every
            // session EXCEPT the one that matters (methods_session.py:180-186).
            guard let sessions = try? await client.listSessions(limit: 6, profile: bot.id,
                                                                includeHidden: true) else {
                failures += 1
                continue
            }
            for session in sessions.prefix(3) where session.messageCount > 0 {
                guard !Task.isCancelled else { return }
                do {
                    let rows = try await GatewayREST.sessionMessages(
                        baseURL: base, credential: credential,
                        storedID: session.id, profile: bot.id, limit: 150)
                    scanned += 1
                    let title = session.title.isEmpty ? (session.preview ?? "session") : session.title
                    let harvest = Self.artifacts(in: rows, botID: bot.id,
                                                 sessionID: session.id, sessionTitle: title,
                                                 sessionStart: session.startedAt)
                    for artifact in harvest {
                        refs[artifact.id] = SessionRef(botID: bot.id, storedID: session.id)
                    }
                    found.append(contentsOf: harvest)
                } catch {
                    failures += 1
                }
            }
        }

        // Live tool.complete ingestion may have added rows this sweep did not
        // see (the transcript row is written after the event). Keep those, but
        // match on bot + value, not id: the same file ingested live and swept
        // from the transcript carries two different timestamps.
        let swept = Set(found.map { "\($0.botID)|\(Self.artifactValue($0.id))" })
        let liveOnly = artifacts.filter {
            runtime.artifactSessions[$0.id] != nil
                && !swept.contains("\($0.botID)|\(Self.artifactValue($0.id))")
        }
        for artifact in liveOnly { refs[artifact.id] = runtime.artifactSessions[artifact.id] }

        runtime.artifactSessions = refs
        artifacts = (found + liveOnly)
            .sorted { Self.sortKey($0) > Self.sortKey($1) }
            .prefix(150)
            .map { $0 }
        runtime.artifactsNote = theme.copy.artifactsDerivationNote(theme.themeID,
                                                                  sessions: scanned,
                                                                  failures: failures)
    }

    /// Artifacts sort on the timestamp encoded in their id (see `artifactID`),
    /// so the grid stays newest-first across sweeps and live ingestion.
    static func sortKey(_ artifact: Artifact) -> Double {
        Double(artifact.id.split(separator: "|").first.map(String.init) ?? "") ?? 0
    }

    /// Card tap → open the exact session that produced it. `Artifact` carries
    /// no session field (shared model), so the owning session travels in the
    /// runtime's ref table and the chat is rebound to it before opening.
    func openArtifact(_ artifact: Artifact) {
        selectedTab = .home
        guard mode == .live, let ref = FeedsRuntime.shared.artifactSessions[artifact.id] else {
            // No owning session recorded — fall back to the bot's canonical
            // chat through openChat, never a raw openBotID write (which leaves
            // the transcript empty and forks on the first send).
            openChat(botID: artifact.botID)
            return
        }
        open(ref)
    }

    /// Rebind a bot's chat to a specific stored session and push into it.
    /// `openStoredSession` is the one path that rebinds AND resumes AND
    /// hydrates; `openChat` deliberately re-resolves the canonical forever-chat
    /// instead, so routing an artifact/inbox jump through it would land the
    /// user somewhere other than the session the row describes.
    internal func open(_ ref: SessionRef) {
        openStoredSession(ref.storedID, botID: ref.botID)
    }

    /// tool.complete → artifact rows, for files produced while you watch. Same
    /// admission rule as the transcript sweep: a producer tool, or any tool that
    /// announces media explicitly.
    internal func ingestArtifacts(fromTool tool: ToolCompletePayload, botID: String, sessionID: String) {
        let text = [tool.resultText, tool.summary].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let producer = ArtifactScan.isProducer(tool.name.lowercased())
        guard producer || text.contains("MEDIA:") || text.contains("Screenshot path:") else { return }

        let stored = chats[botID]?.storedSessionID
        // Same file, same bot, twice in a turn is one artifact.
        let known = Set(artifacts.filter { $0.botID == botID }
            .map { Self.artifactValue($0.id) })
        var added = false
        for value in ArtifactScan.values(inToolText: text, producer: producer).prefix(6)
        where !known.contains(value) {
            let artifact = Self.artifact(from: value, botID: botID,
                                         sessionID: stored ?? sessionID,
                                         sessionTitle: tool.name, at: Date())
            if let stored {
                FeedsRuntime.shared.artifactSessions[artifact.id] =
                    SessionRef(botID: botID, storedID: stored)
            }
            artifacts.insert(artifact, at: 0)
            added = true
        }
        if added, artifacts.count > 150 { artifacts.removeLast(artifacts.count - 150) }
    }

    /// Extract every artifact value from one session's transcript rows.
    static func artifacts(in rows: [JSONValue], botID: String, sessionID: String,
                          sessionTitle: String, sessionStart: Double?) -> [Artifact] {
        var seen = Set<String>()
        var out: [Artifact] = []
        for row in rows {
            let role = row["role"]?.stringValue ?? ""
            guard role == "assistant" || role == "tool" else { continue }
            let text = ArtifactScan.text(of: row)
            let when = HermesTime.date(row["timestamp"])
                ?? sessionStart.map { Date(timeIntervalSince1970: $0) }
                ?? Date()
            let values: [String]
            if role == "assistant" {
                values = ArtifactScan.values(inAssistantText: text)
            } else {
                let tool = (row["tool_name"]?.stringValue ?? row["name"]?.stringValue ?? "").lowercased()
                let producer = ArtifactScan.isProducer(tool)
                guard producer || text.contains("MEDIA:") || text.contains("Screenshot path:") else { continue }
                values = ArtifactScan.values(inToolText: text, producer: producer)
            }
            for value in values where seen.insert(value).inserted {
                out.append(artifact(from: value, botID: botID, sessionID: sessionID,
                                    sessionTitle: sessionTitle, at: when))
            }
        }
        return out
    }

    static func artifact(from value: String, botID: String, sessionID: String,
                         sessionTitle: String, at: Date) -> Artifact {
        let kind = ArtifactScan.kind(of: value)
        let label = ArtifactScan.label(of: value)
        return Artifact(id: artifactID(value, sessionID: sessionID, at: at),
                        botID: botID,
                        kind: kind,
                        ext: kind == .file ? ArtifactScan.ext(of: value) : nil,
                        title: kind == .link ? ArtifactScan.linkTitle(of: value) : label,
                        meta: sessionTitle,
                        when: shortTime(at.timeIntervalSince1970))
    }

    /// "<unix>|<session>|<value>" — sortable, unique, and the session id is
    /// recoverable for the jump-to-session tap.
    static func artifactID(_ value: String, sessionID: String, at: Date) -> String {
        "\(Int(at.timeIntervalSince1970))|\(sessionID)|\(value)"
    }

    /// The path/URL an artifact id was built from (the value may contain "|",
    /// so only the first two separators are structural).
    static func artifactValue(_ id: String) -> String {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 ? String(parts[2]) : id
    }
}

// MARK: - Agent Inbox (bot ⇄ bot)

public extension AppModel {

    /// Build the inbox from each profile's "Agent Inbox" session — the session
    /// upstream's handoff writes into (`hermes -p <bot> chat -c "Agent Inbox"`).
    /// Rows are split back into from → to by the A2A prefix the sender uses.
    func refreshAgentInbox(force: Bool = false) async {
        guard mode == .live, let client, !bots.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        if runtime.inboxScanning { return }
        if !force, let last = runtime.lastInboxScan, last.timeIntervalSinceNow > -60 { return }
        guard let (base, credential) = gatewayRESTContext() else {
            runtime.inboxNote = theme.copy.needsRESTNote(theme.themeID)
            return
        }

        runtime.inboxScanning = true
        defer { runtime.inboxScanning = false; runtime.lastInboxScan = Date() }

        var messages: [(A2AMessage, Date, SessionRef)] = []
        var sessionCount = 0

        for bot in bots.prefix(10) {
            // `isInboxSession` matches "Bot Chat" too, and Bot Mode sessions —
            // canonical chats included — are hidden, which session.list drops
            // unless asked (methods_session.py:180-186).
            guard let sessions = try? await client.listSessions(limit: 40, profile: bot.id,
                                                                includeHidden: true) else { continue }
            let inboxes = sessions.filter { Self.isInboxSession($0.title) }.prefix(2)
            for session in inboxes {
                guard !Task.isCancelled else { return }
                guard let rows = try? await GatewayREST.sessionMessages(
                    baseURL: base, credential: credential,
                    storedID: session.id, profile: bot.id, limit: 60) else { continue }
                sessionCount += 1
                let ref = SessionRef(botID: bot.id, storedID: session.id)
                for (message, at) in Self.inboxMessages(in: rows, owner: bot.id) {
                    messages.append((message, at, ref))
                }
            }
        }

        let ordered = messages.sorted { $0.1 > $1.1 }.prefix(80)
        var refs: [UUID: SessionRef] = [:]
        for entry in ordered { refs[entry.0.id] = entry.2 }
        runtime.inboxSessions = refs
        agentInbox = ordered.map(\.0)
        runtime.inboxNote = theme.copy.inboxSourceNote(theme.themeID, sessions: sessionCount)
    }

    /// The CLI handoff names the conversation; both the current "Agent Inbox"
    /// form and the newer "Bot Chat" one are the same feed.
    static func isInboxSession(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("agent inbox") || t.contains("bot chat")
    }

    /// Split one inbox transcript into attributed A2A rows.
    static func inboxMessages(in rows: [JSONValue], owner: String) -> [(A2AMessage, Date)] {
        var out: [(A2AMessage, Date)] = []
        var lastSender: String?
        for row in rows {
            let role = row["role"]?.stringValue ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let text = ArtifactScan.text(of: row).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let at = HermesTime.date(row["timestamp"]) ?? Date()
            let time = shortTime(at.timeIntervalSince1970)
            if role == "user" {
                guard let sender = a2aSender(in: text) else { continue }
                lastSender = sender
                out.append((A2AMessage(fromBotID: sender, toBotID: owner, time: time,
                                       text: strippedA2A(text)), at))
            } else if let sender = lastSender {
                // The owner's reply goes back to whoever last wrote in.
                out.append((A2AMessage(fromBotID: owner, toBotID: sender, time: time,
                                       text: previewLine(text)), at))
            }
        }
        return out
    }

    /// Hand a message to another bot: it lands in that bot's own "Agent Inbox"
    /// session with the sender attribution the roster convention expects.
    func sendHandoff(from: String, to: String, text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, from != to else { return }
        guard mode == .live, let client else {
            throw GatewayError(code: -3, message: "connect a gateway to hand off")
        }
        // The attribution prefix is a wire contract, and both halves are the
        // sender's IDENTITY, not its profile id: desktop sends
        // `Message from 🤖 ${senderName} (@${senderHandle})` where senderName
        // is the display title and senderHandle the @handle (plugin.js:2635,
        // and the same shape in the CLI recipe at 3654). Sending the raw
        // profile name put "Message from 🤖 default (@default)" into the other
        // bot's permanent transcript for the profile that presents as
        // Hermes/@hermes.
        let sender = identity(from)
        let attributed = "Message from 🤖 \(sender.displayTitle) (@\(sender.handle)): \(body)"
        // Inbox and canonical ("Bot Chat") sessions are hidden, and session.list
        // omits hidden rows unless asked (methods_session.py:180-186) — without
        // the flag an existing inbox is invisible and every handoff mints a
        // second one.
        let sessions = try await client.listSessions(limit: 40, profile: to, includeHidden: true)
        let existing = sessions.first { Self.isInboxSession($0.title) }
        let live: LiveSession
        if let existing {
            live = try await client.resumeSession(existing.id, profile: to, deferHistory: true)
        } else {
            live = try await client.createSession(profile: to, title: "Agent Inbox")
        }
        guard !live.sessionID.isEmpty else {
            throw GatewayError(code: -8, message: "could not open \(to)'s inbox session")
        }
        try await client.submitPrompt(sessionID: live.sessionID, text: attributed)

        // Show it immediately; the next sweep replaces it with the stored row
        // (and picks up the reply), so drop the sweep throttle too.
        let message = A2AMessage(fromBotID: from, toBotID: to, time: Self.clock(), text: body)
        agentInbox.insert(message, at: 0)
        let stored = live.storedSessionID.isEmpty ? existing?.id : live.storedSessionID
        if let stored {
            FeedsRuntime.shared.inboxSessions[message.id] = SessionRef(botID: to, storedID: stored)
        }
        FeedsRuntime.shared.lastInboxScan = nil
        recordActivity(kind: .mention, botID: to,
                       text: theme.copy.feedHandoffSent(theme.themeID) + " @" + from,
                       subtext: Self.previewLine(body))
    }

    /// Inbox row tap → the owning bot's inbox session.
    func openInboxMessage(_ message: A2AMessage) {
        guard mode == .live, let ref = FeedsRuntime.shared.inboxSessions[message.id] else {
            // Same rule as the artifact fallback: openChat, so the bot's
            // canonical conversation is resumed rather than opened empty.
            openChat(botID: message.toBotID == "all" ? message.fromBotID : message.toBotID)
            return
        }
        open(ref)
    }

    // MARK: A2A attribution (desktop's A2A_RE / A2A_PREFIX_RE)

    /// Sender handle from "Message from 🤖 <name> (@<handle>): …" or the older
    /// "Message from agent '<name>'" form.
    static func a2aSender(in text: String) -> String? {
        guard let range = text.range(of: #"^Message from (?:agent '[^']+'|🤖\s*[^\s(@:]+)"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let head = String(text[range])
        if let quoted = head.range(of: #"'[^']+'"#, options: .regularExpression) {
            return String(head[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "'")).lowercased()
        }
        let name = head.replacingOccurrences(of: "Message from", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "🤖", with: "")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name.lowercased()
    }

    /// The message with its attribution prefix removed.
    static func strippedA2A(_ text: String) -> String {
        guard let range = text.range(of: #"^Message from (?:agent '[^']+'|🤖[^:]+):\s*"#,
                                     options: [.regularExpression, .caseInsensitive]) else {
            return previewLine(text)
        }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Artifact scanning (port of desktop's artifact-utils.ts)

enum ArtifactScan {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp"]
    private static let fileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "pdf", "txt", "json", "md", "csv",
        "zip", "tar", "gz", "avi", "flac", "m4a", "mkv", "mp3", "ogg", "opus", "wav", "webm",
        "mp4", "mov", "html", "log", "py", "swift", "ts", "tsx", "js", "yaml", "yml", "toml",
    ]

    /// Tools that *produce* things. Reading a file is not an artifact; writing,
    /// generating, rendering, downloading or exporting one is.
    static func isProducer(_ tool: String) -> Bool {
        tool.range(of: #"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write|screenshot|image)(?:_|$)"#,
                   options: .regularExpression) != nil
            || tool.hasPrefix("bfl_flux3_")
    }

    /// Message text across the two row shapes: raw DB rows carry `content`,
    /// the session projection carries `text`.
    static func text(of row: JSONValue) -> String {
        if let content = row["content"]?.stringValue, !content.isEmpty { return content }
        if let text = row["text"]?.stringValue, !text.isEmpty { return text }
        if let context = row["context"]?.stringValue, !context.isEmpty { return context }
        // Multimodal content arrives as a structure; flatten its string leaves.
        if let content = row["content"] { return leaves(of: content).joined(separator: "\n") }
        return ""
    }

    private static func leaves(of value: JSONValue, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        switch value {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap { leaves(of: $0, depth: depth + 1) }
        case .object(let o): return o.values.flatMap { leaves(of: $0, depth: depth + 1) }
        default: return []
        }
    }

    /// Assistant prose: markdown images/links, bare URLs, MEDIA: tags, paths.
    static func values(inAssistantText text: String) -> [String] {
        var found: [String] = []
        found.append(contentsOf: matches(#"!\[[^\]]*\]\(([^)\s]+)\)"#, in: text, group: 1))
        found.append(contentsOf: matches(#"(?<!\!)\[[^\]]+\]\(([^)\s]+)\)"#, in: text, group: 1))
        found.append(contentsOf: mediaTags(in: text))
        found.append(contentsOf: matches(#"https?://[^\s<>"')]+"#, in: text, group: 0))
        found.append(contentsOf: matches(#"(?:^|[\s("'`])((?:/|~/|\./)[^\s"'`<>]+)"#, in: text, group: 1))
        return normalize(found)
    }

    /// Tool results: MEDIA: tags and screenshot paths always; everything else
    /// only from a producer tool, so a `read_file` never fills the gallery.
    static func values(inToolText text: String, producer: Bool) -> [String] {
        var found = mediaTags(in: text)
        found.append(contentsOf: matches(#"Screenshot path:\s*([^\r\n<>]+)"#, in: text, group: 1))
        if producer {
            found.append(contentsOf: matches(#"https?://[^\s<>"')]+"#, in: text, group: 0))
            found.append(contentsOf: matches(#"(?:^|[\s("'`])((?:/|~/|\./)[^\s"'`<>]+)"#, in: text, group: 1))
            found.append(contentsOf: matches(#""(?:[a-z_]*(?:path|file|url|saved_to))"\s*:\s*"([^"]+)""#,
                                             in: text, group: 1))
        }
        return normalize(found)
    }

    private static func mediaTags(in text: String) -> [String] {
        matches(#"MEDIA:\s*[`"']?([^`"'\n\s]+)[`"']?"#, in: text, group: 1)
    }

    private static func matches(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Trim trailing punctuation, drop anything that is not plausibly a file,
    /// image or link, and de-duplicate while keeping order.
    private static func normalize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "),.;\"'`*_"))
            guard value.count > 3, value.count < 400, looksLikeArtifact(value),
                  seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }

    static func looksLikeArtifact(_ value: String) -> Bool {
        if value.hasPrefix("data:image/") { return true }
        let isURL = value.hasPrefix("http://") || value.hasPrefix("https://")
        let isPath = value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("~/")
            || value.hasPrefix("file://")
        guard isURL || isPath else { return false }
        if isURL, !hasKnownExtension(value) { return true }   // a plain link
        return hasKnownExtension(value)
    }

    private static func hasKnownExtension(_ value: String) -> Bool {
        fileExtensions.contains(ext(of: value)?.lowercased() ?? "")
    }

    static func kind(of value: String) -> ArtifactKind {
        if value.hasPrefix("data:image/") { return .image }
        if let ext = ext(of: value)?.lowercased(), imageExtensions.contains(ext) { return .image }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return .link }
        return .file
    }

    /// Uppercased extension chip ("MD", "CSV") — nil when there is none. Reads
    /// the last path component so a dotted directory never wins.
    static func ext(of value: String) -> String? {
        let name = label(of: value)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8,
              ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext.uppercased()
    }

    /// Last path component — the file name people recognize.
    static func label(of value: String) -> String {
        let trimmed = value.split(separator: "?").first.map(String.init) ?? value
        let parts = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? trimmed
    }

    /// Links show host + last segment, the way the design's link cards read.
    static func linkTitle(of value: String) -> String {
        guard let url = URL(string: value), let host = url.host() else { return value }
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

// MARK: - Copy (themed strings for the derived feeds)

public extension CopyPack {

    // Activity ledger lines.
    func feedTurnDone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Finished a turn"
        case .control: "TURN COMPLETE"
        case .ink: "A turn was completed"
        }
    }

    func feedMention(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Message from"
        case .control: "INBOUND FROM"
        case .ink: "Word from"
        }
    }

    func feedMentionYou(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Mentioned you in its chat"
        case .control: "MENTIONED YOU"
        case .ink: "It called upon you"
        }
    }

    func feedRoutineRan(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Routine finished"
        case .control: "ROUTINE COMPLETE"
        case .ink: "A rite was kept"
        }
    }

    func feedRoutineOK(_ t: ThemeID) -> String {
        switch t {
        case .soft: "ran clean"
        case .control: "CLEAN"
        case .ink: "done cleanly"
        }
    }

    func feedRoutineFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "the run failed"
        case .control: "RUN FAILED"
        case .ink: "the rite failed"
        }
    }

    func feedRoutineAdded(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Routine scheduled"
        case .control: "ROUTINE ARMED"
        case .ink: "A rite inscribed"
        }
    }

    func feedRoutineTriggered(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Routine run now"
        case .control: "MANUAL FIRE"
        case .ink: "A rite called early"
        }
    }

    func feedApprovalRaised(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Needs approval"
        case .control: "HOLD RAISED"
        case .ink: "Awaits your seal"
        }
    }

    func feedApprovalResolved(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approval cleared"
        case .control: "HOLD CLEARED"
        case .ink: "The seal was given"
        }
    }

    func feedGatewayDown(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway unreachable"
        case .control: "LINK DOWN"
        case .ink: "The way is severed"
        }
    }

    func feedGatewayUp(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway recovered"
        case .control: "LINK RESTORED"
        case .ink: "The way is open"
        }
    }

    func feedHandoffSent(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Handoff sent as"
        case .control: "HANDOFF TX AS"
        case .ink: "A word carried as"
        }
    }

    // Empty states.
    func activityEmptyTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing yet"
        case .control: "FEED EMPTY"
        case .ink: "The ledger is blank"
        }
    }

    func activityEmptyBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Approvals, finished runs, routines and gateway blips land here as they happen."
        case .control: "APPROVALS · RUNS · ROUTINES · LINK EVENTS — LOGGED AS THEY LAND."
        case .ink: "Every deed — seals, rites, finished turns — shall be written here."
        }
    }

    func artifactsEmptyTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No outputs yet"
        case .control: "VAULT EMPTY"
        case .ink: "No relics yet"
        }
    }

    func artifactsEmptyBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Files, images and links your bots produce show up here once they have made some."
        case .control: "FILES · IMAGES · LINKS — INDEXED FROM SESSION OUTPUT."
        case .ink: "What the familiars make shall be kept here."
        }
    }

    func inboxEmptyTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No handoffs yet"
        case .control: "NO TRAFFIC"
        case .ink: "No parley yet"
        }
    }

    func inboxEmptyBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "When one bot hands work to another it lands in that bot’s Agent Inbox session — and here."
        case .control: "CROSS-PROFILE TRAFFIC APPEARS HERE — SESSION \"AGENT INBOX\" PER PROFILE."
        case .ink: "When one familiar addresses another, the word is kept in its Agent Inbox — and here."
        }
    }

    // Footnotes / derivation honesty.
    func artifactsDerivationNote(_ t: ThemeID, sessions: Int, failures: Int) -> String {
        let miss = failures > 0 ? (t == .control ? " · \(failures) UNREADABLE" : " · \(failures) unreadable") : ""
        switch t {
        case .soft:
            return "Derived on-device: \(sessions) recent sessions scanned for files, images and links. No artifacts API exists\(miss)."
        case .control:
            return "DERIVED CLIENT-SIDE — \(sessions) SESSIONS SCANNED. NO ARTIFACT RPC EXISTS\(miss)."
        case .ink:
            return "Gathered by hand from \(sessions) recent audiences; the gateway keeps no register of relics\(miss)."
        }
    }

    func inboxSourceNote(_ t: ThemeID, sessions: Int) -> String {
        switch t {
        case .soft: return "Read from \(sessions) “Agent Inbox” sessions across your profiles, attributed by sender."
        case .control: return "SOURCE — \(sessions) \"AGENT INBOX\" SESSIONS, CROSS-PROFILE, ATTRIBUTED."
        case .ink: return "Taken from \(sessions) Agent Inbox audiences, each word attributed."
        }
    }

    func routinesScopeNote(_ t: ThemeID, perProfile: Bool, count: Int) -> String {
        switch t {
        case .soft:
            return perProfile ? "\(count) jobs · each profile’s own cron store"
                              : "\(count) jobs · one cron store, attributed by [bot:] tag"
        case .control:
            return perProfile ? "\(count) JOBS · PER-PROFILE CRON STORES"
                              : "\(count) JOBS · SINGLE STORE · [BOT:] ATTRIBUTION"
        case .ink:
            return perProfile ? "\(count) rites, each kept in its familiar’s own book"
                              : "\(count) rites in one book, marked [bot:]"
        }
    }

    func needsRESTNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This needs the gateway’s HTTP API — reconnect and try again."
        case .control: "REQUIRES GATEWAY HTTP API — RECONNECT."
        case .ink: "This asks the gateway’s other door; open the way again."
        }
    }

    // Routine composer.
    func newRoutineTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "New routine"
        case .control: "NEW ROUTINE"
        case .ink: "Inscribe a rite"
        }
    }

    func routineNamePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name — e.g. Morning digest"
        case .control: "NAME — E.G. MORNING DIGEST"
        case .ink: "the rite’s name — e.g. Morning digest"
        }
    }

    func routineSchedulePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "When — “every morning at 7”"
        case .control: "WHEN — \"EVERY MORNING AT 7\""
        case .ink: "when — “every morning at seven”"
        }
    }

    func routinePromptPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What it should do, in full — the bot gets only this."
        case .control: "THE INSTRUCTION — SELF-CONTAINED."
        case .ink: "the charge, entire — the familiar reads only this."
        }
    }

    func scheduleHelp(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Try “every 30m”, “every morning at 7”, “weekdays at 9”, or a cron line like 0 9 * * *."
        case .control: "ACCEPTS: every 30m · 2h · weekdays at 9 · 0 9 * * *"
        case .ink: "Say “every 30m”, “every morning at seven”, “weekdays at nine”, or a cron line."
        }
    }

    func runNow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Run now"
        case .control: "FIRE NOW"
        case .ink: "keep it now"
        }
    }

    /// The run was claimed and is going; the outcome lands in the bot's chat.
    func routineRunStarted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Running now — the result lands in this bot’s chat."
        case .control: "FIRED — OUTPUT LANDS IN AGENT CHAT."
        case .ink: "It is being kept now; the result returns to this familiar’s chat."
        }
    }

    /// Activity's destructive action: drop the persisted ledger.
    func clearLedger(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Clear activity"
        case .control: "PURGE FEED"
        case .ink: "burn the ledger"
        }
    }

    func deleteRoutineLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete routine"
        case .control: "DELETE"
        case .ink: "strike it out"
        }
    }

    func repeatForever(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Repeat until stopped"
        case .control: "REPEAT FOREVER"
        case .ink: "kept without end"
        }
    }

    func continuityLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Feed it its own last output"
        case .control: "CONTINUITY — PRIOR OUTPUT IN"
        case .ink: "let it read its own last work"
        }
    }

    // Inbox composer.
    func composeHandoff(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Hand off to a bot"
        case .control: "TRANSMIT HANDOFF"
        case .ink: "send word to a familiar"
        }
    }

    func handoffFrom(_ t: ThemeID) -> String {
        switch t {
        case .soft: "From"
        case .control: "FROM"
        case .ink: "from"
        }
    }

    func handoffTo(_ t: ThemeID) -> String {
        switch t {
        case .soft: "To"
        case .control: "TO"
        case .ink: "unto"
        }
    }

    func handoffPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What should it do?"
        case .control: "PAYLOAD"
        case .ink: "what shall it do?"
        }
    }

    func send(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Send"
        case .control: "TRANSMIT"
        case .ink: "send"
        }
    }

    // Artifact filters.
    func artifactFilter(_ t: ThemeID, kind: ArtifactKind?) -> String {
        switch (kind, t) {
        case (nil, .soft): return "All"
        case (nil, .control): return "ALL"
        case (nil, .ink): return "all"
        case (.image, .soft): return "Images"
        case (.image, .control): return "IMAGES"
        case (.image, .ink): return "images"
        case (.file, .soft): return "Files"
        case (.file, .control): return "FILES"
        case (.file, .ink): return "files"
        case (.link, .soft): return "Links"
        case (.link, .control): return "LINKS"
        case (.link, .ink): return "links"
        }
    }

    func refreshLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Refresh"
        case .control: "RESCAN"
        case .ink: "gather again"
        }
    }

    func scanningLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Scanning sessions…"
        case .control: "SCANNING SESSIONS…"
        case .ink: "reading the audiences…"
        }
    }
}

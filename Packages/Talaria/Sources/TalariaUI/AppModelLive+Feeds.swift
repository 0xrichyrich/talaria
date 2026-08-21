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
    /// Routine UI id → exact gateway/job/profile destination. Primary rows
    /// keep their raw ids for the existing detail surface; remote rows do not.
    @ObservationIgnored var routineTargets: [String: RoutineTarget] = [:]
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
        cronJobs.removeAll(); cronScope.removeAll(); routineTargets.removeAll()
        cronPerProfile = false
        routinesNote = ""; routinesError = nil; lastRoutinesRefresh = nil
        routinesLoaded = false
        artifactSessions.removeAll(); artifactsNote = ""; lastArtifactScan = nil
        // Inbox refs are gateway-qualified and may belong to retained
        // secondary clients. Primary teardown removes only its scope through
        // dropA2AScope; a primary client identity change must preserve remotes.
        inboxNote = ""; lastInboxScan = nil
        artifactsTask?.cancel(); artifactsTask = nil
        inboxTask?.cancel(); inboxTask = nil
        routinesTask?.cancel(); routinesTask = nil
    }
}

struct RoutineTarget: Sendable, Equatable {
    var route: GatewayRoutineRoute
    /// The bot route is a display/manageability identity parsed from the
    /// namespaced job title. It is never REST/store authority.
    var bot: GatewayBotRoute
    /// Only an exact echo from a profile-scoped listing may populate this
    /// store scope. Nil means the launch store remains intentionally
    /// unscoped, even when `bot` carries a display tag.
    var profile: String?
}

/// Where a derived row came from, so a tap can reopen the exact session.
struct SessionRef: Sendable, Equatable {
    /// Exact source of both the profile and durable session id.
    var gatewayID: String
    var botID: String
    /// Durable session key (session.resume / REST transcript id). This is
    /// transcript provenance only; it is not filesystem authority. Artifact
    /// bytes still require a separately validated managed-root admission at
    /// the fetch boundary.
    var storedID: String

    func rosterID(activeGatewayID: String?) -> String? {
        let profile = GatewayBotRoute(qualifiedID: botID)?.profile ?? botID
        guard !gatewayID.isEmpty, !profile.isEmpty else { return nil }
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        return route.gatewayID == activeGatewayID ? route.profile : route.qualifiedID
    }
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
                Task { @MainActor [weak self] in
                    self?.journal(event: event, sourceClient: client)
                }
            }
            FeedsRuntime.shared.eventToken = token
        }
    }

    private func journal(event: GatewayEvent, sourceClient: GatewayClient) {
        guard mode == .live, client === sourceClient,
              let gatewayID = LiveRuntime.shared.gatewayID,
              let sourceFence = cronSourceMutationFence(gatewayID: gatewayID, profile: nil),
              cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else { return }
        let botID = LiveRuntime.shared.sessionToBot[event.sessionID]
        switch TypedGatewayEvent(event) {
        case .messageComplete(let payload):
            guard let botID,
                  let eventProfileToken = profileLifecycleGenerationToken(for: botID),
                  profileLifecycleAccepts(eventProfileToken),
                  payload.status != .error else { return }
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
            guard let botID,
                  let eventProfileToken = profileLifecycleGenerationToken(for: botID),
                  profileLifecycleAccepts(eventProfileToken) else { return }
            ingestArtifacts(fromTool: tool, botID: botID, sessionID: event.sessionID)

        case .changed(let what) where what == "cron.changed":
            // The stock router also refreshes routines here; this refresh is
            // debounced so the richer per-profile mapping is the one that
            // lands last.
            FeedsRuntime.shared.cronDebounce?.cancel()
            FeedsRuntime.shared.cronDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self,
                      self.client === sourceClient,
                      self.cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else { return }
                await self.refreshRoutinesLive(force: true)
                guard self.client === sourceClient,
                      self.cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else { return }
                self.journalRoutineRuns(sourceClient: sourceClient,
                                        sourceFence: sourceFence)
            }

        default:
            break
        }
    }

    /// After a cron.changed refresh, journal every job whose last run is new.
    private func journalRoutineRuns(sourceClient: GatewayClient,
                                    sourceFence: CronSourceMutationFence) {
        guard client === sourceClient,
              cronMutationFenceAccepts(sourceFence, expectedClient: sourceClient) else { return }
        let runtime = FeedsRuntime.shared
        for routine in routines {
            guard let target = runtime.routineTargets[routine.id],
                  target.route.gatewayID == sourceFence.gatewayID,
                  let routineFence = cronRoutineMutationFence(routine.id),
                  cronMutationFenceAccepts(routineFence, expectedClient: sourceClient) else { continue }
            guard let job = runtime.cronJobs[routine.id], let last = job.lastRun,
                  last.timeIntervalSinceNow > -900 else { continue }
            let status = (job.lastStatus ?? "").lowercased()
            recordActivity(kind: .routine, botID: routine.botID,
                           text: theme.copy.feedRoutineRan(theme.themeID) + " — " + routine.name,
                           subtext: status == "error" ? theme.copy.feedRoutineFailed(theme.themeID)
                                                      : theme.copy.feedRoutineOK(theme.themeID),
                           key: "cron-run:\(routineFence.activityIdentity):"
                               + "\(Int(last.timeIntervalSince1970))",
                           at: last)
        }
    }
}

// MARK: - Routines (cron)

public extension AppModel {

    /// Remove every authoritative and in-flight detail artifact for a row that
    /// no longer belongs to the current source. Keeping only `detail` clear
    /// would let a late editor/history task repopulate the replacement screen.
    func clearCronRoutineCaches(_ routineID: String) {
        let detail = CronDetailRuntime.shared
        detail.detail.removeValue(forKey: routineID)
        detail.runs.removeValue(forKey: routineID)
        detail.detailError.removeValue(forKey: routineID)
        detail.detailAuthority.removeValue(forKey: routineID)
        detail.runsAuthority.removeValue(forKey: routineID)
        detail.detailLoadingAuthority.removeValue(forKey: routineID)
        detail.runsLoadingAuthority.removeValue(forKey: routineID)
        detail.loadingDetail.remove(routineID)
        detail.loadingRuns.remove(routineID)
    }

    /// Quarantine markers are full routine-fence identities. Clear every
    /// generation owned by a removed row, including a legacy raw-id marker
    /// left by an older process. The matching quarantine/run activity rows are
    /// part of the same disposable source state; leaving them in the journal
    /// would make a deleted profile look as if it still owned a live routine.
    func clearCronRoutineQuarantine(_ routineID: String) {
        let prefix = "\(routineID)|"
        CronDetailRuntime.shared.quarantined = CronDetailRuntime.shared.quarantined
            .filter { $0 != routineID && !$0.hasPrefix(prefix) }
        let feeds = FeedsRuntime.shared
        if !feeds.journalLoaded {
            feeds.journalLoaded = true
            feeds.journal = Self.loadJournal()
        }
        let filtered = feeds.journal.filter { entry in
            guard let key = entry.key else { return true }
            return !CronQuarantinePolicy.ownsActivityKey(key, routineID: routineID)
        }
        guard filtered.count != feeds.journal.count else { return }
        feeds.journal = filtered
        Self.saveJournal(filtered)
        publishActivity()
    }

    func dropRoutineScope(gatewayID: String) {
        let runtime = FeedsRuntime.shared
        let stale = Set(runtime.routineTargets.compactMap { key, target in
            target.route.gatewayID == gatewayID ? key : nil
        })
        routines.removeAll { routine in
            stale.contains(routine.id)
                || GatewayBotRoute(qualifiedID: routine.botID)?.gatewayID == gatewayID
        }
        for id in stale {
            runtime.cronJobs.removeValue(forKey: id)
            runtime.cronScope.removeValue(forKey: id)
            runtime.routineTargets.removeValue(forKey: id)
            clearCronRoutineCaches(id)
            clearCronRoutineQuarantine(id)
        }
        CronDetailRuntime.shared.deliveryTargets.removeValue(forKey: gatewayID)
        CronDetailRuntime.shared.deliveryLoaded.remove(gatewayID)
        CronDetailRuntime.shared.deliveryGeneration.removeValue(forKey: gatewayID)
        CronDetailRuntime.shared.restSupported.removeValue(forKey: gatewayID)
        CronDetailRuntime.shared.restSupportGeneration.removeValue(forKey: gatewayID)
    }

    /// Every live row carries an exact gateway/job/profile destination. Full
    /// management is therefore safe for remote rows too; individual actions
    /// still fail closed if that gateway was removed or signed out.
    func routineHasFullManagement(_ routine: Routine) -> Bool {
        mode != .live || FeedsRuntime.shared.routineTargets[routine.id] != nil
    }

    /// Live routine list. Reads the launch-profile cron store, then each bot's
    /// own store when the gateway honors `profile` scoping, and attributes
    /// anything unscoped by its "[bot:<name>] " prefix.
    func refreshRoutinesLive(force: Bool = false) async {
        guard mode == .live, let client, let primaryGatewayID = LiveRuntime.shared.gatewayID
        else { return }
        guard let sourceFence = cronSourceMutationFence(gatewayID: primaryGatewayID, profile: nil),
              cronMutationFenceAccepts(sourceFence, expectedClient: client),
              self.client === client else { return }
        let runtime = FeedsRuntime.shared
        // One list sweep at a time: a toggle, a cron.changed broadcast and a
        // screen appearing can all land within the same second. `force` skips
        // the idle throttle, never the in-flight guard.
        if runtime.routinesBusy { return }
        if !force, let last = runtime.lastRoutinesRefresh, last.timeIntervalSinceNow > -5 { return }
        runtime.routinesBusy = true
        defer { runtime.routinesBusy = false; runtime.lastRoutinesRefresh = Date() }

        let primaryProfileIDs = bots.prefix(10).map(\.id)
        let primaryProfileTokens = Dictionary(uniqueKeysWithValues: primaryProfileIDs.compactMap {
            profileID in
            profileLifecycleGenerationToken(for: profileID).map { token in (profileID, token) }
        })
        guard primaryProfileTokens.count == primaryProfileIDs.count,
              primaryProfileTokens.values.allSatisfy({ profileLifecycleAccepts($0) }) else {
            runtime.routinesError = "Profile authority is unavailable; routines were not refreshed."
            runtime.routinesLoaded = false
            return
        }
        var jobs: [String: (job: CronJobRecord, displayBotID: String, scope: String?)] = [:]
        var scopedCount = 0
        var failed: String?

        do {
            let listing = try await client.cronJobs(includeDisabled: true)
            guard self.client === client,
                  cronMutationFenceAccepts(sourceFence, expectedClient: client),
                  primaryProfileTokens.values.allSatisfy({ profileLifecycleAccepts($0) }) else { return }
            for job in listing.jobs where !job.id.isEmpty {
                // This request is unscoped: even a deceptive row/top-level
                // profile is not evidence that the process launched that
                // store. Keep the raw payload, but leave target/scope nil.
                jobs[job.id] = (job, CronListingAttributionPolicy.displayBotID(for: job), nil)
            }
        } catch {
            failed = (error as? GatewayError)?.message ?? error.localizedDescription
        }

        // Per-profile stores: only trust the rows when the gateway echoes the
        // scope marker — an older gateway ignores `profile` and would hand the
        // launch store back once per bot.
        if failed == nil {
            for botID in primaryProfileIDs {
                guard self.client === client,
                      cronMutationFenceAccepts(sourceFence, expectedClient: client),
                      let token = primaryProfileTokens[botID], profileLifecycleAccepts(token)
                else { return }
                do {
                    let listing = try await client.cronJobs(profile: botID,
                                                            includeDisabled: true)
                    // A successful response without the exact scope marker is
                    // an incomplete snapshot, not legacy success. Continuing
                    // would make the final publication prune a prior verified
                    // row for this profile.
                    guard CronListingScopePolicy.acceptsExactScopeEcho(
                        listing, requestedProfile: botID),
                          let scope = CronListingScopePolicy.scope(
                              for: listing, requestedProfile: botID) else {
                        failed = CronListingScopePolicy.incompleteScopeMessage
                        break
                    }
                    guard self.client === client,
                          cronMutationFenceAccepts(sourceFence, expectedClient: client),
                          profileLifecycleAccepts(token) else { return }
                    scopedCount += 1
                    for job in listing.jobs where !job.id.isEmpty {
                        jobs[job.id] = (job, CronListingAttributionPolicy.displayBotID(
                            for: job, scopedProfile: scope), scope)
                    }
                } catch {
                    failed = (error as? GatewayError)?.message ?? error.localizedDescription
                    break
                }
            }
        }

        guard self.client === client,
              cronMutationFenceAccepts(sourceFence, expectedClient: client),
              primaryProfileTokens.values.allSatisfy({ profileLifecycleAccepts($0) }) else {
            return
        }
        guard failed == nil else {
            runtime.routinesError = failed
            runtime.routinesLoaded = false
            return
        }

        let oldPrimaryIDs = Set(runtime.routineTargets.compactMap { id, target in
            target.route.gatewayID == primaryGatewayID ? id : nil
        })
        // Keep the previous source-qualified rows before pruning them. The
        // comparison below decides whether a same-id row is actually a new
        // target; consulting the already-filtered dictionary would make every
        // refresh look like a replacement and clear every open detail cache.
        let priorPrimaryTargets = runtime.routineTargets.filter {
            $0.value.route.gatewayID == primaryGatewayID
        }
        let newPrimaryIDs = Set(jobs.keys)
        for id in oldPrimaryIDs.subtracting(newPrimaryIDs) {
            clearCronRoutineCaches(id)
            clearCronRoutineQuarantine(id)
        }
        runtime.cronJobs = runtime.cronJobs.filter {
            runtime.routineTargets[$0.key]?.route.gatewayID != primaryGatewayID
        }
        runtime.cronScope = runtime.cronScope.filter {
            runtime.routineTargets[$0.key]?.route.gatewayID != primaryGatewayID
        }
        runtime.routineTargets = runtime.routineTargets.filter {
            $0.value.route.gatewayID != primaryGatewayID
        }
        for (jobID, entry) in jobs {
            let nextTarget = RoutineTarget(
                route: GatewayRoutineRoute(gatewayID: primaryGatewayID, jobID: jobID),
                bot: GatewayBotRoute(gatewayID: primaryGatewayID, profile: entry.displayBotID),
                profile: entry.scope)
            let priorTarget = priorPrimaryTargets[jobID]
            let priorDetailAuthority = CronDetailRuntime.shared.detailAuthority[jobID]
            runtime.routineTargets[jobID] = nextTarget
            // A list refresh can reuse the same raw job id after a profile or
            // source replacement. Do not let the old detail/history become
            // editable against the new row while its fresh REST read is still
            // pending.
            if priorTarget != nextTarget
                || (priorDetailAuthority != nil
                    && cronRoutineMutationFence(jobID) != priorDetailAuthority) {
                clearCronRoutineCaches(jobID)
                clearCronRoutineQuarantine(jobID)
            }
            runtime.cronJobs[jobID] = entry.job
            runtime.cronScope[jobID] = entry.scope
        }
        runtime.cronPerProfile = scopedCount > 0
        runtime.routinesError = failed
        runtime.routinesLoaded = failed == nil

        let primaryRows = jobs.values
            .sorted { ($0.job.nextRun ?? .distantFuture) < ($1.job.nextRun ?? .distantFuture) }
            .map { entry in
                Routine(id: entry.job.id, botID: entry.displayBotID, name: entry.job.displayTitle,
                        schedule: entry.job.schedule,
                        next: entry.job.nextRun.map { Self.relativeNext($0.timeIntervalSince1970) } ?? "",
                        last: Self.lastRunLine(entry.job, theme: theme.themeID),
                        isOn: entry.job.isActive)
            }
        routines.removeAll { routine in
            oldPrimaryIDs.contains(routine.id)
                || (GatewayBotRoute(qualifiedID: routine.botID) == nil
                    && !newPrimaryIDs.contains(routine.id))
        }
        routines.append(contentsOf: primaryRows)

        await refreshSecondaryRoutines()
        guard self.client === client,
              cronMutationFenceAccepts(sourceFence, expectedClient: client) else { return }
        routines.sort { lhs, rhs in
            let left = runtime.cronJobs[lhs.id]?.nextRun ?? .distantFuture
            let right = runtime.cronJobs[rhs.id]?.nextRun ?? .distantFuture
            return left < right
        }

        runtime.routinesNote = theme.copy.routinesScopeNote(theme.themeID,
                                                            perProfile: runtime.cronPerProfile,
                                                            count: routines.count)
    }

    private func refreshSecondaryRoutines() async {
        let feeds = FeedsRuntime.shared
        let gatewayIDs = ConnectionRegistry.shared.saved.map(\.id)
        for gatewayID in gatewayIDs {
            guard gatewayID != LiveRuntime.shared.gatewayID else { continue }
            // Roster enumeration already owns dialing/backoff. A routines
            // refresh consumes only retained clients so opening this screen
            // cannot serially wake every sleeping LAN machine.
            guard let client = await ConnectionRegistry.shared.clientPool.client(for: gatewayID)
            else { continue }
            await attachRoutedEventsIfNeeded(client: client, gatewayID: gatewayID)
            guard let current = MultiGatewayRuntime.shared.routedEvents[gatewayID],
                  current.client === client,
                  let sourceFence = cronSourceMutationFence(gatewayID: gatewayID, profile: nil),
                  CronProfileRefreshPolicy.mayPublishSnapshot(
                      sourceAccepted: cronMutationFenceAccepts(sourceFence,
                                                               expectedClient: client),
                      lifecycleAuthorityAccepted: true) else { continue }
            guard let profiles = try? await client.listProfiles(includeSessions: false) else {
                continue
            }
            guard let current = MultiGatewayRuntime.shared.routedEvents[gatewayID],
                  current.client === client,
                  CronProfileRefreshPolicy.mayPublishSnapshot(
                      sourceAccepted: cronMutationFenceAccepts(sourceFence,
                                                               expectedClient: client),
                      lifecycleAuthorityAccepted: true) else { continue }
            // Capture every expected profile token before reading any cron
            // store. Re-reading only the profile currently in the loop would
            // accept a stale A snapshot when A changes during a later B read.
            let expectedProfiles = Array(profiles.prefix(10))
            let expectedProfileNames = expectedProfiles.map(\.name)
            var profileTokens: [String: ProfileLifecycleGenerationToken] = [:]
            for profile in expectedProfiles {
                guard let token = profileLifecycleGenerationToken(
                    for: GatewayBotRoute(gatewayID: gatewayID,
                                         profile: profile.name).qualifiedID) else {
                    profileTokens.removeAll()
                    break
                }
                profileTokens[profile.name] = token
            }
            guard CronProfileRefreshPolicy.capturedProfilesRemainCurrent(
                expectedProfiles: expectedProfileNames,
                tokens: profileTokens,
                isCurrent: profileLifecycleAccepts) else { continue }

            var jobs: [String: (job: CronJobRecord, displayBotID: String, scope: String?)] = [:]
            let launchListing: CronListing
            do {
                launchListing = try await client.cronJobs(includeDisabled: true)
            } catch {
                // No authoritative launch identity is available for an
                // unscoped response; retain the previous gateway snapshot.
                continue
            }
            guard let current = MultiGatewayRuntime.shared.routedEvents[gatewayID],
                  current.client === client,
                  CronProfileRefreshPolicy.mayPublishSnapshot(
                      sourceAccepted: cronMutationFenceAccepts(sourceFence,
                                                               expectedClient: client),
                      lifecycleAuthorityAccepted: CronProfileRefreshPolicy
                          .capturedProfilesRemainCurrent(
                              expectedProfiles: expectedProfileNames,
                              tokens: profileTokens,
                              isCurrent: profileLifecycleAccepts)) else { continue }
            for job in launchListing.jobs where !job.id.isEmpty {
                // The unscoped launch store has no profile authority. Ignore
                // both the row and listing profile fields until a scoped
                // request with an exact echo proves ownership.
                jobs[job.id] = (job, CronListingAttributionPolicy.displayBotID(for: job), nil)
            }
            var profileReadFailed = false
            for profile in expectedProfiles {
                guard CronProfileRefreshPolicy.capturedProfilesRemainCurrent(
                    expectedProfiles: expectedProfileNames,
                    tokens: profileTokens,
                    isCurrent: profileLifecycleAccepts) else {
                    profileReadFailed = true
                    break
                }
                do {
                    let listing = try await client.cronJobs(
                        profile: profile.name, includeDisabled: true)
                    guard let current = MultiGatewayRuntime.shared.routedEvents[gatewayID],
                          current.client === client,
                          cronMutationFenceAccepts(sourceFence, expectedClient: client),
                          CronProfileRefreshPolicy.capturedProfilesRemainCurrent(
                              expectedProfiles: expectedProfileNames,
                              tokens: profileTokens,
                              isCurrent: profileLifecycleAccepts) else {
                        profileReadFailed = true
                        break
                    }
                    // A successful response without the exact scope marker is
                    // an incomplete snapshot, not legacy success. Continuing
                    // would make publication prune a prior verified row.
                    guard CronListingScopePolicy.acceptsExactScopeEcho(
                        listing, requestedProfile: profile.name),
                          let scope = CronListingScopePolicy.scope(
                              for: listing, requestedProfile: profile.name) else {
                        profileReadFailed = true
                        break
                    }
                    for job in listing.jobs where !job.id.isEmpty {
                        jobs[job.id] = (job, CronListingAttributionPolicy.displayBotID(
                            for: job, scopedProfile: scope), scope)
                    }
                } catch {
                    profileReadFailed = true
                    break
                }
            }

            // Do not prune/publish this gateway's old rows when one scoped
            // request threw or omitted its exact scope echo.
            if profileReadFailed { continue }

            guard let current = MultiGatewayRuntime.shared.routedEvents[gatewayID],
                  current.client === client,
                  CronProfileRefreshPolicy.mayPublishSnapshot(
                      sourceAccepted: cronMutationFenceAccepts(sourceFence,
                                                               expectedClient: client),
                      lifecycleAuthorityAccepted: CronProfileRefreshPolicy
                          .capturedProfilesRemainCurrent(
                              expectedProfiles: expectedProfileNames,
                              tokens: profileTokens,
                              isCurrent: profileLifecycleAccepts)) else { continue }

            let oldIDs = Set(feeds.routineTargets.compactMap { key, target in
                target.route.gatewayID == gatewayID ? key : nil
            })
            let newIDs = Set(jobs.values.map {
                GatewayRoutineRoute(gatewayID: gatewayID, jobID: $0.job.id).qualifiedID
            })
            let stale = oldIDs.subtracting(newIDs)
            routines.removeAll { routine in
                oldIDs.contains(routine.id)
                    || GatewayBotRoute(qualifiedID: routine.botID)?.gatewayID == gatewayID
            }
            for id in stale {
                feeds.cronJobs.removeValue(forKey: id)
                feeds.cronScope.removeValue(forKey: id)
                feeds.routineTargets.removeValue(forKey: id)
                clearCronRoutineCaches(id)
                clearCronRoutineQuarantine(id)
            }
            for entry in jobs.values {
                let route = GatewayRoutineRoute(gatewayID: gatewayID, jobID: entry.job.id)
                let bot = GatewayBotRoute(gatewayID: gatewayID, profile: entry.displayBotID)
                let id = route.qualifiedID
                let nextTarget = RoutineTarget(route: route, bot: bot, profile: entry.scope)
                let priorTarget = feeds.routineTargets[id]
                let priorDetailAuthority = CronDetailRuntime.shared.detailAuthority[id]
                feeds.routineTargets[id] = nextTarget
                if priorTarget != nextTarget
                    || (priorDetailAuthority != nil
                        && cronRoutineMutationFence(id) != priorDetailAuthority) {
                    clearCronRoutineCaches(id)
                    clearCronRoutineQuarantine(id)
                }
                feeds.cronJobs[id] = entry.job
                feeds.cronScope[id] = entry.scope
                routines.append(Routine(
                    id: id, botID: bot.qualifiedID, name: entry.job.displayTitle,
                    schedule: entry.job.schedule,
                    next: entry.job.nextRun.map { Self.relativeNext($0.timeIntervalSince1970) } ?? "",
                    last: Self.lastRunLine(entry.job, theme: theme.themeID),
                    isOn: entry.job.isActive))
            }
        }
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
        let capturedFence = mode == .live ? cronRoutineMutationFence(routine.id) : nil
        let key = capturedFence.map { "routine-toggle:\($0.activityIdentity)" }
            ?? "routine-toggle:\(routine.id)"
        toast(kind: .info,
              title: theme.copy.toastRoutinePaused(routine.name, on: enabled, theme.themeID),
              botID: routine.botID, key: key)
        guard mode == .live, let fence = capturedFence,
              let target = FeedsRuntime.shared.routineTargets[routine.id],
              target == fence.target else {
            routines[idx].isOn = !enabled
            settleToast(key: key)
            return
        }
        Task { @MainActor in
            let runtime = FeedsRuntime.shared
            do {
                let client = try await self.routedClient(gatewayID: target.route.gatewayID)
                guard self.cronMutationFenceAccepts(fence, expectedClient: client) else {
                    self.rollbackRoutineToggle(routine.id, enabled: enabled, fence: fence)
                    self.retractToast(key: key)
                    return
                }
                try await client.cronSetPaused(jobID: target.route.jobID, paused: !enabled,
                                               profile: target.profile)
                guard self.cronMutationFenceAccepts(fence, expectedClient: client) else {
                    self.rollbackRoutineToggle(routine.id, enabled: enabled, fence: fence)
                    self.retractToast(key: key)
                    return
                }
                runtime.routinesError = nil
                await refreshRoutinesLive(force: true)
                guard self.cronMutationFenceAccepts(fence, expectedClient: client) else {
                    self.rollbackRoutineToggle(routine.id, enabled: enabled, fence: fence)
                    self.retractToast(key: key)
                    return
                }
                settleToast(key: key)
            } catch {
                guard self.cronMutationFenceAccepts(fence, expectedClient: client) else {
                    self.rollbackRoutineToggle(routine.id, enabled: enabled, fence: fence)
                    self.retractToast(key: key)
                    return
                }
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

    private func rollbackRoutineToggle(_ routineID: String, enabled: Bool,
                                       fence: CronRoutineMutationFence) {
        // Do not put the old optimistic bit onto a replacement row that reused
        // the same UI/job id. Target equality alone is insufficient when the
        // gateway generation or profile store changed underneath the await.
        guard FeedsRuntime.shared.routineTargets[routineID] == fence.target,
              cronRoutineMutationFence(routineID) == fence else { return }
        if let index = routines.firstIndex(where: { $0.id == routineID }) {
            routines[index].isOn = !enabled
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
        guard GatewayBotRoute(qualifiedID: botID) == nil else {
            throw GatewayRouteError.noRoute
        }
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
        guard let gatewayID = LiveRuntime.shared.gatewayID,
              let fence = cronSourceMutationFence(
                  gatewayID: gatewayID, profile: nil),
              cronMutationFenceAccepts(fence, expectedClient: client) else {
            throw GatewayRouteError.noRoute
        }
        do {
            try await client.cronAdd(name: "[bot:\(botID)] \(cleanTitle)",
                                     schedule: normalized,
                                     prompt: routinePrompt(botID: botID, title: cleanTitle,
                                                           instruction: cleanPrompt),
                                     profile: nil,
                                     repeatCount: repeatCount,
                                     continuity: continuity)
        } catch {
            if !cronMutationFenceAccepts(fence, expectedClient: client) {
                throw cronSourceChangedError()
            }
            throw error
        }
        guard cronMutationFenceAccepts(fence, expectedClient: client) else {
            throw cronSourceChangedError()
        }
        await refreshRoutinesLive(force: true)
        guard cronMutationFenceAccepts(fence, expectedClient: client) else {
            throw cronSourceChangedError()
        }
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
        AppModel.delegatedPrompt(botID: botID, title: title, instruction: instruction)
    }

    func deleteRoutine(_ routine: Routine) async throws {
        guard routineHasFullManagement(routine), let fence = cronRoutineMutationFence(routine.id),
              let target = FeedsRuntime.shared.routineTargets[routine.id], target == fence.target
        else { throw GatewayRouteError.noRoute }
        guard mode == .live else { return }
        let client = try await routedClient(gatewayID: target.route.gatewayID)
        guard cronMutationFenceAccepts(fence, expectedClient: client) else {
            throw cronSourceChangedError()
        }
        do {
            try await client.cronRemove(jobID: target.route.jobID, profile: target.profile)
        } catch {
            if !cronMutationFenceAccepts(fence, expectedClient: client) {
                throw cronSourceChangedError()
            }
            throw error
        }
        guard cronMutationFenceAccepts(fence, expectedClient: client) else {
            throw cronSourceChangedError()
        }
        await refreshRoutinesLive(force: true)
        // The row is intentionally gone now, so the routine fence (which
        // includes `currentTarget == fence.target`) cannot be used after the
        // accepted remove. The source fence still proves that the refresh and
        // local cache clear belong to the same client/generation.
        guard cronMutationFenceAccepts(fence.source, expectedClient: client) else {
            throw cronSourceChangedError()
        }
        let refreshedTarget = FeedsRuntime.shared.routineTargets[routine.id]
        guard CronDeletePostRefreshPolicy.mayClear(
            capturedTarget: fence.target, currentTarget: refreshedTarget) else {
            // A newer same-id target now owns the row and all of its caches.
            // The accepted delete is not permission to clear that replacement.
            throw cronSourceChangedError()
        }
        if refreshedTarget != nil {
            // The target may be byte-for-byte equal while its profile
            // lifecycle generation has been retired and recreated. Require
            // the full routine fence before clearing that still-present row.
            guard cronRoutineMutationFence(routine.id) == fence else {
                throw cronSourceChangedError()
            }
        }
        routines.removeAll { $0.id == routine.id }
        FeedsRuntime.shared.cronJobs.removeValue(forKey: routine.id)
        FeedsRuntime.shared.cronScope.removeValue(forKey: routine.id)
        FeedsRuntime.shared.routineTargets.removeValue(forKey: routine.id)
        clearCronRoutineCaches(routine.id)
        clearCronRoutineQuarantine(routine.id)
    }

    /// Fire a job now. `cron.manage` has no run action (4016) — the trigger
    /// lives on the REST router, so this needs the gateway's HTTP credential.
    ///
    /// - Returns: true when the run finished before the request returned; false
    ///   when it is still running on the gateway (the normal case for a real
    ///   agent run) so the caller can say "started" rather than "done".
    @discardableResult
    func runRoutineNow(_ routine: Routine) async throws -> Bool {
        guard routineHasFullManagement(routine), let fence = cronRoutineMutationFence(routine.id),
              let target = FeedsRuntime.shared.routineTargets[routine.id], target == fence.target
        else { throw GatewayRouteError.noRoute }
        guard mode == .live else { return false }
        guard cronRESTReady(routineID: routine.id),
              let sourceClient = cronSourceClient(gatewayID: target.route.gatewayID),
              let (base, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID) else {
            throw GatewayError(code: -3, message: theme.copy.needsRESTNote(theme.themeID))
        }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        let finished: Bool
        do {
            finished = try await GatewayREST.triggerCronJob(
                baseURL: base, credential: credential, jobID: target.route.jobID,
                profile: target.profile)
        } catch {
            if !cronMutationFenceAccepts(fence, expectedClient: sourceClient) {
                throw cronSourceChangedError()
            }
            throw error
        }
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        await refreshRoutinesLive(force: true)
        guard cronMutationFenceAccepts(fence, expectedClient: sourceClient) else {
            throw cronSourceChangedError()
        }
        recordActivity(kind: .routine, botID: routine.botID,
                       text: theme.copy.feedRoutineTriggered(theme.themeID) + " — " + routine.name,
                       subtext: routine.schedule)
        return finished
    }

    /// Base URL + credential for the REST endpoints the WS surface lacks. The
    /// client keeps its own credential private; the registry holds the same
    /// Keychain copy, refreshed on every connect.
    internal func gatewayRESTContext() -> (URL, GatewayCredential)? {
        guard let gatewayID = LiveRuntime.shared.gatewayID else { return nil }
        return gatewayRESTContext(gatewayID: gatewayID)
    }

    /// REST authority for one exact gateway. A remote routine must never use
    /// the primary base URL merely because its raw job id also exists there.
    internal func gatewayRESTContext(gatewayID: String) -> (URL, GatewayCredential)? {
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let base = gateway.baseURL,
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
        guard mode == .live, !bots.isEmpty,
              let sourceGatewayID = LiveRuntime.shared.gatewayID else { return }
        let sourceGeneration = LiveRuntime.shared.generation
        let runtime = FeedsRuntime.shared
        if runtime.artifactsScanning { return }
        if !force, let last = runtime.lastArtifactScan, last.timeIntervalSinceNow > -120 { return }
        guard let (base, credential) = gatewayRESTContext(gatewayID: sourceGatewayID) else {
            runtime.artifactsNote = theme.copy.needsRESTNote(theme.themeID)
            return
        }
        let sourceClient: GatewayClient
        do {
            sourceClient = try await routedClient(gatewayID: sourceGatewayID)
        } catch {
            runtime.artifactsNote = error.localizedDescription
            return
        }
        guard LiveRuntime.shared.gatewayID == sourceGatewayID,
              LiveRuntime.shared.generation == sourceGeneration else { return }

        // `bots` can momentarily contain retained/qualified rows while a
        // gateway switch reconciles. Bind each sweep row to the captured source
        // and pass Hermes only its raw profile name.
        let sourceProfiles: [String] = bots.compactMap { bot in
            Self.artifactSweepProfile(route: stateRoute(for: bot.id),
                                      sourceGatewayID: sourceGatewayID)
        }

        runtime.artifactsScanning = true
        defer { runtime.artifactsScanning = false; runtime.lastArtifactScan = Date() }

        var found: [Artifact] = []
        var refs: [String: SessionRef] = [:]
        var scanned = 0
        var failures = 0

        // One transcript resident at a time: recent sessions run to thousands
        // of rows and the phone pays for every one of them.
        for profile in sourceProfiles.prefix(8) {
            // The forever chat is where a bot does most of its work, and it is
            // hidden — scanning without the flag indexes artifacts from every
            // session EXCEPT the one that matters (methods_session.py:180-186).
            guard let sessions = try? await sourceClient.listSessions(
                limit: 6, profile: profile, includeHidden: true) else {
                failures += 1
                continue
            }
            for session in sessions.prefix(3) where session.messageCount > 0 {
                guard !Task.isCancelled else { return }
                do {
                    let rows = try await GatewayREST.sessionMessages(
                        baseURL: base, credential: credential,
                        storedID: session.id, profile: profile, limit: 150)
                    scanned += 1
                    let title = session.title.isEmpty ? (session.preview ?? "session") : session.title
                    let harvest = Self.artifacts(in: rows, botID: profile,
                                                 sessionID: session.id, sessionTitle: title,
                                                 sessionStart: session.startedAt,
                                                 sourceGatewayID: sourceGatewayID)
                    for artifact in harvest {
                        refs[artifact.id] = SessionRef(gatewayID: sourceGatewayID,
                                                       botID: profile,
                                                       storedID: session.id)
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
        let swept = Set(found.map {
            Self.artifactSourceKey(gatewayID: sourceGatewayID, botID: $0.botID,
                                   value: Self.artifactValue($0.id))
        })
        let foreign = artifacts.filter {
            runtime.artifactSessions[$0.id]?.gatewayID != sourceGatewayID
        }
        let liveOnly = artifacts.filter {
            guard let ref = runtime.artifactSessions[$0.id], ref.gatewayID == sourceGatewayID else {
                return false
            }
            return !swept.contains(Self.artifactSourceKey(
                gatewayID: ref.gatewayID, botID: ref.botID,
                value: Self.artifactValue($0.id)))
        }
        for artifact in liveOnly { refs[artifact.id] = runtime.artifactSessions[artifact.id] }

        guard !Task.isCancelled,
              LiveRuntime.shared.gatewayID == sourceGatewayID,
              LiveRuntime.shared.generation == sourceGeneration else { return }
        var combinedRefs = runtime.artifactSessions.filter { $0.value.gatewayID != sourceGatewayID }
        combinedRefs.merge(refs) { _, fresh in fresh }
        let published = (found + liveOnly + foreign)
            .sorted { Self.sortKey($0) > Self.sortKey($1) }
            .prefix(150)
            .map { $0 }
        let publishedIDs = Set(published.map(\.id))
        runtime.artifactSessions = combinedRefs.filter { publishedIDs.contains($0.key) }
        artifacts = published
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
        guard let rosterID = ref.rosterID(activeGatewayID: activeGatewayID) else { return }
        openStoredSession(ref.storedID, botID: rosterID)
    }

    /// tool.complete → artifact rows, for files produced while you watch. Same
    /// admission rule as the transcript sweep: a producer tool, or any tool that
    /// announces media explicitly.
    internal func ingestArtifacts(fromTool tool: ToolCompletePayload, botID: String, sessionID: String) {
        let text = [tool.resultText, tool.summary].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let producer = ArtifactScan.isProducer(tool.name.lowercased())
        guard producer || text.contains("MEDIA:") || text.contains("Screenshot path:") else { return }

        let route = stateRoute(for: botID)
        let stored = chats[botID]?.storedSessionID
        let artifactBotID = route?.profile ?? botID
        // Same file, same bot, twice in a turn is one artifact.
        let known = Set(artifacts.filter {
            guard $0.botID == artifactBotID else { return false }
            guard let route else { return true }
            return FeedsRuntime.shared.artifactSessions[$0.id]?.gatewayID == route.gatewayID
        }
            .map { Self.artifactValue($0.id) })
        var added = false
        for value in ArtifactScan.values(inToolText: text, producer: producer).prefix(6)
        where !known.contains(value) {
            let identitySession = route.map {
                "\($0.gatewayID)\u{1f}\(stored ?? sessionID)"
            } ?? (stored ?? sessionID)
            let artifact = Self.artifact(from: value, botID: artifactBotID,
                                         sessionID: identitySession,
                                         sessionTitle: tool.name, at: Date())
            if let stored, let route {
                FeedsRuntime.shared.artifactSessions[artifact.id] =
                    SessionRef(gatewayID: route.gatewayID,
                               botID: route.profile, storedID: stored)
            }
            artifacts.insert(artifact, at: 0)
            added = true
        }
        if added, artifacts.count > 150 { artifacts.removeLast(artifacts.count - 150) }
    }

    /// Extract every artifact value from one session's transcript rows.
    static func artifacts(in rows: [JSONValue], botID: String, sessionID: String,
                          sessionTitle: String, sessionStart: Double?,
                          sourceGatewayID: String? = nil) -> [Artifact] {
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
                let identitySession = sourceGatewayID.map { "\($0)\u{1f}\(sessionID)" }
                    ?? sessionID
                out.append(artifact(from: value, botID: botID, sessionID: identitySession,
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

    static func artifactSourceKey(gatewayID: String, botID: String, value: String) -> String {
        [gatewayID, botID, value].joined(separator: "\u{1f}")
    }

    static func artifactSweepProfile(route: GatewayBotRoute?,
                                     sourceGatewayID: String) -> String? {
        guard let route, route.gatewayID == sourceGatewayID, !route.profile.isEmpty else {
            return nil
        }
        return route.profile
    }
}

// MARK: - Agent Inbox (bot ⇄ bot)

public extension AppModel {

    /// Build the inbox from each profile's "Agent Inbox" session — the session
    /// upstream's handoff writes into (`hermes -p <bot> chat -c "Agent Inbox"`).
    /// Rows are split back into from → to by the A2A prefix the sender uses.
    func refreshAgentInbox(force: Bool = false) async {
        let runtime = FeedsRuntime.shared
        if !force, let last = runtime.lastInboxScan, last.timeIntervalSinceNow > -60 { return }
        await refreshInboxLive()
    }

    /// The CLI handoff names the conversation; both the current "Agent Inbox"
    /// form and the newer "Bot Chat" one are the same feed.
    static func isInboxSession(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("agent inbox") || t.contains("bot chat")
    }

    /// Split one inbox transcript into attributed A2A rows.
    static func inboxMessages(in rows: [JSONValue], owner: String,
                              sourceGatewayID: String? = nil) -> [(A2AMessage, Date)] {
        var out: [(A2AMessage, Date)] = []
        var lastSender: String?
        var lastAttemptID: UUID?
        let orderedRows = rows.enumerated().sorted { left, right in
            let lhs = HermesTime.date(left.element["timestamp"]) ?? .distantPast
            let rhs = HermesTime.date(right.element["timestamp"]) ?? .distantPast
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
        for row in orderedRows {
            let role = row["role"]?.stringValue ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let text = ArtifactScan.text(of: row).trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "user" {
                // Even an empty ordinary user row terminates the prior
                // attributed turn; never let a later assistant inherit it.
                lastSender = nil
                lastAttemptID = nil
            }
            guard !text.isEmpty else { continue }
            let at = HermesTime.date(row["timestamp"]) ?? Date()
            let time = shortTime(at.timeIntervalSince1970)
            if role == "user" {
                guard let sender = a2aSender(in: text) else { continue }
                let immutableSenderRoute = A2AWire.senderRoute(in: text)
                lastSender = immutableSenderRoute?.qualifiedID ?? sourceGatewayID.flatMap { gatewayID in
                    guard gatewayID != LiveRuntime.shared.gatewayID else { return sender }
                    return GatewayBotRoute(gatewayID: gatewayID, profile: sender).qualifiedID
                } ?? sender
                lastAttemptID = A2AWire.attemptID(in: text)
                out.append((A2AMessage(id: lastAttemptID ?? UUID(),
                                       fromBotID: lastSender ?? sender, toBotID: owner, time: time,
                                       text: strippedA2A(text)), at))
            } else if let sender = lastSender {
                // The owner's reply goes back to whoever last wrote in.
                out.append((A2AMessage(id: lastAttemptID.map(A2AWire.replyID(for:)) ?? UUID(),
                                       fromBotID: owner, toBotID: sender, time: time,
                                       text: previewLine(text)), at))
            }
        }
        return out
    }

    /// Compatibility boundary for the original one-recipient feed action.
    /// Exact source resolution and all wire work live in `deliverHandoff`;
    /// keeping a second primary-client implementation here would let an old
    /// caller silently send a qualified remote id to the wrong gateway.
    func sendHandoff(from: String, to: String, text: String) async throws {
        _ = try await deliverHandoff(from: from, to: [to], text: text)
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
        guard text.range(of: #"^Message from (?:agent '[^']+'|🤖)"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        // Restrict identity markers to the attributed prefix. This prevents a
        // body mentioning another handle from changing sender ownership.
        let attributionPrefix: String = {
            guard let marker = text.range(
                of: #"^Message from .*?\[Talaria handoff attempt [0-9a-fA-F-]{36}\]:"#,
                options: .regularExpression) else { return text }
            guard let markerStart = text[..<marker.upperBound].lastIndex(of: "[") else {
                return text
            }
            return String(text[..<markerStart])
        }()
        if let handleRange = attributionPrefix.range(of: #"\(@[^)\s]+\)"#,
                                        options: .regularExpression) {
            let marker = attributionPrefix[handleRange]
            return String(marker.dropFirst(2).dropLast()).lowercased()
        }
        if text.range(of: #"^Message from agent '"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return legacyA2ASender(in: text)
        }
        guard let emoji = attributionPrefix.range(of: "🤖") else { return nil }
        var display = String(attributionPrefix[emoji.upperBound...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        for delimiter in ["(@", "[Talaria handoff attempt", ":"] {
            if let boundary = display.range(of: delimiter) {
                display = String(display[..<boundary.lowerBound])
                break
            }
        }
        return display.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func legacyA2ASender(in text: String) -> String? {
        guard let range = text.range(of: #"^Message from agent '[^']+'"#,
                                     options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let head = String(text[range])
        if let quoted = head.range(of: #"'[^']+'"#, options: .regularExpression) {
            return String(head[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "'")).lowercased()
        }
        return nil
    }

    /// The message with its attribution prefix removed.
    static func strippedA2A(_ text: String) -> String {
        guard text.range(of: #"^Message from (?:agent '[^']+'|🤖)"#,
                         options: [.regularExpression, .caseInsensitive]) != nil else {
            return previewLine(text)
        }
        if let marker = text.range(of: #"^Message from .*?\[Talaria handoff attempt [0-9a-fA-F-]{36}\]:\s*"#,
                                   options: .regularExpression) {
            return String(text[marker.upperBound...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        if let handle = text.range(of: #"\(@[^)\s]+\)\s*:\s*"#,
                                   options: .regularExpression) {
            return String(text[handle.upperBound...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        guard let colon = text.firstIndex(of: ":") else { return previewLine(text) }
        return String(text[text.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Artifact scanning (port of desktop's artifact-utils.ts)

enum ArtifactScan {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp"]
    private static let mediaExtensions: Set<String> = ["mp4", "mov", "m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "webm", "mkv", "avi"]
    private static let fileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "pdf", "txt", "json", "md", "csv",
        "zip", "tar", "gz", "avi", "flac", "m4a", "mkv", "mp3", "ogg", "opus", "wav", "webm",
        "mp4", "mov", "html", "log", "py", "swift", "ts", "tsx", "js", "yaml", "yml", "toml",
    ]

    /// Values that address the gateway host. A transcript may mention one of
    /// these, but that mention is never itself an authorization to read it;
    /// AppModel's artifact admission gate must prove managed-root containment
    /// before any REST file route or prefetch can use the value.
    static func isGatewayPath(_ value: String) -> Bool {
        !value.hasPrefix("data:") && !value.hasPrefix("http://")
            && !value.hasPrefix("https://")
    }

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
        if let ext = ext(of: value)?.lowercased() {
            if imageExtensions.contains(ext) { return .image }
            if mediaExtensions.contains(ext) { return .media }
        }
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
        case .soft: "Approvals, agent replies, finished runs, routines and gateway blips land here as they happen."
        case .control: "APPROVALS · AGENT REPLIES · RUNS · ROUTINES · LINK EVENTS — LOGGED AS THEY LAND."
        case .ink: "Every deed — seals, answers, rites, finished turns — shall be written here."
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
        case (.media, .soft): return "Media"
        case (.media, .control): return "MEDIA"
        case (.media, .ink): return "media"
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

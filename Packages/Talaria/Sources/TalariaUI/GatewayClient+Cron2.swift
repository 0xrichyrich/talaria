import Foundation
import TalariaKit

// The half of Hermes cron that `cron.manage` cannot reach.
//
// VERIFIED CONTRACT. `cron.manage` (tui_gateway/methods_tools.py:1676) accepts
// exactly five actions — list / add / remove / pause / resume — and rejects
// everything else with 4016. There is no update, no run-now, no per-job read
// and no run history over the socket. All four live on the REST cron router
// (hermes_cli/web_routers/cron.py), which is what desktop uses:
//
//   GET    /api/cron/jobs/{id}            :68   → the RAW job record
//   GET    /api/cron/jobs/{id}/runs?limit :73   → {runs:[session rows], limit}
//   PUT    /api/cron/jobs/{id}            :111  → body {updates:{…}}
//   POST   /api/cron/jobs/{id}/trigger    :126  (already in GatewayClient+Cron)
//   GET    /api/cron/delivery-targets     :86   → {targets:[…]}
//
// Every one takes an optional `?profile=`; omitted, the server searches each
// profile's store for the job (web_server.py:12570 `_find_cron_job_profile`).
//
// Why the RAW record matters: `cron.manage list` runs rows through
// `_format_job` (tools/cronjob_tools.py:620), which truncates the prompt to a
// 100-char `prompt_preview` and drops `last_error`, `provider_snapshot` and
// `model_snapshot` entirely. Editing a prompt you can only see 100 characters
// of would silently truncate it, and the drift guard's whole state is invisible.
// `get_job` (cron/jobs.py:2007) returns the stored record untouched.

// MARK: - The stored job record

/// A cron job exactly as `cron/jobs.py create_job` (:1948) stores it and
/// `get_job` (:2007) returns it. Distinct from `CronJobRecord`, which decodes
/// the lossy `_format_job` projection the WS list emits.
public struct CronJobDetail: Sendable, Equatable, Identifiable {
    public var id: String
    /// Full stored title, "[bot:<name>] " prefix included.
    public var name: String
    /// The COMPLETE prompt — not the 100-char preview the socket list carries.
    public var prompt: String
    /// Human schedule string; the raw record keeps the parsed dict in
    /// `schedule` and the display form in `schedule_display`.
    public var scheduleDisplay: String
    public var enabled: Bool
    public var state: String
    /// Delivery route, comma-separated for multi-target jobs (cron.py:86).
    public var deliver: String

    // Inference routing. nil on an axis means "follow global config at fire
    // time" — which is exactly the axis the drift guard watches.
    public var model: String?
    public var provider: String?
    public var baseURL: String?
    /// What `provider` resolved to when the job was created; only ever set for
    /// an UNPINNED axis on an agent job (cron/jobs.py:1695 `_compute_provider_
    /// model_snapshots`). Present ⇒ the drift guard is armed on that axis.
    public var providerSnapshot: String?
    public var modelSnapshot: String?

    /// Script-only job: runs a shell script on schedule with no agent. Its
    /// prompt is legitimately empty and must never be written back as one.
    public var noAgent: Bool
    public var script: String?
    /// Jobs whose previous output is injected into this one; the reserved
    /// "self" entry is the continuity toggle.
    public var contextFrom: [String]

    public var nextRun: Date?
    public var lastRun: Date?
    /// "ok" | "error" | "blocked_config" (cron/jobs.py:2437, :6431).
    public var lastStatus: String?
    /// Why the last run failed, verbatim. Carries the guard markers.
    public var lastError: String?
    public var lastDeliveryError: String?
    /// Set when a scheduled fire could not be handed to the runner at all
    /// (web_routers/cron.py:187 `note_fire_forward_failure`).
    public var lastFireError: String?
    public var pausedReason: String?
    public var pausedAt: Date?
    /// Consecutive agent failures; reset by any success (cron/jobs.py:2452).
    public var failureStreak: Int
    /// Alert-once dedupe bits. Still set ⇒ the condition has not healed.
    public var driftAlerted: Bool
    public var preflightAlerted: Bool
    /// repeat.times — nil means forever.
    public var repeatTimes: Int?
    public var repeatCompleted: Int

    /// True when the gateway considers this job live. Same guard as
    /// `CronJobRecord.isActive`: a half-paused record keeps `enabled: true`.
    public var isActive: Bool { enabled && state.lowercased() != "paused" }

    /// True when the job runs a script instead of an agent — desktop's
    /// `jobIsScriptOnly` (app/cron/cron-job-model.ts:6).
    public var isScriptOnly: Bool {
        noAgent && !(script ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Continuity: the job's own last output is fed back in.
    public var continuity: Bool {
        contextFrom.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "self" || $0 == id }
    }

    /// context_from minus the reserved self-reference, so an edit can rewrite
    /// continuity without dropping a real cross-job dependency.
    public var externalContext: [String] {
        contextFrom.filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "self" && $0 != id }
    }

    /// Title with the "[bot:…]" namespace stripped.
    public var displayTitle: String {
        guard name.hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else { return name }
        let rest = name[name.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The "[bot:<name>] " prefix itself, so an edited title can be re-stamped
    /// with the namespace it arrived with.
    public var namespacePrefix: String {
        guard name.hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else { return "" }
        return String(name[...close]) + " "
    }

    public init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? v["job_id"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        prompt = v["prompt"]?.stringValue ?? ""
        scheduleDisplay = v["schedule_display"]?.stringValue
            ?? v["schedule"]?.stringValue
            ?? v["schedule"]?["display"]?.stringValue ?? ""
        enabled = v["enabled"]?.boolValue ?? true
        state = v["state"]?.stringValue ?? "scheduled"
        deliver = v["deliver"]?.stringValue ?? "local"
        model = Self.text(v["model"])
        provider = Self.text(v["provider"])
        baseURL = Self.text(v["base_url"])
        providerSnapshot = Self.text(v["provider_snapshot"])
        modelSnapshot = Self.text(v["model_snapshot"])
        noAgent = v["no_agent"]?.boolValue ?? false
        script = Self.text(v["script"])
        if let list = v["context_from"]?.arrayValue {
            contextFrom = list.compactMap(\.stringValue)
        } else if let one = v["context_from"]?.stringValue, !one.isEmpty {
            contextFrom = [one]
        } else {
            contextFrom = []
        }
        nextRun = HermesTime.date(v["next_run_at"])
        lastRun = HermesTime.date(v["last_run_at"])
        lastStatus = Self.text(v["last_status"])
        lastError = Self.text(v["last_error"])
        lastDeliveryError = Self.text(v["last_delivery_error"])
        lastFireError = Self.text(v["last_fire_error"])
        pausedReason = Self.text(v["paused_reason"])
        pausedAt = HermesTime.date(v["paused_at"])
        failureStreak = v["failure_streak"]?.intValue ?? 0
        driftAlerted = v["drift_alerted"]?.boolValue ?? false
        preflightAlerted = v["preflight_alerted"]?.boolValue ?? false
        repeatTimes = v["repeat"]?["times"]?.intValue
        repeatCompleted = v["repeat"]?["completed"]?.intValue ?? 0
    }

    /// JSON null and "" both mean "unset" in the cron store; collapse them so
    /// callers can test one thing.
    private static func text(_ value: JSONValue?) -> String? {
        guard let s = value?.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Health (the fail-closed states)

/// What the gateway last recorded about this job, reduced to one state the UI
/// can act on. The order matters: a job can be paused AND carry a stale error,
/// and the reason it is not running now is the one worth showing.
public enum CronJobCondition: Sendable, Equatable {
    /// Skipped before any inference: global provider/model drifted away from
    /// the snapshot this unpinned job was created against (cron/scheduler.py
    /// :5318, marker `[drift_skip]`). Nothing was spent; nothing will run
    /// until the axes are pinned or the config is restored.
    case driftSkipped
    /// Refused pre-dispatch by config validation — missing provider key,
    /// unconfigured delivery platform, a skill with missing env
    /// (cron/scheduler.py:4306, `last_status == "blocked_config"`).
    case blockedConfig
    /// The scheduler could not hand the fire to the runner at all
    /// (web_routers/cron.py:187).
    case fireUnreachable
    /// The run itself failed.
    case failed
    /// The agent ran, the delivery did not (cron/jobs.py:2464).
    case deliveryFailed
    case paused
    case ok
}

public struct CronJobHealth: Sendable, Equatable {
    public var condition: CronJobCondition
    /// Server text, guard markers stripped. Empty when there is nothing to add.
    public var detail: String
    /// Consecutive failures, for "failed 4 times in a row".
    public var failureStreak: Int

    public var isProblem: Bool { condition != .ok }

    public init(condition: CronJobCondition, detail: String, failureStreak: Int = 0) {
        self.condition = condition; self.detail = detail; self.failureStreak = failureStreak
    }

    /// Full read, from the raw record.
    public init(_ job: CronJobDetail) {
        let error = job.lastError ?? ""
        // The guard stamps its own marker into last_error and the delivery
        // path strips it before sending (cron/scheduler.py:6307) — do the same
        // here so the phone shows the remediation, not the internal tag.
        let stripped = CronJobHealth.stripMarkers(error)
        failureStreak = job.failureStreak

        if error.contains("[drift_skip") {
            condition = .driftSkipped
            detail = stripped
        } else if (job.lastStatus ?? "") == "blocked_config" || error.contains("[blocked_config") {
            condition = .blockedConfig
            detail = stripped
        } else if let fire = job.lastFireError, !fire.isEmpty {
            condition = .fireUnreachable
            detail = fire
        } else if !job.isActive {
            condition = .paused
            detail = job.pausedReason ?? ""
        } else if (job.lastStatus ?? "").lowercased() == "error" || !stripped.isEmpty {
            condition = .failed
            detail = stripped
        } else if let delivery = job.lastDeliveryError, !delivery.isEmpty {
            condition = .deliveryFailed
            detail = delivery
        } else {
            condition = .ok
            detail = ""
        }
    }

    /// Reduced read, from the socket list projection — `_format_job` carries
    /// `last_status`, `last_fire_error`, `last_delivery_error` and
    /// `paused_reason` but never `last_error`, so this can name the condition
    /// and rarely the reason.
    public init(_ job: CronJobRecord) {
        failureStreak = 0
        let status = (job.lastStatus ?? "").lowercased()
        if status == "blocked_config" {
            condition = .blockedConfig; detail = ""
        } else if !job.isActive {
            condition = .paused; detail = ""
        } else if status == "error" {
            condition = .failed; detail = ""
        } else {
            condition = .ok; detail = ""
        }
    }

    private static func stripMarkers(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var out = text
        for marker in ["[drift_skip:silent]", "[drift_skip]",
                       "[blocked_config:silent]", "[blocked_config]"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Runs

/// One execution of a cron job. Runs are ordinary sessions with the id
/// `cron_{job_id}_{YYYYmmdd_HHMMSS}` (cron/scheduler.py:4806), which is exactly
/// how the server finds them (`SessionDB.list_cron_job_runs`,
/// hermes_state_portability.py:71) — so the row shape is a session row, and the
/// id is directly resumable.
public struct CronRun: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var preview: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var lastActive: Date?
    /// "cron_complete" for a run the scheduler closed (cron/scheduler.py:5856).
    public var endReason: String?
    public var messageCount: Int
    public var toolCallCount: Int
    /// Server-computed: no end and activity within 5 min (web_server.py:12613).
    public var isActive: Bool
    public var model: String?
    public var costUSD: Double?
    public var profile: String?

    public enum Outcome: Sendable, Equatable { case running, finished, interrupted }

    /// A cron run has no status column of its own. What the session record can
    /// prove is whether the scheduler closed it: `ended_at` is written by
    /// `end_session`, which only the completion path calls. An unfinished,
    /// non-live run is therefore one that died — not one that failed, which is
    /// a claim only the job's own `last_status` can make.
    public var outcome: Outcome {
        if isActive { return .running }
        return endedAt == nil ? .interrupted : .finished
    }

    /// Wall time, when both ends are known.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt > startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// The line to label the row with: the scheduler's title, else the first
    /// user turn, else the id (desktop's fallback chain, app/cron/index.tsx:940).
    public var label: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let p = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? id : p
    }

    public init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? ""
        title = v["title"]?.stringValue ?? ""
        preview = v["preview"]?.stringValue ?? ""
        startedAt = HermesTime.date(v["started_at"])
        endedAt = HermesTime.date(v["ended_at"])
        lastActive = HermesTime.date(v["last_active"])
        endReason = v["end_reason"]?.stringValue
        messageCount = v["message_count"]?.intValue ?? 0
        toolCallCount = v["tool_call_count"]?.intValue ?? 0
        isActive = v["is_active"]?.boolValue ?? false
        model = v["model"]?.stringValue
        costUSD = v["actual_cost_usd"]?.doubleValue ?? v["estimated_cost_usd"]?.doubleValue
        profile = v["profile"]?.stringValue
    }
}

// MARK: - Delivery targets

/// Where a job's output goes. `local` is always offered; everything else is
/// derived from the gateway's configured platforms, and a platform with no
/// cron home channel comes back with `home_target_set: false` so the UI can
/// say "configure a home channel first" instead of hiding it
/// (web_routers/cron.py:86-111).
public struct CronDeliveryTarget: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var homeTargetSet: Bool

    public init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? id
        homeTargetSet = v["home_target_set"]?.boolValue ?? true
    }
}

// MARK: - RPCs

public extension GatewayREST {

    /// A gateway that does not mount the cron router answers FastAPI's own
    /// bare 404. Callers hide the surface on this rather than showing an error
    /// the user cannot act on.
    static let cronRESTUnavailable = -32_404

    /// `GET /api/cron/jobs/{id}` (web_routers/cron.py:68) — the raw record.
    static func cronJob(baseURL: URL, credential: GatewayCredential,
                        jobID: String, profile: String?) async throws -> CronJobDetail {
        let payload = try await cronCall(baseURL: baseURL, credential: credential,
                                         path: "api/cron/jobs/\(try cronPathComponent(jobID))",
                                         method: "GET", profile: profile, body: nil, timeout: 25)
        return CronJobDetail(payload)
    }

    /// `GET /api/cron/jobs/{id}/runs` (web_routers/cron.py:73). The server
    /// clamps limit to 1...100 (web_server.py:12606); clamp here too so the
    /// requested window and the returned one agree.
    static func cronJobRuns(baseURL: URL, credential: GatewayCredential,
                            jobID: String, profile: String?,
                            limit: Int = 20) async throws -> [CronRun] {
        let clamped = max(1, min(limit, 100))
        let payload = try await cronCall(baseURL: baseURL, credential: credential,
                                         path: "api/cron/jobs/\(try cronPathComponent(jobID))/runs",
                                         method: "GET", profile: profile, body: nil, timeout: 30,
                                         query: [URLQueryItem(name: "limit", value: String(clamped))])
        return (payload["runs"]?.arrayValue ?? []).map(CronRun.init).filter { !$0.id.isEmpty }
    }

    /// `PUT /api/cron/jobs/{id}` with body `{updates: {...}}`
    /// (web_routers/cron.py:111). Only the keys present are touched — the
    /// server merges them over the stored record (cron/jobs.py:2105) — so a
    /// partial edit cannot clear a field the phone never showed. `id` is
    /// immutable and rejected (cron/jobs.py:460).
    @discardableResult
    static func updateCronJob(baseURL: URL, credential: GatewayCredential,
                              jobID: String, profile: String?,
                              updates: [String: JSONValue]) async throws -> CronJobDetail {
        let payload = try await cronCall(baseURL: baseURL, credential: credential,
                                         path: "api/cron/jobs/\(try cronPathComponent(jobID))",
                                         method: "PUT", profile: profile,
                                         body: .object(["updates": .object(updates)]), timeout: 30)
        return CronJobDetail(payload)
    }

    /// `GET /api/cron/delivery-targets` (web_routers/cron.py:86). Takes no
    /// profile — the list is derived from the gateway's configured platforms.
    static func cronDeliveryTargets(baseURL: URL,
                                    credential: GatewayCredential) async throws -> [CronDeliveryTarget] {
        let payload = try await cronCall(baseURL: baseURL, credential: credential,
                                         path: "api/cron/delivery-targets",
                                         method: "GET", profile: nil, body: nil, timeout: 20)
        return (payload["targets"]?.arrayValue ?? []).map(CronDeliveryTarget.init).filter { !$0.id.isEmpty }
    }

    // MARK: Transport

    /// Job ids are single filesystem path components on the server
    /// (cron/jobs.py:463 rejects separators for exactly this reason), so a
    /// separator here means a malformed id, not a nested route.
    private static func cronPathComponent(_ jobID: String) throws -> String {
        let trimmed = jobID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics
                  .union(CharacterSet(charactersIn: "-_.~")))
        else { throw GatewayError(code: -9, message: "invalid cron job id") }
        return encoded
    }

    private static func cronCall(baseURL: URL, credential: GatewayCredential,
                                 path: String, method: String, profile: String?,
                                 body: JSONValue?, timeout: TimeInterval,
                                 query: [URLQueryItem] = []) async throws -> JSONValue {
        var items = query
        if let profile, !profile.isEmpty {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        let encodedBody = try body.map { try JSONEncoder().encode($0) }
        let data: Data
        do {
            data = try await GatewayREST.restData(
                baseURL: baseURL, credential: credential, path: path,
                query: items, method: method, body: encodedBody,
                timeout: timeout, what: "cron request")
        } catch let error as GatewayError {
            // FastAPI's unrouted-path body is exactly {"detail":"Not Found"};
            // the cron handlers' own 404 says "Job not found". Only the former
            // means this gateway has no cron REST surface at all.
            if error.code == 404, error.message == "Not Found" {
                throw GatewayError(code: cronRESTUnavailable, message: "cron REST surface unavailable")
            }
            throw error
        }
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard let decoded else {
            throw GatewayError(code: -9, message: "cron response was not JSON")
        }
        return decoded
    }
}

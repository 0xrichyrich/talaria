import Foundation
import TalariaKit

// Hermes cron, as the gateway actually speaks it.
//
// Verified upstream contract (hermes-agent-upstream):
//   cron.manage (tui_gateway/methods_tools.py:1675) accepts EXACTLY five
//   actions — anything else is rejected with 4016 "unknown cron action":
//     {action:"list",   include_disabled?, profile?} → {success, count, jobs:[…]}
//     {action:"add",    name, schedule, prompt, repeat?, continuity?, profile?}
//     {action:"remove"|"pause"|"resume", name:<job_id>, profile?}
//   The handler forwards `params["name"]` as cronjob()'s `job_id` for
//   remove/pause/resume (tools/cronjob_tools.py:1180) — so the *job id* travels
//   in the `name` param. There is no enable/disable, no update, no run-now over
//   the socket; run-now and per-job runs are REST only (see GatewayREST below).
//
//   Job rows come from `_format_job` (cronjob_tools.py:620): `job_id`, `name`,
//   `schedule` (the display string), `prompt_preview`, `enabled`, `state`,
//   `next_run_at` / `last_run_at` (ISO-8601 strings, NOT unix numbers),
//   `last_status`, `deliver`, `repeat`.
//
//   `profile` scopes the whole call to that profile's cron store by swapping
//   HERMES_HOME (methods_tools.py:1679-1690). A gateway that honors it stamps
//   `scoped:"<profile>"` on the list result; older gateways silently ignore the
//   param and return the launch-profile store, which is why every job is still
//   attributed by its "[bot:<name>] " title prefix as the fallback. Desktop's
//   Bot Mode does exactly this (apps/desktop/src/plugins/hermes-bots/plugin.js
//   :5988-6020, :6173, :6490).

// MARK: - Job model

/// A cron job in the shape `_format_job` emits. TalariaKit's `CronJob` predates
/// the verified payload (it reads `id`/`next_run`/`last_run`, none of which the
/// server sends), so routines decode through this instead.
public struct CronJobRecord: Sendable, Identifiable, Equatable {
    /// Canonical job id — the value pause/resume/remove/trigger address.
    public var id: String
    /// Full stored title, including any "[bot:<name>] " namespace prefix.
    public var name: String
    /// Human schedule string ("every 30m", "0 9 * * *", "once at …").
    public var schedule: String
    public var promptPreview: String
    public var enabled: Bool
    /// Server-side lifecycle state ("scheduled" | "paused" | "running" | …).
    public var state: String
    public var nextRun: Date?
    public var lastRun: Date?
    /// Outcome of the last fire ("success" | "error" | nil before the first).
    public var lastStatus: String?
    /// Delivery target ("local" unless a messaging platform is configured).
    public var deliver: String?
    public var repeatDisplay: String?
    /// Profile store that produced this row when the gateway echoes it. Older
    /// gateways omit it; callers then use the resolved launch/scoped profile.
    public var profile: String?
    /// Exact optional per-job reasoning pin emitted by `_format_job`.
    ///
    /// Keep this raw instead of eagerly folding it into the known choices:
    /// jobs.json is user-editable, and Hermes deliberately ignores an unknown
    /// stored value at fire time and falls back to config. A client that turns
    /// that unknown value into nil would hide the repairable bad pin and could
    /// erase it on an otherwise unrelated edit.
    public var reasoningEffortRaw: String?

    public var reasoningEffort: CronReasoningEffort {
        CronReasoningEffort(raw: reasoningEffortRaw)
    }

    /// True when the gateway considers this job live — `enabled` alone is not
    /// enough, a half-paused record keeps `enabled: true` with `state:"paused"`
    /// (the same guard desktop's RoutineRow applies).
    public var isActive: Bool { enabled && state.lowercased() != "paused" }

    /// Bot id parsed from the "[bot:<name>] " prefix, lowercased like desktop's
    /// BOT_TAG_RE.
    public var taggedBotID: String? {
        guard name.hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else { return nil }
        let tag = name[name.index(name.startIndex, offsetBy: 5)..<close]
        let trimmed = tag.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Title with the "[bot:…]" namespace stripped.
    public var displayTitle: String {
        guard name.hasPrefix("[bot:"), let close = name.firstIndex(of: "]") else { return name }
        let rest = name[name.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    public init(_ v: JSONValue) {
        id = v["job_id"]?.stringValue ?? v["id"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        schedule = v["schedule"]?.stringValue ?? ""
        promptPreview = v["prompt_preview"]?.stringValue ?? v["prompt"]?.stringValue ?? ""
        enabled = v["enabled"]?.boolValue ?? true
        state = v["state"]?.stringValue ?? "scheduled"
        nextRun = HermesTime.date(v["next_run_at"])
        lastRun = HermesTime.date(v["last_run_at"])
        lastStatus = v["last_status"]?.stringValue
        deliver = v["deliver"]?.stringValue
        repeatDisplay = v["repeat"]?.stringValue
        profile = v["profile"]?.stringValue ?? v["profile_name"]?.stringValue
            ?? v["info"]?["profile_name"]?.stringValue
        reasoningEffortRaw = v["reasoning_effort"]?.stringValue
    }
}

/// A `cron.manage {action:"list"}` result plus the scope marker that tells us
/// whether the gateway honored the `profile` param.
public struct CronListing: Sendable {
    public var jobs: [CronJobRecord]
    /// Non-nil when the gateway echoed `scoped`, `profile`, or `profile_name` —
    /// proof every job in this listing belongs to that profile's own store.
    public var scopedProfile: String?
    /// Some REST/WS bridges call the scope `profile_name` instead of `scoped`.
    /// Preserve that response identity for launch-store attribution.
    public var profile: String?

    public init(jobs: [CronJobRecord], scopedProfile: String?, profile: String? = nil) {
        self.jobs = jobs; self.scopedProfile = scopedProfile; self.profile = profile
    }
}

// MARK: - Timestamps

/// Cron timestamps are `datetime.isoformat()` strings (cron/jobs.py:1934), with
/// or without fractional seconds, and occasionally naive (no offset) on older
/// records. Session rows, by contrast, carry unix numbers — parse both.
public enum HermesTime {
    private static let internetDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Naive "2026-08-18T07:00:00[.123]" — interpreted in the device timezone,
    /// which is the closest thing the phone has to the gateway's clock.
    private static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public static func date(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if let unix = value.doubleValue, unix > 0 {
            // Session rows store unix seconds; anything past the year-2286
            // seconds ceiling is already milliseconds.
            return Date(timeIntervalSince1970: unix > 10_000_000_000 ? unix / 1000 : unix)
        }
        guard let raw = value.stringValue, !raw.isEmpty else { return nil }
        if let d = fractional.date(from: raw) ?? internetDate.date(from: raw) { return d }
        return naive.date(from: String(raw.prefix(19)))
    }
}

// MARK: - Schedules

/// The gateway's schedule grammar (cron/jobs.py:694 `parse_schedule`) is narrow:
/// a duration ("30m"/"2h"/"1d"), "every <duration>", a 5-field cron expression,
/// or an ISO timestamp. Free text like "every weekday at 9" is rejected with a
/// ValueError, so the phone normalizes the phrases people actually type into
/// that grammar *before* the RPC and refuses locally when it cannot.
public enum HermesSchedule {

    /// Normalize a human phrase into a schedule the gateway accepts, or nil
    /// when it cannot be expressed (the caller shows the accepted forms).
    public static func normalize(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if isNative(raw) { return raw }

        // "at" and "o'clock" carry no information once a clock time is parsed
        // out; dropping them keeps the time regex from tripping over them.
        let s = raw.lowercased()
            .replacingOccurrences(of: "at ", with: "")
            .replacingOccurrences(of: "o'clock", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // Bare shorthands.
        switch s {
        case "hourly", "every hour": return "every 1h"
        case "daily", "every day", "nightly": return "every 1d"
        case "weekly", "every week": return "0 9 * * 1"
        case "now", "immediately": return "1m"
        default: break
        }

        let time = clockTime(in: s)
        let hour = time?.hour
        let minute = time?.minute ?? 0

        if s.contains("weekday") || s.contains("workday") {
            return "\(minute) \(hour ?? 9) * * 1-5"
        }
        if let weekday = weekdayField(in: s) {
            return "\(minute) \(hour ?? 9) * * \(weekday)"
        }
        if s.contains("morning"), !s.contains("every "), hour == nil {
            return "0 8 * * *"
        }
        if s.hasPrefix("every"), let interval = duration(in: s) {
            return "every \(interval)"
        }
        if s.hasPrefix("in "), let interval = duration(in: s) {
            return interval
        }
        if let hour {
            // "every day at 7", "7am", "19:30" → a daily cron at that time.
            return "\(minute) \(hour) * * *"
        }
        if let interval = duration(in: s) { return interval }
        return nil
    }

    /// Already valid for `parse_schedule` — pass straight through.
    static func isNative(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.range(of: #"^\d+\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$"#,
                       options: .regularExpression) != nil { return true }
        if lower.hasPrefix("every "),
           lower.dropFirst(6).trimmingCharacters(in: .whitespaces)
               .range(of: #"^\d+\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$"#,
                      options: .regularExpression) != nil { return true }
        let fields = s.split(separator: " ")
        if fields.count >= 5,
           fields.prefix(5).allSatisfy({ $0.range(of: #"^[\d\*\-,/]+$"#, options: .regularExpression) != nil }) {
            return true
        }
        return s.contains("T") && s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    /// "30 minutes" / "2 hours" / "45m" → "30m" / "2h" / "45m".
    private static func duration(in s: String) -> String? {
        guard let match = s.range(of: #"(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d)\b"#,
                                  options: .regularExpression) else { return nil }
        let text = String(s[match])
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let unit = text.drop(while: { $0.isNumber || $0 == " " }).first.map(String.init) ?? "m"
        return "\(digits)\(unit)"
    }

    /// "7", "7am", "19:30", "7:15 pm" → components, or nil when absent.
    private static func clockTime(in s: String) -> (hour: Int, minute: Int)? {
        guard let match = s.range(of: #"(\d{1,2})(:(\d{2}))?\s*(am|pm)?"#, options: .regularExpression)
        else { return nil }
        let text = String(s[match])
        // A bare number attached to a duration ("30m") is not a clock time.
        if text.range(of: #"^\d+\s*(m|h|d)\b"#, options: .regularExpression) != nil { return nil }
        let parts = text.split(whereSeparator: { !$0.isNumber })
        guard let first = parts.first, var hour = Int(first), hour <= 24 else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        if text.contains("pm"), hour < 12 { hour += 12 }
        if text.contains("am"), hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func weekdayField(in s: String) -> String? {
        let days = ["sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
                    "thursday": 4, "friday": 5, "saturday": 6]
        for (name, index) in days where s.contains(name) { return String(index) }
        return nil
    }

    /// Short label for a schedule string, for row subtitles.
    public static func label(_ schedule: String) -> String {
        let fields = schedule.split(separator: " ")
        guard fields.count >= 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else {
            return schedule
        }
        let clock = String(format: "%02d:%02d", hour, minute)
        switch fields[4] {
        case "*": return "daily at \(clock)"
        case "1-5": return "weekdays at \(clock)"
        default: return "\(clock) · \(fields[4])"
        }
    }
}

// MARK: - RPCs

public extension GatewayClient {

    /// `cron.manage {action:"list"}`. `includeDisabled` matters: paused jobs are
    /// omitted by default, which reads as deletion in any UI with a toggle.
    func cronJobs(profile: String? = nil, includeDisabled: Bool = true) async throws -> CronListing {
        var params: [String: JSONValue] = ["action": "list",
                                           "include_disabled": .bool(includeDisabled)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("cron.manage", .object(params))
        try Self.throwIfToolFailed(result)
        let rows = result["jobs"]?.arrayValue ?? []
        let responseProfile = result["profile"]?.stringValue
            ?? result["profile_name"]?.stringValue
        return CronListing(jobs: rows.map(CronJobRecord.init),
                           scopedProfile: result["scoped"]?.stringValue ?? responseProfile,
                           profile: responseProfile)
    }

    /// `cron.manage {action:"add"}`. `name` carries the full stored title —
    /// callers namespace it "[bot:<name>] <title>". Returns the new job id.
    @discardableResult
    func cronAdd(name: String, schedule: String, prompt: String,
                 profile: String? = nil, repeatCount: Int? = nil,
                 continuity: Bool = false) async throws -> String {
        var params: [String: JSONValue] = ["action": "add", "name": .string(name),
                                           "schedule": .string(schedule),
                                           "prompt": .string(prompt)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let repeatCount, repeatCount > 0 { params["repeat"] = .number(Double(repeatCount)) }
        if continuity { params["continuity"] = .bool(true) }
        let result = try await rpc("cron.manage", .object(params), timeout: 60)
        try Self.throwIfToolFailed(result)
        return result["job_id"]?.stringValue ?? ""
    }

    /// Pause / resume — the gateway's only enable-disable vocabulary. The job
    /// id travels in `name` (the handler forwards it as cronjob's job_id).
    func cronSetPaused(jobID: String, paused: Bool, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["action": .string(paused ? "pause" : "resume"),
                                           "name": .string(jobID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("cron.manage", .object(params))
        try Self.throwIfToolFailed(result)
    }

    func cronRemove(jobID: String, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["action": "remove", "name": .string(jobID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("cron.manage", .object(params))
        try Self.throwIfToolFailed(result)
    }

    /// The cronjob tool reports its own failures inside a successful RPC
    /// envelope ({"success":false,"error":…}) — surface those as errors instead
    /// of silently "succeeding".
    private static func throwIfToolFailed(_ result: JSONValue) throws {
        guard result["success"]?.boolValue == false else { return }
        let message = result["error"]?.stringValue ?? "cron.manage failed"
        throw GatewayError(code: 5023, message: message)
    }
}

// MARK: - REST (the parts cron.manage cannot do)

/// Authenticated REST calls Talaria makes outside `GatewayClient`'s own surface.
/// The client keeps its credential private, so callers pass the one held by the
/// ConnectionRegistry (the Keychain copy the client refreshes on connect).
public enum GatewayREST {

    /// `POST /api/cron/jobs/{id}/trigger` (hermes_cli/web_routers/cron.py:126) —
    /// the only run-now path; cron.manage rejects "run" with 4016. `job_id` may
    /// be an id or a job name, and an omitted profile makes the server search
    /// every profile's store (web_server.py:12732).
    ///
    /// The handler fires the job INSIDE the request (`_fire_cron_job_for_profile`),
    /// which is why desktop gives this call a 24 h ceiling. A phone cannot hold a
    /// request open for a whole agent run, so a timeout here is not a failure:
    /// the durable claim was taken before the run began, the job IS running, and
    /// its outcome arrives over cron.changed.
    ///
    /// - Returns: true when the run finished inside the request, false when it
    ///   is still going server-side.
    @discardableResult
    public static func triggerCronJob(baseURL: URL, credential: GatewayCredential,
                                      jobID: String, profile: String?) async throws -> Bool {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query = [URLQueryItem(name: "profile", value: profile)]
        }
        do {
            _ = try await restData(baseURL: baseURL, credential: credential,
                                   path: "api/cron/jobs/\(jobID)/trigger",
                                   query: query, method: "POST",
                                   timeout: 45, what: "trigger")
            return true
        } catch let error as URLError where error.code == .timedOut {
            return false
        }
    }

    /// `GET /api/sessions/{id}/messages` with a profile scope — the transcript
    /// read behind the artifact index and the Agent Inbox feed. Rows are raw
    /// message records (`role`, `content`, `tool_name`, `timestamp`), not the
    /// session.resume projection, so callers read `content` first.
    public static func sessionMessages(baseURL: URL, credential: GatewayCredential,
                                       storedID: String, profile: String?,
                                       limit: Int) async throws -> [JSONValue] {
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "order", value: "latest")]
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        let data = try await restData(baseURL: baseURL, credential: credential,
                                      path: "api/sessions/\(storedID)/messages",
                                      query: query, timeout: 25, what: "transcript")
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        return payload["messages"]?.arrayValue ?? []
    }
}

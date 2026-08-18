import Foundation
import Observation

#if canImport(EventKit)
import EventKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

// Solo mode's hands — roadmap Phase 5, docs/SOLO-MODE.md §"The Solo tool surface".
//
// SoloEngine.swift (its own file, another owner) is the agent loop and owns the
// `SoloTool` / `SoloToolSpec` / `SoloToolRegistry` contract. This file is the
// iOS-permitted tool set built against it, plus the stores those tools read and
// the two gates every call passes through.
//
// iOS deletes most of what makes hermes powerful. There is no fork/exec, so the
// terminal tool — hermes's most-used — cannot exist here at all
// (.research/profiles-runtime.md §8.3). What the platform does permit is the
// set below, each chosen because it is useful FROM A PHONE rather than because
// it mimics a desktop:
//
//   files      read/write inside Solo's own workspace and the folders you grant
//   web        fetch a URL and hand back its readable text
//   calendar   EventKit events, read and create
//   reminders  EventKit reminders, read and create
//   photos     the images you hand Solo — listed, and read for their text
//   shortcuts  run a named shortcut, the honest iOS analogue of a shell: it is
//              how the platform lets one app trigger automation the user wrote
//   memory     Solo's own notes file, and search over Solo's own transcripts
//
// TWO GATES, ALWAYS, IN THIS ORDER
//
//   1. PERMISSION (`SoloSettingsStore`). A permission that is off does not make
//      its tools refuse — it keeps them out of the registry entirely, so the
//      model is never told they exist. That is not tidiness, it is the context
//      budget: §8.4 of the runtime research is blunt that prefill dominates
//      on-device latency and that a ≤4B model's tool-calling reliability falls
//      away past a handful of schemas. Hiding what you switched off is free
//      speed and better answers.
//   2. APPROVAL (`SoloApprovalCenter`). Anything that changes the device or
//      leaves it goes through the SAME vocabulary as gateway bots — `Approval`,
//      `ApprovalChoice`, once/session/always/deny — so the safety story reads
//      identically whichever tier you are in. "Always" persists into a local
//      allowlist scoped per host and per shortcut, which is the phone's answer
//      to hermes's `command_allowlist` (tools/approval.py:2931-2957) and, like
//      it, something Settings owes you a way to take back.
//
// The OS's own permission is a third gate we do not own and must never
// pre-empt: EventKit is asked at the point of use, and if this build carries no
// usage description for it the tool reports itself unavailable rather than
// calling the framework — an EventKit request with no Info.plist string
// terminates the process, and a crash is not a degradation path.
//
// NOTHING HERE TALKS TO A GATEWAY, so there is no RPC shape to cite: every byte
// stays on the device except a `web_fetch` the person approved, and the
// Shortcuts hand-off, which leaves Talaria entirely.

// MARK: - The registry contract

/// What a tool call produced. `text` is what the model reads; `summary` is the
/// one-line chip the transcript renders, the role `ToolCall.summary` plays for
/// gateway tools.
public struct SoloToolResult: Sendable, Equatable {
    public var text: String
    public var summary: String
    public var isError: Bool

    public init(text: String, summary: String, isError: Bool = false) {
        self.text = text
        self.summary = summary
        self.isError = isError
    }
}

/// Why a Solo tool could not do what was asked.
///
/// `SoloToolRegistry.run` turns these into a `SoloToolResult` the model reads
/// and recovers from, so `modelFacingText` is written FOR THE MODEL: specific,
/// and explicit about whether retrying is pointless — a small model told merely
/// "error" will try the same call again.
public enum SoloToolError: Error, LocalizedError, Sendable, Equatable {
    /// The person answered "deny".
    case denied(String)
    /// Talaria's own switch for this family is off.
    case permissionMissing(SoloPermission)
    /// The OS refused, or this build cannot ask the OS.
    case notAuthorized(String)
    /// The model's arguments did not match the schema.
    case badArguments(String)
    /// The platform, or this build, cannot do it at all.
    case unavailable(String)
    /// It was attempted and it failed.
    case failed(String)

    public var modelFacingText: String {
        switch self {
        case .denied(let what):
            "The person declined: \(what). Do not retry it — answer with what you "
                + "already know, or ask them what to do instead."
        case .permissionMissing(let permission):
            "The \(permission.rawValue) permission is switched off in Solo settings. "
                + "Tell the person rather than retrying."
        case .notAuthorized(let what): "Not authorized: \(what). Do not retry."
        case .badArguments(let why): "Invalid arguments: \(why)."
        case .unavailable(let why): "Unavailable: \(why). Do not retry."
        case .failed(let why): "Failed: \(why)."
        }
    }

    public var errorDescription: String? { modelFacingText }
}

/// The registry contract, shared with SoloEngine.swift.
///
/// Implementations are values built per listing, so a description can name the
/// folders and shortcuts that exist right now rather than the ones that existed
/// at launch.
public protocol SoloTool: Sendable {
    /// snake_case and stable — the name the model emits.
    var name: String { get }
    /// One or two sentences, written for a 3B model rather than for a reader.
    /// Every character is prefill on every turn.
    var description: String { get }
    /// JSON Schema for the arguments object.
    var parameters: JSONValue { get }
    func invoke(_ arguments: JSONValue) async throws -> SoloToolResult
}

/// Everything Solo's own tools add on top of the registry contract: which
/// switch owns them, what they do to the world, and the question they would
/// raise before doing it.
public protocol SoloGatedTool: SoloTool {
    var permission: SoloPermission { get }
    var effect: SoloToolEffect { get }
    /// Only vision-capable engines are offered a tool that hands an image back.
    ///
    /// Nothing sets this today and that is a statement rather than an omission:
    /// Talaria's inference seam is text-only (`InferenceMessage` is
    /// `{role, content}`), so no engine in this app can be handed a picture. The
    /// flag and the registry's filter exist because `SoloEngine` already carries
    /// `visionCapable` through, and because the honest photo tool — reading the
    /// text inside an image with Vision — needs no vision model at all.
    var requiresVision: Bool { get }
    /// The approval this call would raise, or nil when there is nothing worth
    /// asking. Built from the actual arguments, because "fetch a URL" is not a
    /// question — "fetch https://example.com/x" is.
    func approval(for arguments: JSONValue) -> SoloApprovalDraft?
}

public extension SoloGatedTool {
    var requiresVision: Bool { false }
}

// MARK: - Permissions

/// The seven switches in Solo settings. One per tool family, because that is
/// the granularity a person can reason about — "Solo can read my calendar" is a
/// decision; "Solo can call calendar_events" is a chore.
public enum SoloPermission: String, CaseIterable, Codable, Sendable, Identifiable {
    case files, web, calendar, reminders, photos, shortcuts, memory

    public var id: String { rawValue }

    /// Memory is Solo's own notes and its own transcripts — the equivalent of
    /// remembering the last thing you said to it. Off by default it would make
    /// Solo amnesiac in a way nobody asked for, so it is the one that starts on.
    public var defaultsToEnabled: Bool { self == .memory }

    /// Whether granting this ALSO requires an OS permission dialog Talaria does
    /// not control, so settings can explain the second gate honestly.
    public var needsSystemPermission: Bool {
        switch self {
        case .calendar, .reminders: true
        case .files, .web, .photos, .shortcuts, .memory: false
        }
    }

    /// Tool names this permission carries, granted or not. The explainer lists
    /// these, so that screen cannot drift from what the registry actually builds.
    public var toolNames: [String] {
        switch self {
        case .files: ["files_list", "files_read", "files_write"]
        case .web: ["web_fetch"]
        case .calendar: ["calendar_events", "calendar_add_event"]
        case .reminders: ["reminders_list", "reminders_add"]
        case .photos: ["photos_list", "photos_read_text"]
        case .shortcuts: ["shortcuts_list", "shortcuts_run"]
        case .memory: ["memory_read", "memory_write", "sessions_search"]
        }
    }

    /// Families this build cannot serve at all. Compile-time, and the only real
    /// case is an SDK without EventKit or Vision — but a switch that cannot do
    /// anything must not offer itself.
    public var isCompiledIn: Bool {
        switch self {
        case .calendar, .reminders:
            #if canImport(EventKit)
            true
            #else
            false
            #endif
        case .photos:
            #if canImport(Vision)
            true
            #else
            false
            #endif
        default: true
        }
    }

    /// Compiled in AND askable on this build. A family whose OS permission has
    /// no Info.plist usage description can never be granted — asking without one
    /// terminates the process, so `SoloEventKitGate` refuses to ask at all — and
    /// a surface that advertised it would be promising a switch that cannot move.
    ///
    /// One predicate rather than two, because Solo settings (which decides
    /// whether to draw a toggle) and the explainer (which decides whether to
    /// list the tools) must never disagree about what this build can do.
    public var isUsableInThisBuild: Bool {
        guard isCompiledIn else { return false }
        #if canImport(EventKit)
        return SoloEventKitGate.canAsk(for: self)
        #else
        return !needsSystemPermission
        #endif
    }
}

/// What a call does to the world, which is what decides whether it asks first.
public enum SoloToolEffect: String, Sendable, Equatable {
    /// Reads something already on the device, inside a scope the person granted.
    case read
    /// Changes something on the device.
    case write
    /// Sends data off the device, or hands control to another app.
    case leaves
}

/// How often a permission asks. The local analogue of hermes's `approvals.mode`
/// (tools/approval.py:3142-3168), collapsed to the three answers that still
/// mean something with no gateway-side auxiliary model to triage with.
public enum SoloAskPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Every call asks, reads included.
    case always
    /// Only calls that change the device or leave it. The default.
    case changes
    /// Nothing asks. Deliberately reachable — and deliberately spelled out on
    /// the row that sets it.
    case never

    public var id: String { rawValue }

    public func requiresApproval(for effect: SoloToolEffect) -> Bool {
        switch self {
        case .always: true
        case .changes: effect != .read
        case .never: false
        }
    }
}

// MARK: - Settings store

/// Solo's persisted choices: which engine, which model, which permissions, how
/// often each asks. Lives in `UserDefaults` under the `talaria.solo.` namespace
/// so Settings → Privacy's inventory finds it without being told —
/// AppModelLive+Settings.swift:524 walks the whole `talaria` namespace, which
/// is precisely so a preference added by a file it has never heard of still
/// shows up there and is still removed by "delete local data".
@MainActor
@Observable
public final class SoloSettingsStore {
    public static let shared = SoloSettingsStore()

    public static let engineKey = "talaria.solo.engine"
    public static let modelKey = "talaria.solo.model"
    public static let permissionsKey = "talaria.solo.permissions"
    public static let policiesKey = "talaria.solo.ask-policies"
    public static let explainerSeenKey = "talaria.solo.explainer-seen"

    public var engine: SoloEngineID {
        didSet { defaults.set(engine.rawValue, forKey: Self.engineKey) }
    }

    /// Hub id of the MLX model the person picked; empty means "whichever one is
    /// downloaded", which is the honest answer while only one ever is.
    public var modelID: String {
        didSet { defaults.set(modelID, forKey: Self.modelKey) }
    }

    /// Set once the explainer has been opened. It gates nothing except whether
    /// onboarding shows it unprompted — the screen stays reachable from
    /// Settings forever, which is the entire point of it.
    public var hasSeenExplainer: Bool {
        didSet { defaults.set(hasSeenExplainer, forKey: Self.explainerSeenKey) }
    }

    private var enabled: [String: Bool] {
        didSet { defaults.set(enabled, forKey: Self.permissionsKey) }
    }

    private var policies: [String: String] {
        didSet { defaults.set(policies, forKey: Self.policiesKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = SoloEngineID(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .foundation
        modelID = defaults.string(forKey: Self.modelKey) ?? ""
        hasSeenExplainer = defaults.bool(forKey: Self.explainerSeenKey)
        enabled = defaults.dictionary(forKey: Self.permissionsKey) as? [String: Bool] ?? [:]
        policies = defaults.dictionary(forKey: Self.policiesKey) as? [String: String] ?? [:]
    }

    /// `isUsableInThisBuild`, not `isCompiledIn`: a stored `true` from a build
    /// that could ask the OS must not put tools in the registry on one that
    /// cannot — the model would be offered a family whose every call fails.
    public func isEnabled(_ permission: SoloPermission) -> Bool {
        guard permission.isUsableInThisBuild else { return false }
        return enabled[permission.rawValue] ?? permission.defaultsToEnabled
    }

    public func setEnabled(_ permission: SoloPermission, _ on: Bool) {
        enabled[permission.rawValue] = on
    }

    public func askPolicy(for permission: SoloPermission) -> SoloAskPolicy {
        SoloAskPolicy(rawValue: policies[permission.rawValue] ?? "") ?? .changes
    }

    public func setAskPolicy(_ policy: SoloAskPolicy, for permission: SoloPermission) {
        policies[permission.rawValue] = policy.rawValue
    }

    /// Permissions that are on, in declaration order.
    public var grantedPermissions: [SoloPermission] {
        SoloPermission.allCases.filter(isEnabled)
    }

    /// Back to shipped values. Needed by "delete local data": every property
    /// here writes through on `didSet`, so removing the defaults keys while this
    /// store still holds the old values only postpones the deletion until the
    /// next write — see the same warning in `AppModel.deleteAllLocalData`.
    public func resetToDefaults() {
        engine = .foundation
        modelID = ""
        hasSeenExplainer = false
        enabled = [:]
        policies = [:]
    }
}

// MARK: - Approvals

/// The question a tool wants to ask, before it becomes an `Approval` card.
public struct SoloApprovalDraft: Sendable, Equatable {
    public var toolName: String
    public var kind: ApprovalKind
    public var title: String
    /// The human sentence describing THIS call — also what the transcript's
    /// tool chip shows, so the chip and the card never disagree.
    public var target: String
    public var subject: String
    public var body: String
    public var why: String
    /// What "always" would remember. Scoped as narrowly as the action allows —
    /// `web:example.com`, never `web` — because the grant is given in a hurry,
    /// often from a lock screen, and a blanket one is a trap.
    public var scopeKey: String

    public init(toolName: String, kind: ApprovalKind = .other, title: String, target: String,
                subject: String = "", body: String = "", why: String, scopeKey: String) {
        self.toolName = toolName; self.kind = kind; self.title = title
        self.target = target; self.subject = subject; self.body = body
        self.why = why; self.scopeKey = scopeKey
    }
}

/// Solo's pending approvals and the standing grants that answer them.
///
/// `AppModel`'s stored properties live in AppModel.swift (another owner) and
/// extensions cannot add storage, so — following `ApprovalBridges`' precedent —
/// this is a MainActor singleton. Whoever mounts Solo merges `pending` into the
/// approvals surface and calls `resolve(_:choice:)`. The cards are ordinary
/// `Approval` values, so `ApprovalsView` and `InlineApprovalCard` render them
/// with no new code — which is the whole claim behind "the same approval flow".
@MainActor
@Observable
public final class SoloApprovalCenter {
    public static let shared = SoloApprovalCenter()

    public static let allowlistKey = "talaria.solo.allowlist"

    /// The bot id Solo's approvals are attributed to, so a card carries an
    /// identity without inventing a gateway bot.
    public static let botID = "solo"

    /// Oldest first. A Solo turn parks on one of these at a time, but the array
    /// is the shape the approvals surface already speaks.
    public private(set) var pending: [Approval] = []

    /// Scope keys answered "always" — the phone's `command_allowlist`
    /// (tools/approval.py:2931-2957), and like it, something Settings owes you a
    /// way to take back.
    public private(set) var allowlist: [String] = [] {
        didSet { defaults.set(allowlist, forKey: Self.allowlistKey) }
    }

    /// "Just this conversation" grants, dropped by `endSession()`.
    public private(set) var sessionAllowlist: Set<String> = []

    private var scopes: [String: String] = [:]
    private var waiters: [String: CheckedContinuation<ApprovalChoice, Never>] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowlist = defaults.stringArray(forKey: Self.allowlistKey) ?? []
    }

    /// Park until the person answers. Returns `.deny` on cancellation — a
    /// stopped turn must never leave a tool thread waiting forever.
    public func decide(_ draft: SoloApprovalDraft) async -> ApprovalChoice {
        if allowlist.contains(draft.scopeKey) { return .always }
        if sessionAllowlist.contains(draft.scopeKey) { return .session }

        let id = "solo-\(UUID().uuidString)"
        let approval = Approval(id: id, botID: Self.botID, kind: draft.kind,
                                title: draft.title, target: draft.target,
                                subject: draft.subject, body: draft.body,
                                why: draft.why, age: "now")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalChoice, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .deny)
                    return
                }
                scopes[id] = draft.scopeKey
                waiters[id] = continuation
                pending.append(approval)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, choice: .deny) }
        }
    }

    /// Solo answers everything a gateway approval can — there is no server to
    /// narrow the set, so the card offers all four.
    public func choices(for approvalID: String) -> [ApprovalChoice] {
        waiters[approvalID] == nil ? [] : [.once, .session, .always, .deny]
    }

    public func resolve(_ approvalID: String, choice: ApprovalChoice) {
        guard let continuation = waiters.removeValue(forKey: approvalID) else { return }
        let scopeKey = scopes.removeValue(forKey: approvalID)
        pending.removeAll { $0.id == approvalID }

        if let scopeKey {
            switch choice {
            case .always: if !allowlist.contains(scopeKey) { allowlist.append(scopeKey) }
            case .session: sessionAllowlist.insert(scopeKey)
            case .once, .deny: break
            }
        }
        continuation.resume(returning: choice)
    }

    /// A Solo conversation ended: session grants do not outlive it.
    public func endSession() {
        sessionAllowlist.removeAll()
    }

    public func revoke(_ scopeKey: String) {
        allowlist.removeAll { $0 == scopeKey }
        sessionAllowlist.remove(scopeKey)
    }

    public func clearAllowlist() {
        allowlist.removeAll()
        sessionAllowlist.removeAll()
    }

    /// Deny everything still parked — used when Solo is torn down.
    public func denyAll() {
        for id in Array(waiters.keys) { resolve(id, choice: .deny) }
    }

    /// How an allowlist entry reads on the row that revokes it. `nonisolated`
    /// because it is a pure rendering of a string and has no business being
    /// pinned to the main actor.
    public nonisolated static func describe(scopeKey: String) -> String {
        let parts = scopeKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return scopeKey }
        switch parts[0] {
        case "web": return "Fetch \(parts[1])"
        case "shortcuts": return "Run \u{201C}\(parts[1].replacingOccurrences(of: "run:", with: ""))\u{201D}"
        case "files": return "Write \(parts[1].replacingOccurrences(of: "write:", with: ""))"
        case "calendar": return "Calendar \(parts[1])"
        case "reminders": return "Reminders \(parts[1])"
        case "memory": return "Memory \(parts[1])"
        case "photos": return "Images \(parts[1])"
        default: return scopeKey
        }
    }
}

// MARK: - Host seam

/// The two things a tool needs that only the app layer can do: open a URL, and
/// receive the `talaria://` callback Shortcuts sends back. Both are one-line
/// installs from the app target:
///
///     SoloToolHost.shared.openURL = { await UIApplication.shared.open($0) }
///     // in the app's URL route:
///     if SoloToolHost.shared.deliver(url) { return }
///
/// With no opener installed `shortcuts_run` reports itself unavailable rather
/// than pretending to have run something.
@MainActor
@Observable
public final class SoloToolHost {
    public static let shared = SoloToolHost()

    public var openURL: ((URL) async -> Bool)?

    /// The MLX model manager, installed by the app when it links `TalariaLocal`.
    /// Nil in builds without it: the catalog still renders, the buttons do not.
    public var modelHost: (any SoloModelHost)?

    private var shortcutWaiters: [String: CheckedContinuation<SoloShortcutOutcome, Never>] = [:]
    /// Outcomes that arrived before anyone was waiting for them.
    private var deliveredEarly: [String: SoloShortcutOutcome] = [:]

    public init() {}

    /// The callback Shortcuts opens when a run finishes. Returns true when the
    /// URL was ours, so the app's router can stop looking.
    ///
    /// Shape: `talaria://solo/shortcut?token=<t>[&result=…][&errorMessage=…]` —
    /// the `x-success` / `x-error` URLs `shortcuts_run` hands to
    /// `shortcuts://x-callback-url/run-shortcut`. Shortcuts appends the
    /// shortcut's own output as `result` when it ends with a value.
    @discardableResult
    public func deliver(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "talaria",
              url.host?.lowercased() == "solo",
              url.path.hasSuffix("shortcut") else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let token = value("token") else { return true }
        let outcome: SoloShortcutOutcome = if let message = value("errorMessage") ?? value("error") {
            .failed(message)
        } else {
            .finished(value("result") ?? "")
        }
        if let continuation = shortcutWaiters.removeValue(forKey: token) {
            continuation.resume(returning: outcome)
        } else {
            // The callback beat the waiter. `shortcuts_run` starts the wait in a
            // child task, so registration is concurrent with opening the URL —
            // and a shortcut that returns instantly would otherwise be lost and
            // the turn would park for the full timeout. Hold the answer for
            // whoever asks next.
            deliveredEarly[token] = outcome
        }
        return true
    }

    /// Wait for one shortcut callback. Times out rather than hanging: plenty of
    /// shortcuts never call back at all, and "it ran and said nothing" is a true
    /// answer where a stuck turn is not.
    func awaitShortcut(token: String, timeout: Duration) async -> SoloShortcutOutcome {
        if let early = deliveredEarly.removeValue(forKey: token) { return early }

        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            shortcutWaiters.removeValue(forKey: token)?.resume(returning: .noCallback)
        }
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SoloShortcutOutcome, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .noCallback)
                    return
                }
                shortcutWaiters[token] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.shortcutWaiters.removeValue(forKey: token)?.resume(returning: .noCallback)
            }
        }
    }
}

enum SoloShortcutOutcome: Sendable, Equatable {
    case finished(String)
    case failed(String)
    case noCallback
}

/// The MLX side of Solo, kept behind a protocol so this package stays free of
/// third-party dependencies — `TalariaLocal` is a separate package precisely so
/// MLX's Metal kernels never enter the default app target
/// (docs/LOCAL-INFERENCE.md §"On-device models").
@MainActor
public protocol SoloModelHost: AnyObject {
    var downloadedModelIDs: [String] { get }
    func diskUsageBytes(for modelID: String) -> Int64
    func download(_ modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws
    func delete(_ modelID: String) throws
}

// MARK: - Storage

/// Solo's corner of the disk. Separate from anything gateway-shaped: Solo has
/// its own storage and its own memory note and never pretends to share a
/// profile's (docs/SOLO-MODE.md §"The three tiers").
public enum SoloStore {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Talaria/Solo", isDirectory: true)
    }

    public static var workspace: URL { root.appendingPathComponent("Workspace", isDirectory: true) }
    public static var photos: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    public static var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    public static var memoryFile: URL { root.appendingPathComponent("memory.md") }

    @discardableResult
    public static func ensure(_ directory: URL) -> Bool {
        if (try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)) != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: directory.path)
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: url,
                                                        includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walk {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Everything Solo has written — for Settings and for "forget it all".
    public static var totalBytes: Int64 { directorySize(root) }

    public static func eraseEverything() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - File scopes

/// The folders Solo may touch: its own workspace, plus whatever the person
/// picked in the document picker. Grants are security-scoped bookmarks, so they
/// survive relaunch without Talaria keeping a copy of anyone's files.
@MainActor
@Observable
public final class SoloFileScopes {
    public static let shared = SoloFileScopes()

    public static let storageKey = "talaria.solo.file-scopes"

    /// The name the workspace answers to in a tool argument. `nonisolated`
    /// because tool descriptions are built off the main actor and this is a
    /// constant, not state.
    public nonisolated static let workspaceName = "workspace"

    public struct Scope: Identifiable, Sendable, Equatable {
        public var id: String
        /// The single path component the model uses as a prefix.
        public var name: String
        public var displayPath: String
        /// A bookmark the system could no longer resolve — the folder moved, or
        /// the grant lapsed. Shown as such rather than silently failing later.
        public var isStale: Bool
    }

    public private(set) var scopes: [Scope] = []

    private var bookmarks: [String: Data] = [:] {
        didSet { defaults.set(bookmarks, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = defaults.dictionary(forKey: Self.storageKey) as? [String: Data] ?? [:]
        rebuild()
    }

    /// Grant a folder. Its own last path component becomes the name, uniquified,
    /// so `files_list "Notes"` reads the way a person would write it.
    public func add(_ url: URL) throws {
        var base = url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty || base == Self.workspaceName { base = "folder" }
        var name = base
        var suffix = 2
        while bookmarks[name] != nil {
            name = "\(base)-\(suffix)"
            suffix += 1
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        // iOS has no `.withSecurityScope` option: a plain bookmark of a
        // document-picker URL already carries the sandbox extension.
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        #endif
        bookmarks[name] = data
        rebuild()
    }

    public func remove(_ name: String) {
        bookmarks.removeValue(forKey: name)
        rebuild()
    }

    public func removeAll() {
        bookmarks.removeAll()
        rebuild()
    }

    /// Folder names a tool description should advertise.
    public var names: [String] { [Self.workspaceName] + bookmarks.keys.sorted() }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    fileprivate func resolve(name: String) -> (url: URL, accessed: Bool)? {
        if name == Self.workspaceName {
            SoloStore.ensure(SoloStore.workspace)
            return (SoloStore.workspace, false)
        }
        guard let data = bookmarks[name] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.resolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, url.startAccessingSecurityScopedResource())
    }

    private func rebuild() {
        SoloStore.ensure(SoloStore.workspace)
        var rows = [Scope(id: Self.workspaceName, name: Self.workspaceName,
                          displayPath: SoloStore.workspace.path, isStale: false)]
        for name in bookmarks.keys.sorted() {
            guard let data = bookmarks[name] else { continue }
            var stale = false
            let url = try? URL(resolvingBookmarkData: data, options: Self.resolutionOptions,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            rows.append(Scope(id: name, name: name, displayPath: url?.path ?? "",
                              isStale: stale || url == nil))
        }
        scopes = rows
    }
}

/// A path the model asked for, checked against the folders Solo was granted.
struct SoloResolvedPath: Sendable {
    var url: URL
    var scope: String
    var relative: String
    var accessed: Bool

    /// Every resolution must be released, or the sandbox extension leaks.
    func release() {
        if accessed { url.stopAccessingSecurityScopedResource() }
    }
}

/// Splits `folder/some/relative/path` into a granted scope and a safe relative
/// path. Refuses `..` and anything that resolves outside the granted root — the
/// model writes these strings, so they are never trusted.
enum SoloPath {
    @MainActor
    static func resolve(_ raw: String) -> SoloResolvedPath? {
        let scopes = SoloFileScopes.shared
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.contains("..") else { return nil }

        let names = scopes.names
        let scopeName: String
        if let first = components.first, names.contains(first) {
            scopeName = first
            components.removeFirst()
        } else {
            scopeName = SoloFileScopes.workspaceName
        }
        guard let opened = scopes.resolve(name: scopeName) else { return nil }

        var url = opened.url
        for component in components { url.appendPathComponent(component) }

        // Standardizing after the fact catches whatever the component filter did
        // not: a path that climbs out of the granted root is not one we hold.
        let rootPath = opened.url.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target == rootPath || target.hasPrefix(rootPath + "/") else {
            if opened.accessed { opened.url.stopAccessingSecurityScopedResource() }
            return nil
        }
        return SoloResolvedPath(url: url, scope: scopeName,
                                relative: components.joined(separator: "/"),
                                accessed: opened.accessed)
    }
}

// MARK: - Photo shelf

/// The images the person handed Solo. Solo never sees the photo library: the
/// picker copies chosen images in here and the tools read only from here. That
/// is what "read selected images" means when you write it down.
@MainActor
@Observable
public final class SoloPhotoShelf {
    public static let shared = SoloPhotoShelf()

    static let indexName = "index.json"

    public struct Item: Identifiable, Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var file: String
        public var bytes: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var addedAt: Date
    }

    public private(set) var items: [Item] = []

    public init() { load() }

    @discardableResult
    public func add(data: Data, name: String) throws -> Item {
        SoloStore.ensure(SoloStore.photos)
        let id = UUID().uuidString
        let suggested = (name as NSString).pathExtension
        let ext = suggested.isEmpty ? "jpg" : suggested
        let file = "\(id).\(ext)"
        try data.write(to: SoloStore.photos.appendingPathComponent(file), options: .atomic)

        let size = Self.pixelSize(of: data)
        let item = Item(id: id, name: name.isEmpty ? "image.\(ext)" : name, file: file,
                        bytes: data.count, pixelWidth: size.width, pixelHeight: size.height,
                        addedAt: Date())
        items.append(item)
        save()
        return item
    }

    public func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(
            at: SoloStore.photos.appendingPathComponent(items[index].file))
        items.remove(at: index)
        save()
    }

    public func removeAll() {
        for item in items {
            try? FileManager.default.removeItem(
                at: SoloStore.photos.appendingPathComponent(item.file))
        }
        items.removeAll()
        save()
    }

    public func url(for item: Item) -> URL {
        SoloStore.photos.appendingPathComponent(item.file)
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + Int64($1.bytes) } }

    /// Pixel dimensions without decoding the image, so the shelf can show what
    /// was actually handed over.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return (0, 0) }
        return ((properties[kCGImagePropertyPixelWidth] as? Int) ?? 0,
                (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        #else
        return (0, 0)
        #endif
    }

    private var indexURL: URL { SoloStore.photos.appendingPathComponent(Self.indexName) }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let rows = try? JSONDecoder().decode([Item].self, from: data) else { return }
        // A file removed behind our back must not survive as a phantom row.
        items = rows.filter {
            FileManager.default.fileExists(
                atPath: SoloStore.photos.appendingPathComponent($0.file).path)
        }
    }

    private func save() {
        SoloStore.ensure(SoloStore.photos)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Shortcut book

/// iOS gives an app no way to enumerate a person's shortcuts, so Solo cannot
/// discover them — the person names the ones Solo may run. That is a smaller
/// surface than a shell and an honest one: nothing runs that they did not both
/// write and list.
@MainActor
@Observable
public final class SoloShortcutBook {
    public static let shared = SoloShortcutBook()

    public static let storageKey = "talaria.solo.shortcuts"

    public private(set) var names: [String] = [] {
        didSet { defaults.set(names, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    public func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !names.contains(trimmed) else { return }
        names.append(trimmed)
    }

    public func remove(_ name: String) { names.removeAll { $0 == name } }

    public func removeAll() { names.removeAll() }

    func canonical(_ name: String) -> String? {
        names.first { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}

// MARK: - Memory

/// Solo's notes file. One markdown document, editable by hand in Settings,
/// which is the whole of Solo's long-term memory — no embeddings, no index, and
/// no promise of recall it cannot keep.
public enum SoloMemory {
    public static let characterCeiling = 32_000

    public static func read() -> String {
        (try? String(contentsOf: SoloStore.memoryFile, encoding: .utf8)) ?? ""
    }

    public static func write(_ text: String) throws {
        SoloStore.ensure(SoloStore.root)
        let clipped = text.count > characterCeiling ? String(text.prefix(characterCeiling)) : text
        try clipped.write(to: SoloStore.memoryFile, atomically: true, encoding: .utf8)
    }

    public static func append(_ text: String) throws {
        let existing = read()
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try write(existing + separator + text + "\n")
    }

    public static var characterCount: Int { read().count }

    public static func erase() {
        try? FileManager.default.removeItem(at: SoloStore.memoryFile)
    }
}

// MARK: - Session archive

/// Solo's own transcripts, appended as JSON Lines so a crash costs one turn
/// rather than a file. Search over them is term-scored rather than FTS5:
/// SQLite's full-text extension needs a custom build on iOS
/// (docs/SOLO-MODE.md §"What we are NOT building"), and Solo's archive is
/// measured in megabytes, not gigabytes.
@MainActor
public final class SoloSessionArchive {
    public static let shared = SoloSessionArchive()

    public struct Turn: Codable, Sendable, Equatable {
        public var sessionID: String
        public var title: String
        public var role: String
        public var text: String
        public var at: Date
    }

    public struct Hit: Identifiable, Sendable, Equatable {
        public var id: String
        public var sessionID: String
        public var title: String
        public var role: String
        public var snippet: String
        public var at: Date
        public var score: Int
    }

    public init() {}

    /// The seam SoloEngine calls: every user and assistant turn, as it lands.
    public func record(sessionID: String, title: String, role: String, text: String,
                       at: Date = Date()) {
        guard !text.isEmpty else { return }
        SoloStore.ensure(SoloStore.sessions)
        let turn = Turn(sessionID: sessionID, title: title, role: role, text: text, at: at)
        guard var line = try? JSONEncoder().encode(turn) else { return }
        line.append(0x0A)

        let url = fileURL(for: sessionID)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    public func search(_ query: String, limit: Int = 8) -> [Hit] {
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }

        var hits: [Hit] = []
        for turn in allTurns() {
            let haystack = turn.text.lowercased()
            var matched = 0
            var occurrences = 0
            var first: String.Index?
            for term in terms {
                var searchRange = haystack.startIndex..<haystack.endIndex
                var found = false
                while let range = haystack.range(of: term, range: searchRange) {
                    found = true
                    occurrences += 1
                    if first == nil || range.lowerBound < first! { first = range.lowerBound }
                    guard range.upperBound < haystack.endIndex else { break }
                    searchRange = range.upperBound..<haystack.endIndex
                }
                if found { matched += 1 }
            }
            guard matched > 0 else { continue }
            hits.append(Hit(id: "\(turn.sessionID)-\(turn.at.timeIntervalSince1970)",
                            sessionID: turn.sessionID, title: turn.title, role: turn.role,
                            snippet: Self.snippet(turn.text, around: first, in: haystack),
                            at: turn.at,
                            // Breadth beats depth: a turn mentioning every term
                            // once answers better than one repeating a single
                            // term ten times.
                            score: matched * 100 + min(occurrences, 20)))
        }
        return Array(hits
            .sorted { $0.score == $1.score ? $0.at > $1.at : $0.score > $1.score }
            .prefix(limit))
    }

    public func sessionCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: SoloStore.sessions,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.count ?? 0
    }

    public var totalBytes: Int64 { SoloStore.directorySize(SoloStore.sessions) }

    public func eraseAll() {
        try? FileManager.default.removeItem(at: SoloStore.sessions)
    }

    private func fileURL(for sessionID: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = sessionID.components(separatedBy: allowed.inverted).joined()
        return SoloStore.sessions.appendingPathComponent("\(safe.isEmpty ? "session" : safe).jsonl")
    }

    private func allTurns() -> [Turn] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: SoloStore.sessions, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        var turns: [Turn] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let turn = try? decoder.decode(Turn.self, from: Data(line.utf8)) {
                    turns.append(turn)
                }
            }
        }
        return turns
    }

    private static func snippet(_ original: String, around index: String.Index?,
                                in lowered: String) -> String {
        guard let index else { return String(original.prefix(200)) }
        let offset = lowered.distance(from: lowered.startIndex, to: index)
        let start = max(0, offset - 90)
        let end = min(original.count, offset + 130)
        guard start < end else { return String(original.prefix(200)) }
        let lower = original.index(original.startIndex, offsetBy: start)
        let upper = original.index(original.startIndex, offsetBy: end)
        var text = String(original[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
        if start > 0 { text = "…" + text }
        if end < original.count { text += "…" }
        return text
    }
}

// MARK: - Engines

public enum SoloEngineID: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Apple's on-device system model through the Foundation Models framework.
    /// The default: zero download, tool calling is first class, and Apple owns
    /// the thermal envelope (docs/SOLO-MODE.md §"Inference on device").
    case foundation
    /// A model you chose and downloaded yourself, via the MLX package.
    case mlx
    /// Nous Portal — no gateway, no local weights, and by far the fastest tier.
    case portal

    public var id: String { rawValue }

    /// Portal is the only tier that needs the network — and the only one where
    /// the conversation leaves the device.
    public var isOnDevice: Bool { self != .portal }
}

public enum SoloUnavailableReason: String, Sendable, Equatable, Codable {
    /// The framework wants iOS 26 / macOS 26 and this system is older, or this
    /// build was made against an SDK without it.
    case osTooOld
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    /// This build does not link the MLX package at all.
    case notBuilt
    case noModelDownloaded
    case notSignedIn
    case unknown
}

public enum SoloEngineAvailability: Sendable, Equatable {
    case available
    case unavailable(SoloUnavailableReason)

    public var isAvailable: Bool { self == .available }

    public var reason: SoloUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Runtime probes. Every one is a measurement, never an assumption: the
/// explainer is only worth reading if it describes THIS device.
public enum SoloEngineProbe {

    /// Apple Foundation Models, as the UI asks it.
    ///
    /// `FoundationModelsProvider.availability` is the one implementation — it
    /// has to be `nonisolated` because the generation path checks it off the
    /// main actor — and this is the MainActor-bound alias the screens call, so
    /// there is exactly one probe and it is never cached: Apple Intelligence
    /// can be switched on, and the system model can finish downloading, between
    /// one visit to the explainer and the next.
    @MainActor
    public static func foundationModels() -> SoloEngineAvailability {
        FoundationModelsProvider.availability
    }

    @MainActor
    public static func mlx() -> SoloEngineAvailability {
        guard let host = SoloToolHost.shared.modelHost else { return .unavailable(.notBuilt) }
        return host.downloadedModelIDs.isEmpty ? .unavailable(.noModelDownloaded) : .available
    }

    public static func portal(isSignedIn: Bool) -> SoloEngineAvailability {
        isSignedIn ? .available : .unavailable(.notSignedIn)
    }
}

// MARK: - Device profile

/// What this device can actually do, measured rather than branded. Feeds the
/// explainer's "what it costs" column and the catalog's fit test.
public struct SoloDeviceProfile: Sendable, Equatable {
    public enum Tier: String, Sendable, Equatable {
        /// ≤4 GB — the 1.7B tier only.
        case compact
        /// 6 GB — a 3B fits.
        case standard
        /// ≥8 GB — a 4B fits, with the increased-memory entitlement.
        case pro
    }

    public var machine: String
    public var physicalMemoryBytes: UInt64
    public var processorCount: Int
    public var tier: Tier

    public init(machine: String, physicalMemoryBytes: UInt64, processorCount: Int, tier: Tier) {
        self.machine = machine
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.tier = tier
    }

    /// The measured sustained decode band for a 3–4B 4-bit model on phone-class
    /// silicon (.research/profiles-runtime.md §8.4: "sustained 10-30 tok/s
    /// decode drains and throttles"). ONE band, not a per-device guess: the
    /// research measured a range, and inventing sub-bands from it would be
    /// exactly the overclaiming the explainer exists to prevent.
    public static let decodeTokensPerSecond = 10...30

    public static let current: SoloDeviceProfile = {
        let memory = ProcessInfo.processInfo.physicalMemory
        let tier: Tier = if memory >= 7_500_000_000 { .pro }
            else if memory >= 5_500_000_000 { .standard }
            else { .compact }
        return SoloDeviceProfile(machine: machineIdentifier(),
                                 physicalMemoryBytes: memory,
                                 processorCount: ProcessInfo.processInfo.processorCount,
                                 tier: tier)
    }()

    private static func machineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

// MARK: - Model catalog

/// The curated MLX roster, all 4-bit `mlx-community` conversions. Every figure
/// is the measured one from docs/LOCAL-INFERENCE.md — data for the management
/// screen, not themed copy.
public struct SoloModelSpec: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var downloadBytes: Int64
    public var peakMemoryBytes: Int64
    public var minimumDeviceMemoryBytes: UInt64
    /// The 4B tier needs `com.apple.developer.kernel.increased-memory-limit`.
    public var needsIncreasedMemoryLimit: Bool

    public init(id: String, name: String, downloadBytes: Int64, peakMemoryBytes: Int64,
                minimumDeviceMemoryBytes: UInt64, needsIncreasedMemoryLimit: Bool) {
        self.id = id
        self.name = name
        self.downloadBytes = downloadBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.minimumDeviceMemoryBytes = minimumDeviceMemoryBytes
        self.needsIncreasedMemoryLimit = needsIncreasedMemoryLimit
    }

    public func fits(_ profile: SoloDeviceProfile = .current) -> Bool {
        profile.physicalMemoryBytes >= minimumDeviceMemoryBytes
    }
}

public enum SoloModelCatalog {
    public static let all: [SoloModelSpec] = [
        SoloModelSpec(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B",
                      downloadBytes: 1_000_000_000, peakMemoryBytes: 1_600_000_000,
                      minimumDeviceMemoryBytes: 3_500_000_000, needsIncreasedMemoryLimit: false),
        SoloModelSpec(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B",
                      downloadBytes: 1_800_000_000, peakMemoryBytes: 2_600_000_000,
                      minimumDeviceMemoryBytes: 5_500_000_000, needsIncreasedMemoryLimit: false),
        SoloModelSpec(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B",
                      downloadBytes: 2_300_000_000, peakMemoryBytes: 3_400_000_000,
                      minimumDeviceMemoryBytes: 7_500_000_000, needsIncreasedMemoryLimit: true),
    ]

    public static func spec(_ id: String) -> SoloModelSpec? { all.first { $0.id == id } }
}

// MARK: - Schema & argument helpers

/// JSON Schema fragments. Kept flat and scalar on purpose: the schema is
/// re-expressed as a `GenerationSchema` for Foundation Models and as a line of
/// prose for text-protocol backends, and nested objects survive neither well on
/// a model this size.
public enum SoloSchema {
    public static func object(_ properties: [String: JSONValue],
                              required: [String] = []) -> JSONValue {
        .object(["type": .string("object"),
                 "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string))])
    }

    public static func string(_ description: String, options: [String]? = nil) -> JSONValue {
        var node: [String: JSONValue] = ["type": .string("string"),
                                         "description": .string(description)]
        if let options { node["enum"] = .array(options.map(JSONValue.string)) }
        return .object(node)
    }

    public static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    public static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
}

private extension JSONValue {
    /// Small models hand arguments back as a JSON *string* often enough that
    /// refusing them would be a self-inflicted failure mode
    /// (.research/profiles-runtime.md §8.4: "validate JSON tool calls
    /// defensively"). Parse it, then carry on as normal.
    var normalizedArguments: JSONValue {
        if case .string(let raw) = self,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return parsed
        }
        return self
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw SoloToolError.badArguments("\"\(key)\" is required and must be a non-empty string")
        }
        return value
    }

    func text(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Numbers arrive as strings from small models just as often as arguments do.
    func number(_ key: String) -> Int? {
        if let value = self[key]?.intValue { return value }
        if let raw = self[key]?.stringValue { return Int(raw.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func flag(_ key: String) -> Bool? {
        if let value = self[key]?.boolValue { return value }
        if let raw = self[key]?.stringValue { return Bool(raw.lowercased()) }
        return nil
    }
}

/// ISO-8601 first, then a plain date. Anything else is refused rather than
/// guessed: an appointment on the wrong day is worse than a refusal.
public enum SoloDates {
    public static func parse(_ raw: String) -> Date? {
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: raw) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    public static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Files

public struct SoloFilesListTool: SoloGatedTool {
    /// Folder names as they stand right now, so the description advertises what
    /// the person has actually granted.
    public let folders: [String]

    public init(folders: [String]) { self.folders = folders }

    public var permission: SoloPermission { .files }
    public var effect: SoloToolEffect { .read }
    public var name: String { "files_list" }

    public var description: String {
        "List the files in one of Solo's folders (\(folders.joined(separator: ", "))). "
            + "Paths are folder-first, like \"\(folders.first ?? "workspace")/notes\"."
    }

    public var parameters: JSONValue {
        SoloSchema.object(["path": SoloSchema.string(
            "Folder to list, folder-first. Omit for the workspace root.")])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read a folder",
                          target: arguments.text("path") ?? SoloFileScopes.workspaceName,
                          why: "Solo wants to see what is in this folder.",
                          scopeKey: "files:list")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let raw = arguments.text("path") ?? SoloFileScopes.workspaceName
        guard let resolved = await SoloPath.resolve(raw) else {
            throw SoloToolError.notAuthorized("\(raw) is not inside a folder Solo was granted")
        }
        defer { resolved.release() }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: resolved.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw SoloToolError.failed("\(raw) is not a readable folder")
        }
        let rows = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { return "\(url.lastPathComponent)/" }
                return "\(url.lastPathComponent)  \(values?.fileSize ?? 0) bytes"
            }
        return SoloToolResult(text: rows.isEmpty ? "\(raw) is empty."
                                                 : "\(raw)\n" + rows.joined(separator: "\n"),
                              summary: "\(rows.count) item\(rows.count == 1 ? "" : "s") in \(raw)")
    }
}

public struct SoloFilesReadTool: SoloGatedTool {
    public let folders: [String]

    /// Solo's context is small; a whole file is usually the wrong unit.
    static let characterCeiling = 12_000

    public init(folders: [String]) { self.folders = folders }

    public var permission: SoloPermission { .files }
    public var effect: SoloToolEffect { .read }
    public var name: String { "files_read" }

    public var description: String {
        "Read a UTF-8 text file from one of Solo's folders "
            + "(\(folders.joined(separator: ", "))). Returns at most "
            + "\(Self.characterCeiling) characters."
    }

    public var parameters: JSONValue {
        SoloSchema.object(["path": SoloSchema.string("File to read, folder-first.")],
                          required: ["path"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read a file",
                          target: arguments.text("path") ?? "?",
                          why: "Solo wants to read this file.", scopeKey: "files:read")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let raw = try arguments.requiredString("path")
        guard let resolved = await SoloPath.resolve(raw) else {
            throw SoloToolError.notAuthorized("\(raw) is not inside a folder Solo was granted")
        }
        defer { resolved.release() }

        guard let data = try? Data(contentsOf: resolved.url) else {
            throw SoloToolError.failed("\(raw) could not be read")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SoloToolError.failed("\(raw) is not UTF-8 text (\(data.count) bytes)")
        }
        let clipped = text.count > Self.characterCeiling
        return SoloToolResult(
            text: clipped ? String(text.prefix(Self.characterCeiling))
                    + "\n\n[truncated at \(Self.characterCeiling) characters]"
                : text,
            summary: "read \(raw) · \(data.count) bytes")
    }
}

public struct SoloFilesWriteTool: SoloGatedTool {
    public let folders: [String]

    public init(folders: [String]) { self.folders = folders }

    public var permission: SoloPermission { .files }
    public var effect: SoloToolEffect { .write }
    public var name: String { "files_write" }

    public var description: String {
        "Write or append UTF-8 text to a file in one of Solo's folders "
            + "(\(folders.joined(separator: ", "))). Creates the file if missing."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "path": SoloSchema.string("File to write, folder-first."),
            "content": SoloSchema.string("The text to write."),
            "mode": SoloSchema.string("replace (default) or append.",
                                      options: ["replace", "append"]),
        ], required: ["path", "content"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        let path = arguments.text("path") ?? "?"
        let content = arguments["content"]?.stringValue ?? ""
        let append = (arguments.text("mode") ?? "replace").lowercased() == "append"
        return SoloApprovalDraft(
            toolName: name,
            title: append ? "Append to a file" : "Write a file",
            target: path,
            subject: "\(content.count) character\(content.count == 1 ? "" : "s")",
            body: String(content.prefix(600)),
            why: "Solo wants to \(append ? "add to" : "overwrite") this file.",
            // Per-file: "always" on one note must not become "always" on every
            // file Solo can reach.
            scopeKey: "files:write:\(path)")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let raw = try arguments.requiredString("path")
        let content = arguments["content"]?.stringValue ?? ""
        let append = (arguments.text("mode") ?? "replace").lowercased() == "append"

        guard let resolved = await SoloPath.resolve(raw) else {
            throw SoloToolError.notAuthorized("\(raw) is not inside a folder Solo was granted")
        }
        defer { resolved.release() }
        SoloStore.ensure(resolved.url.deletingLastPathComponent())

        do {
            if append, let existing = try? String(contentsOf: resolved.url, encoding: .utf8) {
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                try (existing + separator + content).write(to: resolved.url, atomically: true,
                                                           encoding: .utf8)
            } else {
                try content.write(to: resolved.url, atomically: true, encoding: .utf8)
            }
        } catch {
            throw SoloToolError.failed("could not write \(raw): \(error.localizedDescription)")
        }
        return SoloToolResult(text: "Wrote \(content.count) characters to \(raw).",
                              summary: "\(append ? "appended to" : "wrote") \(raw)")
    }
}

// MARK: - Web

/// Fetch one URL and hand back its readable text.
///
/// Three rules the code enforces rather than trusting the model with:
///   · http/https only — no `file:`, no `data:`, nothing that could reach the
///     sandbox through a scheme;
///   · a byte ceiling applied WHILE streaming, so an enormous or hostile
///     response cannot exhaust memory on a phone;
///   · redirects that change host are not followed. The person approved a host,
///     not a chain, and a 302 is the cheapest way to turn one grant into another.
public struct SoloWebFetchTool: SoloGatedTool {
    static let byteCeiling = 3 * 1024 * 1024
    static let characterCeiling = 8_000

    public init() {}

    public var permission: SoloPermission { .web }
    public var effect: SoloToolEffect { .leaves }
    public var name: String { "web_fetch" }

    public var description: String {
        "Fetch a web page over HTTP(S) and return its readable text with the markup removed."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "url": SoloSchema.string("Full http:// or https:// URL."),
            "max_characters": SoloSchema.integer(
                "Cap on the text returned; defaults to \(Self.characterCeiling)."),
        ], required: ["url"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        let raw = arguments.text("url") ?? "?"
        let host = URL(string: raw)?.host ?? raw
        return SoloApprovalDraft(
            toolName: name, title: "Fetch a web page", target: raw, subject: host,
            why: "Solo wants to request this page. The request leaves this device.",
            // Per-host: the grant a person means when they say "yes, that site".
            scopeKey: "web:\(host.lowercased())")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let raw = try arguments.requiredString("url")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw SoloToolError.badArguments("\(raw) is not an http:// or https:// URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Talaria-Solo/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let redirectGuard = SoloSameHostRedirectGuard(host: host)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch {
            throw SoloToolError.failed("could not reach \(host): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw SoloToolError.failed("\(host) answered HTTP \(http.statusCode)")
        }
        // A declared length over the ceiling is refused before a byte is read:
        // `AsyncBytes` iterates one byte at a time, which is what keeps a
        // hostile response from being buffered whole, but it is not free — so
        // the honest big file is rejected up front and only the ones that lie
        // about their size (or decline to say) pay for the streaming cap.
        if response.expectedContentLength > Int64(Self.byteCeiling) {
            throw SoloToolError.failed(
                "\(host) offered \(response.expectedContentLength) bytes, which is too large to read")
        }

        var data = Data()
        data.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Self.byteCeiling { break }
            }
        } catch {
            guard !data.isEmpty else {
                throw SoloToolError.failed("the response from \(host) was cut short")
            }
        }

        let mime = (response.mimeType ?? "").lowercased()
        guard mime.isEmpty || mime.hasPrefix("text/") || mime.contains("json")
                || mime.contains("xml") || mime.contains("html") else {
            throw SoloToolError.failed("\(host) returned \(mime), which is not readable text")
        }
        guard let source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw SoloToolError.failed("\(host) returned bytes that are not text")
        }

        let readable = (mime.contains("html") || mime.isEmpty)
            ? SoloReadableText.extract(from: source)
            : SoloReadableText.tidy(source)
        let ceiling = arguments.number("max_characters").map { max(200, min($0, 20_000)) }
            ?? Self.characterCeiling

        var text = url.absoluteString + "\n\n"
        text += readable.count > ceiling ? String(readable.prefix(ceiling)) + "\n\n[truncated]"
                                         : readable
        if let blocked = redirectGuard.blockedHost {
            text += "\n\n[a redirect to \(blocked) was not followed — only \(host) was approved]"
        }
        return SoloToolResult(text: text, summary: "fetched \(host) · \(readable.count) chars")
    }
}

/// Refuses cross-host redirects. Handing nil to the completion handler tells
/// URLSession to deliver the redirect response itself instead of following it.
final class SoloSameHostRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private(set) var blockedHost: String?

    init(host: String) {
        self.host = host.lowercased()
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url?.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        if target == host || target.hasSuffix("." + host) {
            completionHandler(request)
        } else {
            blockedHost = target
            completionHandler(nil)
        }
    }
}

/// HTML → the text a person would have read. Deliberately rules-and-regex
/// rather than a parser: the budget for this is a few milliseconds on a phone,
/// and the failure mode of over-stripping is a shorter answer, not a wrong one.
public enum SoloReadableText {

    public static func extract(from html: String) -> String {
        var text = html

        let title = firstMatch(in: text, pattern: "<title[^>]*>(.*?)</title>")
        text = strip(text, pattern: "<!--.*?-->")
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer", "form"] {
            text = strip(text, pattern: "<\(tag)[^>]*>.*?</\(tag)>")
        }

        // Prefer the article body when the page marks one and it is substantial;
        // otherwise the surrounding chrome is the smaller evil.
        for container in ["article", "main"] {
            if let inner = firstMatch(in: text, pattern: "<\(container)[^>]*>(.*?)</\(container)>"),
               inner.count > 400 {
                text = inner
                break
            }
        }

        text = replace(text, pattern: "<li[^>]*>", with: "\n- ")
        text = replace(text, pattern: "<br[^>]*>", with: "\n")
        text = replace(text, pattern: "<h[1-6][^>]*>", with: "\n\n")
        text = replace(text, pattern: "</(p|div|section|h[1-6]|tr|ul|ol|li|blockquote)>", with: "\n")
        text = strip(text, pattern: "<[^>]+>")
        text = decodeEntities(text)
        text = tidy(text)

        let heading = decodeEntities(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty, !text.hasPrefix(heading) {
            text = "\(heading)\n\n\(text)"
        }
        return text
    }

    /// Whitespace normalisation, shared by the HTML and plain-text paths.
    public static func tidy(_ input: String) -> String {
        let lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        var out: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks > 1 { continue }
            } else {
                blanks = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One pass, never two.
    ///
    /// Decoding entity by entity in a loop cascades: `&amp;lt;` becomes `&lt;`
    /// on the `&amp;` pass and then `<` on the `&lt;` pass, so text a page
    /// deliberately escaped comes back out as markup — and because the table is
    /// a dictionary, whether that happened depended on hash order, which is the
    /// worst kind of bug to own. A single regex sweep replaces each match from
    /// the original string exactly once.
    public static func decodeEntities(_ input: String) -> String {
        replaceMatches(input, pattern: "&(#[Xx][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);") { body in
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map(String.init)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
            }
            return named[body.lowercased()]
        }
    }

    /// The entities that actually turn up in article text. An unknown one is
    /// left exactly as written rather than guessed at or eaten.
    private static let named: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "deg": "\u{00B0}", "euro": "\u{20AC}", "pound": "\u{00A3}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "times": "\u{00D7}", "hyphen": "-",
    ]

    // MARK: Regex plumbing

    private static let options: NSRegularExpression.Options =
        [.caseInsensitive, .dotMatchesLineSeparators]

    private static func strip(_ input: String, pattern: String) -> String {
        replace(input, pattern: pattern, with: " ")
    }

    private static func replace(_ input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        return regex.stringByReplacingMatches(in: input, options: [],
                                              range: NSRange(input.startIndex..., in: input),
                                              withTemplate: template)
    }

    private static func firstMatch(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: input, options: [],
                                           range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }

    private static func replaceMatches(_ input: String, pattern: String,
                                       transform: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        var output = input
        let matches = regex.matches(in: input, options: [],
                                    range: NSRange(input.startIndex..., in: input))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let whole = Range(match.range, in: input),
                  let body = Range(match.range(at: 1), in: input),
                  let replacement = transform(String(input[body])) else { continue }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }
}

// MARK: - Calendar & reminders

#if canImport(EventKit)

/// The Info.plist strings EventKit requires. Asking without them terminates the
/// process, so both families check first and report themselves unavailable — a
/// crash is not a degradation path.
public enum SoloEventKitGate {
    public static let calendarKey = "NSCalendarsFullAccessUsageDescription"
    public static let remindersKey = "NSRemindersFullAccessUsageDescription"

    public static func hasUsageDescription(_ key: String) -> Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return !(value ?? "").isEmpty
    }

    /// Whether this build could even raise the OS prompt for a permission.
    public static func canAsk(for permission: SoloPermission) -> Bool {
        switch permission {
        case .calendar: hasUsageDescription(calendarKey)
        case .reminders: hasUsageDescription(remindersKey)
        default: true
        }
    }

    /// What system settings say right now, without asking.
    public static func isGranted(_ permission: SoloPermission) -> Bool {
        let entity: EKEntityType = permission == .reminders ? .reminder : .event
        return EKEventStore.authorizationStatus(for: entity) == .fullAccess
    }

    static func store(for entity: EKEntityType) async throws -> EKEventStore {
        let key = entity == .event ? calendarKey : remindersKey
        guard hasUsageDescription(key) else {
            throw SoloToolError.unavailable(
                "this build of Talaria carries no \(key), so it cannot ask for access")
        }
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = entity == .event ? try await store.requestFullAccessToEvents()
                                       : try await store.requestFullAccessToReminders()
        } catch {
            throw SoloToolError.notAuthorized(error.localizedDescription)
        }
        guard granted else {
            throw SoloToolError.notAuthorized(
                entity == .event ? "calendar access was refused in system settings"
                                 : "reminders access was refused in system settings")
        }
        return store
    }
}

public struct SoloCalendarEventsTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .calendar }
    public var effect: SoloToolEffect { .read }
    public var name: String { "calendar_events" }

    public var description: String {
        "List calendar events in a window of days around today. Use this before answering "
            + "anything about the person's schedule."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "days": SoloSchema.integer("Days ahead to look. Default 7, maximum 90."),
            "days_back": SoloSchema.integer("Days back to include. Default 0."),
        ])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read the calendar",
                          target: "your calendar, the next \(arguments.number("days") ?? 7) days",
                          why: "Solo wants to read your events for this window.",
                          scopeKey: "calendar:read")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let ahead = min(max(arguments.number("days") ?? 7, 1), 90)
        let back = min(max(arguments.number("days_back") ?? 0, 0), 90)
        let store = try await SoloEventKitGate.store(for: .event)

        let predicate = store.predicateForEvents(
            withStart: Date().addingTimeInterval(-Double(back) * 86_400),
            end: Date().addingTimeInterval(Double(ahead) * 86_400), calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        guard !events.isEmpty else {
            return SoloToolResult(text: "No events in that window.", summary: "no events")
        }
        let rows = events.prefix(80).map { event -> String in
            let start = event.startDate ?? Date()
            let when = event.isAllDay
                ? "\(SoloDates.describe(start).prefix(10)) (all day)"
                : "\(SoloDates.describe(start))\u{2013}"
                    + "\(SoloDates.describe(event.endDate ?? start).suffix(5))"
            let place = (event.location?.isEmpty == false) ? " @ \(event.location!)" : ""
            return "\(when)  \(event.title ?? "(no title)")\(place)"
        }
        return SoloToolResult(text: rows.joined(separator: "\n"),
                              summary: "\(events.count) event\(events.count == 1 ? "" : "s")")
    }
}

public struct SoloCalendarAddEventTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .calendar }
    public var effect: SoloToolEffect { .write }
    public var name: String { "calendar_add_event" }

    public var description: String {
        "Create a calendar event. Times are ISO-8601 (2026-08-18T14:30) in the device's timezone."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "title": SoloSchema.string("Event title."),
            "start": SoloSchema.string("Start time, ISO-8601."),
            "end": SoloSchema.string("End time, ISO-8601. Omit for a one-hour event."),
            "notes": SoloSchema.string("Optional notes."),
            "location": SoloSchema.string("Optional location."),
        ], required: ["title", "start"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(
            toolName: name, title: "Add a calendar event",
            target: "your calendar",
            subject: "\(arguments.text("title") ?? "?") \u{00B7} \(arguments.text("start") ?? "?")"
                + (arguments.text("location").map { " \u{00B7} \($0)" } ?? ""),
            body: arguments.text("notes") ?? "",
            why: "Solo wants to put this in your calendar.", scopeKey: "calendar:write")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let title = try arguments.requiredString("title")
        let startRaw = try arguments.requiredString("start")
        guard let start = SoloDates.parse(startRaw) else {
            throw SoloToolError.badArguments("\"start\" (\(startRaw)) is not an ISO-8601 time")
        }
        let end = arguments.text("end").flatMap(SoloDates.parse) ?? start.addingTimeInterval(3600)

        let store = try await SoloEventKitGate.store(for: .event)
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw SoloToolError.failed("this device has no default calendar for new events")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = arguments.text("notes")
        event.location = arguments.text("location")
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw SoloToolError.failed("could not save the event: \(error.localizedDescription)")
        }
        return SoloToolResult(text: "Created \"\(title)\" on \(SoloDates.describe(start)).",
                              summary: "added \(title)")
    }
}

public struct SoloRemindersListTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .reminders }
    public var effect: SoloToolEffect { .read }
    public var name: String { "reminders_list" }

    public var description: String {
        "List the person's reminders. Incomplete ones unless asked otherwise."
    }

    public var parameters: JSONValue {
        SoloSchema.object(["include_completed":
            SoloSchema.boolean("Include reminders already ticked off. Default false.")])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read reminders", target: "your reminders",
                          why: "Solo wants to read your reminders.", scopeKey: "reminders:read")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let includeCompleted = arguments.flag("include_completed") ?? false
        let store = try await SoloEventKitGate.store(for: .reminder)
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                    calendars: nil)

        // EventKit's reminder fetch is callback-only; the rows are flattened to
        // strings inside the callback so nothing non-Sendable crosses out.
        let rows: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).prefix(100).map { reminder -> String in
                    let due = reminder.dueDateComponents
                        .flatMap(Calendar.current.date(from:))
                        .map { " \u{00B7} due \(SoloDates.describe($0))" } ?? ""
                    let done = reminder.isCompleted ? " \u{2713}" : ""
                    return "- \(reminder.title ?? "(untitled)")\(due)\(done)"
                }
                continuation.resume(returning: Array(lines))
            }
        }
        return SoloToolResult(text: rows.isEmpty ? "No reminders." : rows.joined(separator: "\n"),
                              summary: "\(rows.count) reminder\(rows.count == 1 ? "" : "s")")
    }
}

public struct SoloRemindersAddTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .reminders }
    public var effect: SoloToolEffect { .write }
    public var name: String { "reminders_add" }

    public var description: String { "Create a reminder, optionally with a due time." }

    public var parameters: JSONValue {
        SoloSchema.object([
            "title": SoloSchema.string("What to be reminded of."),
            "due": SoloSchema.string("Optional due time, ISO-8601."),
            "notes": SoloSchema.string("Optional notes."),
        ], required: ["title"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        let due = arguments.text("due").map { " \u{00B7} due \($0)" } ?? ""
        return SoloApprovalDraft(toolName: name, title: "Add a reminder",
                                 target: "your reminders",
                                 subject: "\(arguments.text("title") ?? "?")\(due)",
                                 body: arguments.text("notes") ?? "",
                                 why: "Solo wants to add this to your reminders.",
                                 scopeKey: "reminders:write")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let title = try arguments.requiredString("title")
        let store = try await SoloEventKitGate.store(for: .reminder)
        guard let list = store.defaultCalendarForNewReminders() else {
            throw SoloToolError.failed("this device has no default reminders list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = arguments.text("notes")
        reminder.calendar = list
        if let due = arguments.text("due").flatMap(SoloDates.parse) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw SoloToolError.failed("could not save the reminder: \(error.localizedDescription)")
        }
        return SoloToolResult(text: "Added reminder \"\(title)\".", summary: "added \(title)")
    }
}

#endif

// MARK: - Photos

public struct SoloPhotosListTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .photos }
    public var effect: SoloToolEffect { .read }
    public var name: String { "photos_list" }

    public var description: String {
        "List the images the person shared with Solo. Solo cannot see the photo library — "
            + "only these."
    }

    public var parameters: JSONValue { SoloSchema.object([:]) }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "List shared images",
                          target: "the images you shared",
                          why: "Solo wants to see which images you shared with it.",
                          scopeKey: "photos:list")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let items = await SoloPhotoShelf.shared.items
        guard !items.isEmpty else {
            return SoloToolResult(text: "No images have been shared with Solo.",
                                  summary: "no images")
        }
        let rows = items.map { item in
            "\(item.name)  \(item.pixelWidth)\u{00D7}\(item.pixelHeight)  "
                + "added \(SoloDates.describe(item.addedAt))"
        }
        return SoloToolResult(text: rows.joined(separator: "\n"),
                              summary: "\(items.count) image\(items.count == 1 ? "" : "s")")
    }
}

#if canImport(Vision)

/// Read the text inside a shared image, on-device, with Vision.
///
/// Deliberately OCR and not "describe this picture". Talaria's inference seam is
/// text-only — `InferenceMessage` is `{role, content}` — so no engine in this
/// app can be handed an image today, and a tool that promised otherwise would be
/// a promise the stack cannot keep. Recognising the text in a receipt, a
/// whiteboard or a screenshot is something the phone genuinely does well,
/// entirely offline, with no model of ours involved at all.
public struct SoloPhotosReadTextTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .photos }
    public var effect: SoloToolEffect { .read }
    public var name: String { "photos_read_text" }

    public var description: String {
        "Read the text inside one of the shared images. Name it exactly as photos_list gave it. "
            + "Returns text only, not a description of the picture."
    }

    public var parameters: JSONValue {
        SoloSchema.object(["name": SoloSchema.string("The image's name from photos_list.")],
                          required: ["name"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read text in an image",
                          target: arguments.text("name") ?? "?",
                          why: "Solo wants to read the words in this image.",
                          scopeKey: "photos:read")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let wanted = try arguments.requiredString("name")
        let found: (name: String, url: URL)? = await MainActor.run {
            let shelf = SoloPhotoShelf.shared
            let items = shelf.items
            guard let item = items.first(where: {
                $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
            }) ?? items.first(where: { $0.id == wanted }) else { return nil }
            return (item.name, shelf.url(for: item))
        }
        guard let item = found else {
            throw SoloToolError.badArguments("no shared image is called \"\(wanted)\"")
        }
        guard let data = try? Data(contentsOf: item.url) else {
            throw SoloToolError.failed("\(item.name) could not be read from Solo's storage")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(data: data, options: [:]).perform([request])
        } catch {
            throw SoloToolError.failed("could not read \(item.name): \(error.localizedDescription)")
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else {
            return SoloToolResult(text: "\(item.name) contains no readable text.",
                                  summary: "no text in \(item.name)")
        }
        return SoloToolResult(text: "Text in \(item.name):\n" + lines.joined(separator: "\n"),
                              summary: "\(lines.count) line\(lines.count == 1 ? "" : "s") from \(item.name)")
    }
}

#endif

// MARK: - Shortcuts

public struct SoloShortcutsListTool: SoloGatedTool {
    public let shortcuts: [String]

    public init(shortcuts: [String]) { self.shortcuts = shortcuts }

    public var permission: SoloPermission { .shortcuts }
    public var effect: SoloToolEffect { .read }
    public var name: String { "shortcuts_list" }

    public var description: String {
        "List the shortcuts the person allowed Solo to run. Only these can be run."
    }

    public var parameters: JSONValue { SoloSchema.object([:]) }

    /// Reading back a list the person themselves typed into Solo settings is not
    /// a question worth asking, whatever the policy says: there is nothing on
    /// the other side of the gate.
    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? { nil }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        guard !shortcuts.isEmpty else {
            return SoloToolResult(
                text: "No shortcuts have been allowed yet. The person adds them in Solo settings.",
                summary: "none allowed")
        }
        return SoloToolResult(text: shortcuts.map { "- \($0)" }.joined(separator: "\n"),
                              summary: "\(shortcuts.count) shortcut\(shortcuts.count == 1 ? "" : "s")")
    }
}

/// Run a named shortcut — the honest iOS analogue of a shell.
///
/// Mechanics worth stating, because they are unlike every other tool here:
/// running a shortcut opens the Shortcuts app, so Talaria goes to the background
/// and the Solo turn is suspended until the person comes back. The
/// x-callback-url form is used so the shortcut's output can return to
/// `talaria://solo/shortcut`; a shortcut that ends without a value returns
/// nothing at all, and "it ran and said nothing" is reported as exactly that
/// rather than as a failure.
public struct SoloShortcutsRunTool: SoloGatedTool {
    public let shortcuts: [String]

    static let callbackTimeout = Duration.seconds(180)

    public init(shortcuts: [String]) { self.shortcuts = shortcuts }

    public var permission: SoloPermission { .shortcuts }
    public var effect: SoloToolEffect { .leaves }
    public var name: String { "shortcuts_run" }

    public var description: String {
        "Run one of the person's shortcuts by name"
            + (shortcuts.isEmpty ? "" : " (\(shortcuts.joined(separator: ", ")))")
            + ". This leaves Talaria and opens the Shortcuts app."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "name": SoloSchema.string("Exact shortcut name, as given by shortcuts_list."),
            "input": SoloSchema.string("Optional text passed to the shortcut as its input."),
        ], required: ["name"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        let wanted = arguments.text("name") ?? "?"
        let input = arguments.text("input")
        return SoloApprovalDraft(
            toolName: name, kind: .command, title: "Run a shortcut",
            target: "\u{201C}\(wanted)\u{201D} in Shortcuts",
            subject: input ?? "", body: input ?? "",
            why: "Solo wants to run this shortcut. Talaria will switch to the Shortcuts app.",
            // Per-shortcut. "Always run anything" is not a thing a person means.
            scopeKey: "shortcuts:run:\(wanted.lowercased())")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let wanted = try arguments.requiredString("name")
        guard let canonical = await SoloShortcutBook.shared.canonical(wanted) else {
            throw SoloToolError.notAuthorized(
                "\"\(wanted)\" is not one of the shortcuts allowed in Solo settings")
        }
        guard let opener = await SoloToolHost.shared.openURL else {
            throw SoloToolError.unavailable("this build cannot open the Shortcuts app")
        }
        let token = UUID().uuidString
        guard let url = Self.callbackURL(shortcut: canonical, input: arguments.text("input"),
                                         token: token) else {
            throw SoloToolError.failed("could not build the Shortcuts URL for \"\(canonical)\"")
        }

        // The waiter is registered BEFORE the open: a fast shortcut can call
        // back before the opener's await has even returned.
        let host = await MainActor.run { SoloToolHost.shared }
        async let outcome = host.awaitShortcut(token: token, timeout: Self.callbackTimeout)
        guard await opener(url) else {
            // Release the waiter, or the turn parks for the full timeout on a
            // shortcut that never started.
            await MainActor.run { _ = host.deliver(Self.cancelURL(token: token)) }
            _ = await outcome
            throw SoloToolError.failed("the Shortcuts app would not open")
        }

        switch await outcome {
        case .finished(let result) where !result.isEmpty:
            return SoloToolResult(text: "\(canonical) finished and returned:\n\(result)",
                                  summary: "ran \(canonical)")
        case .finished:
            return SoloToolResult(text: "\(canonical) finished. It returned no output.",
                                  summary: "ran \(canonical)")
        case .failed(let message):
            throw SoloToolError.failed("\(canonical) reported: \(message)")
        case .noCallback:
            return SoloToolResult(
                text: "\(canonical) was launched but did not report back — either it is still "
                    + "running, or it ends without a value. Ask the person what happened rather "
                    + "than running it again.",
                summary: "launched \(canonical)")
        }
    }

    /// `shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…` with
    /// the success/error hooks pointing at Talaria's own registered scheme
    /// (`talaria`, ios/Talaria/Support/Info.plist:26-29).
    ///
    /// Public because it *is* the contract the app's URL router has to honour:
    /// whoever wires `SoloToolHost.deliver(_:)` needs to see the exact shape of
    /// the callback it will be handed.
    public static func callbackURL(shortcut: String, input: String?, token: String) -> URL? {
        var success = URLComponents()
        success.scheme = "talaria"
        success.host = "solo"
        success.path = "/shortcut"
        success.queryItems = [URLQueryItem(name: "token", value: token)]

        var failure = success
        failure.queryItems = [URLQueryItem(name: "token", value: token),
                              URLQueryItem(name: "error", value: "1")]

        guard let successURL = success.url, let failureURL = failure.url else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        var items = [URLQueryItem(name: "name", value: shortcut)]
        if let input, !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        items.append(URLQueryItem(name: "x-success", value: successURL.absoluteString))
        items.append(URLQueryItem(name: "x-error", value: failureURL.absoluteString))
        components.queryItems = items
        return components.url
    }

    static func cancelURL(token: String) -> URL {
        var components = URLComponents()
        components.scheme = "talaria"
        components.host = "solo"
        components.path = "/shortcut"
        components.queryItems = [URLQueryItem(name: "token", value: token),
                                 URLQueryItem(name: "errorMessage", value: "not opened")]
        return components.url ?? URL(string: "talaria://solo/shortcut")!
    }
}

// MARK: - Memory & search

public struct SoloMemoryReadTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .memory }
    public var effect: SoloToolEffect { .read }
    public var name: String { "memory_read" }

    public var description: String {
        "Read Solo's memory notes — what you were told to remember across conversations."
    }

    public var parameters: JSONValue { SoloSchema.object([:]) }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Read memory", target: "Solo\u{2019}s own notes",
                          why: "Solo wants to read its own notes.", scopeKey: "memory:read")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let text = SoloMemory.read()
        guard !text.isEmpty else {
            return SoloToolResult(text: "Memory is empty.", summary: "memory empty")
        }
        return SoloToolResult(text: text, summary: "read memory \u{00B7} \(text.count) chars")
    }
}

public struct SoloMemoryWriteTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .memory }
    public var effect: SoloToolEffect { .write }
    public var name: String { "memory_write" }

    public var description: String {
        "Add to Solo's memory notes, or replace them. Keep entries short and factual."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "content": SoloSchema.string("What to remember."),
            "mode": SoloSchema.string("append (default) or replace.",
                                      options: ["append", "replace"]),
        ], required: ["content"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        let content = arguments["content"]?.stringValue ?? ""
        let replacing = (arguments.text("mode") ?? "append").lowercased() == "replace"
        return SoloApprovalDraft(
            toolName: name, title: replacing ? "Replace memory" : "Remember this",
            target: "Solo\u{2019}s own notes",
            subject: "\(content.count) character\(content.count == 1 ? "" : "s")",
            body: String(content.prefix(600)),
            why: replacing ? "Solo wants to overwrite everything it remembers."
                           : "Solo wants to add this to its notes.",
            scopeKey: replacing ? "memory:replace" : "memory:append")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let content = try arguments.requiredString("content")
        let replacing = (arguments.text("mode") ?? "append").lowercased() == "replace"
        do {
            if replacing { try SoloMemory.write(content) } else { try SoloMemory.append(content) }
        } catch {
            throw SoloToolError.failed("could not write memory: \(error.localizedDescription)")
        }
        return SoloToolResult(text: replacing ? "Memory replaced." : "Noted.",
                              summary: replacing ? "replaced memory" : "remembered")
    }
}

public struct SoloSessionSearchTool: SoloGatedTool {
    public init() {}

    public var permission: SoloPermission { .memory }
    public var effect: SoloToolEffect { .read }
    public var name: String { "sessions_search" }

    public var description: String {
        "Search everything said in previous Solo conversations on this device."
    }

    public var parameters: JSONValue {
        SoloSchema.object([
            "query": SoloSchema.string("Words to look for."),
            "limit": SoloSchema.integer("How many results. Default 8, maximum 25."),
        ], required: ["query"])
    }

    public func approval(for arguments: JSONValue) -> SoloApprovalDraft? {
        SoloApprovalDraft(toolName: name, title: "Search past conversations",
                          target: "\u{201C}\(arguments.text("query") ?? "?")\u{201D} in past conversations",
                          why: "Solo wants to search its own transcripts on this device.",
                          scopeKey: "memory:search")
    }

    public func invoke(_ arguments: JSONValue) async throws -> SoloToolResult {
        let query = try arguments.requiredString("query")
        let limit = min(max(arguments.number("limit") ?? 8, 1), 25)
        let hits = await SoloSessionArchive.shared.search(query, limit: limit)
        guard !hits.isEmpty else {
            return SoloToolResult(text: "Nothing in past conversations matches \"\(query)\".",
                                  summary: "no matches")
        }
        let rows = hits.map { hit in
            "[\(SoloDates.describe(hit.at))] \(hit.title.isEmpty ? hit.sessionID : hit.title)"
                + " \u{00B7} \(hit.role)\n\(hit.snippet)"
        }
        return SoloToolResult(text: rows.joined(separator: "\n\n"),
                              summary: "\(hits.count) match\(hits.count == 1 ? "" : "es")")
    }
}

// MARK: - The registry

/// The one door. Every call goes through `run`, which applies both gates in
/// order and only then reaches the tool — so there is no path by which a tool
/// runs without its permission, and none by which a change happens without the
/// approval the policy asked for.
///
/// The tool LIST is rebuilt on every read rather than cached, for two reasons
/// that both matter: a description can then name the folders and shortcuts that
/// exist right now, and a permission switched off mid-conversation stops being
/// offered on the very next turn.
@MainActor
public final class SoloToolRegistry {
    public static let shared = SoloToolRegistry()

    private let settings: SoloSettingsStore
    private let approvals: SoloApprovalCenter

    public init(settings: SoloSettingsStore? = nil, approvals: SoloApprovalCenter? = nil) {
        self.settings = settings ?? .shared
        self.approvals = approvals ?? .shared
    }

    /// The tools to hand the model this turn, filtered by the granted
    /// permissions. A model with two switches on sees two families of schemas
    /// rather than fifteen, which is the cheapest latency win Solo has.
    public func tools(visionCapable: Bool = false) -> [any SoloGatedTool] {
        let folders = SoloFileScopes.shared.names
        let shortcuts = SoloShortcutBook.shared.names

        var out: [any SoloGatedTool] = []
        for permission in settings.grantedPermissions {
            switch permission {
            case .files:
                out += [SoloFilesListTool(folders: folders),
                        SoloFilesReadTool(folders: folders),
                        SoloFilesWriteTool(folders: folders)]
            case .web:
                out.append(SoloWebFetchTool())
            case .calendar:
                #if canImport(EventKit)
                out += [SoloCalendarEventsTool(), SoloCalendarAddEventTool()]
                #endif
            case .reminders:
                #if canImport(EventKit)
                out += [SoloRemindersListTool(), SoloRemindersAddTool()]
                #endif
            case .photos:
                out.append(SoloPhotosListTool())
                #if canImport(Vision)
                out.append(SoloPhotosReadTextTool())
                #endif
            case .shortcuts:
                out += [SoloShortcutsListTool(shortcuts: shortcuts),
                        SoloShortcutsRunTool(shortcuts: shortcuts)]
            case .memory:
                out += [SoloMemoryReadTool(), SoloMemoryWriteTool(), SoloSessionSearchTool()]
            }
        }
        return out.filter { visionCapable || !$0.requiresVision }
    }

    public func tool(named name: String, visionCapable: Bool = false) -> (any SoloGatedTool)? {
        tools(visionCapable: visionCapable).first { $0.name == name }
    }

    /// Gate, then run, then throw. Callers that want a result to feed straight
    /// back to the model use `run` instead.
    public func invoke(name: String, arguments: JSONValue,
                       visionCapable: Bool = false) async throws -> SoloToolResult {
        guard let tool = tool(named: name, visionCapable: visionCapable) else {
            let offered = tools(visionCapable: visionCapable).map(\.name)
            throw SoloToolError.unavailable(
                "there is no tool called \"\(name)\". Available: "
                    + (offered.isEmpty ? "none" : offered.joined(separator: ", ")))
        }
        // Belt and braces: an ungranted permission cannot reach here, because
        // its tools are not in the list — but the check that matters is the one
        // next to the call, not the one that built the menu.
        guard settings.isEnabled(tool.permission) else {
            throw SoloToolError.permissionMissing(tool.permission)
        }

        let arguments = arguments.normalizedArguments
        if settings.askPolicy(for: tool.permission).requiresApproval(for: tool.effect),
           let draft = tool.approval(for: arguments) {
            let choice = await approvals.decide(draft)
            guard choice != .deny else {
                throw SoloToolError.denied(draft.title.lowercased())
            }
        }
        return try await tool.invoke(arguments)
    }

    /// Never throws: a refusal or a failure is something the model has to read
    /// and recover from, exactly as a gateway tool error is.
    public func run(name: String, arguments: JSONValue,
                    visionCapable: Bool = false) async -> SoloToolResult {
        do {
            return try await invoke(name: name, arguments: arguments,
                                    visionCapable: visionCapable)
        } catch let error as SoloToolError {
            return SoloToolResult(text: error.modelFacingText,
                                  summary: Self.summary(for: error), isError: true)
        } catch is CancellationError {
            return SoloToolResult(text: "The tool call was stopped.", summary: "stopped",
                                  isError: true)
        } catch {
            return SoloToolResult(text: "Failed: \(error.localizedDescription)",
                                  summary: "failed", isError: true)
        }
    }

    /// How many tools the model will actually be handed with the current
    /// switches — the number the settings screen shows.
    public func toolCount(visionCapable: Bool = false) -> Int {
        tools(visionCapable: visionCapable).count
    }

    private static func summary(for error: SoloToolError) -> String {
        switch error {
        case .denied: "declined"
        case .permissionMissing: "not permitted"
        case .notAuthorized: "not authorized"
        case .badArguments: "bad arguments"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}

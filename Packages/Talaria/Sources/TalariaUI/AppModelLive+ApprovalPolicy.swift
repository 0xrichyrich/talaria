import Foundation
import Observation
import TalariaKit
import TalariaTheme

// The policy behind the approval prompt: which class of dangerous command asks
// at all, how long it waits for you, which patterns you already said "always"
// to, and who is allowed to DM your bots.
//
// Talaria could answer an approval before this; it could not change the rules.
// The three things a phone-first operator actually needs are all here:
//
//   1. approvals.mode — manual / smart / off. Persisted policy, not a session
//      flag. `smart` is the one a sane person leaves on unattended: an aux LLM
//      auto-approves the safe class and auto-denies the genuinely dangerous
//      one, and anything it is unsure about still reaches your phone
//      (tools/approval.py:4626-4670).
//   2. The permanent allowlist. "Always" is granted from a phone, in a hurry,
//      from a lock screen — so the phone owes you somewhere to take it back.
//   3. approvals.timeout — how long a parked agent waits while you are away
//      from the device. The 300 s default was chosen *because* of phones
//      (tools/approval.py:3218-3234).
//
// Shapes verified against the upstream checkout:
//   tui_gateway/methods_config.py:269  — config.get key "approval_mode" |
//                                        "approvals.mode" → {"value": …}
//   tui_gateway/server.py:12014-12028  — config.set writes approvals.mode,
//                                        validates against {manual,smart,off},
//                                        re-emits session.info to every session
//   tui_gateway/server.py:4310-4331    — _APPROVAL_MODES, _load_approval_mode
//   tui_gateway/server.py:5465         — "v3: adds approvals.mode config RPCs";
//                                        get and set landed in one contract bump,
//                                        so a successful get implies a live set
//   tui_gateway/server.py:12030-12105  — config.set key "yolo": scope "session"
//                                        flips one session, scope "global"
//                                        writes approvals.mode off|manual
//   tools/approval.py:2931-2957        — command_allowlist load/save
//   tools/approval.py:2897-2925        — how an entry is matched (exact, or a
//                                        shell-style glob)
//   hermes_cli/web_server.py:6711,7512 — GET / PUT /api/config (deep-merged,
//                                        so a list write replaces just that list)
//
// Why the config file and not an RPC for the allowlist: there is no config.set
// branch for `command_allowlist` anywhere in the gateway — the CLI's own
// `save_permanent_allowlist` writes config.yaml directly — so REST is the write
// path, and it is the same one desktop Settings uses for the identical row
// (PARITY.md:604).

// MARK: - Approval mode

/// The persisted, gateway-wide approval policy. Exactly the three values
/// `_APPROVAL_MODES` accepts; anything else upstream normalizes to `manual`
/// (tools/approval.py:3142-3168), so an unknown string reads as manual here too.
public enum ApprovalMode: String, CaseIterable, Sendable, Identifiable {
    /// Every dangerous command asks you.
    case manual
    /// An auxiliary model triages first: safe → run, dangerous → blocked,
    /// unsure → you.
    case smart
    /// Nothing asks. This is the global bypass — the same state the desktop
    /// status bar's shift-click zap writes (server.py:12058-12070).
    case off

    public var id: String { rawValue }

    init(wire: String?) {
        self = ApprovalMode(rawValue: (wire ?? "").trimmingCharacters(in: .whitespaces)
            .lowercased()) ?? .manual
    }
}

/// The `approvals` block plus the allowlist, as one read of `GET /api/config`.
public struct ApprovalConfigSnapshot: Sendable, Equatable {
    /// `command_allowlist` — command text and shell-style globs, plus the
    /// dangerous-pattern keys that "always" persists (tools/approval.py:2897).
    public var allowlist: [String]
    /// `approvals.timeout`, seconds. 300 is the shipped default.
    public var timeoutSeconds: Int
    /// `approvals.mode` as the config file has it. Only a fallback for display:
    /// the RPC is the authority, because it resolves managed-scope overlays and
    /// `${VAR}` expansion the raw file does not (server.py:4314-4331).
    public var mode: ApprovalMode

    public static let unknown = ApprovalConfigSnapshot(allowlist: [], timeoutSeconds: 300,
                                                       mode: .manual)
}

extension GatewayClient {

    /// `config.get {key:"approval_mode"}` → `{"value":"manual"|"smart"|"off"}`.
    /// Throws 4002 on a gateway that predates the key — which is the probe the
    /// screen uses to decide whether to offer the control at all.
    func approvalMode() async throws -> ApprovalMode {
        let result = try await rpc("config.get", ["key": "approval_mode"], timeout: 20)
        return ApprovalMode(wire: result["value"]?.stringValue)
    }

    /// `config.set {key:"approvals.mode", value}`. The gateway validates the
    /// value, persists it to config.yaml and re-emits `session.info` to every
    /// live session, so the chat strips update themselves.
    ///
    /// Sent under the canonical dotted key: the branch accepts both spellings
    /// (server.py:12014) and answers with `approvals.mode` either way.
    @discardableResult
    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalMode {
        let result = try await rpc("config.set", ["key": "approvals.mode",
                                                  "value": .string(mode.rawValue)],
                                   timeout: 30)
        return ApprovalMode(wire: result["value"]?.stringValue ?? mode.rawValue)
    }

    /// The approvals block of `GET /api/config`. Throws when the dashboard
    /// routes are not mounted, which hides the two rows that need them.
    func approvalConfig(profile: String? = nil) async throws -> ApprovalConfigSnapshot {
        let config = try await restJSON(path: "api/config",
                                        query: Self.configQuery(profile), timeout: 20)
        let approvals = config["approvals"]
        let timeout = approvals?["timeout"]?.intValue ?? 300
        return ApprovalConfigSnapshot(
            allowlist: config["command_allowlist"]?.arrayValue?
                .compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? [],
            // A hand-edited 0 or a negative would mean "never wait", which the
            // gateway does not honor; it falls back to 300 on anything unusable.
            timeoutSeconds: timeout > 0 ? timeout : 300,
            mode: ApprovalMode(wire: approvals?["mode"]?.stringValue))
    }

    /// Replace `command_allowlist` wholesale. `PUT /api/config` deep-merges
    /// dicts but assigns lists (hermes_cli/config.py:2548-2573), so sending
    /// only this key rewrites only this list and leaves the rest of config.yaml
    /// — provider keys included — untouched.
    func writeCommandAllowlist(_ patterns: [String], profile: String? = nil) async throws {
        var body: [String: JSONValue] = [
            "config": .object(["command_allowlist": .array(patterns.map(JSONValue.string))]),
        ]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        try await restJSON(path: "api/config", method: "PUT", body: .object(body), timeout: 30)
    }

    /// Write `approvals.timeout` (seconds). Nested under `approvals`, so the
    /// deep merge keeps `mode` and every other key in that block.
    func writeApprovalTimeout(_ seconds: Int, profile: String? = nil) async throws {
        var body: [String: JSONValue] = [
            "config": .object(["approvals": .object(["timeout": .number(Double(seconds))])]),
        ]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        try await restJSON(path: "api/config", method: "PUT", body: .object(body), timeout: 30)
    }

    private static func configQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }
}

// MARK: - Store

/// State for the approval-policy and pairing surfaces. `AppModel`'s stored
/// properties live in AppModel.swift (another owner) and a Swift extension
/// cannot add storage, so this rides a MainActor observable singleton — the
/// same shape `LiveRuntime`, `ApprovalBridges` and `TalariaSettingsStore` use.
@MainActor
@Observable
public final class ApprovalPolicyStore {
    public static let shared = ApprovalPolicyStore()

    /// Whether a gateway implements one of these surfaces. `.unknown` means
    /// "not probed yet" and renders as neither present nor missing.
    public enum Support: Sendable, Equatable { case unknown, supported, unsupported }

    // Policy
    public internal(set) var mode: ApprovalMode = .manual
    public internal(set) var modeSupport: Support = .unknown
    /// `command_allowlist` + `approvals.timeout`, and whether config is readable.
    public internal(set) var config: ApprovalConfigSnapshot = .unknown
    public internal(set) var configSupport: Support = .unknown

    // Pairing
    public internal(set) var pairing: PairingSnapshot = .empty
    public internal(set) var pairingSupport: Support = .unknown

    // Presentation
    public internal(set) var isLoading = false
    public internal(set) var hasLoaded = false
    public internal(set) var isLoadingPairing = false
    public internal(set) var hasLoadedPairing = false
    /// Keys of in-flight writes, so one row can spin without freezing the screen.
    public internal(set) var busy: Set<String> = []
    /// Themed lead + the gateway's own message. Cleared by the next success.
    public internal(set) var notice: String?
    public internal(set) var pairingNotice: String?

    /// The `pairing.changed` subscription, live only while the screen is up.
    weak var watchedClient: GatewayClient?
    var watchHandler: UUID?
    var watchPump: Task<Void, Never>?
    /// The in-flight `addEventHandler` hop. Held so a detach that lands before
    /// it completes can cancel it instead of racing it.
    var watchRegistration: Task<Void, Never>?

    /// Which world this state describes: the live gateway's base URL, or nil
    /// for the demo world. Compared on every load so a policy read from one
    /// gateway never renders as another's — including the support probes, which
    /// decide whether a row exists at all.
    var boundGateway: URL?

    public init() {}

    public func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// A different gateway is a different policy; nothing carries over.
    func reset() {
        mode = .manual; modeSupport = .unknown
        config = .unknown; configSupport = .unknown
        pairing = .empty; pairingSupport = .unknown
        isLoading = false; hasLoaded = false
        isLoadingPairing = false; hasLoadedPairing = false
        busy.removeAll(); notice = nil; pairingNotice = nil
    }
}

// MARK: - Model API

extension AppModel {

    public var approvalPolicy: ApprovalPolicyStore { .shared }

    /// Ask whoever owns the screen graph to push the approval-policy screen.
    /// Same shape as `requestSettings()` / `requestCapabilities(profile:)`, so
    /// a caller needs no binding and no knowledge that the screen exists.
    public func requestApprovalPolicy() {
        NotificationCenter.default.post(name: .talariaOpenApprovalPolicy, object: nil)
    }

    // MARK: Load

    /// Read the policy. Each half is probed independently: a gateway can have
    /// the `approvals.mode` RPC without the dashboard REST routes, and vice
    /// versa, and each missing half hides only its own rows.
    public func loadApprovalPolicy() async {
        let store = approvalPolicy
        rebindPolicyStoreIfNeeded()
        guard !store.isLoading else { return }
        store.isLoading = true
        store.notice = nil
        defer {
            store.isLoading = false
            store.hasLoaded = true
        }

        guard mode == .live, let client else {
            Self.fillDemoPolicy(store)
            return
        }

        var failure: String?

        // A definitive "no such method / no such key / no such route" is what
        // marks a surface unsupported. Every other failure — a dropped link
        // mid-read, a proxy hiccup — leaves the previous verdict alone: taking
        // a working security control off the screen because one request timed
        // out is worse than showing it a moment stale.
        do {
            store.mode = try await client.approvalMode()
            store.modeSupport = .supported
        } catch let error as GatewayError
            where error.code == GatewayClient.methodNotFound || error.code == 4002 {
            // Pre-v3 gateway: no approvals.mode RPC pair at all (server.py:5465
            // bumped the contract for get and set together). The control
            // disappears rather than writing a key nothing reads.
            store.modeSupport = .unsupported
        } catch {
            failure = Self.policyMessage(error)
        }

        do {
            store.config = try await client.approvalConfig()
            store.configSupport = .supported
            // The file agrees with the RPC in every normal deployment; when the
            // RPC is missing the file is the only reading we have, and saying
            // "manual" while config.yaml says "off" would be a dangerous lie.
            if store.modeSupport != .supported { store.mode = store.config.mode }
        } catch let error as GatewayError where error.code == 404 || error.code == 405 {
            store.configSupport = .unsupported
        } catch {
            failure = failure ?? Self.policyMessage(error)
        }

        if let failure { store.notice = policyNotice(failure) }
    }

    // MARK: Mode

    /// Persist manual / smart / off. Optimistic: the segmented control moves at
    /// once and rolls back if the gateway refuses, because a security control
    /// that silently shows the wrong state is worse than a slow one.
    public func setApprovalMode(_ next: ApprovalMode) async {
        let store = approvalPolicy
        guard store.mode != next else { return }
        let previous = store.mode
        store.mode = next
        store.notice = nil

        guard mode == .live, let client else { return }
        store.busy.insert("mode")
        defer { store.busy.remove("mode") }
        do {
            store.mode = try await client.setApprovalMode(next)
        } catch {
            store.mode = previous
            store.notice = policyNotice(Self.policyMessage(error))
        }
    }

    // MARK: Timeout

    /// How long a parked approval waits before it denies itself. Upstream
    /// treats silence as refusal ("Silence is not consent",
    /// tools/approval.py:3560-3614), so this is the window between a push
    /// landing and the agent giving up on you.
    public func setApprovalTimeout(_ seconds: Int) async {
        let store = approvalPolicy
        guard store.configSupport == .supported, store.config.timeoutSeconds != seconds else {
            return
        }
        let previous = store.config.timeoutSeconds
        store.config.timeoutSeconds = seconds
        store.notice = nil

        guard mode == .live, let client else { return }
        store.busy.insert("timeout")
        defer { store.busy.remove("timeout") }
        do {
            try await client.writeApprovalTimeout(seconds)
        } catch {
            store.config.timeoutSeconds = previous
            store.notice = policyNotice(Self.policyMessage(error))
        }
    }

    // MARK: Permanent allowlist

    /// Take back one "always". Re-reads the list immediately before writing, so
    /// a grant added from desktop between our load and this tap survives —
    /// `PUT /api/config` assigns the whole list and would otherwise erase it.
    public func revokeAlwaysAllowed(_ pattern: String) async {
        let store = approvalPolicy
        guard store.configSupport == .supported else { return }
        let key = "allow:" + pattern
        guard !store.isBusy(key) else { return }
        store.busy.insert(key)
        store.notice = nil
        defer { store.busy.remove(key) }

        guard mode == .live, let client else {
            store.config.allowlist.removeAll { $0 == pattern }
            return
        }
        do {
            let fresh = try await client.approvalConfig()
            let remaining = fresh.allowlist.filter { $0 != pattern }
            // Already gone (revoked from desktop, or the file was hand-edited):
            // adopt the truth instead of writing a no-op.
            if remaining.count != fresh.allowlist.count {
                try await client.writeCommandAllowlist(remaining)
            }
            store.config.allowlist = remaining
            store.config.timeoutSeconds = fresh.timeoutSeconds
        } catch {
            store.notice = policyNotice(Self.policyMessage(error))
        }
    }

    // MARK: Bypass state

    /// True when nothing asks: `approvals.mode: off` is the global bypass, and
    /// it covers the CLI, the TUI, cron and every session at once
    /// (server.py:12036-12042).
    public var globalApprovalBypass: Bool {
        approvalPolicy.mode == .off && approvalPolicy.modeSupport != .unknown
    }

    /// Bots whose *session* reports the bypass. `session.info.yolo` is the
    /// EFFECTIVE flag — process `--yolo`, OR this session's toggle, OR
    /// `approvals.mode: off` (server.py:5539-5554) — so while the global switch
    /// is off every session reports true and listing them individually would
    /// invite you to turn off a per-session flag that was never on. In that
    /// state the list is empty and the screen names the global switch instead.
    public var sessionBypassBots: [Bot] {
        guard !globalApprovalBypass else { return [] }
        return bots.filter { chats[$0.id]?.yolo == true }
    }

    /// Clear one session's YOLO — `config.set {key:"yolo", scope:"session"}`,
    /// the same write the chat strip makes.
    public func clearSessionBypass(botID: String) {
        setYolo(botID: botID, enabled: false)
    }

    // MARK: Pairing

    /// Read the pairing store. A gateway with no dashboard routes answers 404,
    /// which marks the surface unsupported and takes the whole row away.
    public func loadPairing() async {
        let store = approvalPolicy
        rebindPolicyStoreIfNeeded()
        guard !store.isLoadingPairing else { return }
        store.isLoadingPairing = true
        defer {
            store.isLoadingPairing = false
            store.hasLoadedPairing = true
        }

        guard mode == .live, let client else {
            Self.fillDemoPairing(store)
            return
        }
        do {
            store.pairing = try await client.pairingSnapshot()
            store.pairingSupport = .supported
            store.pairingNotice = nil
        } catch PairingFailure.unsupported {
            store.pairingSupport = .unsupported
            store.pairing = .empty
            store.pairingNotice = nil
        } catch {
            // Keep whatever we last read: a dropped link must not look like
            // "nobody is waiting".
            store.pairingNotice = pairingNotice(for: error)
        }
    }

    /// Let one person in, by request id. Optimistic with rollback, like the
    /// desktop row (app/messaging/index.tsx:354).
    @discardableResult
    public func approvePairing(_ request: PairingRequest) async -> Bool {
        let store = approvalPolicy
        guard request.isApprovable else { return false }
        let key = "pair:" + request.id
        guard !store.isBusy(key) else { return false }
        store.busy.insert(key)
        store.pairingNotice = nil
        defer { store.busy.remove(key) }

        let snapshot = store.pairing
        store.pairing = PairingSnapshot(
            pending: snapshot.pending.filter { $0.id != request.id },
            approved: snapshot.approved + [PairedUser(platform: request.platform,
                                                      userID: request.userID,
                                                      userName: request.userName,
                                                      approvedAt: Date().timeIntervalSince1970)])

        guard mode == .live, let client else { return true }
        do {
            _ = try await client.approvePairingRequest(platform: request.platform,
                                                       requestID: request.requestID)
            return true
        } catch {
            store.pairing = snapshot
            store.pairingNotice = pairingNotice(for: error)
            return false
        }
    }

    /// Take access away. Destructive, so the screen confirms before calling.
    @discardableResult
    public func revokePairing(_ user: PairedUser) async -> Bool {
        let store = approvalPolicy
        let key = "revoke:" + user.id
        guard !store.isBusy(key) else { return false }
        store.busy.insert(key)
        store.pairingNotice = nil
        defer { store.busy.remove(key) }

        let snapshot = store.pairing
        store.pairing = PairingSnapshot(pending: snapshot.pending,
                                        approved: snapshot.approved.filter { $0.id != user.id })

        guard mode == .live, let client else { return true }
        do {
            try await client.revokePairedUser(platform: user.platform, userID: user.userID)
            return true
        } catch PairingFailure.notFound {
            // Somebody else already revoked them; the optimistic removal was
            // right and there is nothing to report.
            return true
        } catch {
            store.pairing = snapshot
            store.pairingNotice = pairingNotice(for: error)
            return false
        }
    }

    // MARK: Live refresh

    /// Subscribe to `pairing.changed` (server.py:3753, a 2 s watch over every
    /// profile's pairing store) while the screen is on. It is the difference
    /// between seeing a colleague appear in the queue and having to know to
    /// pull down.
    public func attachPairingWatch() {
        let store = approvalPolicy
        guard mode == .live, let client, store.watchedClient !== client else { return }
        detachPairingWatch()
        store.watchedClient = client

        // Same funnel the approval bridges use: events leave the client actor
        // through one stream so MainActor delivery keeps wire order.
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        store.watchPump = Task { @MainActor [weak self] in
            for await event in stream where event.type == "pairing.changed" {
                await self?.loadPairing()
            }
        }
        store.watchRegistration = Task { @MainActor in
            let handler = await client.addEventHandler { continuation.yield($0) }
            // Registering costs an actor hop, and a detach can land inside it —
            // the screen closing, or `rebindPolicyStoreIfNeeded` firing from the
            // first load. Assigning the id blindly would leave a live handler
            // pumping into a cancelled stream for the life of the connection,
            // with nothing holding its id to remove it by.
            guard store.watchedClient === client else {
                await client.removeEventHandler(handler)
                return
            }
            store.watchHandler = handler
        }
    }

    public func detachPairingWatch() {
        let store = approvalPolicy
        store.watchRegistration?.cancel(); store.watchRegistration = nil
        if let client = store.watchedClient, let handler = store.watchHandler {
            Task { await client.removeEventHandler(handler) }
        }
        store.watchPump?.cancel(); store.watchPump = nil
        store.watchedClient = nil
        store.watchHandler = nil
    }

    // MARK: Internals

    /// Drop everything the moment the world changes. The store is a process
    /// singleton (extensions cannot add stored properties to AppModel), so
    /// without this a gateway that HAS pairing leaves its row visible after a
    /// switch to one that does not — the worst kind of stale, because the
    /// support probes are what decide whether a control exists.
    private func rebindPolicyStoreIfNeeded() {
        let store = approvalPolicy
        let current = mode == .live ? LiveRuntime.shared.baseURL : nil
        guard store.boundGateway != current else { return }
        // The screen arms the watch (presenter `onChange`) BEFORE its first load
        // runs, and that first load is always a rebind because `boundGateway`
        // starts nil. Detaching without putting it back therefore killed the
        // `pairing.changed` subscription on every single open — the queue only
        // ever updated on a manual pull.
        let wasWatching = store.watchedClient != nil
        detachPairingWatch()
        store.reset()
        store.boundGateway = current
        if wasWatching { attachPairingWatch() }
    }

    static func policyMessage(_ error: Error) -> String {
        if let error = error as? GatewayError { return error.message }
        if let failure = error as? PairingFailure, case .failed(let message) = failure {
            return message
        }
        return (error as NSError).localizedDescription
    }

    /// "<themed lead> — <gateway message>", clipped so a stack trace cannot
    /// take over the screen. Mirrors the Capabilities notice exactly.
    func policyNotice(_ detail: String) -> String {
        let lead = theme.copy.policyNoticeLead(theme.themeID)
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lead }
        let clipped = trimmed.count > 160
            ? String(trimmed.prefix(160)).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        return "\(lead) — \(clipped)"
    }

    /// Pairing failures get their own copy: "expired" and "locked out" are
    /// states the operator can act on, not errors to apologise for.
    func pairingNotice(for error: Error) -> String {
        let copy = theme.copy
        let themeID = theme.themeID
        switch error as? PairingFailure {
        case .expired: return copy.pairExpired(themeID)
        case .lockedOut: return copy.pairLockedOut(themeID)
        case .notFound: return copy.pairGone(themeID)
        case .unsupported, .failed, .none: return policyNotice(Self.policyMessage(error))
        }
    }

    // MARK: Demo world

    /// The canned policy. Demo mode is the no-gateway world the onboarding
    /// "explore" path and App Review see; an empty security screen there would
    /// read as a broken feature rather than a quiet one.
    private static func fillDemoPolicy(_ store: ApprovalPolicyStore) {
        store.mode = .smart
        store.modeSupport = .supported
        store.configSupport = .supported
        store.config = ApprovalConfigSnapshot(
            allowlist: ["git status", "npm run build", "rg *", "recursive delete"],
            timeoutSeconds: 300, mode: .smart)
    }

    private static func fillDemoPairing(_ store: ApprovalPolicyStore) {
        store.pairingSupport = .supported
        store.pairing = PairingSnapshot(
            pending: [PairingRequest(platform: "telegram", requestID: "a1b2c3d4e5f60718",
                                     userID: "48812207", userName: "Mara",
                                     ageMinutes: 12)],
            approved: [PairedUser(platform: "telegram", userID: "10233145",
                                  userName: "you", approvedAt: nil),
                       PairedUser(platform: "discord", userID: "204118883721",
                                  userName: "ops-oncall", approvedAt: nil)])
    }
}

// MARK: - Deep link

public extension Notification.Name {
    /// Posted by `AppModel.requestApprovalPolicy()`; the presenter mounted with
    /// `View.talariaApprovalPolicy(model:)` pushes the screen.
    static let talariaOpenApprovalPolicy = Notification.Name("talaria.open.approvalPolicy")
}

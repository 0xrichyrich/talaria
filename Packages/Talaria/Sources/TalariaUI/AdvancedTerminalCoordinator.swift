import Foundation
import Observation
import TalariaKit

@MainActor
final class GatewayPTYAttachmentStore {
    static let shared = GatewayPTYAttachmentStore()
    private let defaults: UserDefaults
    private let key = "talaria.gatewayPTY.attachments.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func token(gatewayID: String, profile: String, resume: String?) -> String {
        let scope = Self.scope(gatewayID: gatewayID, profile: profile, resume: resume)
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let existing = values[scope], !existing.isEmpty { return existing }
        let token = UUID().uuidString.lowercased()
        values[scope] = token
        defaults.set(values, forKey: key)
        return token
    }

    @discardableResult
    func rotate(gatewayID: String, profile: String, resume: String?) -> String {
        let scope = Self.scope(gatewayID: gatewayID, profile: profile, resume: resume)
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let token = UUID().uuidString.lowercased()
        values[scope] = token
        defaults.set(values, forKey: key)
        return token
    }

    func remove(gatewayID: String) {
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let prefix = "\(gatewayID.utf8.count):\(gatewayID)|"
        values = values.filter { !$0.key.hasPrefix(prefix) }
        defaults.set(values, forKey: key)
    }

    func removeAll() { defaults.removeObject(forKey: key) }

    private static func scope(gatewayID: String, profile: String, resume: String?) -> String {
        let resume = resume ?? ""
        return "\(gatewayID.utf8.count):\(gatewayID)|\(profile.utf8.count):\(profile)|\(resume.utf8.count):\(resume)"
    }
}

/// One app-wide terminal owner. Keeping it above the tab view prevents a tab
/// redraw from opening a duplicate attachment; the socket is still detached
/// whenever the Command Center leaves the foreground.
@MainActor
@Observable
final class AdvancedTerminalCoordinator {
    private enum Egress {
        case bytes(Data)
        case resize(columns: Int, rows: Int)
    }
    static let shared = AdvancedTerminalCoordinator()
    static let detachedSessionSafetyWindow: TimeInterval = 29 * 60

    private(set) var state: GatewayPTYRuntimeState = .idle
    private(set) var chunks: [GatewayTerminalChunk] = []
    private(set) var gatewayName = ""
    private(set) var profile = ""
    private(set) var requiresResumeDecision = false
    private(set) var message = ""
    private(set) var rendererGeneration: UInt64 = 0

    @ObservationIgnored private var runtime: GatewayPTYRuntime?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var egressTask: Task<Void, Never>?
    @ObservationIgnored private var target: GatewayPTYTarget?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var lastKnownSize: (columns: Int, rows: Int)?
    @ObservationIgnored private var renderWaiter: (UUID, CheckedContinuation<Void, Never>)?

    var acceptsInput: Bool { state == .open && !requiresResumeDecision }

    func startFromWorkspace(resume: String? = nil, fresh: Bool = false) {
        let workspace = WorkspaceRuntime.shared
        guard let gatewayID = workspace.gatewayID,
              let rawProfile = workspace.profile,
              workspace.profiles.contains(where: { $0.profile == rawProfile }),
              ProfileLifecycleTrafficAdmission.allows(gatewayID),
              let gateway = ConnectionRegistry.shared.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL,
              let credential = ConnectionRegistry.shared.credential(for: gateway) else {
            stop()
            message = "Choose a signed-in gateway and an available profile before opening Advanced Terminal."
            return
        }

        let requestedResume = fresh ? nil : resume
        let attach = fresh
            ? GatewayPTYAttachmentStore.shared.rotate(gatewayID: gatewayID, profile: rawProfile, resume: nil)
            : GatewayPTYAttachmentStore.shared.token(
                gatewayID: gatewayID, profile: rawProfile, resume: requestedResume)
        let captured = GatewayPTYTarget(
            gatewayID: gatewayID,
            connectionGeneration: workspace.generation,
            baseURL: baseURL,
            credential: credential,
            profile: rawProfile,
            resume: requestedResume,
            fresh: fresh,
            attach: attach
        )
        guard captured.isValid else {
            stop()
            message = "This gateway or profile cannot form a safe terminal request."
            return
        }
        if target == captured, runtime != nil { return }

        stop(clearTranscript: true)
        rendererGeneration &+= 1
        target = captured
        gatewayName = gateway.name
        profile = rawProfile
        message = ""
        requiresResumeDecision = false
        let supervisor = GatewayPTYRuntime(currentness: { candidate in
            await MainActor.run { Self.isCurrent(candidate) }
        })
        runtime = supervisor
        eventTask = Task { @MainActor [weak self, weak supervisor] in
            guard let self, let supervisor else { return }
            for await event in supervisor.events {
                guard self.runtime === supervisor, self.target == captured else { return }
                switch event {
                case .state(let value):
                    self.state = value
                    switch value {
                    case .open:
                        self.message = ""
                        if let size = self.lastKnownSize {
                            self.enqueue(.resize(columns: size.columns, rows: size.rows))
                        }
                    case .closed(let close), .ended(let close):
                        self.message = Self.description(close)
                    default: break
                    }
                case .bytes(let bytes):
                    let chunk = GatewayTerminalChunk(bytes: bytes)
                    self.chunks.append(chunk)
                    // Keep exactly one renderer-owned frame in flight. The
                    // runtime stream cannot drain again until SwiftTerm feeds
                    // and acknowledges this chunk, propagating backpressure
                    // all the way to URLSession without dropping ANSI bytes.
                    await withCheckedContinuation { continuation in
                        self.renderWaiter = (chunk.id, continuation)
                    }
                }
            }
        }
        supervisor.start(captured)
    }

    func send(_ bytes: Data) {
        guard acceptsInput else { return }
        enqueue(.bytes(bytes))
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        lastKnownSize = (columns, rows)
        guard acceptsInput else { return }
        enqueue(.resize(columns: columns, rows: rows))
    }

    func consume(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let consumed = Set(ids)
        chunks.removeAll { chunk in
            guard consumed.contains(chunk.id) else { return false }
            return true
        }
        if let waiter = renderWaiter, consumed.contains(waiter.0) {
            renderWaiter = nil
            waiter.1.resume()
        }
    }

    func setForeground(_ foreground: Bool, now: Date = Date()) {
        if !foreground {
            if backgroundedAt == nil { backgroundedAt = now }
            runtime?.setForeground(false)
            return
        }
        if let backgroundedAt,
           Self.needsResumeDecision(backgroundedAt: backgroundedAt, now: now) {
            requiresResumeDecision = true
            message = "Hermes may have expired this detached PTY. Reattach may start a new process; choose how to continue."
            return
        }
        backgroundedAt = nil
        runtime?.setForeground(true)
    }

    func reattachAfterExpiry() {
        requiresResumeDecision = false
        backgroundedAt = nil
        message = "Reattaching with the previous token; Hermes does not report whether it reused or recreated the PTY."
        runtime?.setForeground(true)
    }

    func startNewSession() { startFromWorkspace(fresh: true) }

    func stop(clearTranscript: Bool = false) {
        eventTask?.cancel()
        eventTask = nil
        if let waiter = renderWaiter {
            renderWaiter = nil
            waiter.1.resume()
        }
        egressTask?.cancel()
        egressTask = nil
        runtime?.stop()
        runtime = nil
        target = nil
        state = .idle
        backgroundedAt = nil
        requiresResumeDecision = false
        if clearTranscript {
            chunks = []
        }
    }

    func stopAndForget(gatewayID: String) {
        if target?.gatewayID == gatewayID { stop(clearTranscript: true) }
        GatewayPTYAttachmentStore.shared.remove(gatewayID: gatewayID)
    }

    func stopAndForgetEverything() {
        stop(clearTranscript: true)
        GatewayPTYAttachmentStore.shared.removeAll()
    }

    static func needsResumeDecision(backgroundedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(backgroundedAt) >= detachedSessionSafetyWindow
    }

    private func enqueue(_ operation: Egress) {
        guard let runtime else { return }
        let previous = egressTask
        egressTask = Task { @MainActor [weak self, weak runtime] in
            _ = await previous?.result
            guard let self, let runtime, !Task.isCancelled,
                  self.runtime === runtime, self.acceptsInput else { return }
            do {
                switch operation {
                case .bytes(let bytes): try await runtime.send(bytes)
                case .resize(let columns, let rows):
                    try await runtime.resize(columns: columns, rows: rows)
                }
            } catch {
                guard self.runtime === runtime else { return }
                self.message = "Terminal input was not sent because the connection changed."
            }
        }
    }

    private static func isCurrent(_ candidate: GatewayPTYTarget) -> Bool {
        let workspace = WorkspaceRuntime.shared
        guard workspace.gatewayID == candidate.gatewayID,
              workspace.generation == candidate.connectionGeneration,
              workspace.profile == candidate.profile,
              candidate.profile.map({ profile in workspace.profiles.contains { $0.profile == profile } }) == true,
              ProfileLifecycleTrafficAdmission.allows(candidate.gatewayID),
              let saved = ConnectionRegistry.shared.saved.first(where: { $0.id == candidate.gatewayID }),
              saved.baseURL == candidate.baseURL,
              ConnectionRegistry.shared.credential(for: saved) != nil else { return false }
        return true
    }

    private static func description(_ close: GatewayPTYClose) -> String {
        switch close.kind {
        case .unauthorized: "Terminal sign-in expired. Sign in to this gateway again."
        case .forbidden, .peerRejected: "This gateway rejected the terminal connection from this device."
        case .unavailable: "Advanced Terminal is unavailable on this gateway."
        case .superseded: "This terminal was opened somewhere else. Reconnect explicitly to take it back."
        case .processExited, .ended: "The remote terminal process ended."
        case .serverFailure: "The gateway could not provide a PTY on this platform."
        case .transient: "The terminal connection was interrupted. Reconnecting…"
        }
    }
}

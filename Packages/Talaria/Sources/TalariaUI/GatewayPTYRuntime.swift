import Foundation
import TalariaKit

private final class GatewayPTYRuntimeCurrentness: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var target: GatewayPTYTarget?

    func update(generation: UInt64, target: GatewayPTYTarget?) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        self.target = target
    }

    func matches(generation: UInt64, target: GatewayPTYTarget) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation && self.target == target
    }
}

public enum GatewayPTYRuntimeState: Equatable, Sendable {
    case idle
    case connecting
    case open
    case reconnecting(attempt: Int)
    case closed(GatewayPTYClose)
    case ended(GatewayPTYClose)
}

public enum GatewayPTYRuntimeEvent: Equatable, Sendable {
    case state(GatewayPTYRuntimeState)
    case bytes(Data)
}

/// Type-erased, identity-bearing PTY session used by the recovery supervisor.
/// Every operation remains bound to the connection created for one exact target.
public final class GatewayPTYSessionHandle: @unchecked Sendable {
    public let id: UUID
    public let events: AsyncStream<GatewayPTYEvent>
    private let sendOperation: @Sendable (Data) async throws -> Void
    private let resizeOperation: @Sendable (Int, Int) async throws -> Void
    private let closeOperation: @Sendable () async -> Void

    public init(id: UUID = UUID(), events: AsyncStream<GatewayPTYEvent>,
                send: @escaping @Sendable (Data) async throws -> Void,
                resize: @escaping @Sendable (Int, Int) async throws -> Void,
                close: @escaping @Sendable () async -> Void) {
        self.id = id
        self.events = events
        sendOperation = send
        resizeOperation = resize
        closeOperation = close
    }

    public func send(_ bytes: Data) async throws { try await sendOperation(bytes) }
    public func resize(columns: Int, rows: Int) async throws {
        try await resizeOperation(columns, rows)
    }
    public func close() async { await closeOperation() }

    static func production(
        target: GatewayPTYTarget,
        currentness: @escaping GatewayPTYConnection.CurrentnessCheck
    ) async throws -> Self {
        let connection = GatewayPTYConnection(
            target: target, currentness: currentness)
        try await connection.connect()
        return Self(
            events: connection.events,
            send: { try await connection.send($0) },
            resize: { try await connection.resize(columns: $0, rows: $1) },
            close: { await connection.close() })
    }
}

@MainActor
struct GatewayPTYRuntimeOperations {
    var connect: @Sendable (
        GatewayPTYTarget, @escaping GatewayPTYConnection.CurrentnessCheck
    ) async throws -> GatewayPTYSessionHandle
    var sleep: @Sendable (Duration) async throws -> Void

    static let production = Self(
        connect: {
            try await GatewayPTYSessionHandle.production(
                target: $0, currentness: $1)
        },
        sleep: { try await Task.sleep(for: $0) })
}

/// Mobile lifecycle supervisor for one visible PTY. It deliberately owns no
/// navigation: a screen supplies an exact saved-gateway generation and forwards
/// foreground/online changes. Late connects, frames, and closes are fenced by
/// generation + complete target + session identity.
@MainActor
public final class GatewayPTYRuntime {
    public typealias ExternalAuthority = @Sendable (GatewayPTYTarget) async -> Bool
    public nonisolated let events: AsyncStream<GatewayPTYRuntimeEvent>
    private nonisolated let continuation:
        AsyncStream<GatewayPTYRuntimeEvent>.Continuation

    public private(set) var state: GatewayPTYRuntimeState = .idle
    public private(set) var target: GatewayPTYTarget?
    public private(set) var reconnectAttempt = 0
    public private(set) var isOnline = true
    public private(set) var isForeground = true

    private let operations: GatewayPTYRuntimeOperations
    private let externalAuthority: ExternalAuthority
    private let currentness = GatewayPTYRuntimeCurrentness()
    private var generation: UInt64 = 0
    private var session: GatewayPTYSessionHandle?
    private var connectTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    public convenience init(
        currentness: @escaping ExternalAuthority = { _ in true }
    ) {
        self.init(operations: .production, externalAuthority: currentness)
    }

    init(operations: GatewayPTYRuntimeOperations,
         externalAuthority: @escaping ExternalAuthority = { _ in true }) {
        self.operations = operations
        self.externalAuthority = externalAuthority
        var captured: AsyncStream<GatewayPTYRuntimeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) {
            captured = $0
        }
        continuation = captured
    }

    deinit {
        connectTask?.cancel()
        pumpTask?.cancel()
        retryTask?.cancel()
        if let session { Task { await session.close() } }
        continuation.finish()
    }

    public func start(_ target: GatewayPTYTarget) {
        generation &+= 1
        let expectedGeneration = generation
        self.target = target
        currentness.update(generation: generation, target: target)
        cancelTasksAndCloseSession()
        reconnectAttempt = 0
        guard target.isValid else {
            publish(.closed(GatewayPTYClose(code: 4404, reason: "invalid target")))
            return
        }
        guard isOnline, isForeground else {
            publish(.reconnecting(attempt: 0))
            return
        }
        beginConnect(target: target, generation: expectedGeneration)
    }

    public func stop() {
        generation &+= 1
        target = nil
        currentness.update(generation: generation, target: nil)
        reconnectAttempt = 0
        cancelTasksAndCloseSession()
        publish(.idle)
    }

    public func setOnline(_ online: Bool) {
        guard isOnline != online else {
            if online { recoverIfNeeded() }
            return
        }
        isOnline = online
        if online {
            recoverIfNeeded(immediate: true)
        } else {
            suspendForRecovery()
        }
    }

    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else {
            if foreground { recoverIfNeeded() }
            return
        }
        isForeground = foreground
        if foreground { recoverIfNeeded(immediate: true) }
        else { suspendForRecovery() }
    }

    /// Explicit lifecycle nudge for a foreground socket known to be stale after
    /// a radio handoff. It rotates the attempt even if URLSession has not yet
    /// delivered the old socket's close callback.
    public func recoverNow() {
        guard target != nil, isOnline, isForeground else { return }
        suspendForRecovery()
        recoverIfNeeded(immediate: true)
    }

    public func send(_ bytes: Data) async throws {
        guard state == .open, let session else { throw GatewayPTYError.notConnected }
        let expectedGeneration = generation
        let expectedTarget = target
        let expectedID = session.id
        try await session.send(bytes)
        guard generation == expectedGeneration, target == expectedTarget,
              self.session?.id == expectedID else { throw CancellationError() }
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard state == .open, let session else { throw GatewayPTYError.notConnected }
        let expectedGeneration = generation
        let expectedTarget = target
        let expectedID = session.id
        try await session.resize(columns: columns, rows: rows)
        guard generation == expectedGeneration, target == expectedTarget,
              self.session?.id == expectedID else { throw CancellationError() }
    }

    static func reconnectDelay(attempt: Int) -> Duration {
        let bounded = min(max(attempt, 1), 5)
        return .milliseconds(min(250 * (1 << (bounded - 1)), 3_000))
    }

    private func beginConnect(target: GatewayPTYTarget, generation expected: UInt64) {
        guard connectTask == nil, isOnline, isForeground,
              generation == expected, self.target == target else { return }
        retryTask?.cancel()
        retryTask = nil
        publish(reconnectAttempt == 0 ? .connecting
                                     : .reconnecting(attempt: reconnectAttempt))
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fence = self.currentness
                let externalAuthority = self.externalAuthority
                let connected = try await self.operations.connect(target) {
                    candidate in
                    guard fence.matches(generation: expected, target: candidate)
                    else { return false }
                    return await externalAuthority(candidate)
                }
                guard !Task.isCancelled, self.generation == expected,
                      self.target == target else {
                    await connected.close()
                    return
                }
                self.connectTask = nil
                self.session = connected
                self.reconnectAttempt = 0
                self.publish(.open)
                self.startPump(connected, target: target, generation: expected)
            } catch {
                guard !Task.isCancelled, self.generation == expected,
                      self.target == target else { return }
                self.connectTask = nil
                guard await self.externalAuthority(target) else {
                    self.publish(.closed(GatewayPTYClose(
                        code: 4403, reason: "PTY target authority changed")))
                    return
                }
                if let close = Self.terminalClose(for: error) {
                    self.publish(close.kind == .processExited
                        ? .ended(close) : .closed(close))
                } else {
                    self.scheduleReconnect(target: target, generation: expected)
                }
            }
        }
    }

    private func startPump(_ connected: GatewayPTYSessionHandle,
                           target: GatewayPTYTarget, generation expected: UInt64) {
        let sessionID = connected.id
        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in connected.events {
                guard !Task.isCancelled, self.generation == expected,
                      self.target == target, self.session?.id == sessionID else {
                    return
                }
                switch event {
                case .opened:
                    continue
                case .bytes(let bytes):
                    self.continuation.yield(.bytes(bytes))
                case .closed(let close):
                    self.session = nil
                    self.pumpTask = nil
                    if close.kind.reconnectsAutomatically {
                        self.scheduleReconnect(target: target, generation: expected)
                    } else if close.kind == .processExited || close.kind == .ended {
                        self.publish(.ended(close))
                    } else {
                        self.publish(.closed(close))
                    }
                    return
                }
            }
            guard !Task.isCancelled, self.generation == expected,
                  self.target == target, self.session?.id == sessionID else { return }
            self.session = nil
            self.pumpTask = nil
            if await self.externalAuthority(target) {
                self.scheduleReconnect(target: target, generation: expected)
            } else {
                self.publish(.closed(GatewayPTYClose(
                    code: 4403, reason: "PTY target authority changed")))
            }
        }
    }

    private func scheduleReconnect(target: GatewayPTYTarget, generation expected: UInt64) {
        guard retryTask == nil, generation == expected, self.target == target else { return }
        guard isOnline, isForeground else {
            publish(.reconnecting(attempt: reconnectAttempt))
            return
        }
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let attempt = reconnectAttempt
        publish(.reconnecting(attempt: attempt))
        let delay = Self.reconnectDelay(attempt: attempt)
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.operations.sleep(delay) }
            catch { return }
            guard !Task.isCancelled, self.generation == expected,
                  self.target == target, self.isOnline, self.isForeground else { return }
            self.retryTask = nil
            self.beginConnect(target: target, generation: expected)
        }
    }

    private func suspendForRecovery() {
        guard target != nil else { return }
        generation &+= 1
        currentness.update(generation: generation, target: target)
        connectTask?.cancel(); connectTask = nil
        pumpTask?.cancel(); pumpTask = nil
        retryTask?.cancel(); retryTask = nil
        if let session {
            Task { await session.close() }
            self.session = nil
        }
        publish(.reconnecting(attempt: reconnectAttempt))
    }

    private func recoverIfNeeded(immediate: Bool = false) {
        guard let target, isOnline, isForeground,
              state != .open, connectTask == nil else { return }
        generation &+= 1
        let expected = generation
        currentness.update(generation: generation, target: target)
        retryTask?.cancel(); retryTask = nil
        if immediate { reconnectAttempt = max(1, reconnectAttempt) }
        beginConnect(target: target, generation: expected)
    }

    private func cancelTasksAndCloseSession() {
        connectTask?.cancel(); connectTask = nil
        pumpTask?.cancel(); pumpTask = nil
        retryTask?.cancel(); retryTask = nil
        if let session {
            Task { await session.close() }
            self.session = nil
        }
    }

    private func publish(_ state: GatewayPTYRuntimeState) {
        self.state = state
        continuation.yield(.state(state))
    }

    private static func terminalClose(for error: Error) -> GatewayPTYClose? {
        if case GatewayPTYError.closed(let close) = error { return close }
        switch error {
        case AuthError.unauthorized(let reason):
            return GatewayPTYClose(code: 4401, reason: reason)
        case AuthError.sessionExpired:
            return GatewayPTYClose(code: 4401, reason: "session expired")
        case GatewayPTYError.invalidTarget, GatewayPTYError.invalidURL:
            return GatewayPTYClose(code: 4404, reason: "invalid PTY target")
        default:
            return nil
        }
    }
}

import Foundation
import TalariaKit

/// Immutable identity for one `/api/pty` attachment. The generation belongs to
/// the caller's saved-gateway slot, not the PTY process; it prevents a late
/// socket from publishing into a replacement connection with the same id.
public struct GatewayPTYTarget: Equatable, Sendable {
    public var gatewayID: String
    public var connectionGeneration: UInt64
    public var baseURL: URL
    public var credential: GatewayCredential
    public var profile: String?
    public var resume: String?
    public var channel: String?
    public var fresh: Bool
    public var attach: String
    private var parametersAreValid: Bool

    public init(gatewayID: String, connectionGeneration: UInt64,
                baseURL: URL, credential: GatewayCredential,
                profile: String? = nil, resume: String? = nil,
                channel: String? = nil, fresh: Bool = false,
                attach: String) {
        self.gatewayID = gatewayID
        self.connectionGeneration = connectionGeneration
        self.baseURL = baseURL
        self.credential = credential
        let safeProfile = profile.flatMap { Self.optional($0, maximum: 128) }
        let safeResume = resume.flatMap { Self.optional($0, maximum: 512) }
        let safeChannel = channel.flatMap { Self.validChannel($0) }
        self.profile = safeProfile
        self.resume = safeResume
        self.channel = safeChannel
        self.fresh = fresh
        self.attach = Self.opaque(attach, maximum: 512) ?? ""
        parametersAreValid = (profile == nil || safeProfile.map(Self.validProfile) == true)
            && (resume == nil || safeResume != nil)
            && (channel == nil || safeChannel != nil)
            && !(fresh && resume != nil)
    }

    public var isValid: Bool {
        parametersAreValid && !gatewayID.isEmpty && baseURL.host() != nil && !attach.isEmpty
            && (baseURL.scheme == "http" || baseURL.scheme == "https")
    }

    private static func optional(_ value: String, maximum: Int) -> String? {
        opaque(value, maximum: maximum)
    }

    private static func opaque(_ value: String, maximum: Int) -> String? {
        guard !value.isEmpty, value.count <= maximum,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return value
    }

    private static func validChannel(_ value: String) -> String? {
        guard value.count <= 128,
              value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func validProfile(_ value: String) -> Bool {
        if value == "default" { return true }
        guard value.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#,
                          options: .regularExpression) != nil else { return false }
        return !["hermes", "test", "tmp", "root", "sudo"].contains(value)
    }
}

public enum GatewayPTYCloseKind: Equatable, Sendable {
    case unauthorized        // 4401
    case forbidden           // 4403 host/origin
    case unavailable         // 4404 embedded chat disabled
    case peerRejected        // 4408 non-loopback peer
    case superseded          // 4409 same attachment opened elsewhere
    case processExited       // 4410 child exited
    case serverFailure       // 1011, after the server's ANSI explanation
    case transient           // abnormal/network drop, including 1001/1006
    case ended               // clean/normal close

    public var reconnectsAutomatically: Bool {
        if case .transient = self { return true }
        return false
    }
}

public struct GatewayPTYClose: Equatable, Sendable {
    public var code: Int?
    public var reason: String?
    public var kind: GatewayPTYCloseKind

    public init(code: Int?, reason: String? = nil) {
        self.code = code
        self.reason = reason?.isEmpty == false ? reason : nil
        switch code {
        case 4401: kind = .unauthorized
        case 4403: kind = .forbidden
        case 4404: kind = .unavailable
        case 4408: kind = .peerRejected
        case 4409: kind = .superseded
        case 4410: kind = .processExited
        case 1011: kind = .serverFailure
        case 1000: kind = .ended
        case 1001, 1006, nil: kind = .transient
        default: kind = .ended
        }
    }
}

public enum GatewayPTYEvent: Equatable, Sendable {
    case opened
    case bytes(Data)
    case closed(GatewayPTYClose)
}

public enum GatewayPTYError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidURL
    case ticketTimedOut
    case connectTimedOut
    case notConnected
    case closed(GatewayPTYClose)
}

protocol GatewayPTYWireSocket: Sendable {
    func open() async throws
    func receive() async throws -> Data
    func send(_ bytes: Data) async throws
    func close() async
    func closeDetails() async -> (Int?, String?)
}

actor URLSessionGatewayPTYWireSocket: GatewayPTYWireSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    func open() async throws {
        task.resume()
        // A successful protocol ping proves the HTTP upgrade completed without
        // requiring the quiet PTY to emit application bytes first.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func receive() async throws -> Data {
        Self.bytes(from: try await task.receive())
    }

    func send(_ bytes: Data) async throws {
        try await task.send(.data(bytes))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func closeDetails() -> (Int?, String?) {
        let raw = Int(task.closeCode.rawValue)
        let code = raw == 0 ? nil : raw
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        return (code, reason)
    }

    static func bytes(from message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return Data()
        }
    }
}

/// One raw PTY socket. Reconnect ownership deliberately lives in
/// `GatewayPTYRuntime`; this actor owns exactly one freshly authenticated URL.
public actor GatewayPTYConnection {
    public typealias TicketMinter = @Sendable (URL, GatewayCredential) async throws -> String
    public typealias CredentialPreparer = @Sendable (
        URL, GatewayCredential
    ) async throws -> GatewayCredential
    public typealias CurrentnessCheck = @Sendable (GatewayPTYTarget) async -> Bool
    typealias SocketFactory = @Sendable (URL) -> any GatewayPTYWireSocket

    public nonisolated let events: AsyncStream<GatewayPTYEvent>
    private nonisolated let continuation: AsyncStream<GatewayPTYEvent>.Continuation
    public let target: GatewayPTYTarget

    private let ticketMinter: TicketMinter
    private let credentialPreparer: CredentialPreparer
    private let currentness: CurrentnessCheck
    private let socketFactory: SocketFactory
    private let ticketTimeout: Duration
    private let connectTimeout: Duration
    private var socket: (any GatewayPTYWireSocket)?
    private var receiveTask: Task<Void, Never>?
    private var finished = false

    public init(target: GatewayPTYTarget,
                ticketTimeout: Duration = .seconds(8),
                connectTimeout: Duration = .seconds(8),
                credentialPreparer: @escaping CredentialPreparer = {
                    try await GatewayPTYConnection.prepareCredential(
                        baseURL: $0, credential: $1)
                },
                currentness: @escaping CurrentnessCheck = { _ in true },
                ticketMinter: @escaping TicketMinter = { baseURL, credential in
                    try await GatewayAuthClient(baseURL: baseURL)
                        .mintWSTicket(credential: credential)
                }) {
        self.init(target: target, ticketTimeout: ticketTimeout,
                  connectTimeout: connectTimeout,
                  credentialPreparer: credentialPreparer,
                  currentness: currentness, ticketMinter: ticketMinter,
                  socketFactory: { URLSessionGatewayPTYWireSocket(url: $0) })
    }

    init(target: GatewayPTYTarget, ticketTimeout: Duration,
         connectTimeout: Duration,
         credentialPreparer: @escaping CredentialPreparer = { _, credential in credential },
         currentness: @escaping CurrentnessCheck = { _ in true },
         ticketMinter: @escaping TicketMinter,
         socketFactory: @escaping SocketFactory) {
        self.target = target
        self.ticketTimeout = ticketTimeout
        self.connectTimeout = connectTimeout
        self.credentialPreparer = credentialPreparer
        self.currentness = currentness
        self.ticketMinter = ticketMinter
        self.socketFactory = socketFactory
        var captured: AsyncStream<GatewayPTYEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingOldest(1)) {
            captured = $0
        }
        continuation = captured
    }

    public func connect() async throws {
        guard target.isValid else { throw GatewayPTYError.invalidTarget }
        guard socket == nil else { return }
        try await ensureCurrent()
        let url = try await authenticatedURL()
        try await ensureCurrent()
        let candidate = socketFactory(url)
        socket = candidate
        do {
            try await Self.withTimeout(connectTimeout,
                                       timeoutError: GatewayPTYError.connectTimedOut) {
                try await candidate.open()
            }
            try await ensureCurrent()
        } catch {
            let (code, reason) = await candidate.closeDetails()
            await candidate.close()
            socket = nil
            if let code {
                throw GatewayPTYError.closed(
                    GatewayPTYClose(code: code, reason: reason))
            }
            throw error
        }
        _ = await Self.yieldLosslessly(.opened, to: continuation)
        receiveTask = Task { [weak self] in await self?.receiveLoop(candidate) }
    }

    public func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        guard let socket, !finished else { throw GatewayPTYError.notConnected }
        try await ensureCurrent()
        try await socket.send(bytes)
        try await ensureCurrent()
    }

    public func resize(columns: Int, rows: Int) async throws {
        let columns = min(max(columns, 1), 10_000)
        let rows = min(max(rows, 1), 10_000)
        try await send(Data("\u{1b}[RESIZE:\(columns);\(rows)]".utf8))
    }

    public func close() async {
        guard !finished else { return }
        finished = true
        receiveTask?.cancel()
        receiveTask = nil
        await socket?.close()
        socket = nil
        continuation.finish()
    }

    static func makeURL(target: GatewayPTYTarget, ticket: String?,
                        credential: GatewayCredential? = nil) throws -> URL {
        let auth: URLQueryItem
        switch credential ?? target.credential {
        case .sessionToken(let token):
            auth = URLQueryItem(name: "token", value: token)
        case .oauth:
            guard let ticket, !ticket.isEmpty else {
                throw AuthError.protocolError("gated PTY requires a fresh ws ticket")
            }
            auth = URLQueryItem(name: "ticket", value: ticket)
        }
        var components = URLComponents(url: target.baseURL,
                                       resolvingAgainstBaseURL: false)
        components?.scheme = target.baseURL.scheme == "https" ? "wss" : "ws"
        if components?.path.hasSuffix("/") == true { components?.path.removeLast() }
        components?.path += "/api/pty"
        var query = [auth, URLQueryItem(name: "attach", value: target.attach)]
        if let channel = target.channel {
            query.append(URLQueryItem(name: "channel", value: channel))
        }
        if let resume = target.resume {
            query.append(URLQueryItem(name: "resume", value: resume))
        }
        if target.fresh { query.append(URLQueryItem(name: "fresh", value: "1")) }
        if let profile = target.profile {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw GatewayPTYError.invalidURL }
        return url
    }

    private func authenticatedURL() async throws -> URL {
        let prepared = try await Self.withTimeout(
            ticketTimeout, timeoutError: GatewayPTYError.ticketTimedOut
        ) { [credentialPreparer, currentness, ticketMinter, target] in
            let credential = try await credentialPreparer(
                target.baseURL, target.credential)
            guard !Task.isCancelled, await currentness(target) else {
                throw CancellationError()
            }
            let ticket: String?
            if case .oauth = credential {
                ticket = try await ticketMinter(target.baseURL, credential)
            } else {
                ticket = nil
            }
            return (credential, ticket)
        }
        try await ensureCurrent()
        return try Self.makeURL(target: target, ticket: prepared.1,
                                credential: prepared.0)
    }

    private func receiveLoop(_ socket: any GatewayPTYWireSocket) async {
        do {
            while !Task.isCancelled {
                let bytes = try await socket.receive()
                try await ensureCurrent()
                if !bytes.isEmpty {
                    let delivered = await Self.yieldLosslessly(
                        .bytes(bytes), to: continuation)
                    if !delivered { return }
                }
            }
        } catch {
            guard !finished else { return }
            guard !Task.isCancelled, await currentness(target) else {
                finished = true
                self.socket = nil
                await socket.close()
                continuation.finish()
                return
            }
            let (code, reason) = await socket.closeDetails()
            finished = true
            self.socket = nil
            _ = await Self.yieldLosslessly(
                .closed(GatewayPTYClose(code: code, reason: reason)), to: continuation)
            continuation.finish()
        }
    }

    private func ensureCurrent() async throws {
        guard !Task.isCancelled, await currentness(target) else {
            throw CancellationError()
        }
    }

    public static func prepareCredential(
        baseURL: URL, credential: GatewayCredential
    ) async throws -> GatewayCredential {
        // A prior PTY attempt may have rotated OAuth refresh tokens. Always
        // begin with the credential currently persisted for this gateway;
        // falling back to the captured value is only for isolated/test use.
        let authoritative = KeychainStore().load(for: baseURL) ?? credential
        guard case .oauth(let tokens) = authoritative, tokens.needsRefresh else {
            return authoritative
        }
        let auth = GatewayAuthClient(baseURL: baseURL)
        do {
            let refreshed = try await auth.refresh(tokens)
            let prepared = GatewayCredential.oauth(refreshed)
            try KeychainStore().save(prepared, for: baseURL)
            return prepared
        } catch AuthError.providerUnreachable {
            // Match GatewayClient: a temporarily unreachable IdP does not erase
            // a possibly-still-valid access token.
            return authoritative
        } catch AuthError.sessionExpired {
            KeychainStore().delete(for: baseURL)
            throw AuthError.sessionExpired
        }
    }

    private static func withTimeout<T: Sendable>(
        _ duration: Duration, timeoutError: @autoclosure @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw timeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func yieldLosslessly(
        _ event: GatewayPTYEvent,
        to continuation: AsyncStream<GatewayPTYEvent>.Continuation
    ) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(event) {
            case .enqueued: return true
            case .terminated: return false
            case .dropped:
                try? await Task.sleep(for: .milliseconds(1))
            @unknown default: return false
            }
        }
        return false
    }
}

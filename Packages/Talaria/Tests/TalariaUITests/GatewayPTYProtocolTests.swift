#if canImport(XCTest)
import XCTest
@testable import TalariaUI
import TalariaKit

private enum PTYTestFailure: Error { case closed, injected }

private actor FakePTYWireSocket: GatewayPTYWireSocket {
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private(set) var sent: [Data] = []
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private var closeCode: Int?
    private var closeReason: String?
    private var openError: Error?
    var hangOnOpen = false

    func open() async throws {
        openCount += 1
        if hangOnOpen { try await Task.sleep(for: .seconds(60)) }
        if let openError { throw openError }
    }

    func receive() async throws -> Data {
        if !buffered.isEmpty { return buffered.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(_ bytes: Data) { sent.append(bytes) }
    func close() {
        closeCount += 1
        waiter?.resume(throwing: PTYTestFailure.closed)
        waiter = nil
    }
    func closeDetails() -> (Int?, String?) { (closeCode, closeReason) }

    func yield(_ bytes: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: bytes)
        } else { buffered.append(bytes) }
    }
    func fail(code: Int?, reason: String? = nil) {
        closeCode = code; closeReason = reason
        waiter?.resume(throwing: PTYTestFailure.closed)
        waiter = nil
    }
    func rejectOpen(code: Int, reason: String) {
        closeCode = code; closeReason = reason; openError = PTYTestFailure.injected
    }
    func sentValues() -> [Data] { sent }
    func closeCountValue() -> Int { closeCount }
}

private actor PTYTicketProbe {
    private(set) var calls = 0
    var hangs = false

    func mint() async throws -> String {
        calls += 1
        if hangs { try await Task.sleep(for: .seconds(60)) }
        return "single-use-ticket"
    }
    func callCount() -> Int { calls }
}

private actor PTYAuthorityProbe {
    private var current = true
    func isCurrent() -> Bool { current }
    func invalidate() { current = false }
}

private actor PTYSessionProbe {
    private(set) var sent: [Data] = []
    private(set) var resized: [(Int, Int)] = []
    private(set) var closes = 0
    func send(_ data: Data) { sent.append(data) }
    func resize(_ columns: Int, _ rows: Int) { resized.append((columns, rows)) }
    func close() { closes += 1 }
    func sentValues() -> [Data] { sent }
    func resizeValues() -> [(Int, Int)] { resized }
    func closeCount() -> Int { closes }
}

private final class TestPTYSession: @unchecked Sendable {
    let probe = PTYSessionProbe()
    let handle: GatewayPTYSessionHandle
    private let continuation: AsyncStream<GatewayPTYEvent>.Continuation

    init() {
        var captured: AsyncStream<GatewayPTYEvent>.Continuation!
        let events = AsyncStream<GatewayPTYEvent> { captured = $0 }
        continuation = captured
        let probe = self.probe
        handle = GatewayPTYSessionHandle(
            events: events,
            send: { await probe.send($0) },
            resize: { await probe.resize($0, $1) },
            close: { await probe.close() })
    }

    func emit(_ event: GatewayPTYEvent) { continuation.yield(event) }
}

private actor PTYRuntimeBackend {
    private(set) var targets: [GatewayPTYTarget] = []
    private(set) var sessions: [TestPTYSession] = []
    private(set) var sleeps: [Duration] = []
    var connectError: Error?

    func connect(_ target: GatewayPTYTarget) throws -> GatewayPTYSessionHandle {
        targets.append(target)
        if let connectError { throw connectError }
        let session = TestPTYSession()
        sessions.append(session)
        return session.handle
    }

    func sleep(_ duration: Duration) { sleeps.append(duration) }
    func session(_ index: Int) -> TestPTYSession? {
        sessions.indices.contains(index) ? sessions[index] : nil
    }
    func connectCount() -> Int { targets.count }
    func sleepValues() -> [Duration] { sleeps }
    func targetValues() -> [GatewayPTYTarget] { targets }
}

@MainActor
final class GatewayPTYProtocolTests: XCTestCase {
    private let baseURL = URL(string: "https://gateway.example/prefix")!

    func testLegacyURLCarriesExactPTYParametersAndOpaqueAttach() throws {
        let target = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 4,
            baseURL: baseURL, credential: .sessionToken("legacy token"),
            profile: "reviewer", resume: "session/opaque?value",
            channel: "chat.mobile-1", fresh: true,
            attach: "tab/+ opaque?identity")
        let url = try GatewayPTYConnection.makeURL(target: target, ticket: nil)
        let components = try XCTUnwrap(URLComponents(url: url,
                                                      resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/prefix/api/pty")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }), [
                "token": "legacy token", "profile": "reviewer",
                "resume": "session/opaque?value", "channel": "chat.mobile-1",
                "fresh": "1", "attach": "tab/+ opaque?identity",
            ])
    }

    func testGatedURLUsesFreshTicketAndNeverLeaksBearerToken() throws {
        let tokens = TokenSet(accessToken: "secret-bearer", refreshToken: "refresh",
                              expiresAt: 999_999, provider: "nous", userID: nil)
        let target = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 8,
            baseURL: baseURL, credential: .oauth(tokens), attach: "tab-1")
        let url = try GatewayPTYConnection.makeURL(
            target: target, ticket: "one-shot")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "ticket" })?.value, "one-shot")
        XCTAssertNil(items.first(where: { $0.name == "token" }))
        XCTAssertFalse(url.absoluteString.contains("secret-bearer"))
    }

    func testInvalidChannelAndControlBearingOpaqueValuesFailClosed() {
        let target = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 1, baseURL: baseURL,
            credential: .sessionToken("token"), profile: "bad\nprofile",
            channel: "bad/channel", attach: "bad\u{0}attach")
        XCTAssertNil(target.profile)
        XCTAssertNil(target.channel)
        XCTAssertFalse(target.isValid)
        let freshResume = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 1, baseURL: baseURL,
            credential: .sessionToken("token"), resume: "session",
            fresh: true, attach: "tab")
        XCTAssertFalse(freshResume.isValid,
                       "fresh and explicit resume are contradictory authority")
        let unsafeProfile = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 1, baseURL: baseURL,
            credential: .sessionToken("token"), profile: "../root",
            attach: "tab")
        XCTAssertFalse(unsafeProfile.isValid)
    }

    func testTextAndBinaryFramesBecomeExactRawBytes() {
        XCTAssertEqual(URLSessionGatewayPTYWireSocket.bytes(from: .string("hé\u{1b}")),
                       Data("hé\u{1b}".utf8))
        XCTAssertEqual(URLSessionGatewayPTYWireSocket.bytes(from: .data(Data([0, 255, 7]))),
                       Data([0, 255, 7]))
    }

    func testConnectionReceivesBytesAndSendsRawAndExactResizeFrame() async throws {
        let socket = FakePTYWireSocket()
        let target = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 1, baseURL: baseURL,
            credential: .sessionToken("token"), attach: "tab")
        let connection = GatewayPTYConnection(
            target: target, ticketTimeout: .seconds(1), connectTimeout: .seconds(1),
            ticketMinter: { _, _ in XCTFail("legacy auth must not mint"); return "" },
            socketFactory: { _ in socket })
        var iterator = connection.events.makeAsyncIterator()

        try await connection.connect()
        let opened = await iterator.next()
        XCTAssertEqual(opened, .opened)
        await socket.yield(Data([0, 1, 255]))
        let received = await iterator.next()
        XCTAssertEqual(received, .bytes(Data([0, 1, 255])))
        try await connection.send(Data([3, 4]))
        try await connection.resize(columns: 132, rows: 47)

        let sent = await socket.sentValues()
        XCTAssertEqual(sent, [Data([3, 4]), Data("\u{1b}[RESIZE:132;47]".utf8)])
        await connection.close()
    }

    func testOAuthMintsExactlyOneTicketPerConnection() async throws {
        let probe = PTYTicketProbe()
        let socket = FakePTYWireSocket()
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 999_999, provider: "nous", userID: nil)
        let target = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 2, baseURL: baseURL,
            credential: .oauth(tokens), attach: "tab")
        let connection = GatewayPTYConnection(
            target: target, ticketTimeout: .seconds(1), connectTimeout: .seconds(1),
            ticketMinter: { _, _ in try await probe.mint() },
            socketFactory: { url in
                XCTAssertTrue(url.absoluteString.contains("ticket=single-use-ticket"))
                return socket
            })
        try await connection.connect()
        let calls = await probe.callCount()
        XCTAssertEqual(calls, 1)
        await connection.close()
    }

    func testOAuthCredentialPreparationPrecedesTicketMintAndURLBuild() async throws {
        let socket = FakePTYWireSocket()
        let stale = TokenSet(accessToken: "stale", refreshToken: "refresh",
                             expiresAt: 1, provider: "nous", userID: nil)
        let fresh = TokenSet(accessToken: "fresh", refreshToken: "new-refresh",
                             expiresAt: 9_999_999_999, provider: "nous", userID: nil)
        let target = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 2, baseURL: baseURL,
            credential: .oauth(stale), attach: "tab")
        let connection = GatewayPTYConnection(
            target: target, ticketTimeout: .seconds(1), connectTimeout: .seconds(1),
            credentialPreparer: { _, credential in
                XCTAssertEqual(credential, .oauth(stale))
                return .oauth(fresh)
            },
            ticketMinter: { _, credential in
                XCTAssertEqual(credential, .oauth(fresh))
                return "fresh-ticket"
            },
            socketFactory: { url in
                XCTAssertTrue(url.absoluteString.contains("ticket=fresh-ticket"))
                XCTAssertFalse(url.absoluteString.contains("stale"))
                return socket
            })
        try await connection.connect()
        await connection.close()
    }

    func testConnectionCurrentnessFenceStopsBeforeTicketOrSocket() async {
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 9_999_999_999, provider: "nous", userID: nil)
        let target = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 3, baseURL: baseURL,
            credential: .oauth(tokens), attach: "tab")
        let connection = GatewayPTYConnection(
            target: target, ticketTimeout: .seconds(1), connectTimeout: .seconds(1),
            currentness: { $0.connectionGeneration != 3 },
            ticketMinter: { _, _ in XCTFail("stale target must not mint"); return "" },
            socketFactory: { _ in XCTFail("stale target must not dial"); return FakePTYWireSocket() })
        do {
            try await connection.connect()
            XCTFail("stale target should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCurrentnessChangeDuringCredentialPreparationPreventsTicketMint() async {
        let authority = PTYAuthorityProbe()
        let tokens = TokenSet(accessToken: "stale", refreshToken: "refresh",
                              expiresAt: 1, provider: "nous", userID: nil)
        let target = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 3, baseURL: baseURL,
            credential: .oauth(tokens), attach: "tab")
        let connection = GatewayPTYConnection(
            target: target, ticketTimeout: .seconds(1), connectTimeout: .seconds(1),
            credentialPreparer: { _, credential in
                await authority.invalidate()
                return credential
            },
            currentness: { _ in await authority.isCurrent() },
            ticketMinter: { _, _ in
                XCTFail("invalidated target must not mint a ticket")
                return ""
            },
            socketFactory: { _ in
                XCTFail("invalidated target must not dial")
                return FakePTYWireSocket()
            })
        do {
            try await connection.connect()
            XCTFail("invalidated target should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTicketAndConnectPhasesAreIndependentlyBounded() async {
        let probe = PTYTicketProbe()
        await probe.setHangs(true)
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 999_999, provider: "nous", userID: nil)
        let oauthTarget = GatewayPTYTarget(
            gatewayID: "remote", connectionGeneration: 1, baseURL: baseURL,
            credential: .oauth(tokens), attach: "tab")
        let ticketTimeout = GatewayPTYConnection(
            target: oauthTarget, ticketTimeout: .milliseconds(1),
            connectTimeout: .seconds(1),
            ticketMinter: { _, _ in try await probe.mint() },
            socketFactory: { _ in FakePTYWireSocket() })
        do {
            try await ticketTimeout.connect()
            XCTFail("ticket timeout should fail")
        } catch {
            XCTAssertEqual(error as? GatewayPTYError, .ticketTimedOut)
        }

        let socket = FakePTYWireSocket()
        await socket.setHangOnOpen(true)
        let legacyTarget = GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: 1, baseURL: baseURL,
            credential: .sessionToken("token"), attach: "tab")
        let connectTimeout = GatewayPTYConnection(
            target: legacyTarget, ticketTimeout: .seconds(1),
            connectTimeout: .milliseconds(1), ticketMinter: { _, _ in "" },
            socketFactory: { _ in socket })
        do {
            try await connectTimeout.connect()
            XCTFail("connect timeout should fail")
        } catch {
            XCTAssertEqual(error as? GatewayPTYError, .connectTimedOut)
        }
        let closeCount = await socket.closeCountValue()
        XCTAssertEqual(closeCount, 1)
    }

    func testHandshakeRejectionPreservesExactServerCloseSemantics() async {
        let socket = FakePTYWireSocket()
        await socket.rejectOpen(code: 4403, reason: "host mismatch")
        let connection = GatewayPTYConnection(
            target: legacyTarget(generation: 1), ticketTimeout: .seconds(1),
            connectTimeout: .seconds(1), ticketMinter: { _, _ in "" },
            socketFactory: { _ in socket })
        do {
            try await connection.connect()
            XCTFail("rejected upgrade must fail")
        } catch GatewayPTYError.closed(let close) {
            XCTAssertEqual(close.code, 4403)
            XCTAssertEqual(close.reason, "host mismatch")
            XCTAssertEqual(close.kind, .forbidden)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExactCloseCodeSemantics() {
        XCTAssertEqual(GatewayPTYClose(code: 4401).kind, .unauthorized)
        XCTAssertEqual(GatewayPTYClose(code: 4403).kind, .forbidden)
        XCTAssertEqual(GatewayPTYClose(code: 4404).kind, .unavailable)
        XCTAssertEqual(GatewayPTYClose(code: 4408).kind, .peerRejected)
        XCTAssertEqual(GatewayPTYClose(code: 4409).kind, .superseded)
        XCTAssertEqual(GatewayPTYClose(code: 4410).kind, .processExited)
        XCTAssertEqual(GatewayPTYClose(code: 1011).kind, .serverFailure)
        XCTAssertTrue(GatewayPTYClose(code: 1006).kind.reconnectsAutomatically)
        XCTAssertFalse(GatewayPTYClose(code: 1011).kind.reconnectsAutomatically)
    }

    func testTransientCloseReconnectsWithBackoffAndTerminalCloseStops() async {
        let backend = PTYRuntimeBackend()
        let runtime = makeRuntime(backend)
        let target = legacyTarget(generation: 1)

        runtime.start(target)
        await waitUntil { await backend.connectCount() == 1 && runtime.state == .open }
        let first = await backend.session(0)
        first?.emit(.closed(GatewayPTYClose(code: 1006, reason: "radio")))
        await waitUntil { await backend.connectCount() == 2 && runtime.state == .open }
        let sleeps = await backend.sleepValues()
        XCTAssertEqual(sleeps, [.milliseconds(250)])

        let second = await backend.session(1)
        second?.emit(.closed(GatewayPTYClose(code: 4401, reason: "auth")))
        await waitUntil {
            if case .closed(let close) = runtime.state { return close.code == 4401 }
            return false
        }
        for _ in 0..<20 { await Task.yield() }
        let connectCount = await backend.connectCount()
        XCTAssertEqual(connectCount, 2)
    }

    func testTargetGenerationFencesLateFramesAndClose() async {
        let backend = PTYRuntimeBackend()
        let runtime = makeRuntime(backend)
        runtime.start(legacyTarget(generation: 1))
        await waitUntil { await backend.connectCount() == 1 && runtime.state == .open }
        let stale = await backend.session(0)

        runtime.start(legacyTarget(generation: 2))
        await waitUntil { await backend.connectCount() == 2 && runtime.state == .open }
        stale?.emit(.bytes(Data("stale".utf8)))
        stale?.emit(.closed(GatewayPTYClose(code: 4401)))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(runtime.target?.connectionGeneration, 2)
        XCTAssertEqual(runtime.state, .open)
        let staleCloses = await stale?.probe.closeCount()
        XCTAssertEqual(staleCloses, 1)
    }

    func testExternalAuthorityFailsClosedBeforeRuntimeConnector() async {
        let backend = PTYRuntimeBackend()
        let runtime = GatewayPTYRuntime(
            operations: GatewayPTYRuntimeOperations(
                connect: { target, currentness in
                    guard await currentness(target) else { throw CancellationError() }
                    return try await backend.connect(target)
                }, sleep: { await backend.sleep($0) }),
            externalAuthority: { _ in false })
        runtime.start(legacyTarget(generation: 5))
        await waitUntil {
            if case .closed(let close) = runtime.state { return close.code == 4403 }
            return false
        }
        let connects = await backend.connectCount()
        let sleeps = await backend.sleepValues()
        XCTAssertEqual(connects, 0)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testOfflineAndForegroundRecoveryRedialExactTarget() async {
        let backend = PTYRuntimeBackend()
        let runtime = makeRuntime(backend)
        let target = legacyTarget(generation: 9)
        runtime.start(target)
        await waitUntil { await backend.connectCount() == 1 && runtime.state == .open }

        runtime.setOnline(false)
        XCTAssertEqual(runtime.state, .reconnecting(attempt: 0))
        runtime.setOnline(true)
        await waitUntil { await backend.connectCount() == 2 && runtime.state == .open }
        runtime.setForeground(false)
        XCTAssertEqual(runtime.state, .reconnecting(attempt: 0))
        runtime.recoverNow()
        let backgroundConnectCount = await backend.connectCount()
        XCTAssertEqual(backgroundConnectCount, 2)
        runtime.setForeground(true)
        await waitUntil { await backend.connectCount() == 3 && runtime.state == .open }
        let generations = (await backend.targetValues()).map(\.connectionGeneration)
        XCTAssertEqual(generations, [9, 9, 9])
    }

    func testReconnectBackoffMatchesPinnedHermesLadder() {
        XCTAssertEqual((1...7).map(GatewayPTYRuntime.reconnectDelay), [
            .milliseconds(250), .milliseconds(500), .milliseconds(1_000),
            .milliseconds(2_000), .milliseconds(3_000),
            .milliseconds(3_000), .milliseconds(3_000),
        ])
    }

    private func legacyTarget(generation: UInt64) -> GatewayPTYTarget {
        GatewayPTYTarget(
            gatewayID: "mini", connectionGeneration: generation,
            baseURL: baseURL, credential: .sessionToken("token"),
            profile: "default", channel: "mobile", attach: "tab")
    }

    private func makeRuntime(_ backend: PTYRuntimeBackend) -> GatewayPTYRuntime {
        GatewayPTYRuntime(operations: GatewayPTYRuntimeOperations(
            connect: { target, currentness in
                guard await currentness(target) else { throw CancellationError() }
                return try await backend.connect(target)
            },
            sleep: { await backend.sleep($0) }))
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<20_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for PTY runtime", file: file, line: line)
    }
}

private extension PTYTicketProbe {
    func setHangs(_ value: Bool) { hangs = value }
}

private extension FakePTYWireSocket {
    func setHangOnOpen(_ value: Bool) { hangOnOpen = value }
}
#endif

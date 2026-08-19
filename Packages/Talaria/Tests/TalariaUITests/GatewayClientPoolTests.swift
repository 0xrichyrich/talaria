#if canImport(XCTest)
import XCTest
import TalariaKit
@testable import TalariaUI

private actor ConnectorCounter {
    var calls = 0
    var failNext = false

    func record() throws {
        calls += 1
        if failNext {
            failNext = false
            throw URLError(.cannotConnectToHost)
        }
    }

    func setFailNext() { failNext = true }
}

final class GatewayClientPoolTests: XCTestCase {
    private let url = URL(string: "https://gateway.example")!
    private let credential = GatewayCredential.sessionToken("test-token")

    func testConcurrentLookupsReuseOneClient() async throws {
        let counter = ConnectorCounter()
        let pool = GatewayClientPool { baseURL, credential in
            try await counter.record()
            return GatewayClient(baseURL: baseURL, credential: credential)
        }

        async let first = pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        async let second = pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let (a, b) = try await (first, second)
        let calls = await counter.calls
        let connected = await pool.connectedGatewayIDs()

        XCTAssertEqual(ObjectIdentifier(a), ObjectIdentifier(b))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(connected, ["one"])
        await pool.disconnectAll()
    }

    func testFailedConnectionIsEvictedAndCanRetry() async throws {
        let counter = ConnectorCounter()
        await counter.setFailNext()
        let pool = GatewayClientPool { baseURL, credential in
            try await counter.record()
            return GatewayClient(baseURL: baseURL, credential: credential)
        }

        do {
            _ = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
            XCTFail("first connection should fail")
        } catch {
            let failedClient = await pool.client(for: "one")
            XCTAssertNil(failedClient)
        }

        _ = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let calls = await counter.calls
        let connectedClient = await pool.client(for: "one")
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(connectedClient)
        await pool.disconnectAll()
    }

    func testDifferentGatewaysNeverShareAClient() async throws {
        let pool = GatewayClientPool { baseURL, credential in
            GatewayClient(baseURL: baseURL, credential: credential)
        }
        let a = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let b = try await pool.connect(gatewayID: "two", baseURL: url, credential: credential)
        let connected = await pool.connectedGatewayIDs()

        XCTAssertNotEqual(ObjectIdentifier(a), ObjectIdentifier(b))
        XCTAssertEqual(connected, ["one", "two"])
        await pool.disconnectAll()
    }
}
#endif

import Foundation
import Testing
import TalariaKit
@testable import TalariaUI

private actor InvocationFlag {
    private var value = false
    func mark() { value = true }
    func read() -> Bool { value }
}

@Suite("Static REST lifecycle admission", .serialized)
struct StaticRESTTrafficAdmissionTests {
    @Test @MainActor func ordinaryRESTLeaseSpansTheWholeOperation() async throws {
        let base = try #require(URL(string: "https://rest-fence-\(UUID().uuidString).example"))
        let gateway = try #require(ConnectionRegistry.shared.upsert(
            urlString: base.absoluteString, name: "REST fence"))
        defer { ConnectionRegistry.shared.remove(id: gateway.id) }

        let result = try await GatewayREST.withTrafficLease(baseURL: base) {
            let lifecycleEntered = await MainActor.run {
                ProfileLifecycleTrafficAdmission.beginLifecycle(gateway.id)
            }
            return lifecycleEntered
        }

        #expect(!result)
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gateway.id))
        ProfileLifecycleTrafficAdmission.endLifecycle(gateway.id)
    }

    @Test @MainActor func fencedStaticRESTNeverStartsItsOperation() async throws {
        let base = try #require(URL(string: "https://rest-held-\(UUID().uuidString).example"))
        let gateway = try #require(ConnectionRegistry.shared.upsert(
            urlString: base.absoluteString, name: "REST held"))
        defer {
            ProfileLifecycleTrafficAdmission.endLifecycle(gateway.id)
            ConnectionRegistry.shared.remove(id: gateway.id)
        }
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gateway.id))

        let invoked = InvocationFlag()
        do {
            _ = try await GatewayREST.withTrafficLease(baseURL: base) {
                await invoked.mark()
                return true
            }
            Issue.record("fenced REST unexpectedly acquired an ordinary lease")
        } catch let error as GatewayError {
            #expect(error.code == GatewayClient.trafficFenced)
        }
        #expect(!(await invoked.read()))
    }
}

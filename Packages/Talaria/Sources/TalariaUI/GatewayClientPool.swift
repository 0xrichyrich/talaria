import Foundation
import TalariaKit

/// Long-lived gateway clients keyed by saved-connection id.
///
/// The primary app connection remains authoritative for global navigation
/// while the pool is introduced. Remote bot and room operations obtain their
/// owning client here instead of tearing that primary world down. Concurrent
/// callers share one connection attempt, and a failed attempt is evicted so a
/// later foreground/reachability event can retry.
public actor GatewayClientPool {
    public typealias Connector = @Sendable (URL, GatewayCredential) async throws -> GatewayClient

    /// The exact pooled connection a caller started work against. The client
    /// identity alone is not enough: `adopt` can replace it with another
    /// client, and a later slot can theoretically reuse the same object in a
    /// test or reconnect path. The slot generation closes both races.
    public struct ConnectionSnapshot: Sendable {
        public let client: GatewayClient
        public let generation: UInt64

        public init(client: GatewayClient, generation: UInt64) {
            self.client = client
            self.generation = generation
        }
    }

    /// A short critical-section lease for source teardown or roster
    /// publication. Pool adoption waits while the lease is held, so a caller
    /// cannot re-check a snapshot and then mutate AppModel/registry state after
    /// a replacement has already won the slot.
    public struct ConnectionLease: Sendable {
        public let snapshot: ConnectionSnapshot
        public let gatewayID: String
        fileprivate let token: UUID

        fileprivate init(snapshot: ConnectionSnapshot, gatewayID: String) {
            self.snapshot = snapshot
            self.gatewayID = gatewayID
            self.token = UUID()
        }
    }

    private struct Slot {
        var generation: UInt64
        var task: Task<GatewayClient, Error>?
        var client: GatewayClient?
        var leaseToken: UUID?
    }

    private var slots: [String: Slot] = [:]
    private var nextGeneration: UInt64 = 0
    private let connector: Connector
    private var leaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {
        connector = { baseURL, credential in
            let client = GatewayClient(baseURL: baseURL, credential: credential)
            try await client.connect()
            return client
        }
    }

    /// Test/support initializer. Production uses the connecting initializer
    /// above; an injected connector makes coalescing and retry behavior
    /// deterministic without opening a network socket.
    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    public func client(for gatewayID: String) -> GatewayClient? {
        slots[gatewayID]?.client
    }

    public func connectedGatewayIDs() -> Set<String> {
        Set(slots.compactMap { key, slot in slot.client == nil ? nil : key })
    }

    /// Return the existing live client, share an in-flight dial, or start one.
    public func connect(gatewayID: String, baseURL: URL,
                        credential: GatewayCredential) async throws -> GatewayClient {
        try await connectWithGeneration(gatewayID: gatewayID, baseURL: baseURL,
                                        credential: credential).client
    }

    /// The same coalesced connection operation as `connect`, carrying the
    /// generation that owns the returned client. Callers that may outlive a
    /// reconnect use this instead of trying to read the generation in a
    /// second actor hop.
    public func connectWithGeneration(
        gatewayID: String, baseURL: URL, credential: GatewayCredential
    ) async throws -> ConnectionSnapshot {
        if let slot = slots[gatewayID], let client = slot.client {
            return ConnectionSnapshot(client: client, generation: slot.generation)
        }
        if let slot = slots[gatewayID], let task = slot.task {
            let client = try await task.value
            guard let current = slots[gatewayID], current.generation == slot.generation else {
                await client.disconnect()
                throw CancellationError()
            }
            return ConnectionSnapshot(client: client, generation: current.generation)
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let connector = self.connector
        let task = Task { try await connector(baseURL, credential) }
        slots[gatewayID] = Slot(generation: generation, task: task, client: nil,
                                 leaseToken: nil)

        do {
            let client = try await task.value
            guard slots[gatewayID]?.generation == generation else {
                await client.disconnect()
                throw CancellationError()
            }
            await installLifecycleAdmission(on: client, gatewayID: gatewayID)
            slots[gatewayID] = Slot(generation: generation, task: nil, client: client,
                                     leaseToken: nil)
            return ConnectionSnapshot(client: client, generation: generation)
        } catch {
            if slots[gatewayID]?.generation == generation { slots[gatewayID] = nil }
            throw error
        }
    }

    /// Whether this exact client still owns the named slot.
    public func isCurrent(_ snapshot: ConnectionSnapshot, for gatewayID: String) -> Bool {
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client else { return false }
        return ObjectIdentifier(client) == ObjectIdentifier(snapshot.client)
    }

    /// Reserve the current slot for one short source-qualified mutation. The
    /// reservation is acquired on the pool actor; once it succeeds, `adopt`
    /// and ordinary disconnects wait until `release` (or the guarded
    /// disconnect) completes.
    public func acquireLease(_ snapshot: ConnectionSnapshot,
                             for gatewayID: String) async -> ConnectionLease? {
        await waitForLease(gatewayID: gatewayID)
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client,
              ObjectIdentifier(client) == ObjectIdentifier(snapshot.client),
              slot.leaseToken == nil else { return nil }
        let lease = ConnectionLease(snapshot: snapshot, gatewayID: gatewayID)
        slots[gatewayID]?.leaseToken = lease.token
        return lease
    }

    /// Release a critical-section lease without disconnecting its client.
    public func release(_ lease: ConnectionLease) {
        guard slots[lease.gatewayID]?.leaseToken == lease.token else { return }
        slots[lease.gatewayID]?.leaseToken = nil
        resumeLeaseWaiters(gatewayID: lease.gatewayID)
    }

    /// Disconnect only if the slot still belongs to the expected connection.
    /// This check and removal are one actor operation, so an old roster
    /// failure cannot disconnect a client adopted after that failure began.
    @discardableResult
    public func disconnectIfCurrent(_ snapshot: ConnectionSnapshot,
                                    for gatewayID: String,
                                    lease: ConnectionLease? = nil) async -> Bool {
        let ownedLease: ConnectionLease?
        if let lease {
            ownedLease = lease
        } else {
            // Preserve the original conditional-disconnect API for callers
            // that do not also own a cleanup section. Acquiring a lease here
            // still makes the identity check and slot removal safe against a
            // concurrent adoption; the registry path passes its existing
            // lease so AppModel cleanup and removal remain one section.
            ownedLease = await acquireLease(snapshot, for: gatewayID)
        }
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client,
              ObjectIdentifier(client) == ObjectIdentifier(snapshot.client),
              let ownedLease,
              slot.leaseToken == ownedLease.token else {
            if lease == nil, let ownedLease { release(ownedLease) }
            return false
        }
        slots[gatewayID] = nil
        resumeLeaseWaiters(gatewayID: gatewayID)
        await client.disconnect()
        return true
    }

    /// Register a client already connected by the primary AppModel path.
    /// Replacing a different pooled client closes the old one after the new
    /// identity is installed, so a re-entrant lookup never returns the loser.
    public func adopt(_ client: GatewayClient, for gatewayID: String) async {
        await waitForLease(gatewayID: gatewayID)
        let previous = slots[gatewayID]
        await installLifecycleAdmission(on: client, gatewayID: gatewayID)
        nextGeneration &+= 1
        slots[gatewayID] = Slot(generation: nextGeneration, task: nil, client: client,
                                 leaseToken: nil)

        previous?.task?.cancel()
        if let old = previous?.client, ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        } else if let task = previous?.task, let old = try? await task.value,
                  ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        }
    }

    public func disconnect(gatewayID: String) async {
        await waitForLease(gatewayID: gatewayID)
        guard let slot = slots.removeValue(forKey: gatewayID) else { return }
        slot.task?.cancel()
        if let client = slot.client {
            await client.disconnect()
        } else if let task = slot.task, let client = try? await task.value {
            await client.disconnect()
        }
    }

    public func disconnectAll() async {
        let ids = Array(slots.keys)
        for id in ids { await disconnect(gatewayID: id) }
    }

    private func installLifecycleAdmission(on client: GatewayClient, gatewayID: String) async {
        await client.setTrafficAdmission {
            await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
        }
    }

    private func waitForLease(gatewayID: String) async {
        guard slots[gatewayID]?.leaseToken != nil else { return }
        await withCheckedContinuation { continuation in
            leaseWaiters[gatewayID, default: []].append(continuation)
        }
    }

    private func resumeLeaseWaiters(gatewayID: String) {
        let waiters = leaseWaiters.removeValue(forKey: gatewayID) ?? []
        for waiter in waiters { waiter.resume() }
    }
}

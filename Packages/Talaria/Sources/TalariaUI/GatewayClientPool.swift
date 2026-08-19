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

    private struct Slot {
        var generation: UInt64
        var task: Task<GatewayClient, Error>?
        var client: GatewayClient?
    }

    private var slots: [String: Slot] = [:]
    private var nextGeneration: UInt64 = 0
    private let connector: Connector

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
        if let client = slots[gatewayID]?.client { return client }
        if let task = slots[gatewayID]?.task { return try await task.value }

        nextGeneration &+= 1
        let generation = nextGeneration
        let connector = self.connector
        let task = Task { try await connector(baseURL, credential) }
        slots[gatewayID] = Slot(generation: generation, task: task, client: nil)

        do {
            let client = try await task.value
            guard slots[gatewayID]?.generation == generation else {
                await client.disconnect()
                throw CancellationError()
            }
            slots[gatewayID] = Slot(generation: generation, task: nil, client: client)
            return client
        } catch {
            if slots[gatewayID]?.generation == generation { slots[gatewayID] = nil }
            throw error
        }
    }

    /// Register a client already connected by the primary AppModel path.
    /// Replacing a different pooled client closes the old one after the new
    /// identity is installed, so a re-entrant lookup never returns the loser.
    public func adopt(_ client: GatewayClient, for gatewayID: String) async {
        let previous = slots[gatewayID]
        nextGeneration &+= 1
        slots[gatewayID] = Slot(generation: nextGeneration, task: nil, client: client)

        previous?.task?.cancel()
        if let old = previous?.client, ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        } else if let task = previous?.task, let old = try? await task.value,
                  ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        }
    }

    public func disconnect(gatewayID: String) async {
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
}

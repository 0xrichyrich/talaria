import Foundation
import TalariaKit

/// `profiles.configure` merges `ui_meta` only at the top level, so every
/// writer of `ui_meta["hermes-bots"]` must serialize its fresh
/// read/merge/write cycle. Without one shared gate, a room-membership save can
/// erase a concurrent canonical-chat pin or appearance edit even when both
/// callers individually preserve unknown keys.
@MainActor
final class BotModeMetaMutationGate {
    static let shared = BotModeMetaMutationGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held: Set<GatewayBotRoute> = []
    private var waiters: [GatewayBotRoute: [Waiter]] = [:]

    func queuedWaiterCount(for route: GatewayBotRoute) -> Int {
        waiters[route]?.count ?? 0
    }

    func acquire(_ route: GatewayBotRoute) async -> Bool {
        guard !Task.isCancelled else { return false }
        if held.insert(route).inserted { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[route, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(route, waiterID: id) }
        }
    }

    private func cancel(_ route: GatewayBotRoute, waiterID: UUID) {
        guard var queue = waiters[route],
              let index = queue.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { waiters.removeValue(forKey: route) }
        else { waiters[route] = queue }
        waiter.continuation.resume(returning: false)
    }

    func release(_ route: GatewayBotRoute) {
        if var queue = waiters[route], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiters.removeValue(forKey: route) }
            else { waiters[route] = queue }
            next.continuation.resume(returning: true)
            return
        }
        held.remove(route)
    }
}

extension AppModel {
    /// Hold exact profile ownership for the complete server read/merge/write.
    /// The operation remains on MainActor, while its network awaits yield to
    /// unrelated routes; only another mutation of this same source profile is
    /// queued.
    func withBotModeMetaMutation<T>(
        route: GatewayBotRoute,
        _ operation: () async throws -> T
    ) async throws -> T {
        let gate = BotModeMetaMutationGate.shared
        guard await gate.acquire(route) else { throw CancellationError() }
        defer { gate.release(route) }
        try Task.checkCancellation()
        return try await operation()
    }
}

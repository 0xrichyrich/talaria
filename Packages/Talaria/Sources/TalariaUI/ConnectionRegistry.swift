import Foundation
import Observation
import TalariaKit

// The persistent registry behind Connections → Gateways. Metadata (name, kind,
// normalized base URL, last roster size) lives in UserDefaults; credentials
// live only in the Keychain, keyed by the normalized base URL — the iOS
// analogue of desktop's safeStorage-encrypted connection store.
//
// Health probes hit the public `GET /api/status` endpoint (no auth required)
// via GatewayAuthClient.status(), measuring round-trip time for the ping
// column. Bot counts come from profiles.list once a live link is up and are
// cached so rows stay populated while a gateway is unreachable.

/// One saved gateway — metadata only, never credentials.
public struct SavedGateway: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: ConnectionKind
    /// Normalized base URL string (output of GatewayURL.normalize).
    public var urlString: String
    /// Last known roster size, refreshed from profiles.list once connected.
    public var lastBotCount: Int

    public var baseURL: URL? { URL(string: urlString) }

    public init(id: String = UUID().uuidString, name: String, kind: ConnectionKind,
                urlString: String, lastBotCount: Int = 0) {
        self.id = id; self.name = name; self.kind = kind
        self.urlString = urlString; self.lastBotCount = lastBotCount
    }
}

@MainActor
@Observable
public final class ConnectionRegistry {
    public static let shared = ConnectionRegistry()
    public static let defaultsKey = "talaria-gateways"

    /// Latest health-probe result for one saved gateway.
    public struct Health: Sendable, Equatable {
        public var state: ConnectionState
        /// Measured round trip of GET /api/status, when reachable.
        public var pingMS: Int?
        public var version: String?
        public var authRequired: Bool

        public init(state: ConnectionState, pingMS: Int? = nil,
                    version: String? = nil, authRequired: Bool = false) {
            self.state = state; self.pingMS = pingMS
            self.version = version; self.authRequired = authRequired
        }
    }

    public private(set) var saved: [SavedGateway] = []
    public private(set) var health: [String: Health] = [:]

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    /// Short-timeout session so a sleeping LAN box fails fast, not in 60 s.
    private let probeSession: URLSession
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        self.probeSession = URLSession(configuration: config)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([SavedGateway].self, from: data) {
            saved = list
        }
    }

    // MARK: - CRUD (metadata → UserDefaults, credential → Keychain)

    /// Add or update a gateway. The URL is normalized like desktop's
    /// connection-config; an existing row with the same normalized URL is
    /// updated in place so re-adding never duplicates.
    @discardableResult
    public func upsert(urlString: String, name: String? = nil, kind: ConnectionKind? = nil,
                       credential: GatewayCredential? = nil) -> SavedGateway? {
        guard let base = GatewayURL.normalize(urlString) else { return nil }
        if let credential { try? keychain.save(credential, for: base) }
        let normalized = base.absoluteString
        if let idx = saved.firstIndex(where: { $0.urlString == normalized }) {
            if let name, !name.isEmpty { saved[idx].name = name }
            if let kind { saved[idx].kind = kind }
            persist()
            return saved[idx]
        }
        let row = SavedGateway(name: (name?.isEmpty == false ? name! : nil) ?? base.host() ?? normalized,
                               kind: kind ?? Self.inferKind(host: base.host() ?? ""),
                               urlString: normalized)
        saved.append(row)
        persist()
        return row
    }

    public func remove(id: String) {
        guard let idx = saved.firstIndex(where: { $0.id == id }) else { return }
        if let base = saved[idx].baseURL { keychain.delete(for: base) }
        health.removeValue(forKey: id)
        saved.remove(at: idx)
        persist()
    }

    public func rename(id: String, to name: String) {
        guard let idx = saved.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        saved[idx].name = name
        persist()
    }

    public func gateway(forURL url: URL) -> SavedGateway? {
        saved.first { $0.urlString == url.absoluteString }
    }

    public func credential(for gateway: SavedGateway) -> GatewayCredential? {
        gateway.baseURL.flatMap { keychain.load(for: $0) }
    }

    public func setCredential(_ credential: GatewayCredential, for gateway: SavedGateway) {
        guard let base = gateway.baseURL else { return }
        try? keychain.save(credential, for: base)
    }

    // MARK: - Live-link feedback

    /// Roster size from profiles.list once a live connection is up.
    public func noteBotCount(_ count: Int, forURL url: URL) {
        guard let idx = saved.firstIndex(where: { $0.urlString == url.absoluteString }),
              saved[idx].lastBotCount != count else { return }
        saved[idx].lastBotCount = count
        persist()
    }

    /// Direct state report from the live WS link (connect / drop) so the row
    /// flips without waiting for the next HTTP probe.
    public func noteState(_ state: ConnectionState, pingMS: Int? = nil, forURL url: URL) {
        guard let row = gateway(forURL: url) else { return }
        var h = health[row.id] ?? Health(state: state)
        h.state = state
        if let pingMS { h.pingMS = pingMS }
        if state == .offline || state == .asleep { h.pingMS = nil }
        health[row.id] = h
    }

    // MARK: - Health probes

    /// Keep the rows fresh while the Connections screen (or the app) is in
    /// the foreground: probe now, then on an interval. Idempotent.
    public func startAutoProbe(every seconds: TimeInterval = 20) {
        stopAutoProbe()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stopAutoProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Probe every saved gateway in parallel.
    public func probeAll() async {
        let rows = saved
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask { [weak self] in await self?.probe(row) }
            }
        }
    }

    /// One async health probe: GET /api/status with a measured round trip.
    /// Timeout reads as `asleep` (host not answering — likely a sleeping
    /// machine); any other failure reads as `offline`.
    public func probe(_ gateway: SavedGateway) async {
        guard let base = gateway.baseURL else {
            health[gateway.id] = Health(state: .offline)
            return
        }
        health[gateway.id] = Health(state: .connecting,
                                    pingMS: health[gateway.id]?.pingMS,
                                    version: health[gateway.id]?.version,
                                    authRequired: health[gateway.id]?.authRequired ?? false)
        let auth = GatewayAuthClient(baseURL: base, session: probeSession)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let status = try await auth.status()
            let elapsed = start.duration(to: clock.now)
            let ms = max(1, Int((elapsed / .milliseconds(1)).rounded()))
            health[gateway.id] = Health(state: .connected, pingMS: ms,
                                        version: status.version,
                                        authRequired: status.authRequired)
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            health[gateway.id] = Health(state: timedOut ? .asleep : .offline)
        }
    }

    // MARK: - Rows for the Connections screen

    /// Saved gateways as display rows (AppModel.connections shape).
    public var rows: [GatewayConnection] {
        saved.map { gw in
            let h = health[gw.id]
            return GatewayConnection(
                id: gw.id,
                name: gw.name,
                kind: gw.kind,
                address: Self.address(for: gw),
                state: h?.state ?? .offline,
                ping: h?.pingMS.map { "\($0)ms" } ?? "—",
                botCount: gw.lastBotCount)
        }
    }

    // MARK: - Helpers

    static func address(for gateway: SavedGateway) -> String {
        guard let url = gateway.baseURL, let host = url.host() else { return gateway.urlString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// Best-guess kind from the host: Tailscale CGNAT / MagicDNS → tailscale,
    /// RFC1918 + .local + loopback → lan, everything else → cloud.
    static func inferKind(host: String) -> ConnectionKind {
        let h = host.lowercased()
        if h.hasSuffix(".ts.net") { return .tailscale }
        if h == "localhost" || h.hasSuffix(".local") { return .lan }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 100, (64...127).contains(parts[1]) { return .tailscale }
            if parts[0] == 10 { return .lan }
            if parts[0] == 127 { return .lan }
            if parts[0] == 192, parts[1] == 168 { return .lan }
            if parts[0] == 172, (16...31).contains(parts[1]) { return .lan }
            if parts[0] == 169, parts[1] == 254 { return .lan }
        }
        return .cloud
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

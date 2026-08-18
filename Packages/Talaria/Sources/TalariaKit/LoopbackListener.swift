import Foundation
import Network

/// Minimal one-shot HTTP listener on 127.0.0.1 for the native PKCE redirect
/// (RFC 8252 §7.3). The gateway 302s the system browser to
/// `http://127.0.0.1:<port>/callback?code=…&state=…` (or `?error=…`);
/// we answer with a tiny "return to Talaria" page and hand the query back.
public actor LoopbackListener {
    public struct Callback: Sendable {
        public var code: String?
        public var state: String?
        public var error: String?
        public var errorDescription: String?
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?

    public init() {}

    /// Start listening on an ephemeral port; returns the bound port.
    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            self?.receive(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))

        // Wait briefly for the port to be assigned.
        var attempts = 0
        while listener.port == nil, attempts < 100 {
            usleep(10_000)
            attempts += 1
        }
        guard let port = listener.port?.rawValue else {
            throw AuthError.protocolError("loopback listener failed to bind")
        }
        return port
    }

    /// Await the browser redirect. Times out after `timeout` seconds
    /// (desktop uses 5 minutes).
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        try await withThrowingTaskGroup(of: Callback.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AuthError.flowCancelled
            }
            guard let result = try await group.next() else { throw AuthError.flowCancelled }
            group.cancelAll()
            self.stop()
            return result
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: AuthError.flowCancelled)
        continuation = nil
    }

    private func setContinuation(_ cont: CheckedContinuation<Callback, Error>) {
        continuation = cont
    }

    private nonisolated func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
            guard error == nil, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { await self.handleRequest(text, connection: connection) }
        }
    }

    private func handleRequest(_ text: String, connection: NWConnection) {
        // Request line: GET /callback?code=...&state=... HTTP/1.1
        let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"

        var cb = Callback()
        if let comps = URLComponents(string: target) {
            for item in comps.queryItems ?? [] {
                switch item.name {
                case "code": cb.code = item.value
                case "state": cb.state = item.value
                case "error": cb.error = item.value
                case "error_description": cb.errorDescription = item.value
                default: break
                }
            }
        }

        let body = """
        <!doctype html><meta charset="utf-8"><title>Talaria</title>\
        <body style="font-family:-apple-system,sans-serif;background:#05070A;color:#EAF4EC;\
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">\
        <div style="text-align:center"><div style="font-size:40px">☤</div>\
        <p>Signed in. Return to <b>Talaria</b>.</p></div>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        // Ignore stray requests (favicon etc.) that carry no result.
        guard cb.code != nil || cb.error != nil else { return }
        continuation?.resume(returning: cb)
        continuation = nil
    }
}

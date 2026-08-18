import Foundation
import Observation
import TalariaKit
#if os(iOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Drives sign-in against one gateway base URL, at parity with Hermes Desktop
// (.research/auth-flows.md §4, §12):
//
//   probe /api/status
//     ├─ auth_required == false → session-token path: paste the dashboard
//     │  token, validate with a plain authenticated REST call.
//     └─ gated → native PKCE broker (RFC 8252): loopback listener on
//        127.0.0.1, system browser at /auth/native/authorize, state check,
//        redeem the one-time code at /auth/native/token.
//
// Password providers (`supports_password`) ride the SAME browser broker —
// the gateway 302s the browser to its /login form and mints the loopback
// code from there — so every provider button opens the system browser.
// Credentials land in the Keychain keyed by normalized base URL.

@MainActor
@Observable
public final class AuthController {

    // MARK: - Phase

    public enum Phase: Equatable, Sendable {
        case idle
        case probing
        /// Browser is open; the loopback listener is waiting for the redirect.
        case waitingForBrowser
        /// Redeeming the code / validating a pasted token.
        case exchanging
        case done
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var status: GatewayStatus?
    public private(set) var providers: [AuthProviderInfo] = []
    public private(set) var baseURL: URL?
    /// Set once sign-in succeeds; already persisted to the Keychain.
    public private(set) var credential: GatewayCredential?

    @ObservationIgnored private var listener: LoopbackListener?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let urlSession: URLSession

    public nonisolated init(keychain: KeychainStore = KeychainStore(),
                            urlSession: URLSession = .shared) {
        self.keychain = keychain
        self.urlSession = urlSession
    }

    // MARK: - Derived state for the UI

    /// Probe finished and the gateway is open (loopback / trusted): show the
    /// paste-a-session-token path.
    public var wantsSessionToken: Bool {
        status.map { !$0.authRequired } ?? false
    }

    /// Probe finished and the gateway is gated: show provider buttons.
    public var isGated: Bool {
        status?.authRequired ?? false
    }

    /// OAuth-style providers first, password providers after — mirrors the
    /// primary/secondary button order of the design.
    public var orderedProviders: [AuthProviderInfo] {
        providers.filter { !$0.supportsPassword } + providers.filter(\.supportsPassword)
    }

    public var hasPasswordProvider: Bool {
        providers.contains(where: \.supportsPassword)
    }

    // MARK: - Probe

    /// Normalize + probe a base URL. On success `status` (and `providers`
    /// when gated) are populated and phase returns to `.idle` — unless a
    /// stored Keychain credential still works, in which case we jump straight
    /// to `.done`. Returns whether the probe succeeded.
    @discardableResult
    public func probe(_ urlString: String) async -> Bool {
        cancelSignIn()
        status = nil
        providers = []
        credential = nil

        guard let base = GatewayURL.normalize(urlString) else {
            phase = .failed("That does not look like a gateway URL — try http://host:9119.")
            return false
        }
        baseURL = base
        phase = .probing

        let client = GatewayAuthClient(baseURL: base, session: urlSession)
        do {
            let probed = try await client.status()
            status = probed
            if probed.authRequired {
                providers = (try? await client.providers()) ?? []
                if providers.isEmpty {
                    phase = .failed("The gateway is gated but lists no sign-in providers.")
                    return false
                }
            }
            // A credential from an earlier sign-in may still be good.
            if let stored = keychain.load(for: base), await works(stored, base: base) {
                credential = stored
                phase = .done
                return true
            }
            phase = .idle
            return true
        } catch {
            phase = .failed("Could not reach the gateway — \(shortDescription(error))")
            return false
        }
    }

    // MARK: - Native PKCE broker flow (gated gateways)

    /// Start the browser sign-in for `provider` (nil lets the gateway pick its
    /// only brokerable provider). Password providers use the same flow — the
    /// browser lands on the gateway's /login form.
    public func signIn(provider: AuthProviderInfo?) {
        guard let base = baseURL, let status else {
            phase = .failed("Point at a gateway first.")
            return
        }
        guard status.authRequired else { return }
        guard status.supportsNativePKCE else {
            phase = .failed("This gateway does not offer the native sign-in flow — update hermes-agent, or paste a session token instead.")
            return
        }
        cancelSignIn()
        flowTask = Task { await runNativeFlow(base: base, provider: provider) }
    }

    private func runNativeFlow(base: URL, provider: AuthProviderInfo?) async {
        #if os(iOS)
        // In-app web sheet: no loopback listener at all. WKWebView intercepts
        // the 127.0.0.1 callback as a *navigation* before any socket is
        // dialed — Safari under Lockdown Mode refuses http://127.0.0.1:<port>
        // ("restricted network port"), so the system-browser flow cannot
        // complete there. The port in the redirect URI is never contacted.
        let flow = NativePKCEFlow()
        guard let authorizeURL = flow.authorizeURL(base: base, redirectPort: 43210,
                                                   provider: provider?.name) else {
            phase = .failed("Could not build the authorize URL.")
            return
        }
        pendingFlow = flow
        pendingBase = base
        phase = .waitingForBrowser
        webAuthRequest = WebAuthRequest(url: authorizeURL)
        #else
        let listener = LoopbackListener()
        self.listener = listener
        do {
            let port = try await listener.start()
            let flow = NativePKCEFlow()
            guard let authorizeURL = flow.authorizeURL(base: base, redirectPort: port,
                                                       provider: provider?.name) else {
                throw AuthError.protocolError("Could not build the authorize URL.")
            }
            phase = .waitingForBrowser
            openSystemBrowser(authorizeURL)

            let callback = try await listener.waitForCallback(timeout: 300)
            if let error = callback.error {
                throw AuthError.protocolError(callback.errorDescription ?? error)
            }
            // Verify state BEFORE redeeming — a mismatch means the redirect
            // was not the one we initiated.
            guard callback.state == flow.state else { throw AuthError.stateMismatch }
            guard let code = callback.code else {
                throw AuthError.protocolError("The browser callback carried no code.")
            }

            phase = .exchanging
            let tokens = try await flow.redeem(code: code, base: base, session: urlSession)
            let cred = GatewayCredential.oauth(tokens)
            try keychain.save(cred, for: base)
            credential = cred
            self.listener = nil
            phase = .done
        } catch {
            await listener.stop()
            self.listener = nil
            guard !Task.isCancelled else { return }   // cancelSignIn already reset phase
            phase = .failed(message(for: error))
        }
        #endif
    }

    // MARK: - In-app web sign-in (iOS sheet)

    /// A pending in-app sign-in: the sheet loads `url` and hands back the
    /// loopback callback navigation.
    public struct WebAuthRequest: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
    }

    public private(set) var webAuthRequest: WebAuthRequest?
    @ObservationIgnored private var pendingFlow: NativePKCEFlow?
    @ObservationIgnored private var pendingBase: URL?

    /// The auth sheet intercepted the gateway's redirect to
    /// `http://127.0.0.1:<port>/callback`. Verify state, redeem, store.
    public func handleWebCallback(_ url: URL) {
        webAuthRequest = nil
        guard let flow = pendingFlow, let base = pendingBase else { return }
        pendingFlow = nil
        pendingBase = nil

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            phase = .failed(value("error_description") ?? error)
            return
        }
        guard value("state") == flow.state else {
            phase = .failed("The sign-in state did not match — try again.")
            return
        }
        guard let code = value("code") else {
            phase = .failed("The callback carried no code.")
            return
        }

        phase = .exchanging
        flowTask = Task {
            do {
                let tokens = try await flow.redeem(code: code, base: base, session: urlSession)
                let cred = GatewayCredential.oauth(tokens)
                try keychain.save(cred, for: base)
                credential = cred
                phase = .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(message(for: error))
            }
        }
    }

    /// The sheet was dismissed without completing.
    public func webAuthCancelled() {
        webAuthRequest = nil
        pendingFlow = nil
        pendingBase = nil
        if case .waitingForBrowser = phase { phase = .idle }
    }

    /// Abort an in-flight browser flow (or probe) and go back to idle.
    public func cancelSignIn() {
        flowTask?.cancel()
        flowTask = nil
        webAuthRequest = nil
        pendingFlow = nil
        pendingBase = nil
        if let listener {
            Task { await listener.stop() }
        }
        listener = nil
        switch phase {
        case .probing, .waitingForBrowser, .exchanging: phase = .idle
        default: break
        }
    }

    /// Forget everything, including the probe result.
    public func reset() {
        cancelSignIn()
        status = nil
        providers = []
        baseURL = nil
        credential = nil
        phase = .idle
    }

    // MARK: - Session-token path (open / loopback gateways)

    /// Validate a pasted dashboard session token by just trying a REST call
    /// with it, then persist it.
    public func submitSessionToken(_ raw: String) async {
        guard let base = baseURL else {
            phase = .failed("Point at a gateway first.")
            return
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            phase = .failed("Paste the gateway's session token first.")
            return
        }
        phase = .exchanging
        let cred = GatewayCredential.sessionToken(token)
        if await works(cred, base: base) {
            do {
                try keychain.save(cred, for: base)
                credential = cred
                phase = .done
            } catch {
                phase = .failed("Signed in, but the Keychain refused the token — \(shortDescription(error))")
            }
        } else {
            phase = .failed("The gateway rejected that token.")
        }
    }

    // MARK: - Results

    /// A client for the authenticated gateway (call after `.done`).
    public func makeClient() -> GatewayClient? {
        guard let baseURL, let credential else { return nil }
        return GatewayClient(baseURL: baseURL, credential: credential, keychain: keychain)
    }

    /// The Connections-row shape for a just-authenticated gateway.
    public func makeConnection(named name: String? = nil,
                               kindHint: ConnectionKind? = nil) -> GatewayConnection? {
        guard let baseURL, credential != nil else { return nil }
        let host = baseURL.host() ?? baseURL.absoluteString
        let address = baseURL.port.map { "\(host):\($0)" } ?? host
        let kind = kindHint ?? (host.hasPrefix("100.") ? .tailscale : .lan)
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return GatewayConnection(id: baseURL.absoluteString.lowercased(),
                                 name: trimmed.isEmpty ? host : trimmed,
                                 kind: kind,
                                 address: address,
                                 state: .connected,
                                 ping: "—",
                                 botCount: status?.activeAgents ?? 0)
    }

    // MARK: - Internals

    /// "Just try a REST call": /api/auth/me with the credential attached.
    /// Anything but an auth rejection counts as working (loopback builds may
    /// not serve the identity route).
    private func works(_ credential: GatewayCredential, base: URL) async -> Bool {
        var request = URLRequest(url: base.appending(path: "api/auth/me"))
        GatewayAuthClient(baseURL: base, session: urlSession)
            .apply(credential: credential, to: &request)
        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode != 401 && http.statusCode != 403
        } catch {
            return false
        }
    }

    private func openSystemBrowser(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func message(for error: Error) -> String {
        switch error {
        case AuthError.stateMismatch:
            return "The browser callback failed a security check (state mismatch) — try again."
        case AuthError.flowCancelled:
            return "The sign-in timed out — try again."
        case AuthError.sessionExpired:
            return "The session expired — sign in again."
        case AuthError.providerUnreachable:
            return "The sign-in provider is unreachable — try again shortly."
        case AuthError.unauthorized(let detail):
            return "Not authorized — \(detail)"
        case AuthError.protocolError(let detail):
            return detail
        default:
            return shortDescription(error)
        }
    }

    private func shortDescription(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}

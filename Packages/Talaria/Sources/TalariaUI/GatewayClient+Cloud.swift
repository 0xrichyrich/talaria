import Foundation
import Observation
import TalariaKit

#if os(iOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Hermes Cloud discovery — the phone's half of desktop's `mode:'cloud'`.
//
// Desktop (apps/desktop/electron/main.ts:7270-7810) signs in to the Nous
// portal ONCE inside an Electron session partition, then GETs
// `{portal}/api/agents` carrying that partition's Privy cookie, and opens each
// agent's dashboard through a silent SSO cascade in the same partition.
// Talaria has no shareable cookie partition, so it authenticates the same
// endpoint with a Bearer token from the portal's device-code grant — the exact
// credential `hermes auth add nous` mints, which NousPortalClient already
// implements and stores, and which hermes_cli/nous_account.py:584-598 uses
// against `{portal}/api/oauth/account`.
//
// Response shapes are desktop's, read off trimCloudAgents / trimCloudOrg /
// parseOrgSelectionError (main.ts:7703-7769):
//   200 → {"agents":[{id,name,status,dashboardUrl,dashboardGatewayState}],"org"?:{…}}
//   409 → {"error":"org_selection_required","orgs":[{id,slug,name,isPersonal,role}]}
//   401/403 → the portal did not accept this credential for discovery.
//
// The portal may reserve /api/agents for browser (Privy) sessions. That case is
// reported honestly as `.discoveryRefused` and the UI falls back to the manual
// dashboard-URL path — Talaria never invents a roster it cannot see. Once an
// agent IS picked, its dashboard URL is an ordinary gated gateway: the existing
// AuthController PKCE path signs in, so nothing about the connection is special
// beyond the `.cloud` kind stamped on the saved row.

// MARK: - Trimmed DTOs

/// One hosted agent from the portal's inventory.
public struct CloudAgent: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Lifecycle word from the portal ("running", "provisioning", …).
    public let status: String
    /// nil until the agent has a provisioned dashboard — those rows are shown
    /// but not tappable (desktop renders them as "provisioning…").
    public let dashboardURL: URL?
    /// "active" | "degraded" | "down" | "unknown".
    public let gatewayState: String

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = v["name"]?.stringValue ?? id
        status = v["status"]?.stringValue ?? "unknown"
        // Only https dashboards are honored: the value becomes a gateway base
        // URL that will carry OAuth tokens, so a plain-http portal answer is
        // dropped rather than dialed.
        if let raw = v["dashboardUrl"]?.stringValue, let url = URL(string: raw),
           url.scheme == "https", url.host() != nil {
            dashboardURL = url
        } else {
            dashboardURL = nil
        }
        gatewayState = v["dashboardGatewayState"]?.stringValue ?? "unknown"
    }

    public var isReachable: Bool { dashboardURL != nil }
}

/// An org the signed-in account belongs to (the 409 disambiguation list).
public struct CloudOrg: Identifiable, Sendable, Equatable {
    public let id: String
    public let slug: String?
    public let name: String
    public let isPersonal: Bool
    /// "OWNER" | "MEMBER".
    public let role: String

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        slug = v["slug"]?.stringValue
        name = v["name"]?.stringValue ?? id
        isPersonal = v["isPersonal"]?.boolValue ?? false
        role = v["role"]?.stringValue ?? "MEMBER"
    }

    /// What `?org=` takes — desktop passes a slug or id from a prior list.
    public var queryValue: String { slug ?? id }
}

public enum CloudDiscovery: Sendable, Equatable {
    case agents([CloudAgent], org: CloudOrg?)
    /// Multi-org account that has not picked one yet (NAS 409).
    case needsOrgSelection([CloudOrg])
}

public enum CloudDiscoveryError: Error, Sendable, Equatable {
    /// No portal token on this device — run the device-code sign-in.
    case notSignedIn
    /// The refresh chain is dead; tokens were dropped.
    case sessionExpired
    /// The portal answered but refused this credential for discovery — the
    /// honest "browser session required" case.
    case refused(status: Int)
    case portalUnreachable(String)
    case protocolError(String)
}

// MARK: - Portal directory API

/// GET {portal}/api/agents with a Bearer portal token. Deliberately separate
/// from NousPortalClient (TalariaKit, owned elsewhere): that actor owns tokens
/// and inference, this owns one org-inventory call.
struct PortalDirectoryAPI: Sendable {
    var portalURL: URL

    init(portalURL: URL = PortalDirectoryAPI.resolvedPortalURL) {
        self.portalURL = portalURL
    }

    /// Same override names as every other Hermes surface (main.ts
    /// resolvePortalBaseUrl / hermes_cli DEFAULT_NOUS_PORTAL_URL), run through
    /// the Kit's host allowlist so a hostile value cannot redirect the token.
    static var resolvedPortalURL: URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["HERMES_PORTAL_BASE_URL"] ?? env["NOUS_PORTAL_BASE_URL"]
        return NousPortal.validatedPortalURL(raw) ?? NousPortal.defaultPortalURL
    }

    func discover(token: String, org: String?) async throws -> CloudDiscovery {
        var comps = URLComponents(url: portalURL.appending(path: "api/agents"),
                                  resolvingAgainstBaseURL: false)
        if let org, !org.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "org", value: org)]
        }
        guard let url = comps?.url else {
            throw CloudDiscoveryError.protocolError("could not build the discovery URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Desktop's discovery budget (main.ts:7651 timeoutMs: 15_000).
        request.timeoutInterval = 15

        let data: Data
        let http: HTTPURLResponse
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard let typed = response as? HTTPURLResponse else {
                throw CloudDiscoveryError.protocolError("non-HTTP response")
            }
            data = payload
            http = typed
        } catch let error as CloudDiscoveryError {
            throw error
        } catch {
            throw CloudDiscoveryError.portalUnreachable((error as NSError).localizedDescription)
        }

        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        switch http.statusCode {
        case 200:
            guard let body else {
                throw CloudDiscoveryError.protocolError("the agent list was not JSON")
            }
            let agents = body["agents"]?.arrayValue?.compactMap(CloudAgent.init) ?? []
            return .agents(agents, org: body["org"].flatMap(CloudOrg.init))
        case 409:
            guard body?["error"]?.stringValue == "org_selection_required",
                  let rows = body?["orgs"]?.arrayValue else {
                throw CloudDiscoveryError.protocolError("unexpected 409 from the agent list")
            }
            return .needsOrgSelection(rows.compactMap(CloudOrg.init))
        case 401, 403:
            throw CloudDiscoveryError.refused(status: http.statusCode)
        default:
            throw CloudDiscoveryError.portalUnreachable("the agent list returned \(http.statusCode)")
        }
    }
}

// MARK: - Directory controller (device-code sign-in + discovery)

/// Drives the Hermes Cloud panel: portal device-code sign-in (the flow
/// `hermes auth add nous` runs), then the org/agent inventory. One instance per
/// add-gateway sheet; the token itself is shared through the Keychain, so a
/// sign-in here is remembered for next time.
@MainActor
@Observable
public final class CloudDirectory {

    public enum Phase: Equatable, Sendable {
        case signedOut
        case requestingCode
        /// Waiting for the user to approve `code` at the portal.
        case awaitingApproval(code: String)
        case discovering
        case ready
        case chooseOrg
        /// Signed in, but the portal will not serve the inventory to this
        /// credential — fall back to the manual dashboard URL.
        case discoveryRefused
        case failed(String)
    }

    public private(set) var phase: Phase = .signedOut
    public private(set) var agents: [CloudAgent] = []
    public private(set) var orgs: [CloudOrg] = []
    public private(set) var org: CloudOrg?
    /// Set while the portal's approval page should be shown in-app.
    public private(set) var approvalRequest: AuthController.WebAuthRequest?

    @ObservationIgnored private let portal: NousPortalClient
    @ObservationIgnored private let api: PortalDirectoryAPI
    @ObservationIgnored private var task: Task<Void, Never>?

    /// nonisolated so a SwiftUI `@State` can construct it in place, matching
    /// AuthController's initializer.
    public nonisolated init() {
        let url = PortalDirectoryAPI.resolvedPortalURL
        portal = NousPortalClient(portalURL: url)
        api = PortalDirectoryAPI(portalURL: url)
    }

    /// Called when the cloud panel appears. Idempotent: an existing token goes
    /// straight to discovery, anything already in flight is left alone.
    public func start() {
        switch phase {
        case .signedOut, .failed:
            break
        default:
            return
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.portal.isSignedIn else {
                self.phase = .signedOut
                return
            }
            await self.discover(org: nil)
        }
    }

    /// Portal device-code grant: request a code, show the portal's approval
    /// page, poll until it is approved, then discover.
    public func signIn() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.phase = .requestingCode
                let grant = try await self.portal.requestDeviceCode()
                self.phase = .awaitingApproval(code: grant.userCode)
                self.present(grant.verificationURIComplete)
                _ = try await self.portal.waitForAuthorization(grant)
                self.approvalRequest = nil
                await self.discover(org: nil)
            } catch is CancellationError {
                self.approvalRequest = nil
                self.phase = .signedOut
            } catch {
                self.approvalRequest = nil
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Re-run discovery scoped to one org (answers the 409 picker).
    public func selectOrg(_ org: CloudOrg) {
        self.org = org
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.discover(org: org.queryValue)
        }
    }

    public func retry() {
        phase = .signedOut
        start()
    }

    /// Drop the portal token from the Keychain (client-side only — the portal
    /// has no public revocation grant; the RT dies at its TTL).
    public func signOut() {
        task?.cancel()
        task = nil
        approvalRequest = nil
        agents = []
        orgs = []
        org = nil
        phase = .signedOut
        Task { await portal.signOut() }
    }

    /// The approval sheet was dismissed by hand. Only aborts while the grant is
    /// genuinely still pending — a sheet that closes because polling succeeded
    /// must not cancel the discovery that follows it.
    public func approvalSheetDismissed() {
        guard case .awaitingApproval = phase else { return }
        cancel()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        approvalRequest = nil
        switch phase {
        case .requestingCode, .awaitingApproval, .discovering:
            phase = .signedOut
        default:
            break
        }
    }

    // MARK: Internals

    private func discover(org: String?) async {
        phase = .discovering
        do {
            let token = try await portal.validAccessToken()
            switch try await api.discover(token: token, org: org) {
            case .agents(let rows, let resolvedOrg):
                agents = rows
                if let resolvedOrg { self.org = resolvedOrg }
                phase = .ready
            case .needsOrgSelection(let rows):
                orgs = rows
                phase = .chooseOrg
            }
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            switch error {
            case CloudDiscoveryError.refused:
                phase = .discoveryRefused
            case CloudDiscoveryError.notSignedIn, CloudDiscoveryError.sessionExpired,
                 NousPortalError.notSignedIn, NousPortalError.sessionExpired:
                // The stored grant died (or was never there): back to the
                // sign-in offer rather than an error the user cannot act on.
                phase = .signedOut
            default:
                phase = .failed(Self.message(for: error))
            }
        }
    }

    /// iOS keeps the approval page in-app (the poll must keep running, and a
    /// hop out to Safari suspends it); macOS opens the system browser.
    private func present(_ url: URL) {
        #if os(iOS)
        approvalRequest = AuthController.WebAuthRequest(url: url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Wire-level detail only — every user-facing sentence around it is themed
    /// copy chosen by the panel.
    static func message(for error: Error) -> String {
        switch error {
        case NousPortalError.deviceCodeExpired:
            return "the code expired"
        case NousPortalError.authorizationFailed(let code, let description):
            return description ?? code
        case NousPortalError.portalUnreachable(let detail),
             CloudDiscoveryError.portalUnreachable(let detail):
            return detail
        case NousPortalError.protocolError(let detail),
             CloudDiscoveryError.protocolError(let detail):
            return detail
        case NousPortalError.http(let status, let message):
            return "\(status) — \(message)"
        default:
            return (error as NSError).localizedDescription
        }
    }
}

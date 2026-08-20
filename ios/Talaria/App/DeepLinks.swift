// DeepLinks — the talaria:// URL space and its router.
//
// Registered in Info.plist (CFBundleURLTypes → scheme "talaria") and used by
// every out-of-process surface that re-enters the app:
//   talaria://bot/<id>      island / lock-screen Live Activity, widgets,
//                           per-bot notification taps → that bot's chat
//   talaria://bot/<id>?session_id=<stored>&gateway_id=<source>
//                           response push → exact source/session chat
//   talaria://approvals     approval pushes → the Approvals tab
//   talaria://connections   gateway pushes ("homelab reconnected") →
//                           Connections (pushed off the roster)
//
// PushCoordinator performs the same bot/approvals mutations for notification
// *responses*; this router is the single entry point for actual URL opens
// (onOpenURL), so both paths land in identical AppModel state.

import Foundation
import TalariaKit
import TalariaUI

/// A parsed talaria:// destination.
enum DeepLink: Equatable {

    case approvals
    case connections
    case bot(id: String)
    case storedSession(id: String, sessionID: String, gatewayID: String?)

    /// Strict parse — unknown hosts and empty bot ids are rejected so a bad
    /// URL can never scramble navigation state.
    @MainActor
    init?(url: URL) {
        guard url.scheme?.lowercased() == "talaria" else { return nil }
        // The custom scheme has no authority-bearing routes. Reject userinfo,
        // ports, and fragments so a crafted URL cannot smuggle routing data
        // outside the path/query contract.
        guard url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { return nil }
        switch url.host?.lowercased() {
        case "approvals":
            self = .approvals
        case "connections":
            self = .connections
        case "bot":
            // talaria://bot/<id> — the id is the first real path component.
            let components = url.pathComponents.filter { $0 != "/" }
            guard let id = components.first, !id.isEmpty else { return nil }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let sessionItems = query.filter { $0.name == "session_id" }
            let gatewayItems = query.filter { $0.name == "gateway_id" }
            guard query.allSatisfy({ $0.name == "session_id" || $0.name == "gateway_id" }),
                  sessionItems.count <= 1, gatewayItems.count <= 1,
                  sessionItems.allSatisfy({ !($0.value ?? "").isEmpty }),
                  gatewayItems.allSatisfy({ !($0.value ?? "").isEmpty }) else {
                return nil
            }
            let sessionID = sessionItems.first?.value
            let gatewayID = gatewayItems.first?.value
            if let sessionID, !sessionID.isEmpty {
                // A qualified path already carries its source; accepting a
                // second gateway query would make the URL ambiguous.
                if let qualified = GatewayBotRoute(qualifiedID: id) {
                    guard gatewayID == nil,
                          Self.savedGatewayIDs.contains(qualified.gatewayID) else {
                        return nil
                    }
                } else {
                    guard let gatewayID,
                          Self.savedGatewayIDs.contains(gatewayID) else {
                        return nil
                    }
                }
                self = .storedSession(id: id, sessionID: sessionID, gatewayID: gatewayID)
            } else {
                // A source without a durable session is not a usable response
                // deep link. Ordinary bot links remain query-free.
                guard gatewayID == nil else { return nil }
                self = .bot(id: id)
            }
        default:
            return nil
        }
    }

    @MainActor
    private static var savedGatewayIDs: Set<String> {
        Set(ConnectionRegistry.shared.saved.map(\.id))
    }
}

/// Applies a deep link to the app's navigation state.
@MainActor
struct DeepLinkRouter {

    let model: AppModel

    /// `onOpenURL` entry point. Returns whether the URL was recognized.
    @discardableResult
    func open(_ url: URL) -> Bool {
        // talaria://solo/shortcut?token=… is the x-callback-url return leg of
        // Solo's `shortcuts_run` (SoloShortcutsRunTool.callbackURL). It carries
        // no navigation — a Solo turn is parked on it — so it is answered here
        // and never reaches the navigation switch below.
        if SoloToolHost.shared.deliver(url) { return true }
        guard let link = DeepLink(url: url) else { return false }
        route(link)
        return true
    }

    func route(_ link: DeepLink) {
        switch link {
        case .approvals:
            model.openBotID = nil
            model.selectedTab = .approvals

        case .bot(let id):
            // Not validated against the roster on purpose: on a cold start in
            // live mode the roster may still be loading when the island tap
            // arrives; the root view resolves the id once bots land.
            //
            // openChat, not a raw openBotID write: it resumes the bot's
            // canonical forever-chat and hydrates the transcript.
            model.openChat(botID: id)

        case .storedSession(let id, let sessionID, let gatewayID):
            let botID: String
            if let gatewayID, GatewayBotRoute(qualifiedID: id) == nil {
                guard ConnectionRegistry.shared.saved.contains(where: { $0.id == gatewayID }) else {
                    return
                }
                // Match push routing: the active source keeps its bare roster
                // id, while a saved foreign source must remain qualified.
                botID = gatewayID == model.activeGatewayID
                    ? id
                    : GatewayBotRoute(gatewayID: gatewayID, profile: id).qualifiedID
            } else {
                if let route = GatewayBotRoute(qualifiedID: id),
                   !ConnectionRegistry.shared.saved.contains(where: { $0.id == route.gatewayID }) {
                    return
                }
                botID = id
            }
            // Unlike a generic bot URL, response links must reopen the exact
            // durable session and never fall back to the canonical chat.
            model.openStoredSession(sessionID, botID: botID)

        case .connections:
            // Connections is pushed off the roster, not a tab; surface the
            // roster and let the root view perform the push.
            model.openBotID = nil
            model.selectedTab = .home
            // .talariaOpenConnections is declared in TalariaUI next to
            // PushCoordinator; TalariaRootView observes it and performs the
            // Connections navigation push.
            NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
        }
    }
}

// DeepLinks — the talaria:// URL space and its router.
//
// Registered in Info.plist (CFBundleURLTypes → scheme "talaria") and used by
// every out-of-process surface that re-enters the app:
//   talaria://bot/<id>      island / lock-screen Live Activity, widgets,
//                           per-bot notification taps → that bot's chat
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

    /// Strict parse — unknown hosts and empty bot ids are rejected so a bad
    /// URL can never scramble navigation state.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "talaria" else { return nil }
        switch url.host?.lowercased() {
        case "approvals":
            self = .approvals
        case "connections":
            self = .connections
        case "bot":
            // talaria://bot/<id> — the id is the first real path component.
            let components = url.pathComponents.filter { $0 != "/" }
            guard let id = components.first, !id.isEmpty else { return nil }
            self = .bot(id: id)
        default:
            return nil
        }
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

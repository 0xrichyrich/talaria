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
        guard let link = TalariaDeepLink(url: url) else { return false }
        route(link)
        return true
    }

    func route(_ link: TalariaDeepLink) {
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

        case .storedSession(let route):
            // Unlike a generic bot URL, response links are retained as one
            // immutable source/profile/session identity through cold restore.
            // `.demo` is also the model's cold-launch placeholder, so only a
            // loaded canned world may bypass live exact-session authority.
            if model.demoDataLoaded {
                model.openStoredSession(route.storedSessionID, botID: route.profile)
            } else {
                model.openExactStoredSession(route, origin: .deepLink)
            }

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

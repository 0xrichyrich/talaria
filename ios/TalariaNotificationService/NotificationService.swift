import UserNotifications
import Intents
import TalariaKit

// TalariaNotificationService — the mutable-content hook for pushes from the
// gateway relay. The relay sends `mutable-content: 1` with a data payload
// mirroring the design DB's PUSHES shape:
//
//     { kind, gateway_id, bot, bot_display_name, bot_avatar, title, body,
//       approval_request_id, session_id }
//
// where `kind` is one of approval | response | routine | mention | task |
// gateway.
// This extension:
//   - prefers the payload's display strings over the aps alert (the relay may
//     ship a generic placeholder alert and carry the real text in data),
//   - stamps the TALARIA_APPROVAL actionable category on approval pushes so
//     Approve / Later appear on the banner and lock screen,
//   - stamps the TALARIA_RESPONSE display-only category on completed agent
//     replies; response pushes never gain approval actions,
//   - threads notifications per bot,
//   - dresses mentions, and portrait-bearing final responses, as communication-
//     style notifications when the intent machinery cooperates. Response
//     portraits are bounded self-contained bytes; no URL is ever fetched.
//
// Key and identifier literals are duplicated from TalariaUI's PushCoordinator
// (`PushPayloadKey` / `PushIdentifiers`) so this extension stays lean — it
// must not drag SwiftUI-facing modules into the NSE memory budget. Keep the
// two in sync.

final class NotificationService: UNNotificationServiceExtension {

    private enum Key {
        static let kind = "kind"
        static let bot = "bot"
        static let gatewayID = "gateway_id"
        static let botDisplayName = "bot_display_name"
        static let title = "title"
        static let body = "body"
        static let approvalRequestID = "approval_request_id"
        static let sessionID = "session_id"
    }

    private enum Identifier {
        static let approvalCategory = PushNotificationPolicy.approvalCategory
        static let responseCategory = PushNotificationPolicy.responseCategory
    }

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        let info = request.content.userInfo
        let wireKind = info[Key.kind] as? String
        let kind = PushNotificationPolicy.kind(for: wireKind)
        let bot = info[Key.bot] as? String
        let identity = NotificationCommunicationIdentity.resolve(
            rawProfile: bot,
            configuredDisplayName: info[Key.botDisplayName] as? String,
            gatewayID: info[Key.gatewayID] as? String)

        // Display strings from the data payload win over the aps alert.
        if let title = info[Key.title] as? String, !title.isEmpty {
            content.title = title
        }
        if let body = info[Key.body] as? String, !body.isEmpty {
            content.body = body
        }

        // One thread per bot so a chatty roster stays grouped.
        if let bot, !bot.isEmpty {
            // Raw profile remains the grouping/filter identity. Friendly title
            // and source-qualified INPerson identifiers are display metadata;
            // neither is allowed to rewrite the relay's route/thread field.
            content.threadIdentifier = bot
        }

        // APNs can carry a stale or forged category independently of `kind`.
        // Clear the approval category before handling every non-approval so
        // only an explicitly decoded approval can expose Approve / Later.
        if kind != .approval {
            content.categoryIdentifier = ""
        }

        switch kind {
        case .approval:
            // Actionable Approve / Later; bots are blocked on the user, so
            // ask for time-sensitive delivery (silently downgraded when the
            // app lacks the entitlement).
            content.categoryIdentifier = Identifier.approvalCategory
            content.interruptionLevel = .timeSensitive
            contentHandler(content)
        case .response:
            // A completed agent reply is a normal, active notification. Keep
            // this category action-free: response readiness is informational,
            // never authority to answer or approve work.
            content.categoryIdentifier = Identifier.responseCategory
            content.interruptionLevel = .active
            // A valid tiny local portrait opts this response into iOS'
            // communication rendering. Missing/malformed bytes intentionally
            // retain the ordinary notification and its app icon.
            guard let identity,
                  let avatar = NotificationAvatarPayload.decode(info) else {
                contentHandler(content)
                return
            }
            let presentation = ResponseNotificationPresentation.resolve(
                identity: identity, body: content.body)
            content.title = presentation.title
            content.body = presentation.body
            content.threadIdentifier = presentation.threadIdentifier
            content.categoryIdentifier = presentation.categoryIdentifier
            content.interruptionLevel = .active
            deliverAsCommunication(content, identity: identity,
                                   avatar: avatar, requiresAvatar: true)
        case .mention:
            // A bot speaking to you — try the communication style; any
            // failure delivers the undecorated content.
            guard let identity else {
                contentHandler(content)
                return
            }
            deliverAsCommunication(
                content, identity: identity,
                avatar: NotificationAvatarPayload.decode(info),
                requiresAvatar: false)
        default:
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    // MARK: - Communication styling

    /// Wraps a mention in an incoming INSendMessageIntent so the system
    /// renders it like a message from the bot. Needs the communication-
    /// notifications capability on the app; without it `updating(from:)`
    /// simply fails and the plain content ships.
    private func deliverAsCommunication(
        _ content: UNMutableNotificationContent,
        identity: NotificationCommunicationIdentity,
        avatar: NotificationAvatarImage?,
        requiresAvatar: Bool
    ) {
        guard let contentHandler else { return }
        guard !requiresAvatar || avatar != nil else {
            contentHandler(content)
            return
        }

        let sender = INPerson(
            personHandle: INPersonHandle(
                value: identity.sourceQualifiedIdentifier, type: .unknown),
            nameComponents: nil,
            displayName: identity.displayName,
            image: avatar.map { INImage(imageData: $0.data) },
            contactIdentifier: nil,
            customIdentifier: identity.sourceQualifiedIdentifier)
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: identity.sourceQualifiedIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        if let styled = try? content.updating(from: intent),
           let restamped = styled.mutableCopy() as? UNMutableNotificationContent {
            // INInteraction owns the sender/avatar presentation, not Talaria's
            // routing or response policy. Reassert every exact field iOS is
            // allowed to rewrite while adapting the intent.
            restamped.title = content.title
            restamped.subtitle = content.subtitle
            restamped.body = content.body
            restamped.threadIdentifier = content.threadIdentifier
            restamped.categoryIdentifier = content.categoryIdentifier
            restamped.interruptionLevel = content.interruptionLevel
            contentHandler(restamped)
        } else {
            contentHandler(content)
        }
    }
}

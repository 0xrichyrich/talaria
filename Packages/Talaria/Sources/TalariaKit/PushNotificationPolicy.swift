import Foundation
import ImageIO

/// The small, dependency-free part of the push contract shared by the app
/// and its notification service extension. Keeping this policy in TalariaKit
/// lets the NSE make the same decision without importing SwiftUI-facing code.
public enum PushNotificationPolicy {
    public static let approvalCategory = "TALARIA_APPROVAL"
    public static let responseCategory = "TALARIA_RESPONSE"

    /// Relay wire names are not quite the same as the app's display model:
    /// `long_task` is shown as `.task` in the app. Unknown kinds stay unknown
    /// and must pass through as ordinary, non-actionable notifications.
    public static func kind(for wireKind: String?) -> PushKind? {
        guard let wireKind = wireKind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wireKind.isEmpty else { return nil }
        return PushKind(rawValue: wireKind == "long_task" ? "task" : wireKind)
    }

    /// Only approvals have notification actions. Response-ready pushes are
    /// informational, even if a forged response arrives with an approval
    /// action identifier attached to it.
    public static func allowsApprovalAction(for wireKind: String?) -> Bool {
        kind(for: wireKind) == .approval
    }

    /// The two categories with app-owned semantics. The relay may use
    /// display-only categories for other event kinds, but the app only needs
    /// to register categories whose behavior it owns.
    public static func category(for wireKind: String?) -> String? {
        switch kind(for: wireKind) {
        case .approval: approvalCategory
        case .response: responseCategory
        default: nil
        }
    }

    /// APNs' normal interruption level for a response-ready answer. Approval
    /// and gateway state remain time-sensitive; responses are active and
    /// visible without pretending they can authorize work.
    public enum InterruptionLevel: String, Sendable, Equatable {
        case active
        case timeSensitive = "time-sensitive"
    }

    public static func interruptionLevel(for wireKind: String?) -> InterruptionLevel {
        switch kind(for: wireKind) {
        case .approval, .gateway: .timeSensitive
        default: .active
        }
    }

    /// Mentions are communication notifications. A completed response may also
    /// use that presentation when the service extension has a small validated
    /// local portrait; without one it deliberately keeps the ordinary app icon.
    public static func usesCommunicationStyle(for wireKind: String?) -> Bool {
        switch kind(for: wireKind) {
        case .mention, .response: true
        default: false
        }
    }
}

/// Display-only identity used by the notification service. `rawProfile`
/// remains the routing/filter value; neither display_name nor a gateway label
/// is ever substituted for it.
public struct NotificationCommunicationIdentity: Sendable, Equatable {
    public var rawProfile: String
    public var displayName: String
    public var sourceQualifiedIdentifier: String

    public static func resolve(rawProfile: String?, configuredDisplayName: String?,
                               gatewayID: String?) -> Self? {
        guard let raw = normalized(rawProfile), !raw.isEmpty else { return nil }
        let configured = normalized(configuredDisplayName)
        let display = String((configured?.isEmpty == false
            ? configured! : (raw == "default" ? "Hermes" : raw)).prefix(120))
        let source = normalized(gatewayID)
        let identifier = source.map {
            "bot:\($0.utf8.count):\($0)\(raw)"
        } ?? "bot:\(raw)"
        return Self(rawProfile: raw, displayName: display,
                    sourceQualifiedIdentifier: identifier)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return trimmed
    }
}

/// Fields the NSE must restore after `content.updating(from:)`. Intents may
/// rewrite presentation metadata; the relay's exact display/body/raw-thread
/// contract and response category remain authoritative.
public struct ResponseNotificationPresentation: Sendable, Equatable {
    public var title: String
    public var body: String
    public var threadIdentifier: String
    public var categoryIdentifier: String
    public var interruptionLevel: PushNotificationPolicy.InterruptionLevel

    public static func resolve(identity: NotificationCommunicationIdentity,
                               body: String) -> Self {
        Self(title: identity.displayName, body: body,
             threadIdentifier: identity.rawProfile,
             categoryIdentifier: PushNotificationPolicy.responseCategory,
             interruptionLevel: .active)
    }
}

public struct NotificationAvatarImage: Sendable, Equatable {
    public var mimeType: String
    public var data: Data
}

/// Strict decoder for the relay's self-contained, context-local portrait.
/// Arbitrary URLs are not part of this contract and are never fetched by the
/// extension. Missing or malformed data returns nil for the app-icon fallback.
public enum NotificationAvatarPayload {
    public static let key = "bot_avatar"
    public static let maximumDecodedBytes = 1_400
    public static let allowedMIMETypes: Set<String> = ["image/png", "image/jpeg"]

    public static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationAvatarImage? {
        guard let object = userInfo[key] else { return nil }
        let fields: [AnyHashable: Any]
        if let typed = object as? [AnyHashable: Any] {
            fields = typed
        } else if let typed = object as? [String: Any] {
            fields = Dictionary(uniqueKeysWithValues: typed.map { (AnyHashable($0.key), $0.value) })
        } else {
            return nil
        }
        guard let rawMIME = fields["mime"] as? String else { return nil }
        let mime = rawMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedMIMETypes.contains(mime),
              let encoded = fields["data"] as? String,
              !encoded.isEmpty,
              encoded.count <= ((maximumDecodedBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty, data.count <= maximumDecodedBytes,
              signatureMatches(data, mimeType: mime),
              hasSafeImageMetadata(data) else { return nil }
        return NotificationAvatarImage(mimeType: mime, data: data)
    }

    private static func signatureMatches(_ data: Data, mimeType: String) -> Bool {
        switch mimeType {
        case "image/png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
        default:
            return false
        }
    }

    /// Metadata-only ImageIO inspection prevents a tiny forged file from
    /// declaring bomb-sized dimensions before INImage sees it. The relay emits
    /// one 40px still; allow modest headroom but never animation/multi-frame.
    private static func hasSafeImageMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 128, height <= 128 else { return false }
        return true
    }
}

import Foundation

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

    /// Communication styling is reserved for an actual mention. An agent's
    /// completed response is a clean response-ready notification, not an
    /// incoming human message, so it must not be wrapped in INSendMessageIntent.
    public static func usesCommunicationStyle(for wireKind: String?) -> Bool {
        kind(for: wireKind) == .mention
    }
}

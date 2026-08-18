import Foundation

// The Live Activity contract shared by the app process (which starts, updates
// and ends activities via LiveActivityController) and the TalariaWidgets
// extension (which renders them on the lock screen and in the Dynamic Island).
// Both targets link TalariaKit, so the ActivityAttributes shape lives here.
//
// Gated on os(iOS) as well as canImport: newer macOS SDKs vend ActivityKit,
// but this package still compile-checks against macOS 14 where the framework's
// symbols are unavailable.

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// One activity per working bot ("<bot> is working"), capped at a single
/// concurrent activity system-wide — mirrors the prototype's single island
/// pill for the most recently started working bot.
public struct BotWorkAttributes: ActivityAttributes, Sendable {

    /// The dynamic half: everything that changes while the bot works.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Short description of the in-flight task ("Reading arXiv 2508.11402").
        public var task: String
        /// When this work stint began; drives `Text(timerInterval:)` so the
        /// elapsed clock ticks without pushes.
        public var startedAt: Date
        /// Approvals currently blocking on the user (across the roster).
        public var pendingApprovals: Int

        public init(task: String, startedAt: Date, pendingApprovals: Int = 0) {
            self.task = task
            self.startedAt = startedAt
            self.pendingApprovals = pendingApprovals
        }
    }

    // The fixed half: bot identity + avatar language (shape × hue), so the
    // extension can redraw the silhouette without talking to the gateway.
    public var botID: String
    public var botName: String
    public var shape: AvatarShape
    public var hue: AvatarHue

    public init(botID: String, botName: String, shape: AvatarShape, hue: AvatarHue) {
        self.botID = botID
        self.botName = botName
        self.shape = shape
        self.hue = hue
    }
}

public extension BotWorkAttributes {
    /// Tap target for the island / lock-screen card: `talaria://bot/<id>`.
    var deepLinkURL: URL? { URL(string: "talaria://bot/\(botID)") }
}
#endif

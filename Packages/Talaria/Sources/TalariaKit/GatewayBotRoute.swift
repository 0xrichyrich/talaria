import Foundation

/// The stable identity of a Hermes profile in a multi-connection roster.
///
/// Profile names are only unique inside one gateway. Hermes Desktop therefore
/// keys remote rows as `<connection-id>::<profile>`; Talaria uses the same wire-
/// independent identity so chat, unread, approval, and room state cannot leak
/// between two machines that both expose (for example) `default`.
public struct GatewayBotRoute: Codable, Hashable, Sendable {
    public static let separator = "::"

    public var gatewayID: String
    public var profile: String

    public init(gatewayID: String, profile: String) {
        self.gatewayID = gatewayID
        self.profile = profile
    }

    public var qualifiedID: String {
        gatewayID + Self.separator + profile
    }

    /// Parse an explicitly source-qualified roster id.
    public init?(qualifiedID: String) {
        guard let boundary = qualifiedID.range(of: Self.separator) else { return nil }
        let gateway = String(qualifiedID[..<boundary.lowerBound])
        let profile = String(qualifiedID[boundary.upperBound...])
        guard !gateway.isEmpty, !profile.isEmpty else { return nil }
        self.init(gatewayID: gateway, profile: profile)
    }

    /// Resolve either a remote qualified id or a local bare profile. A bare
    /// profile has no safe route while there is no active gateway.
    public static func resolve(rosterID: String, activeGatewayID: String?) -> Self? {
        if let qualified = Self(qualifiedID: rosterID) { return qualified }
        guard let activeGatewayID, !activeGatewayID.isEmpty, !rosterID.isEmpty else { return nil }
        return Self(gatewayID: activeGatewayID, profile: rosterID)
    }
}

/// A runtime session id scoped to the gateway that issued it. Hermes runtime
/// ids are intentionally short and can collide across simultaneously connected
/// machines, so they are never a process-global key on their own.
public struct GatewaySessionRoute: Codable, Hashable, Sendable {
    public var gatewayID: String
    public var sessionID: String

    public init(gatewayID: String, sessionID: String) {
        self.gatewayID = gatewayID
        self.sessionID = sessionID
    }
}

/// A gateway-scoped approval request identity.
///
/// Hermes request ids are unique inside one gateway process, not across every
/// gateway a phone can retain at once. `qualifiedID` is an opaque UI/state key;
/// the original `requestID` is kept separately and is the only value sent back
/// over the wire.
public struct GatewayApprovalRoute: Codable, Hashable, Sendable {
    public var gatewayID: String
    public var requestID: String

    public init(gatewayID: String, requestID: String) {
        self.gatewayID = gatewayID
        self.requestID = requestID
    }

    public var qualifiedID: String {
        Self.qualifiedPrefix(gatewayID: gatewayID) + requestID
    }

    public static func qualifiedPrefix(gatewayID: String) -> String {
        "approval:\(gatewayID.count):\(gatewayID)"
    }
}

/// A cron job id scoped to the gateway whose scheduler owns it.
public struct GatewayRoutineRoute: Codable, Hashable, Sendable {
    public var gatewayID: String
    public var jobID: String

    public init(gatewayID: String, jobID: String) {
        self.gatewayID = gatewayID
        self.jobID = jobID
    }

    public var qualifiedID: String {
        "routine:\(gatewayID.count):\(gatewayID)\(jobID)"
    }
}

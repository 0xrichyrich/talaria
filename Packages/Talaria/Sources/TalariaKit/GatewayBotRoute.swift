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

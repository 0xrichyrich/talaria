import Foundation

extension ProtocolChecks {
    static func gatewayBotRouting() throws {
        let route = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        try expect(route.qualifiedID == "homelab::default", "route qualifies source and profile")
        try expect(GatewayBotRoute(qualifiedID: route.qualifiedID) == route,
                   "qualified route round-trips")
        try expect(GatewayBotRoute.resolve(rosterID: "researcher", activeGatewayID: "mac")
            == GatewayBotRoute(gatewayID: "mac", profile: "researcher"),
                   "bare profile resolves only through active gateway")
        try expect(GatewayBotRoute.resolve(rosterID: "homelab::researcher", activeGatewayID: "mac")
            == GatewayBotRoute(gatewayID: "homelab", profile: "researcher"),
                   "qualified route outranks active gateway")
        try expect(GatewayBotRoute.resolve(rosterID: "researcher", activeGatewayID: nil) == nil,
                   "bare profile fails closed without active gateway")
        try expect(GatewayBotRoute(qualifiedID: "::default") == nil,
                   "empty gateway is rejected")
        try expect(GatewayBotRoute(qualifiedID: "homelab::") == nil,
                   "empty profile is rejected")
    }
}

import Foundation

/// Desktop Bot Mode stores per-bot cosmetics server-side in the profile's
/// `ui_meta["hermes-bots"]` block (title, shape, color, pinned chat), synced
/// through `profiles.configure` so they follow the profile between machines.
///
/// Talaria reads that same block first and only falls back to its own
/// `ui_meta["talaria"]` — otherwise a bot renamed or recolored on desktop
/// would look like a different bot on the phone.
/// Source: apps/desktop/src/plugins/hermes-bots/plugin.js (`mergeServerMeta`,
/// `AVATAR_SHAPES` 606, `AVATAR_COLORS` 660).
public struct BotModeMeta: Sendable, Equatable {
    public var title: String?
    /// Desktop shape vocabulary: circle, squircle, pill, triangle, hexagon,
    /// cloud, drop (+ blob in the picker).
    public var shape: String?
    /// Desktop stores a literal hex from AVATAR_COLORS.
    public var colorHex: String?
    /// Stored-session id of the bot's canonical "forever chat".
    public var pinnedChat: String?

    public init(title: String? = nil, shape: String? = nil,
                colorHex: String? = nil, pinnedChat: String? = nil) {
        self.title = title; self.shape = shape
        self.colorHex = colorHex; self.pinnedChat = pinnedChat
    }

    /// Parse the desktop block out of a profile's `ui_meta`.
    public init?(uiMeta: JSONValue?) {
        guard let block = uiMeta?["hermes-bots"], block.objectValue != nil else { return nil }
        title = block["title"]?.stringValue
        shape = block["shape"]?.stringValue
        colorHex = block["color"]?.stringValue
        pinnedChat = block["chat"]?.stringValue
        if title == nil, shape == nil, colorHex == nil, pinnedChat == nil { return nil }
    }

    /// Desktop's shape vocabulary mapped onto Talaria's six silhouettes.
    /// Shapes Talaria has no glyph for fall back to the nearest sibling
    /// rather than being dropped (a bot should never change shape between
    /// apps more than it must).
    public var talariaShape: AvatarShape? {
        switch shape?.lowercased() {
        case "circle", "cloud": .circle
        case "squircle", "pill", "blob": .squircle
        case "hexagon": .hexagon
        case "triangle": .triangle
        case "drop", "diamond": .diamond
        case "pentagon": .pentagon
        default: nil
        }
    }

    /// Nearest Talaria hue for a desktop AVATAR_COLORS hex, by RGB distance
    /// against the palette's reference values.
    public var talariaHue: AvatarHue? {
        guard let hex = colorHex, let rgb = Self.rgb(from: hex) else { return nil }
        let reference: [(AvatarHue, (Double, Double, Double))] = [
            (.teal, (0x14, 0xb8, 0xa6)),
            (.blue, (0x38, 0xbd, 0xf8)),
            (.violet, (0x8b, 0x5c, 0xf6)),
            (.pink, (0xec, 0x48, 0x99)),
            (.amber, (0xf9, 0x73, 0x16)),
            (.green, (0x22, 0xc5, 0x5e)),
        ]
        return reference.min { a, b in
            Self.distance(rgb, a.1) < Self.distance(rgb, b.1)
        }?.0
    }

    static func rgb(from hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 0xFF), Double((n >> 8) & 0xFF), Double(n & 0xFF))
    }

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }
}

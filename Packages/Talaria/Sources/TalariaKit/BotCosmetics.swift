import Foundation

/// THE place a bot's shape and hue are decided. There is no other.
///
/// Precedence, and the ordering is the whole point of the type:
///
///   1. **Desktop Bot Mode's own block**, `ui_meta["hermes-bots"]` — the
///      cosmetics a human actually chose, stored server-side on the profile so
///      they follow it between machines (plugin.js `mergeServerMeta` 432-482).
///      Present means authoritative, on the first paint and on every refresh
///      after it, forever.
///   2. **Talaria's own mirror**, `ui_meta["talaria"]` — written beside
///      desktop's block by this app's own save path so an older gateway that
///      round-trips only part of ui_meta still remembers the pick.
///   3. **A stable hash of the profile name** — LAST RESORT, and only for a
///      profile that carries no stored cosmetics at all. A derived face is a
///      placeholder for a bot nobody has dressed yet; it must never be able to
///      replace one that has been.
///
/// This decision used to be spelled out five separate times — the live roster
/// map, the secondary-gateway roster row, a name-only copy for a gateway
/// mid-switch, and two more inside the profile editor that read Talaria's
/// mirror alone and defaulted to circle/teal when it was missing. Five copies
/// of a precedence rule is five chances for one paint to disagree with the
/// next, which is exactly what shipped: a roster that was correct on launch and
/// wrong eight seconds later. `ProtocolChecks.rosterCosmeticsSurviveRefresh`
/// guards the collapse.
///
/// The `uiMeta:`/`name:` pair is the primitive; the `HermesProfile` overloads
/// exist so a caller holding a roster row cannot accidentally pass one
/// profile's ui_meta with another's name. Callers holding an *edit* payload
/// (a profile being created, a look being saved) use the primitive — the block
/// they are about to write obeys the same precedence as the block that comes
/// back.
public enum BotCosmetics {

    // MARK: - Stored cosmetics (nil when the profile carries none)

    /// The shape a human chose, or nil if nobody has. Desktop's block first,
    /// Talaria's mirror second.
    public static func storedShape(uiMeta: JSONValue?) -> AvatarShape? {
        BotModeMeta(uiMeta: uiMeta)?.talariaShape
            ?? uiMeta?["talaria"]?["shape"]?.stringValue
                .flatMap(AvatarShape.init(rawValue:))
    }

    /// The hue a human chose, or nil if nobody has.
    public static func storedHue(uiMeta: JSONValue?) -> AvatarHue? {
        BotModeMeta(uiMeta: uiMeta)?.talariaHue
            ?? uiMeta?["talaria"]?["hue"]?.stringValue
                .flatMap(AvatarHue.init(rawValue:))
    }

    public static func storedShape(for profile: HermesProfile) -> AvatarShape? {
        storedShape(uiMeta: profile.uiMeta)
    }

    public static func storedHue(for profile: HermesProfile) -> AvatarHue? {
        storedHue(uiMeta: profile.uiMeta)
    }

    // MARK: - Resolved cosmetics (always an answer)

    public static func shape(uiMeta: JSONValue?, name: String) -> AvatarShape {
        storedShape(uiMeta: uiMeta) ?? derivedShape(forName: name)
    }

    public static func hue(uiMeta: JSONValue?, name: String) -> AvatarHue {
        storedHue(uiMeta: uiMeta) ?? derivedHue(forName: name)
    }

    public static func shape(for profile: HermesProfile) -> AvatarShape {
        shape(uiMeta: profile.uiMeta, name: profile.name)
    }

    public static func hue(for profile: HermesProfile) -> AvatarHue {
        hue(uiMeta: profile.uiMeta, name: profile.name)
    }

    // MARK: - Last resort

    /// Placeholder cosmetics for a profile with no stored ones — and for a
    /// gateway mid-switch, where a name is all there is to go on.
    public static func derivedShape(forName name: String) -> AvatarShape {
        let cases = AvatarShape.allCases
        return cases[(stableHash(name) & Int.max) % cases.count]
    }

    public static func derivedHue(forName name: String) -> AvatarHue {
        // .gateway is reserved for gateway-originated feed items.
        let cases: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]
        return cases[(stableHash(name + "hue") & Int.max) % cases.count]
    }

    /// Deterministic across launches (`String.hashValue` is seeded per-process,
    /// so a bot's face would change every time the app was killed).
    public static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return h
    }
}

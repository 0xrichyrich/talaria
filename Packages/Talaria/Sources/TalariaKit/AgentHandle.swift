import Foundation

// ── The duplicate-name rule: @name-device ────────────────────────────────────
//
// This one is NOT ported from plugin.js. The `@name-device` form is minted in
// the Electron main process and the plugin only ever consumes it — `botHandle`
// (plugin.js:2406-2412) prefers a precomputed `bot.handle` over its own
// default→hermes rule, and `mergeMultiSourceRoster` copies it onto the row
// (2334) or into a thin remote one (2350). The rule itself lives in
// apps/desktop/electron/connection-registry.ts:
//
//   labelSlug         :121-129   kebab-slug of a connection label
//   agentHandle       :137-141   "the one place the duplicate-agent naming rule lives"
//   buildAgentRoster  :336-372   who counts as duplicated, and across what
//   RosterAgent.handle :252-254  the shape's own statement of the rule
//
// It sits in TalariaKit rather than beside `ConnectionRegistry` — which owns
// the saved gateways it is fed from — for the same reason `RosterSearch` and
// `BotMention` do: the roster, the palette, the composer and the resolver all
// have to agree on what a handle is, and `talaria-verify` links TalariaKit
// alone, so ProtocolChecks+AgentHandle.swift can pin these on every build.

public enum AgentHandle {

    /// `labelSlug` (connection-registry.ts:121-129) — "Kebab-slug of a label
    /// for ids and @handles. Never empty for a non-empty label."
    ///
    /// Trim → lowercase → every run of non-alphanumerics to ONE hyphen → trim
    /// hyphens off both ends → 48 chars. The cap is applied last, so a long
    /// label can end in a hyphen; that is upstream's order (`.slice(0, 48)`
    /// after the trim) and it is kept, because the slug has to be reproduced
    /// byte-for-byte on both machines or the handle stops round-tripping.
    ///
    /// `"connection"` is the fallback for a label that slugs to nothing (all
    /// punctuation, or empty) — never an empty suffix, which would mint the
    /// bare name back and un-disambiguate the row.
    public static func labelSlug(_ label: String) -> String {
        let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hyphenated = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-",
                                                      options: .regularExpression)
        let slug = hyphenated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "connection" : String(slug.prefix(48))
    }

    /// `agentHandle` (connection-registry.ts:137-141) — the whole rule.
    ///
    /// `duplicated ? "<profile>-<label-slug>" : "<profile>"`. A bare hyphen
    /// join: not `@name@device`, not a colon, and the slug is of the
    /// connection LABEL rather than its id, so the form a user types is the
    /// device name they gave the machine.
    ///
    /// Ambiguity must refuse rather than guess — silently picking one of two
    /// bots named `default` would deliver a real message to the wrong machine
    /// (plugin.js:2457-2466) — so this is the only escape hatch the resolver
    /// leaves once a bare name is poisoned, and it has to be exact.
    public static func mint(profile: String, connectionLabel: String,
                            duplicated: Bool) -> String {
        let name = profileName(profile)
        return duplicated ? "\(name)-\(labelSlug(connectionLabel))" : name
    }

    /// `String(profile || '').trim() || 'default'` — the normalisation every
    /// upstream identity path starts with (connection-registry.ts:138, 345;
    /// plugin.js:2670). A nameless row is the primary profile, not an error.
    public static func profileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// The counting half of `buildAgentRoster` (connection-registry.ts:341-358):
    /// which bare profile names exist on more than one source.
    ///
    /// Two details are load-bearing and both are upstream's:
    ///
    ///  1. DEDUPE PER SOURCE FIRST (:341-352). Identities are collected under
    ///     `${connection.id}\0${name}` before anything is counted, so a
    ///     gateway that transiently reports the same profile twice — or a
    ///     connection that arrives twice while registry state reconciles —
    ///     cannot invent a collision and disambiguate a name nothing else
    ///     claims.
    ///  2. THE LIVE SOURCE COUNTS TOO (:354-358 counts every identity, and
    ///     :362-370 stamps every one of them). `default` on this phone's
    ///     gateway and `default` on a saved one make BOTH sides duplicated:
    ///     desktop mints `default-macbook` and `default-homelab`, not a bare
    ///     name on the near side and a suffixed one on the far side.
    ///
    /// Each element of `sources` is one source's profile names, in any order.
    public static func duplicatedNames(across sources: [[String]]) -> Set<String> {
        var counts: [String: Int] = [:]
        for source in sources {
            for name in Set(source.map { profileName($0) }) {
                counts[name, default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}

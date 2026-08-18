import Foundation
import TalariaKit

// Slash commands: the backend command catalog, alias resolution, live
// completion, execution, and the answer leg of the mcp.setup blocking bridge.
//
// Shapes verified against upstream (never inferred):
//   commands.catalog   tui_gateway/methods_tools.py:255
//   command.resolve    tui_gateway/methods_tools.py:412
//   slash.exec         tui_gateway/methods_tools.py:1110
//   complete.slash     tui_gateway/methods_complete.py:330
//   mcp.setup.respond  tui_gateway/methods_prompt.py:1435
//
// The catalog is the interesting one: `pairs` is the flat universe (registry
// commands + quick_commands + skill commands), `categories` covers everything
// EXCEPT skill commands, and `skills` names the skill commands. So a row's
// kind is decided by membership in `skills`, not by its category.

/// One row of the gateway's slash catalog — a registry command, a user
/// quick-command, or a skill command.
public struct SlashCommand: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case command, skill }

    public var id: String { name }
    /// Canonical name including the leading slash ("/compress").
    public var name: String
    /// Description with the "(usage: /x …)" tail lifted out into `usage`.
    public var description: String
    /// Catalog category ("Session", "Configuration", "User commands", …).
    /// Empty for skill commands — the catalog files them outside categories.
    public var category: String
    public var kind: Kind
    /// Argument hint ("[N]", "<json|md|html> [filename]", "on|off|status"),
    /// empty when the command runs with no argument. Sourced from the
    /// description's usage tail, falling back to the catalog's `sub` map.
    public var usage: String
    /// Other spellings `canon` maps onto this command ("/compact" → /compress).
    public var aliases: [String]

    /// A command that needs no argument can be fired straight from a list;
    /// anything else has to land in the composer first.
    public var takesArguments: Bool { !usage.isEmpty }

    public init(name: String, description: String, category: String,
                kind: Kind = .command, usage: String = "", aliases: [String] = []) {
        self.name = name; self.description = description; self.category = category
        self.kind = kind; self.usage = usage; self.aliases = aliases
    }

    /// True when `query` (slash-stripped, lowercased) matches the name, one of
    /// the aliases, or the description.
    public func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let bare = name.hasPrefix("/") ? String(name.dropFirst()).lowercased() : name.lowercased()
        if bare.contains(query) { return true }
        if aliases.contains(where: { $0.lowercased().contains(query) }) { return true }
        return description.lowercased().contains(query)
    }

    /// Split "Back up N user turns (default 1) (usage: /undo [N])" into the
    /// prose and the "[N]" hint. Searches backwards: several descriptions
    /// contain their own parenthetical before the usage tail.
    static func splitUsage(from raw: String, name: String) -> (text: String, usage: String) {
        guard raw.hasSuffix(")"),
              let marker = raw.range(of: " (usage: ", options: .backwards) else {
            return (raw, "")
        }
        let inner = raw[marker.upperBound..<raw.index(before: raw.endIndex)]
        var usage = String(inner)
        if usage.hasPrefix(name) { usage = String(usage.dropFirst(name.count)) }
        return (String(raw[raw.startIndex..<marker.lowerBound]),
                usage.trimmingCharacters(in: .whitespaces))
    }
}

/// The whole `commands.catalog` payload, flattened for the palette.
public struct SlashCatalog: Sendable {
    /// Commands in catalog order (categories first, skill commands last).
    public var commands: [SlashCommand]
    public var skillCount: Int
    /// Non-empty when skill or quick-command discovery failed server-side —
    /// the rest of the catalog is still good, so this is a banner, not an error.
    public var warning: String

    public init(commands: [SlashCommand], skillCount: Int, warning: String) {
        self.commands = commands; self.skillCount = skillCount; self.warning = warning
    }

    public static let empty = SlashCatalog(commands: [], skillCount: 0, warning: "")
}

/// `complete.slash` result: ranked items plus the index in the typed text the
/// chosen item replaces from.
public struct SlashCompletions: Sendable {
    public var items: [SlashCommand]
    public var replaceFrom: Int

    public init(items: [SlashCommand], replaceFrom: Int) {
        self.items = items; self.replaceFrom = replaceFrom
    }

    public static let empty = SlashCompletions(items: [], replaceFrom: 0)
}

extension GatewayClient {

    // MARK: - Catalog

    /// The backend slash catalog. Categories keep their server-side order;
    /// skill commands are appended last with `kind == .skill`.
    public func commandsCatalog() async throws -> SlashCatalog {
        let result = try await rpc("commands.catalog", .object([:]))

        // canon maps every spelling (lowercased, slash-prefixed) at its
        // canonical name — invert it once so rows can carry their aliases.
        var aliases: [String: [String]] = [:]
        for (spelling, canonical) in result["canon"]?.objectValue ?? [:] {
            guard let canonical = canonical.stringValue,
                  spelling.lowercased() != canonical.lowercased() else { continue }
            aliases[canonical, default: []].append(spelling)
        }
        for key in aliases.keys { aliases[key]?.sort() }

        // sub: "/cmd" → ["sub1", …]. Only consulted when the description
        // carried no usage tail, so an explicit hint always wins.
        var subcommands: [String: [String]] = [:]
        for (name, list) in result["sub"]?.objectValue ?? [:] {
            let subs = list.arrayValue?.compactMap(\.stringValue) ?? []
            if !subs.isEmpty { subcommands[name] = subs }
        }

        let skillEntries = result["skills"]?.objectValue ?? [:]

        func row(_ pair: JSONValue, category: String, kind: SlashCommand.Kind) -> SlashCommand? {
            guard let fields = pair.arrayValue, let name = fields.first?.stringValue,
                  !name.isEmpty else { return nil }
            let raw = fields.count > 1 ? (fields[1].stringValue ?? "") : ""
            var (text, usage) = SlashCommand.splitUsage(from: raw, name: name)
            if usage.isEmpty, let subs = subcommands[name] {
                usage = subs.joined(separator: "|")
            }
            return SlashCommand(name: name, description: text, category: category,
                                kind: kind, usage: usage, aliases: aliases[name] ?? [])
        }

        var commands: [SlashCommand] = []
        var placed = Set<String>()
        for category in result["categories"]?.arrayValue ?? [] {
            let label = category["name"]?.stringValue ?? ""
            for pair in category["pairs"]?.arrayValue ?? [] {
                guard let command = row(pair, category: label, kind: .command),
                      !skillEntries.keys.contains(command.name),
                      placed.insert(command.name).inserted else { continue }
                commands.append(command)
            }
        }

        // Everything else in `pairs`: the skill commands, plus (defensively)
        // any row the server left out of every category.
        for pair in result["pairs"]?.arrayValue ?? [] {
            guard let name = pair.arrayValue?.first?.stringValue, !placed.contains(name) else { continue }
            let kind: SlashCommand.Kind = skillEntries.keys.contains(name) ? .skill : .command
            guard let command = row(pair, category: "", kind: kind),
                  placed.insert(name).inserted else { continue }
            commands.append(command)
        }

        return SlashCatalog(commands: commands,
                            skillCount: result["skill_count"]?.intValue ?? skillEntries.count,
                            warning: result["warning"]?.stringValue ?? "")
    }

    /// Resolve an alias or partial spelling to its canonical command.
    /// Throws 4011 when the gateway knows no such command.
    public func resolveCommand(_ name: String) async throws -> SlashCommand {
        let result = try await rpc("command.resolve", ["name": .string(name)])
        // The registry answers with a bare name; the catalog everywhere else
        // is slash-prefixed, so normalize here.
        let canonical = result["canonical"]?.stringValue ?? name
        let slashed = canonical.hasPrefix("/") ? canonical : "/" + canonical
        let raw = result["description"]?.stringValue ?? ""
        let (text, usage) = SlashCommand.splitUsage(from: raw, name: slashed)
        return SlashCommand(name: slashed, description: text,
                            category: result["category"]?.stringValue ?? "",
                            kind: .command, usage: usage)
    }

    // MARK: - Execution

    /// Run a slash command against a live session. Worker-backed; the gateway
    /// re-routes skill/bundle/pending-input commands to command.dispatch on our
    /// behalf, so this one call covers the whole surface. Long timeout because
    /// /compress and /refine drive the model.
    public func execSlash(sessionID: String, command: String) async throws -> String {
        let result = try await rpc("slash.exec",
                                   ["session_id": .string(sessionID), "command": .string(command)],
                                   timeout: 300)
        return result["output"]?.stringValue ?? ""
    }

    // MARK: - Completion

    /// Live completion for composer text starting with "/". The gateway ranks
    /// by usage and fuzzy-matches descriptions, so its order is worth keeping.
    public func completeSlash(_ text: String) async throws -> SlashCompletions {
        let result = try await rpc("complete.slash", ["text": .string(text)], timeout: 20)
        let items: [SlashCommand] = (result["items"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["text"]?.stringValue, !name.isEmpty else { return nil }
            let display = item["display"]?.stringValue ?? name
            let meta = item["meta"]?.stringValue ?? ""
            let raw = meta.isEmpty ? (display == name ? "" : display) : meta
            let (text, usage) = SlashCommand.splitUsage(from: raw, name: name)
            let kind: SlashCommand.Kind =
                item["kind"]?.stringValue == "skill" ? .skill : .command
            return SlashCommand(name: name, description: text, category: "",
                                kind: kind, usage: usage)
        }
        return SlashCompletions(items: items,
                                replaceFrom: result["replace_from"]?.intValue ?? 0)
    }

    // MARK: - MCP setup bridge

    /// Answer a parked `mcp.setup.request`. `result` is a JSON *string* the
    /// gateway hands to the setup_mcp tool verbatim; the tool understands
    /// status ∈ installed|enabled|authorized|declined|unanswered|error
    /// (tools/setup_mcp_tool.py:84). The respond leg is allow_expired, so a
    /// late answer resolves as {"status":"expired"} instead of erroring.
    public func respondToMCPSetup(requestID: String, status: String,
                                  server: String, detail: String? = nil) async throws {
        var outcome: [String: JSONValue] = ["status": .string(status), "server": .string(server)]
        if let detail, !detail.isEmpty { outcome["detail"] = .string(detail) }
        let encoded = (try? JSONEncoder().encode(JSONValue.object(outcome)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"status":"declined"}"#
        try await rpc("mcp.setup.respond",
                      ["request_id": .string(requestID), "result": .string(encoded)])
    }
}

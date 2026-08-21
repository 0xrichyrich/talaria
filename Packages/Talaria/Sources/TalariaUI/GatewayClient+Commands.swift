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
// commands + quick_commands + standalone skill commands), `categories` covers
// everything EXCEPT standalone skills, and `skills` names those skills. Hermes
// c1e25 deliberately rejects that last class from slash.exec with 4018 and asks
// callers to use command.dispatch. Talaria cannot safely retry across that
// boundary because a quick/plugin collision may resolve differently, so those
// rows are retained only as an unsupported-name fence and never advertised.

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

/// The complete typed `slash.exec` contract. Hermes may return a raw worker
/// output or a result passed through from command.dispatch; callers must not
/// infer that a second dispatch is safe.
public enum SlashExecutionResult: Sendable, Equatable {
    case output(String, warning: String?)
    case exec(String)
    case send(message: String, notice: String?, display: String?)
    case skill(message: String, name: String, display: String?)
    case prefill(message: String, notice: String?)
    case alias(target: String)

    init(result: [String: JSONValue]) throws {
        let type = result["type"]?.stringValue
        func required(_ key: String) throws -> String {
            guard let value = result[key]?.stringValue, !value.isEmpty else {
                throw GatewayError(code: 502, message: "Malformed slash.exec result: missing \(key).")
            }
            return value
        }
        switch type {
        case nil, "output", "plugin":
            self = .output(result["output"]?.stringValue ?? "", warning: result["warning"]?.stringValue)
        case "exec": self = .exec(try required("output"))
        case "send": self = .send(message: try required("message"), notice: result["notice"]?.stringValue,
                                  display: result["display"]?.stringValue)
        case "skill": self = .skill(message: try required("message"), name: try required("name"), display: result["display"]?.stringValue)
        case "prefill": self = .prefill(message: try required("message"), notice: result["notice"]?.stringValue)
        case "alias": self = .alias(target: try required("target"))
        default: throw GatewayError(code: 502, message: "Unsupported slash.exec result type: \(type ?? "unknown").")
        }
    }
}

/// The whole `commands.catalog` payload, flattened for the palette.
public struct SlashCatalog: Sendable {
    /// Commands in catalog order. Standalone skills rejected by slash.exec are
    /// deliberately absent.
    public var commands: [SlashCommand]
    /// Number of executable skill rows. This remains zero until Hermes exposes
    /// a source-safe slash.exec path for standalone skills.
    public var skillCount: Int
    /// Non-empty when skill or quick-command discovery failed server-side —
    /// the rest of the catalog is still good, so this is a banner, not an error.
    public var warning: String
    /// Canonical lowercased slash names hidden from discovery and direct
    /// dispatch. This lets completion filter only unsupported standalone
    /// skills while preserving skill bundles that slash.exec routes safely.
    public var unsupportedStandaloneSkillNames: Set<String>

    public init(commands: [SlashCommand], skillCount: Int, warning: String,
                unsupportedStandaloneSkillNames: Set<String> = []) {
        self.commands = commands
        self.skillCount = skillCount
        self.warning = warning
        self.unsupportedStandaloneSkillNames = unsupportedStandaloneSkillNames
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

    func hidingStandaloneSkills(_ unsupported: Set<String>) -> SlashCompletions {
        guard !unsupported.isEmpty else { return self }
        return SlashCompletions(
            items: items.filter { command in
                !unsupported.contains(SlashCatalog.normalizedName(command.name))
            },
            replaceFrom: replaceFrom)
    }
}

extension SlashCatalog {
    static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// Decode the verified c1e25 commands.catalog shape without opening a
    /// socket. Kept separate from the RPC so the unsupported-skill boundary is
    /// exhaustively testable.
    init(result: [String: JSONValue]) {
        var aliases: [String: [String]] = [:]
        for (spelling, canonical) in result["canon"]?.objectValue ?? [:] {
            guard let canonical = canonical.stringValue,
                  spelling.lowercased() != canonical.lowercased() else { continue }
            aliases[canonical, default: []].append(spelling)
        }
        for key in aliases.keys { aliases[key]?.sort() }

        var subcommands: [String: [String]] = [:]
        for (name, list) in result["sub"]?.objectValue ?? [:] {
            let subs = list.arrayValue?.compactMap(\.stringValue) ?? []
            if !subs.isEmpty { subcommands[name] = subs }
        }

        let skillEntries = result["skills"]?.objectValue ?? [:]
        let unsupported = Set(skillEntries.keys.map(Self.normalizedName))

        func row(_ pair: JSONValue, category: String) -> SlashCommand? {
            guard let fields = pair.arrayValue, let name = fields.first?.stringValue,
                  !name.isEmpty else { return nil }
            let raw = fields.count > 1 ? (fields[1].stringValue ?? "") : ""
            var (text, usage) = SlashCommand.splitUsage(from: raw, name: name)
            if usage.isEmpty, let subs = subcommands[name] {
                usage = subs.joined(separator: "|")
            }
            return SlashCommand(name: name, description: text, category: category,
                                kind: .command, usage: usage, aliases: aliases[name] ?? [])
        }

        var commands: [SlashCommand] = []
        var placed = Set<String>()
        for category in result["categories"]?.arrayValue ?? [] {
            let label = category["name"]?.stringValue ?? ""
            for pair in category["pairs"]?.arrayValue ?? [] {
                guard let command = row(pair, category: label),
                      !unsupported.contains(Self.normalizedName(command.name)),
                      placed.insert(command.name).inserted else { continue }
                commands.append(command)
            }
        }

        // Preserve uncategorized quick/registry commands, but never publish a
        // standalone skill that c1e25 will reject from slash.exec.
        for pair in result["pairs"]?.arrayValue ?? [] {
            guard let name = pair.arrayValue?.first?.stringValue,
                  !unsupported.contains(Self.normalizedName(name)),
                  !placed.contains(name),
                  let command = row(pair, category: ""),
                  placed.insert(name).inserted else { continue }
            commands.append(command)
        }

        let hiddenCount = result["skill_count"]?.intValue ?? skillEntries.count
        let compatibility = hiddenCount > 0
            ? "\(hiddenCount) standalone Hermes skill command\(hiddenCount == 1 ? " is" : "s are") hidden because slash.exec refuses them and Talaria will not retry through command.dispatch."
            : ""
        let serverWarning = result["warning"]?.stringValue ?? ""
        let warning = [serverWarning, compatibility].filter { !$0.isEmpty }
            .joined(separator: "\n")
        self.init(commands: commands, skillCount: 0, warning: warning,
                  unsupportedStandaloneSkillNames: unsupported)
    }
}

public enum MCPSetupResponseReceipt: Sendable, Equatable {
    case accepted
    case expired

    init(result: JSONValue) throws {
        switch result["status"]?.stringValue {
        case "ok": self = .accepted
        case "expired": self = .expired
        default:
            throw GatewayError(code: 502,
                               message: "Hermes returned an uncertain mcp.setup.respond status.")
        }
    }
}

extension GatewayClient {

    // MARK: - Catalog

    /// The backend slash catalog. Categories keep their server-side order;
    /// rejected standalone-skill rows are recorded as a hidden safety fence.
    public func commandsCatalog() async throws -> SlashCatalog {
        let result = try await rpc("commands.catalog", .object([:]))
        guard let object = result.objectValue else {
            throw GatewayError(code: 502,
                               message: "Malformed commands.catalog result: expected an object.")
        }
        return SlashCatalog(result: object)
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

    /// Run a slash command against a live session. Worker-backed; c1e25 routes
    /// bundles/pending-input commands internally but rejects standalone skills.
    /// Talaria filters those rows before this boundary. Long timeout because
    /// /compress and /refine drive the model.
    public func execSlash(sessionID: String, command: String) async throws -> SlashExecutionResult {
        let result = try await rpc("slash.exec",
                                   ["session_id": .string(sessionID), "command": .string(command)],
                                   timeout: 300)
        guard let object = result.objectValue else {
            throw GatewayError(code: 502, message: "Malformed slash.exec result: expected an object.")
        }
        return try SlashExecutionResult(result: object)
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
                                  server: String, detail: String? = nil) async throws
        -> MCPSetupResponseReceipt {
        var outcome: [String: JSONValue] = ["status": .string(status), "server": .string(server)]
        if let detail, !detail.isEmpty { outcome["detail"] = .string(detail) }
        let data = try JSONEncoder().encode(JSONValue.object(outcome))
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw GatewayError(code: 500,
                               message: "Could not encode the MCP setup response.")
        }
        let result = try await rpc("mcp.setup.respond",
                                   ["request_id": .string(requestID),
                                    "result": .string(encoded)])
        return try MCPSetupResponseReceipt(result: result)
    }
}

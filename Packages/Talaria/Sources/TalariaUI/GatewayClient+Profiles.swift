import Foundation
import TalariaKit

// The profile-editor half of the profiles.* surface: the READ that must
// happen before any write, and a write that only names the sections the user
// actually touched.
//
// Why this file exists at all: profiles.configure applies every section it is
// handed (methods_profiles.py:660). `soul` is a FULL SOUL.md replacement,
// `disabled_skills` / `enabled_toolsets` are replace-semantics lists. An
// editor that opens with blank fields and saves them back therefore erases
// the real SOUL.md, re-enables every skill the user had disabled and drops
// the toolset pin. So: prefill from profiles.describe, then diff.
//
// Second contract detail with teeth: the model pin is written only when BOTH
// `model` and `provider` are present (`if model and provider:` — same file,
// and identically in profiles.create). A model-only configure is a silent
// no-op, which is why ModelChoice carries the provider slug alongside the id.

// MARK: - profiles.describe

/// Editor snapshot of one profile — everything the sheets need to prefill.
/// Mirrors profiles.describe (ws-protocol.md §11).
public struct ProfileSnapshot: Sendable, Equatable {

    public struct Skill: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var enabled: Bool

        public init(name: String, enabled: Bool) {
            self.name = name; self.enabled = enabled
        }
    }

    public struct Toolset: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var label: String
        public var detail: String
        public var toolCount: Int
        public var enabled: Bool

        public init(name: String, label: String, detail: String = "",
                    toolCount: Int = 0, enabled: Bool) {
            self.name = name; self.label = label; self.detail = detail
            self.toolCount = toolCount; self.enabled = enabled
        }
    }

    public struct MCPServer: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var enabled: Bool
        public var transport: String

        public init(name: String, enabled: Bool, transport: String) {
            self.name = name; self.enabled = enabled; self.transport = transport
        }
    }

    public var name: String
    public var description: String
    /// The profile's real SOUL.md, verbatim. Empty when the file is absent.
    public var soul: String
    /// model.default from the profile's config.yaml ("" = gateway default).
    public var model: String
    /// model.provider — required alongside `model` on every write.
    public var provider: String
    public var skills: [Skill]
    public var toolsets: [Toolset]
    /// True when the profile pins tools.enabled_toolsets; false = "all on".
    public var toolsetsPinned: Bool
    public var mcpServers: [MCPServer]

    public init(name: String, description: String = "", soul: String = "",
                model: String = "", provider: String = "",
                skills: [Skill] = [], toolsets: [Toolset] = [],
                toolsetsPinned: Bool = false, mcpServers: [MCPServer] = []) {
        self.name = name; self.description = description; self.soul = soul
        self.model = model; self.provider = provider
        self.skills = skills; self.toolsets = toolsets
        self.toolsetsPinned = toolsetsPinned; self.mcpServers = mcpServers
    }

    public init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        description = v["description"]?.stringValue ?? ""
        soul = v["soul"]?.stringValue ?? ""
        model = v["model"]?["default"]?.stringValue ?? ""
        provider = v["model"]?["provider"]?.stringValue ?? ""
        skills = (v["skills"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return Skill(name: name, enabled: row["enabled"]?.boolValue ?? true)
        }
        toolsets = (v["toolsets"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return Toolset(name: name,
                           label: row["label"]?.stringValue ?? name,
                           detail: row["description"]?.stringValue ?? "",
                           toolCount: row["tool_count"]?.intValue ?? 0,
                           enabled: row["enabled"]?.boolValue ?? false)
        }
        toolsetsPinned = v["toolsets_pinned"]?.boolValue ?? false
        mcpServers = (v["mcp_servers"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return MCPServer(name: name,
                             enabled: row["enabled"]?.boolValue ?? true,
                             transport: row["transport"]?.stringValue ?? "stdio")
        }
    }

    /// The disabled-skill list in the shape profiles.configure replaces.
    public var disabledSkills: [String] {
        skills.filter { !$0.enabled }.map(\.name).sorted()
    }

    /// The toolset pin in the shape profiles.configure replaces (an empty
    /// array clears the pin, so an unpinned profile reports nil).
    public var enabledToolsets: [String]? {
        toolsetsPinned ? toolsets.filter(\.enabled).map(\.name).sorted() : nil
    }
}

// MARK: - Dirty diff

/// The sections of a profiles.configure call the user actually changed.
/// Anything left nil is never sent, so the gateway leaves it alone.
public struct ProfileEdit: Sendable, Equatable {
    public var description: String?
    /// Full SOUL.md replacement — set ONLY when the editor loaded the real
    /// soul first and the user then edited it.
    public var soul: String?
    public var model: String?
    public var provider: String?
    public var disabledSkills: [String]?
    public var enabledToolsets: [String]?
    public var uiMeta: JSONValue?

    public init(description: String? = nil, soul: String? = nil,
                model: String? = nil, provider: String? = nil,
                disabledSkills: [String]? = nil, enabledToolsets: [String]? = nil,
                uiMeta: JSONValue? = nil) {
        self.description = description; self.soul = soul
        self.model = model; self.provider = provider
        self.disabledSkills = disabledSkills; self.enabledToolsets = enabledToolsets
        self.uiMeta = uiMeta
    }

    public var isEmpty: Bool {
        description == nil && soul == nil && model == nil && disabledSkills == nil
            && enabledToolsets == nil && uiMeta == nil
    }

    public var isWireValid: Bool {
        model == nil || provider?.isEmpty == false
    }

    /// Per-section acknowledgements profiles.configure must return for this
    /// exact dirty diff. The gateway applies sections independently, so an RPC
    /// success is not itself a successful editor save.
    public var expectedAppliedSections: Set<String> {
        var sections = Set<String>()
        if description != nil { sections.insert("description") }
        if soul != nil { sections.insert("soul") }
        if model != nil, provider?.isEmpty == false { sections.insert("model") }
        if disabledSkills != nil { sections.insert("skills") }
        if enabledToolsets != nil { sections.insert("toolsets") }
        if uiMeta != nil { sections.insert("ui_meta") }
        return sections
    }

    public func wasFullyApplied(_ applied: [String: Bool]) -> Bool {
        isWireValid && expectedAppliedSections.allSatisfy { applied[$0] == true }
    }

    /// profiles.configure params. The model pin is dropped unless a provider
    /// rides with it — the gateway would ignore a lone model silently.
    public func params(name: String) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let model, let provider, !provider.isEmpty {
            params["model"] = .string(model)
            params["provider"] = .string(provider)
        }
        if let disabledSkills {
            params["disabled_skills"] = .array(disabledSkills.map(JSONValue.string))
        }
        if let enabledToolsets {
            params["enabled_toolsets"] = .array(enabledToolsets.map(JSONValue.string))
        }
        if let uiMeta { params["ui_meta"] = uiMeta }
        return .object(params)
    }
}

// MARK: - Model catalog

/// One pickable model plus the provider slug the pin write requires.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    public var id: String { model }
    public var model: String
    public var provider: String
    public var providerName: String
    public var isCurrent: Bool

    public init(model: String, provider: String, providerName: String = "",
                isCurrent: Bool = false) {
        self.model = model; self.provider = provider
        self.providerName = providerName; self.isCurrent = isCurrent
    }
}

/// image.generate outcome — a portrait is only usable when the gateway
/// inlined the bytes; a bare `image` URL points at the gateway host's disk.
public struct GeneratedPortrait: Sendable {
    /// False when the gateway has no image provider at all.
    public var available: Bool
    public var dataURL: String?
    /// A gateway-host path or provider URL — present when the bytes were too
    /// large to inline. Useless to a phone, but worth reporting as such.
    public var remoteReference: String?
    public var error: String?
}

extension GatewayClient {

    /// profiles.describe → the editor snapshot. Must run before any write
    /// that touches soul / skills / toolsets.
    func profileSnapshot(_ name: String) async throws -> ProfileSnapshot {
        ProfileSnapshot(try await describeProfile(name))
    }

    /// profiles.configure with a dirty diff. Returns the per-section
    /// `applied` map so a caller can tell a partial save from a clean one.
    @discardableResult
    func applyProfileEdit(name: String, _ edit: ProfileEdit) async throws -> [String: Bool] {
        guard !edit.isEmpty else { return [:] }
        let result = try await rpc("profiles.configure", edit.params(name: name))
        return (result["applied"]?.objectValue ?? [:]).compactMapValues(\.boolValue)
    }

    /// model.options flattened to (model, provider) pairs. Provider rows are
    /// `{slug, name, is_current, models:[id]}` (hermes_cli/inventory.py
    /// build_models_payload); the session's current model is listed first so
    /// the picker opens on the active pin.
    func modelChoices() async throws -> [ModelChoice] {
        let payload = try await modelOptions()
        let currentModel = payload["model"]?.stringValue ?? ""
        let currentProvider = payload["provider"]?.stringValue ?? ""

        var choices: [ModelChoice] = []
        var seen = Set<String>()
        func add(_ choice: ModelChoice) {
            guard !choice.model.isEmpty, seen.insert(choice.model).inserted else { return }
            choices.append(choice)
        }

        if !currentModel.isEmpty {
            add(ModelChoice(model: currentModel, provider: currentProvider,
                            providerName: currentProvider, isCurrent: true))
        }
        for provider in payload["providers"]?.arrayValue ?? [] {
            let slug = provider["slug"]?.stringValue ?? ""
            let label = provider["name"]?.stringValue ?? slug
            for entry in provider["models"]?.arrayValue ?? [] {
                let id = entry.stringValue ?? (entry["id"] ?? entry["model"])?.stringValue ?? ""
                add(ModelChoice(model: id, provider: slug, providerName: label,
                                isCurrent: id == currentModel))
            }
        }
        return choices
    }

    /// image.generate probe — cheap availability check so the portrait
    /// button can hide itself on gateways with no image provider.
    func imageGenerationAvailable() async -> Bool {
        guard let result = try? await rpc("image.generate", ["probe": .bool(true)], timeout: 30)
        else { return false }
        return result["available"]?.boolValue ?? false
    }

    /// Generate a square portrait. `max_bytes` is asked below the 2 MB
    /// profiles.set_asset ceiling headroom we re-encode into, so the common
    /// case needs no downscale; the gateway omits `image_data` when the
    /// download exceeds the cap and we degrade to reporting the reference.
    func generatePortrait(prompt: String) async throws -> GeneratedPortrait {
        let result = try await rpc("image.generate",
                                   ["prompt": .string(prompt),
                                    "aspect_ratio": "square",
                                    "max_bytes": .number(6_000_000)],
                                   timeout: 300)
        let data = result["image_data"]?.stringValue
        return GeneratedPortrait(available: result["available"]?.boolValue ?? true,
                                 dataURL: data.flatMap { $0.hasPrefix("data:") ? $0 : nil },
                                 remoteReference: result["image"]?.stringValue,
                                 error: result["error"]?.stringValue)
    }

    /// profiles.set_asset {clear:true} — drop a custom portrait and fall back
    /// to the geometric avatar.
    func clearProfileAvatar(name: String) async throws {
        try await rpc("profiles.set_asset",
                      ["name": .string(name), "asset": "avatar", "clear": .bool(true)])
    }
}

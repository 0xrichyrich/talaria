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

/// A stale per-key `ui_meta` precondition reported by profiles.configure.
public struct ProfileUIMetaConflict: Sendable, Equatable {
    public var expected: Int
    public var actual: Int

    public init(expected: Int, actual: Int) {
        self.expected = expected
        self.actual = actual
    }
}

/// Typed profiles.configure acknowledgement. Hermes nests the CAS fields in
/// `result.applied` beside the ordinary per-section booleans.
public struct ProfileConfigureResult: Sendable, Equatable {
    public var applied: [String: Bool]
    public var uiMetaRevisions: [String: Int]?
    public var uiMetaConflicts: [String: ProfileUIMetaConflict]?

    /// True when a present applied/CAS field had the wrong shape. Consumers
    /// must not interpret a malformed authoritative response as legacy
    /// silence or as a successful write.
    public var hasMalformedUIMetaCASFields: Bool

    init(_ result: JSONValue) {
        applied = [:]
        uiMetaRevisions = nil
        uiMetaConflicts = nil
        hasMalformedUIMetaCASFields = false

        guard let appliedNode = result["applied"] else { return }
        guard let fields = appliedNode.objectValue else {
            hasMalformedUIMetaCASFields = true
            return
        }
        // Preserve the legacy wrapper's exact compact-map behavior, including
        // arbitrary future boolean section keys. Typed CAS parsing below is
        // additive and never changes what existing callers receive.
        applied = fields.compactMapValues(\.boolValue)

        for (key, value) in fields {
            switch key {
            case "ui_meta_revisions":
                let decoded = ProfileUIMetaRevisionWire.decodeMap(value)
                uiMetaRevisions = decoded.value
                hasMalformedUIMetaCASFields = hasMalformedUIMetaCASFields || !decoded.isValid
            case "ui_meta_conflicts":
                guard let rawConflicts = value.objectValue else {
                    hasMalformedUIMetaCASFields = true
                    continue
                }
                var conflicts: [String: ProfileUIMetaConflict] = [:]
                for (metaKey, rawConflict) in rawConflicts {
                    guard let conflict = rawConflict.objectValue,
                          Set(conflict.keys) == ["expected", "actual"],
                          let expected = ProfileUIMetaRevisionWire.decode(conflict["expected"]),
                          let actual = ProfileUIMetaRevisionWire.decode(conflict["actual"]) else {
                        hasMalformedUIMetaCASFields = true
                        conflicts.removeAll()
                        break
                    }
                    conflicts[metaKey] = ProfileUIMetaConflict(
                        expected: expected, actual: actual)
                }
                if !hasMalformedUIMetaCASFields { uiMetaConflicts = conflicts }
            default:
                guard value.boolValue != nil else {
                    hasMalformedUIMetaCASFields = true
                    continue
                }
            }
        }
    }

    fileprivate static let empty = ProfileConfigureResult(.object(["applied": .object([:])]))
}

/// The fail-closed commit fence for a CAS ui_meta write. A successful RPC is
/// insufficient: Hermes must affirm the section, report no conflict field,
/// and return exactly the requested keys advanced by exactly one revision.
public enum ProfileUIMetaCASPolicy {
    public static func confirmsCommit(expectedRevisions: [String: Int],
                                      result: ProfileConfigureResult) -> Bool {
        guard !expectedRevisions.isEmpty,
              result.applied["ui_meta"] == true,
              !result.hasMalformedUIMetaCASFields,
              result.uiMetaConflicts == nil,
              let returned = result.uiMetaRevisions,
              Set(returned.keys) == Set(expectedRevisions.keys) else {
            return false
        }
        return expectedRevisions.allSatisfy { key, expected in
            guard ProfileUIMetaRevisionWire.isRequestSafe(expected) else { return false }
            let (next, overflow) = expected.addingReportingOverflow(1)
            return !overflow && returned[key] == next
        }
    }
}

private enum ProfileUIMetaRevisionWire {
    static func decode(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue,
              number.isFinite,
              let revision = Int(exactly: number),
              revision >= 0 else { return nil }
        return revision
    }

    static func decodeMap(_ value: JSONValue?)
        -> (value: [String: Int]?, isValid: Bool) {
        guard let value else { return (nil, true) }
        guard let object = value.objectValue else { return (nil, false) }
        var revisions: [String: Int] = [:]
        revisions.reserveCapacity(object.count)
        for (key, raw) in object {
            guard let revision = decode(raw) else { return (nil, false) }
            revisions[key] = revision
        }
        return (revisions, true)
    }

    /// JSONValue encodes integers through Double. Refuse a value whose exact
    /// integer identity (or the required +1 acknowledgement) would be lost.
    static func isRequestSafe(_ revision: Int) -> Bool {
        guard revision >= 0,
              Int(exactly: Double(revision)) == revision else { return false }
        let (next, overflow) = revision.addingReportingOverflow(1)
        return !overflow && Int(exactly: Double(next)) == next
    }
}

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
    /// Per-top-level-key compare-and-swap preconditions. Omit for the bounded
    /// legacy best-effort path; when present, the key set must exactly match
    /// the `uiMeta` patch so no key can slip through without a precondition.
    public var uiMetaExpectedRevisions: [String: Int]?

    public init(description: String? = nil, soul: String? = nil,
                model: String? = nil, provider: String? = nil,
                disabledSkills: [String]? = nil, enabledToolsets: [String]? = nil,
                uiMeta: JSONValue? = nil,
                uiMetaExpectedRevisions: [String: Int]? = nil) {
        self.description = description; self.soul = soul
        self.model = model; self.provider = provider
        self.disabledSkills = disabledSkills; self.enabledToolsets = enabledToolsets
        self.uiMeta = uiMeta
        self.uiMetaExpectedRevisions = uiMetaExpectedRevisions
    }

    public var isEmpty: Bool {
        description == nil && soul == nil && model == nil && disabledSkills == nil
            && enabledToolsets == nil && uiMeta == nil && uiMetaExpectedRevisions == nil
    }

    public var isWireValid: Bool {
        (model == nil || provider?.isEmpty == false) && hasValidUIMetaCASRequest
    }

    /// Local request fence. The exact Hermes server checks every incoming
    /// ui_meta key independently, while extra expectation keys are ignored;
    /// exact equality here avoids both unprotected and misleading keys.
    var hasValidUIMetaCASRequest: Bool {
        guard let expected = uiMetaExpectedRevisions else { return true }
        guard let patch = uiMeta?.objectValue,
              !patch.isEmpty,
              Set(patch.keys) == Set(expected.keys) else { return false }
        return expected.values.allSatisfy(ProfileUIMetaRevisionWire.isRequestSafe)
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
        if let uiMetaExpectedRevisions, hasValidUIMetaCASRequest {
            params["ui_meta_expected_revisions"] = .object(
                uiMetaExpectedRevisions.mapValues { .number(Double($0)) })
        }
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
        // CAS callers need revisions/conflicts and must use the detailed path;
        // returning only booleans would make a bare ui_meta=true look safe.
        guard edit.uiMetaExpectedRevisions == nil else {
            throw GatewayError(code: -8,
                               message: "ui_meta CAS requires the detailed configure result")
        }
        let result = try await rpc("profiles.configure", edit.params(name: name))
        // Kept byte-for-byte equivalent to the pre-CAS projection for every
        // existing caller and every legacy/future applied section.
        return (result["applied"]?.objectValue ?? [:]).compactMapValues(\.boolValue)
    }

    /// Detailed profiles.configure result for CAS-aware callers. Existing
    /// callers intentionally retain the compact per-section map above; only a
    /// caller that checks `ProfileUIMetaCASPolicy` may treat a CAS write as
    /// committed.
    func applyProfileEditResult(name: String, _ edit: ProfileEdit) async throws
        -> ProfileConfigureResult {
        guard !edit.isEmpty else { return .empty }
        guard edit.hasValidUIMetaCASRequest else {
            throw GatewayError(code: -8,
                               message: "ui_meta CAS revisions were invalid or incomplete")
        }
        return ProfileConfigureResult(
            try await rpc("profiles.configure", edit.params(name: name)))
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

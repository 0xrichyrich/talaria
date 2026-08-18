import Foundation
import SwiftUI
import TalariaKit
import TalariaTheme

// Live logic behind the Capabilities screen: what a bot can actually do —
// skills, MCP servers, toolsets and gateway plugins — read and written over
// the RPCs wrapped in GatewayClient+Capabilities.swift.
//
// Two rules shape everything here:
//
// 1. Enablement is read from profiles.describe, never from the runtime
//    catalogs. skills.manage's list filters disabled skills out AND caches the
//    tree walk per gateway process, and toolsets.list reports the *launch*
//    profile's pin — both would misreport another bot's state. describe walks
//    the profile's own dirs and resolves its pin, so it is the truth.
// 2. A gateway that doesn't know an RPC answers -32601. That is not an error
//    worth showing: the section simply isn't there, so it is hidden. Real
//    failures (5024 &c.) keep the section and raise a themed notice.

// MARK: - Sections

public enum CapabilitySection: String, CaseIterable, Sendable, Identifiable {
    case skills, mcp, toolsets, plugins
    public var id: String { rawValue }
}

// MARK: - Screen state

/// Observable state for one profile's capabilities. `AppModel`'s stored
/// properties live in a file this feature doesn't own and extensions cannot
/// add storage, so the per-profile stores hang off a MainActor side table
/// (same pattern as LiveRuntime).
@MainActor
@Observable
public final class CapabilityState {
    /// Profile (bot id) these capabilities belong to. Empty = launch profile.
    public var profile: String = ""

    public var skills: [SkillEntry] = []
    public var mcpServers: [MCPServer] = []
    public var mcpCatalog: [MCPCatalogEntry] = []
    public var toolsets: [ToolsetEntry] = []
    public var toolsetsPinned = false
    public var plugins: [GatewayPlugin] = []

    /// Sections this gateway actually answered. Anything absent is hidden.
    public var supported: Set<CapabilitySection> = []
    /// Last probe result per MCP server name (mcp.servers.test).
    public var probes: [String: MCPProbeResult] = [:]

    public var isLoading = false
    /// True once a load has completed, so the empty state isn't shown first.
    public var hasLoaded = false
    /// Themed one-line explanation of the last failure; nil when all is well.
    public var notice: String?
    /// Rows with an action in flight, keyed "<section>:<id>".
    public var busy: Set<String> = []

    public func supports(_ section: CapabilitySection) -> Bool {
        supported.contains(section)
    }

    public func isBusy(_ key: String) -> Bool { busy.contains(key) }

    /// Nothing to show at all — every section is either unsupported or empty.
    public var isEmpty: Bool {
        skills.isEmpty && mcpServers.isEmpty && mcpCatalog.isEmpty
            && toolsets.isEmpty && plugins.isEmpty
    }
}

/// Per-profile stores + the in-flight OAuth polls, keyed by profile.
@MainActor
final class CapabilityRuntime {
    static let shared = CapabilityRuntime()
    var states: [String: CapabilityState] = [:]
}

// MARK: - Model API

extension AppModel {

    /// The (memoized) capability store for a bot. Pass nil for the gateway's
    /// launch profile.
    public func capabilities(for profile: String?) -> CapabilityState {
        let key = profile ?? ""
        if let existing = CapabilityRuntime.shared.states[key] { return existing }
        let fresh = CapabilityState()
        fresh.profile = key
        CapabilityRuntime.shared.states[key] = fresh
        return fresh
    }

    /// The profile a Capabilities screen should open on when the caller has no
    /// specific bot in mind: the gateway's default profile, else the first bot.
    public var defaultCapabilityProfile: String? {
        LiveRuntime.shared.defaultBotID ?? bots.first?.id
    }

    /// Ask the root view to push Capabilities for a bot. Screens this feature
    /// doesn't own (bot sheet, Connections) call this instead of constructing
    /// the view themselves.
    public func requestCapabilities(profile: String?) {
        NotificationCenter.default.post(
            name: .talariaOpenCapabilities, object: nil,
            userInfo: profile.map { ["profile": $0] } ?? [:])
    }

    // MARK: Load

    /// Fill every section, hiding the ones this gateway doesn't implement.
    /// Safe to call repeatedly; concurrent calls collapse onto the first.
    public func loadCapabilities(profile: String?) async {
        let state = capabilities(for: profile)
        guard !state.isLoading else { return }
        state.isLoading = true
        state.notice = nil
        defer {
            state.isLoading = false
            state.hasLoaded = true
        }

        guard mode == .live, let client else {
            CapabilityDemo.fill(state, skills: skills)
            return
        }
        let scope = profile?.isEmpty == false ? profile : nil

        // 1. profiles.describe — the per-profile truth for skills + toolsets.
        //    It requires a name, so the launch-profile view skips it and falls
        //    back to the runtime catalogs (read-only, as they cannot be
        //    attributed to a profile).
        var described: ProfileCapabilities?
        if let scope {
            if case .value(let value) = await Self.probe({
                try await client.profileCapabilities(scope)
            }) {
                described = value
            }
        }

        // 2. Shared skill catalog: category annotations plus the skills that
        //    live outside this profile's own dir.
        var catalog: [String: [String]] = [:]
        var skillsSupported = described != nil
        switch await Self.probe({ try await client.skillCatalog(profile: scope) }) {
        case .value(let value):
            catalog = value
            skillsSupported = true
        case .unsupported:
            break
        case .failed(let message):
            state.notice = noticeText(message)
        }
        state.skills = Self.mergeSkills(described: described, catalog: catalog)
        Self.setSupport(state, .skills, skillsSupported || !state.skills.isEmpty)

        // 3. Toolsets: describe when it answered, else the launch-profile
        //    universe. tools.list only contributes tool *names*, which are
        //    profile-independent.
        var toolsets = described?.toolsets ?? []
        var toolsetsSupported = !toolsets.isEmpty
        switch await Self.probe({ try await client.toolsList() }) {
        case .value(let universe):
            toolsetsSupported = true
            if toolsets.isEmpty {
                toolsets = universe
            } else {
                let toolsByName = Dictionary(universe.map { ($0.name, $0.tools) },
                                             uniquingKeysWith: { a, _ in a })
                for index in toolsets.indices {
                    toolsets[index].tools = toolsByName[toolsets[index].name] ?? []
                }
            }
        case .unsupported, .failed:
            break
        }
        state.toolsets = toolsets
        state.toolsetsPinned = described?.toolsetsPinned ?? false
        Self.setSupport(state, .toolsets, toolsetsSupported)

        // 4. MCP: configured servers + the bundled catalog.
        var mcpSupported = false
        switch await Self.probe({ try await client.mcpServers(profile: scope) }) {
        case .value(let servers):
            state.mcpServers = servers
            mcpSupported = true
        case .unsupported:
            state.mcpServers = []
        case .failed(let message):
            state.mcpServers = []
            mcpSupported = true
            state.notice = noticeText(message)
        }
        switch await Self.probe({ try await client.mcpCatalog(profile: scope) }) {
        case .value(let entries):
            state.mcpCatalog = entries
            mcpSupported = true
        case .unsupported, .failed:
            state.mcpCatalog = []
        }
        Self.setSupport(state, .mcp, mcpSupported)

        // 5. Gateway plugins.
        switch await Self.probe({ try await client.pluginsList(profile: scope) }) {
        case .value(let rows):
            state.plugins = rows
            Self.setSupport(state, .plugins, true)
        case .unsupported:
            state.plugins = []
            Self.setSupport(state, .plugins, false)
        case .failed(let message):
            state.plugins = []
            Self.setSupport(state, .plugins, true)
            state.notice = noticeText(message)
        }
    }

    // MARK: Skills

    /// Flip one profile-local skill. `disabled_skills` is a full replacement,
    /// so the whole profile-scope disabled set is recomputed and sent.
    public func setSkill(_ skill: SkillEntry, enabled: Bool, profile: String?) async {
        let state = capabilities(for: profile)
        guard let index = state.skills.firstIndex(where: { $0.id == skill.id }),
              state.skills[index].scope == .profile else { return }
        let previous = state.skills[index].enabled
        state.skills[index].enabled = enabled

        guard mode == .live, let client, let name = profile, !name.isEmpty else { return }
        let key = "skill:\(skill.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        let disabled = state.skills.filter { $0.scope == .profile && !$0.enabled }.map(\.name)
        do {
            try await client.configureProfile(name: name, disabledSkills: disabled)
            state.notice = nil
        } catch {
            state.skills[index].enabled = previous
            state.notice = noticeText(Self.shortMessage(error))
        }
    }

    /// skills.reload — rescan the tree after an install or a file edit.
    public func rescanSkills(profile: String?) async {
        let state = capabilities(for: profile)
        guard mode == .live, let client else { return }
        state.busy.insert("skills:reload")
        defer { state.busy.remove("skills:reload") }
        do {
            _ = try await client.reloadSkills()
            state.notice = nil
        } catch let error as GatewayError where error.code == GatewayClient.methodNotFound {
            // An older gateway simply has no rescan; the list is still valid.
            return
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
            return
        }
        await loadCapabilities(profile: profile)
    }

    // MARK: Toolsets

    /// Enable/disable a toolset for this profile. Everything-on is expressed
    /// by clearing the pin (empty list) rather than pinning every current
    /// name, so toolsets added to the gateway later stay available.
    public func setToolset(_ toolset: ToolsetEntry, enabled: Bool, profile: String?) async {
        let state = capabilities(for: profile)
        guard let index = state.toolsets.firstIndex(where: { $0.id == toolset.id }) else { return }
        let previous = state.toolsets[index].enabled
        state.toolsets[index].enabled = enabled

        guard mode == .live, let client else { return }
        // Writing the pin needs a profile to write it to; the launch-profile
        // view is read-only rather than silently dropping the change.
        guard let name = profile, !name.isEmpty else {
            state.toolsets[index].enabled = previous
            return
        }
        let key = "toolset:\(toolset.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        let allOn = state.toolsets.allSatisfy(\.enabled)
        let names = allOn ? [] : state.toolsets.filter(\.enabled).map(\.name)
        do {
            try await client.setProfileToolsets(name: name, enabled: names)
            state.toolsetsPinned = !allOn
            state.notice = nil
        } catch {
            state.toolsets[index].enabled = previous
            state.notice = noticeText(Self.shortMessage(error))
        }
    }

    // MARK: Plugins

    public func setPlugin(_ plugin: GatewayPlugin, enabled: Bool, profile: String?) async {
        let state = capabilities(for: profile)
        guard let index = state.plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        guard mode == .live, let client else {
            state.plugins[index].status = enabled ? "enabled" : "not enabled"
            return
        }
        let key = "plugin:\(plugin.id)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            let refreshed = try await client.pluginToggle(
                profile: profile?.isEmpty == false ? profile : nil,
                key: plugin.key.isEmpty ? plugin.name : plugin.key, enable: enabled)
            if let refreshed {
                state.plugins[index] = refreshed
            } else {
                state.plugins[index].status = enabled ? "enabled" : "not enabled"
            }
            state.notice = nil
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
        }
    }

    // MARK: MCP

    /// Connect + tools/list probe. A failed connect comes back as data
    /// (`ok:false`), not a thrown error, so it renders in the row either way.
    @discardableResult
    public func testMCPServer(_ server: MCPServer, profile: String?) async -> MCPProbeResult? {
        let state = capabilities(for: profile)
        guard mode == .live, let client else {
            let probe = CapabilityDemo.probe(for: server)
            state.probes[server.name] = probe
            return probe
        }
        let key = "mcp:\(server.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            let probe = try await client.mcpTestServer(
                profile: profile?.isEmpty == false ? profile : nil, name: server.name)
            state.probes[server.name] = probe
            state.notice = nil
            return probe
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
            return nil
        }
    }

    /// Install a bundled catalog entry into this profile's config.yaml.
    public func installCatalogServer(_ entry: MCPCatalogEntry, profile: String?) async {
        let state = capabilities(for: profile)
        guard mode == .live, let client else {
            CapabilityDemo.install(entry, into: state)
            return
        }
        let key = "catalog:\(entry.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            try await client.mcpAddFromCatalog(
                profile: profile?.isEmpty == false ? profile : nil, name: entry.name)
            state.notice = nil
            await refreshMCP(profile: profile)
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
        }
    }

    /// Add a hand-configured server. Returns false (with a notice set) when the
    /// gateway rejects the config, so the sheet can stay open.
    public func addMCPServer(name: String, url: String?, command: String?,
                             args: [String], profile: String?) async -> Bool {
        let state = capabilities(for: profile)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard mode == .live, let client else {
            CapabilityDemo.add(name: trimmed, url: url, command: command,
                               args: args, into: state)
            return true
        }
        state.busy.insert("mcp:add")
        defer { state.busy.remove("mcp:add") }
        do {
            try await client.mcpAddServer(
                profile: profile?.isEmpty == false ? profile : nil,
                name: trimmed, url: url, command: command, args: args)
            state.notice = nil
            await refreshMCP(profile: profile)
            return true
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
            return false
        }
    }

    public func removeMCPServer(_ server: MCPServer, profile: String?) async {
        let state = capabilities(for: profile)
        guard mode == .live, let client else {
            state.mcpServers.removeAll { $0.name == server.name }
            state.probes[server.name] = nil
            return
        }
        let key = "mcp:\(server.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            try await client.mcpRemoveServer(
                profile: profile?.isEmpty == false ? profile : nil, name: server.name)
            state.mcpServers.removeAll { $0.name == server.name }
            state.probes[server.name] = nil
            state.notice = nil
            await refreshMCP(profile: profile)
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
        }
    }

    /// Store a credential for a server. The value never touches this app's
    /// storage — it goes straight to the profile's .env on the gateway.
    public func setMCPAPIKey(_ server: MCPServer, value: String,
                             envVar: String?, profile: String?) async -> Bool {
        let state = capabilities(for: profile)
        guard !value.isEmpty else { return false }
        guard mode == .live, let client else { return true }
        let key = "mcp:\(server.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            try await client.mcpSetAPIKey(
                profile: profile?.isEmpty == false ? profile : nil,
                name: server.name, value: value, envVar: envVar)
            state.notice = nil
            await refreshMCP(profile: profile)
            return true
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
            return false
        }
    }

    /// Begin the gateway-side OAuth flow and hand back the URL to open. The
    /// gateway owns the loopback listener that catches the redirect, so the
    /// phone only opens the page and polls.
    public func beginMCPOAuth(_ server: MCPServer, profile: String?) async -> MCPOAuthFlow? {
        let state = capabilities(for: profile)
        guard mode == .live, let client else { return nil }
        let key = "mcp:\(server.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }
        do {
            let flow = try await client.mcpOAuthStart(
                profile: profile?.isEmpty == false ? profile : nil, name: server.name)
            state.notice = nil
            return flow
        } catch {
            state.notice = noticeText(Self.shortMessage(error))
            return nil
        }
    }

    /// Poll a started flow to completion (or the three-minute ceiling the
    /// desktop flow also uses). On approval the server list is refreshed so
    /// the row's "needs sign-in" badge clears.
    @discardableResult
    public func awaitMCPOAuth(_ server: MCPServer, flow: MCPOAuthFlow,
                              profile: String?) async -> MCPOAuthStatus {
        let state = capabilities(for: profile)
        guard mode == .live, let client else {
            return MCPOAuthStatus(status: "error", errorMessage: nil, authURL: nil)
        }
        let key = "mcp:\(server.name)"
        state.busy.insert(key)
        defer { state.busy.remove(key) }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            let status: MCPOAuthStatus
            do {
                status = try await client.mcpOAuthPoll(
                    profile: profile?.isEmpty == false ? profile : nil,
                    name: server.name, sessionID: flow.sessionID)
            } catch {
                let message = Self.shortMessage(error)
                state.notice = noticeText(message)
                return MCPOAuthStatus(status: "error", errorMessage: message, authURL: nil)
            }
            if status.isPending { continue }
            if status.isApproved {
                await refreshMCP(profile: profile)
                _ = await testMCPServer(server, profile: profile)
            } else if let message = status.errorMessage {
                state.notice = noticeText(message)
            }
            return status
        }
        return MCPOAuthStatus(status: "pending", errorMessage: nil, authURL: nil)
    }

    /// Re-read just the MCP slice after a write.
    private func refreshMCP(profile: String?) async {
        let state = capabilities(for: profile)
        guard mode == .live, let client else { return }
        let scope = profile?.isEmpty == false ? profile : nil
        if case .value(let servers) = await Self.probe({ try await client.mcpServers(profile: scope) }) {
            state.mcpServers = servers
        }
        if case .value(let entries) = await Self.probe({ try await client.mcpCatalog(profile: scope) }) {
            state.mcpCatalog = entries
        }
    }

    // MARK: - Helpers

    /// Outcome of one capability probe: a value, "this gateway has no such
    /// RPC" (hide the section), or a real failure (keep it, show a notice).
    enum CapabilityProbe<T> {
        case value(T)
        case unsupported
        case failed(String)
    }

    static func probe<T>(_ body: () async throws -> T) async -> CapabilityProbe<T> {
        do {
            return .value(try await body())
        } catch let error as GatewayError where error.code == GatewayClient.methodNotFound {
            return .unsupported
        } catch {
            return .failed(shortMessage(error))
        }
    }

    private static func setSupport(_ state: CapabilityState,
                                   _ section: CapabilitySection, _ supported: Bool) {
        if supported {
            state.supported.insert(section)
        } else {
            state.supported.remove(section)
        }
    }

    static func shortMessage(_ error: Error) -> String {
        if let error = error as? GatewayError { return error.message }
        return error.localizedDescription
    }

    /// "<themed lead> — <gateway message>", clipped so a stack trace from a
    /// 5024 doesn't take over the screen.
    private func noticeText(_ detail: String) -> String {
        let lead = theme.copy.capNoticeLead(theme.themeID)
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lead }
        let clipped = trimmed.count > 160
            ? String(trimmed.prefix(160)).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        return "\(lead) — \(clipped)"
    }

    /// Union of the profile's own skills (authoritative enable state) and the
    /// shared catalog (category annotations + skills outside the profile dir).
    static func mergeSkills(described: ProfileCapabilities?,
                            catalog: [String: [String]]) -> [SkillEntry] {
        var categoryByName: [String: String] = [:]
        for (category, names) in catalog {
            for name in names where categoryByName[name] == nil {
                categoryByName[name] = category
            }
        }
        var rows = (described?.skills ?? []).map { flag in
            SkillEntry(name: flag.name, category: categoryByName[flag.name] ?? "",
                       scope: .profile, enabled: flag.enabled)
        }
        let owned = Set(rows.map(\.name))
        for (category, names) in catalog {
            for name in names where !owned.contains(name) {
                // The catalog only lists enabled skills, so a shared row is
                // enabled by definition.
                rows.append(SkillEntry(name: name, category: category,
                                       scope: .shared, enabled: true))
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.scope != rhs.scope { return lhs.scope == .profile }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Deep link

public extension Notification.Name {
    /// Posted by `AppModel.requestCapabilities(profile:)`; the root view pushes
    /// the Capabilities screen for `userInfo["profile"]`.
    static let talariaOpenCapabilities = Notification.Name("talaria.open.capabilities")
}

// MARK: - Demo world

/// The canned capabilities world. DemoData lives in TalariaKit and isn't this
/// feature's to extend, so the fixtures that only this screen needs live here;
/// the skill names still come from DemoData via `AppModel.skills`.
enum CapabilityDemo {

    @MainActor
    static func fill(_ state: CapabilityState, skills names: [String]) {
        state.skills = names.enumerated().map { index, name in
            SkillEntry(name: name, category: categories[index % categories.count],
                       scope: .profile, enabled: name != "browser")
        }
        state.mcpServers = servers
        state.mcpCatalog = catalog
        state.toolsets = toolsets
        state.toolsetsPinned = true
        state.plugins = plugins
        state.supported = Set(CapabilitySection.allCases)
        state.notice = nil
    }

    @MainActor
    static func install(_ entry: MCPCatalogEntry, into state: CapabilityState) {
        guard !state.mcpServers.contains(where: { $0.name == entry.name }) else { return }
        state.mcpServers.append(MCPServer(name: entry.name, transport: entry.transport,
                                          command: entry.transport == "stdio" ? "npx" : nil,
                                          args: entry.transport == "stdio" ? ["-y", entry.name] : [],
                                          envKeys: entry.requires))
        if let index = state.mcpCatalog.firstIndex(where: { $0.name == entry.name }) {
            state.mcpCatalog[index].installed = true
            state.mcpCatalog[index].enabled = true
        }
    }

    @MainActor
    static func add(name: String, url: String?, command: String?,
                    args: [String], into state: CapabilityState) {
        state.mcpServers.append(MCPServer(name: name,
                                          transport: (url?.isEmpty == false) ? "http" : "stdio",
                                          url: url, command: command, args: args))
    }

    static func probe(for server: MCPServer) -> MCPProbeResult {
        MCPProbeResult(ok: true,
                       tools: [MCPToolInfo(name: "\(server.name)_search", detail: "Search the index."),
                               MCPToolInfo(name: "\(server.name)_fetch", detail: "Fetch one record.")],
                       prompts: 0, resources: 2)
    }

    private static let categories = ["research", "communication", "system",
                                     "productivity", "media", "web"]

    private static let servers: [MCPServer] = [
        MCPServer(name: "filesystem", transport: "stdio", command: "npx",
                  args: ["-y", "@modelcontextprotocol/server-filesystem"]),
        MCPServer(name: "linear", transport: "http", url: "https://mcp.linear.app/sse",
                  auth: "oauth", oauthTokensPresent: false),
    ]

    private static let catalog: [MCPCatalogEntry] = [
        MCPCatalogEntry(name: "filesystem", detail: "Read and write local files.",
                        installed: true, enabled: true),
        MCPCatalogEntry(name: "linear", detail: "Issues, projects and cycles.",
                        installed: true, enabled: true, transport: "http"),
        MCPCatalogEntry(name: "brave-search", detail: "Web search over the Brave index.",
                        installed: false, enabled: false, requires: ["BRAVE_API_KEY"]),
    ]

    private static let toolsets: [ToolsetEntry] = [
        ToolsetEntry(name: "core", label: "Core", detail: "Read, write, edit, shell.",
                     toolCount: 9, enabled: true,
                     tools: ["read_file", "write_file", "edit_file", "run_shell"]),
        ToolsetEntry(name: "web", label: "Web", detail: "Fetch and search the open web.",
                     toolCount: 4, enabled: true, tools: ["web_search", "web_fetch"]),
        ToolsetEntry(name: "image_gen", label: "Image generation",
                     detail: "Generate and edit images.", toolCount: 2, enabled: false,
                     tools: ["image_generate"]),
    ]

    private static let plugins: [GatewayPlugin] = [
        GatewayPlugin(name: "talaria-push", key: "notify/talaria-push", version: "1.0.0",
                      detail: "APNs relay for approvals and mentions.",
                      source: "user", status: "enabled"),
        GatewayPlugin(name: "hermes-bots", key: "ui/hermes-bots", version: "6.2.0",
                      detail: "Bot-mode A2A protocol injection.",
                      source: "bundled", status: "enabled"),
        GatewayPlugin(name: "fal", key: "image_gen/fal", version: "0.4.1",
                      detail: "fal.ai image backend.", source: "bundled",
                      status: "not enabled"),
    ]
}

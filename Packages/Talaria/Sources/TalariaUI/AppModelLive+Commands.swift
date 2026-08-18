import SwiftUI
import TalariaKit
import TalariaTheme

// Live-mode slash commands + the mcp.setup answer path.
//
// Two jobs here:
//
// 1. Slash commands. Typed "/status" used to reach the LLM as prose; it now
//    goes through slash.exec against the bot's own session and its {output}
//    lands as a system row. The catalog behind the palette is fetched once per
//    gateway and cached.
//
// 2. The mcp.setup correctness fix. The gateway parks the agent's tool thread
//    for 600 s waiting on mcp.setup.respond; nothing in Talaria answered it, so
//    an agent-initiated MCP setup silently stalled the whole turn. We now
//    surface the request and answer it — including an immediate decline, which
//    is the difference between a 1-second "not here" and a 10-minute hang.
//
//    Talaria cannot actually run the flow: install/enable/authorize are REST +
//    browser-OAuth surfaces the desktop renderer owns (PUT /api/mcp/servers/
//    <name>/enabled and friends), with no WebSocket twin. So both buttons
//    answer `declined` — the one status the tool documents as "continue
//    without the server" — and differ only in the detail the agent reads.

// MARK: - Runtime state (side table)

/// Observable book-keeping for commands. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides alongside `LiveRuntime` as a MainActor singleton. It is `@Observable`
/// because the palette and the MCP prompt read it from a SwiftUI body.
@MainActor
@Observable
final class CommandsRuntime {
    static let shared = CommandsRuntime()

    /// Cached commands.catalog rows for `catalogOwner`.
    var catalog: [SlashCommand] = []
    var skillCount = 0
    /// Server-side discovery warning (skills/quick-commands), banner-worthy.
    var warning = ""
    /// The catalog RPC failed — the palette shows a themed retry state.
    var failed = false
    /// Identity of the client the cache belongs to; nil = the demo catalog.
    var catalogOwner: ObjectIdentifier?
    var catalogLoaded = false
    var catalogTask: Task<[SlashCommand], Never>?

    /// Unanswered mcp.setup.request events, oldest first. Each one is a parked
    /// agent thread, so the queue is normally 0 or 1 deep.
    var mcpRequests: [MCPSetupRequest] = []

    /// The client the event router is attached to, and its pump.
    var routerOwner: ObjectIdentifier?
    var routerPump: Task<Void, Never>?

    func invalidateCatalog(owner: ObjectIdentifier?) {
        catalogTask?.cancel()
        catalogTask = nil
        catalog = []
        skillCount = 0
        warning = ""
        failed = false
        catalogLoaded = false
        catalogOwner = owner
    }
}

// MARK: - MCP setup request

/// A parked `mcp.setup.request` (server.py:6228 → _block, 600 s).
public struct MCPSetupRequest: Identifiable, Sendable, Equatable {
    public enum Action: String, Sendable, Equatable { case install, enable, authorize }

    public var id: String { requestID }
    public var requestID: String
    /// Runtime session id the request belongs to ("" for a global emit).
    public var sessionID: String
    /// Catalog name (install) or configured server name (enable/authorize).
    public var server: String
    public var action: Action
    /// The agent's justification, shown verbatim.
    public var reason: String

    init?(_ event: GatewayEvent) {
        let payload = event.payload
        let requestID = payload?["request_id"]?.stringValue ?? ""
        let server = payload?["server"]?.stringValue ?? ""
        guard !requestID.isEmpty, !server.isEmpty else { return nil }
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.server = server
        // The tool validates the enum before emitting; anything else is a
        // newer gateway and installs are the documented default.
        self.action = Action(rawValue: payload?["action"]?.stringValue ?? "") ?? .install
        self.reason = payload?["reason"]?.stringValue ?? ""
    }

    public init(requestID: String, sessionID: String, server: String,
                action: Action, reason: String) {
        self.requestID = requestID; self.sessionID = sessionID
        self.server = server; self.action = action; self.reason = reason
    }
}

/// What the user chose on the MCP setup card. Both answers unblock the agent
/// immediately; only the detail text differs.
public enum MCPSetupAnswer: Sendable, Equatable {
    /// "I'll do it on desktop" — the agent should carry on without the server.
    case deferToDesktop
    /// "No" — the agent must not propose this server again.
    case decline
}

extension AppModel {

    // MARK: - Catalog

    /// The slash catalog for the current world. Fetched once per gateway and
    /// cached; demo mode gets a small catalog of real Hermes commands so the
    /// palette is explorable without a gateway.
    public func slashCatalog() async -> [SlashCommand] {
        let state = CommandsRuntime.shared
        let owner = client.map { ObjectIdentifier($0) }
        if state.catalogLoaded, state.catalogOwner == owner { return state.catalog }
        if state.catalogOwner != owner { state.invalidateCatalog(owner: owner) }

        guard let client, mode == .live else {
            // Demo gets a real (if small) catalog so the palette is explorable;
            // a live world with no client is a deliberate disconnect, and
            // pretending the demo commands are its catalog would be a lie.
            if mode == .demo {
                state.catalog = Self.demoSlashCatalog
                state.skillCount = Self.demoSlashCatalog.filter { $0.kind == .skill }.count
                state.catalogLoaded = true
            } else {
                state.failed = true
            }
            return state.catalog
        }
        if let inflight = state.catalogTask { return await inflight.value }

        let task = Task<[SlashCommand], Never> { @MainActor in
            do {
                let catalog = try await client.commandsCatalog()
                state.catalog = catalog.commands
                state.skillCount = catalog.skillCount
                state.warning = catalog.warning
                state.failed = false
                state.catalogLoaded = true
            } catch {
                // Older gateways (or a gateway without hermes_cli on the path)
                // simply have no catalog — the palette says so and offers retry
                // rather than pretending an empty command set.
                state.catalog = []
                state.failed = true
                state.warning = Self.commandErrorDetail(error)
                state.catalogLoaded = false
            }
            state.catalogTask = nil
            return state.catalog
        }
        state.catalogTask = task
        return await task.value
    }

    /// Drop the cache so the next `slashCatalog()` refetches (palette retry).
    public func reloadSlashCatalog() async -> [SlashCommand] {
        CommandsRuntime.shared.invalidateCatalog(owner: client.map { ObjectIdentifier($0) })
        return await slashCatalog()
    }

    /// Server-side discovery warning from the last catalog fetch ("skill
    /// discovery unavailable: …"), or the error when the fetch itself failed.
    public var slashCatalogWarning: String { CommandsRuntime.shared.warning }

    /// True when commands.catalog errored — the palette shows a retry state.
    public var slashCatalogFailed: Bool { CommandsRuntime.shared.failed }

    /// Skill commands the gateway reported (`skill_count`).
    public var slashSkillCount: Int { CommandsRuntime.shared.skillCount }

    /// Live completion for composer text starting with "/". The gateway ranks
    /// by usage and fuzzy-matches descriptions, which no local filter can do;
    /// callers fall back to their own filtering when this returns empty.
    public func slashCompletions(for text: String) async -> SlashCompletions {
        guard mode == .live, !isOffline, let client, text.hasPrefix("/") else { return .empty }
        return (try? await client.completeSlash(text)) ?? .empty
    }

    /// Resolve an alias/partial to its canonical command, for the case where a
    /// typed token matches nothing in the catalog (the gateway knows spellings
    /// the catalog does not list).
    public func resolveSlashCommand(_ name: String) async -> SlashCommand? {
        guard mode == .live, !isOffline, let client else { return nil }
        return try? await client.resolveCommand(name)
    }

    // MARK: - Execution

    /// Run "/x …" against the bot's session and drop the result into its chat.
    /// The command is echoed as the user's line (they asked for it, from the
    /// composer or the palette) and `{output}` lands as a system row.
    public func runSlash(_ command: String, botID: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let chat = chat(for: botID)
        let themeID = theme.themeID
        let copy = theme.copy

        chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: line))

        guard mode == .live, !isOffline, let client else {
            chat.messages.append(ChatMessage(author: .system, time: AppModel.clock(),
                                             text: copy.commandsUnavailable(themeID)))
            return
        }

        // Own the typing indicator only if nothing else is already streaming,
        // and never clear it out from under a live turn.
        let ownsTyping = !chat.isTyping
        if ownsTyping { chat.isTyping = true }
        defer {
            if ownsTyping, !LiveRuntime.shared.workingBotIDs.contains(botID) {
                chat.isTyping = false
            }
        }

        do {
            let sessionID = try await ensureSession(botID: botID, hydrate: false)
            let output = try await client.execSlash(sessionID: sessionID, command: line)
            let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.messages.append(ChatMessage(
                author: .system, time: AppModel.clock(),
                text: body.isEmpty ? copy.commandsNoOutput(themeID) : Self.cap(output: body)))
        } catch {
            chat.messages.append(ChatMessage(
                author: .system, time: AppModel.clock(),
                text: copy.commandsFailed(themeID, command: line,
                                          detail: Self.commandErrorDetail(error))))
        }
    }

    /// Slash output is unbounded server-side (/history on a long session runs
    /// to megabytes); the transcript keeps a readable head.
    static func cap(output: String) -> String {
        let limit = 4_000
        guard output.count > limit else { return output }
        return String(output.prefix(limit)) + "\n…"
    }

    static func commandErrorDetail(_ error: Error) -> String {
        (error as? GatewayError)?.message ?? error.localizedDescription
    }

    // MARK: - mcp.setup bridge

    /// The oldest unanswered MCP setup request, or nil. `MCPSetupPrompt` reads
    /// this; the agent thread stays parked until it is answered.
    public var mcpSetupPrompt: MCPSetupRequest? { CommandsRuntime.shared.mcpRequests.first }

    /// Subscribe to the mcp.setup.* events on the current client. Idempotent
    /// per connection — safe to call from a `.task` that reruns, and it
    /// re-attaches automatically after a reconnect swaps the client.
    public func attachCommandsEventRouter() {
        guard mode == .live, let client else { return }
        let state = CommandsRuntime.shared
        let owner = ObjectIdentifier(client)
        guard state.routerOwner != owner else { return }

        state.routerPump?.cancel()
        state.routerOwner = owner
        // Requests belong to the old link's parked threads; that gateway is
        // gone (or reconnected and will re-emit), so start clean.
        state.mcpRequests.removeAll()

        // Same funnel AppModelLive uses: events fan out on the client's actor,
        // one AsyncStream hands them to MainActor in wire order.
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        state.routerPump = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handleMCPSetupRequest(event)
            }
        }
        Task { @MainActor in
            _ = await client.addEventHandler { event in
                guard event.type.hasPrefix("mcp.setup.") else { return }
                continuation.yield(event)
            }
        }
    }

    /// Route one mcp.setup.* event. Public and de-duplicating so the
    /// integrator can also call it straight from the central event switch
    /// instead of (or as well as) `attachCommandsEventRouter()`.
    public func handleMCPSetupRequest(_ event: GatewayEvent) {
        let state = CommandsRuntime.shared
        switch event.type {
        case "mcp.setup.request":
            guard let request = MCPSetupRequest(event),
                  !state.mcpRequests.contains(where: { $0.requestID == request.requestID })
            else { return }
            state.mcpRequests.append(request)
        case "mcp.setup.expire":
            // The 600 s window closed server-side; the tool already returned
            // "unanswered". Drop the card rather than answering into the void.
            let requestID = event.payload?["request_id"]?.stringValue ?? ""
            state.mcpRequests.removeAll { $0.requestID == requestID }
        default:
            break
        }
    }

    /// Answer a parked MCP setup request and unblock the agent. Clearing the
    /// card first is deliberate: the decision is made, and an in-flight RPC
    /// must not leave a live card that can be answered twice.
    public func answerMCPSetup(_ request: MCPSetupRequest, _ answer: MCPSetupAnswer) {
        let state = CommandsRuntime.shared
        state.mcpRequests.removeAll { $0.requestID == request.requestID }

        if let botID = botID(forSession: request.sessionID) {
            let copy = theme.copy, themeID = theme.themeID
            chat(for: botID).messages.append(ChatMessage(
                author: .system, time: AppModel.clock(),
                text: answer == .decline
                    ? copy.mcpSetupDeclinedLine(themeID, server: request.server)
                    : copy.mcpSetupDeferredLine(themeID, server: request.server)))
        }

        guard mode == .live, let client else { return }
        // The agent reads this detail, not the user — plain English, never a
        // themed string.
        let detail: String
        switch answer {
        case .decline:
            detail = "The user declined \(request.server) on Talaria (iOS). "
                + "Do not propose this server again in this session."
        case .deferToDesktop:
            detail = "Talaria (iOS) cannot run MCP install/enable/authorize flows — "
                + "they need the Hermes desktop app or `hermes mcp install \(request.server)` "
                + "in a terminal. The user saw the request and will set it up there. "
                + "Continue without \(request.server) for now."
        }
        Task { @MainActor in
            try? await client.respondToMCPSetup(requestID: request.requestID,
                                                status: "declined",
                                                server: request.server,
                                                detail: detail)
        }
    }

    // MARK: - Demo catalog

    /// Real commands from the upstream registry (hermes_cli/commands.py
    /// COMMAND_REGISTRY) with their real descriptions and argument hints, so
    /// the demo palette shows the true shape of the feature without inventing
    /// a command surface. Running one in demo mode says so.
    static let demoSlashCatalog: [SlashCommand] = [
        SlashCommand(name: "/status", description: "Show session, model, token, and context info",
                     category: "Session"),
        SlashCommand(name: "/context", description: "Show the context window with usage gauge and category breakdown",
                     category: "Session", usage: "all", aliases: ["/ctx"]),
        SlashCommand(name: "/compress", description: "Compress conversation context",
                     category: "Session", usage: "[here [N] | focus topic | --preview]",
                     aliases: ["/compact"]),
        SlashCommand(name: "/undo", description: "Back up N user turns and re-prompt (default 1)",
                     category: "Session", usage: "[N]"),
        SlashCommand(name: "/retry", description: "Retry the last message (resend to agent)",
                     category: "Session"),
        SlashCommand(name: "/save", description: "Export the current conversation",
                     category: "Session", usage: "<json|md|html> [filename] [redact]"),
        SlashCommand(name: "/new", description: "Start a new session (fresh session ID + history)",
                     category: "Session", usage: "[name]", aliases: ["/reset"]),
        SlashCommand(name: "/title", description: "Set a title for the current session",
                     category: "Session", usage: "[name]"),
        SlashCommand(name: "/branch", description: "Branch the current session (explore a different path)",
                     category: "Session", usage: "[name]", aliases: ["/fork"]),
        SlashCommand(name: "/agents", description: "Show active agents and running tasks",
                     category: "Session", aliases: ["/tasks"]),
        SlashCommand(name: "/resume", description: "Resume a previously-named session",
                     category: "Session", usage: "[name]"),
        SlashCommand(name: "/model", description: "Switch model (session-scoped; --global to persist)",
                     category: "Configuration", usage: "[model] [--provider name] [--global]"),
        SlashCommand(name: "/personality", description: "Set a predefined personality",
                     category: "Configuration", usage: "[name]"),
        SlashCommand(name: "/whoami", description: "Show your slash command access (admin / user)",
                     category: "Info"),
        SlashCommand(name: "/profile", description: "Show active profile name and home directory",
                     category: "Info"),
        SlashCommand(name: "/web-research", description: "Research a topic across the open web and summarize",
                     category: "", kind: .skill, usage: "<topic>"),
        SlashCommand(name: "/image-gen", description: "Generate an image from a prompt",
                     category: "", kind: .skill, usage: "<prompt>"),
    ]
}

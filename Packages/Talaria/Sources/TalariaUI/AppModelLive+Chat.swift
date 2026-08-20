import Foundation
import TalariaKit
import TalariaTheme

// The chat surface's live behaviors: the stop control, mid-turn steering,
// tool-call routing into the transcript, and message reactions.
//
// Event routing note: AppModel.handle(event:) (AppModelLive.swift, another
// owner) already pumps message/approval events. Rather than reach into it,
// this file registers a SECOND handler on the client — its own AsyncStream
// pump, so tool.start → tool.complete stay in wire order among themselves —
// and routes only what chat-core owns: ChatState.isRunning and the ToolCall
// list hanging off each assistant message. RootView calls
// `attachChatEventRouter()` after every connect; it is idempotent per client.

// MARK: - Chat runtime (side table)

/// Storage for chat-core's live state. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like LiveRuntime does.
@MainActor
final class ChatRuntime {
    static let shared = ChatRuntime()

    /// The client the router is attached to — re-attaching to the same client
    /// would double every tool chip.
    weak var routedClient: GatewayClient?
    var routerHandler: UUID?
    var pump: Task<Void, Never>?

    /// Index of the first message of the current turn, per bot. Tool chips
    /// only ever attach at or after it, so a tool that starts before the first
    /// token can't land on the previous turn's bubble.
    var turnFloor: [String: Int] = [:]

    /// A submit that never produces message.start must not leave the composer
    /// stuck on Stop (RPC accepted, gateway wedged, socket died mid-flight).
    var submitWatchdogs: [String: Task<Void, Never>] = [:]

    /// Demo replies, cancellable so the demo stop button means something.
    var demoTurns: [String: Task<Void, Never>] = [:]

    /// message id → this device's emoji. ChatMessage has no reactions field
    /// and Models.swift belongs to another owner; the gateway remains the
    /// source of truth, this is the local echo.
    var reactions: [UUID: String] = [:]

    /// tool.generating placeholders carry no tool_id — this prefix marks them
    /// so tool.start can promote rather than duplicate them.
    static let generatingPrefix = "generating:"
}

extension AppModel {

    // MARK: - Router attachment

    /// Register chat-core's event handler on the current client. Safe to call
    /// repeatedly; a no-op in demo mode and when already attached to this
    /// client. Call it after every `connectGateway` — a reconnect keeps the
    /// same client (and therefore this handler), but a new gateway link builds
    /// a fresh client that has no handlers yet.
    public func attachChatEventRouter() {
        let runtime = ChatRuntime.shared
        guard mode == .live, let client else { return }
        guard runtime.routedClient !== client else { return }

        let previous = runtime.routerHandler
        let previousClient = runtime.routedClient
        runtime.routedClient = client
        runtime.pump?.cancel()

        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        runtime.pump = Task { @MainActor [weak self] in
            for await event in stream {
                self?.routeToolEvent(event)
            }
        }
        Task {
            if let previous, let previousClient {
                await previousClient.removeEventHandler(previous)
            }
            let id = await client.addEventHandler { continuation.yield($0) }
            await MainActor.run { ChatRuntime.shared.routerHandler = id }
        }
    }

    // MARK: - Event routing (turn state + tool chips)

    /// Route one gateway event into chat-core state. Public so the router (and
    /// anything replaying events) can hand events in from outside this file.
    public func routeToolEvent(_ event: GatewayEvent, sourceGatewayID: String? = nil) {
        guard mode == .live,
              let botID = botID(forSession: event.sessionID,
                                sourceGatewayID: sourceGatewayID) else { return }
        let chat = chat(for: botID)

        switch TypedGatewayEvent(event) {
        case .messageStart:
            clearWatchdog(botID)
            chat.isRunning = true
            ChatRuntime.shared.turnFloor[botID] = chat.messages.count

        case .messageComplete(let payload):
            clearWatchdog(botID)
            chat.isRunning = false
            finishRunningTools(in: chat, interrupted: payload.status != .complete)

        case .errorEvent:
            clearWatchdog(botID)
            chat.isRunning = false
            finishRunningTools(in: chat, interrupted: true)

        case .sessionInfo(let info):
            // Authoritative after a resume: the turn may have kept running
            // while the socket was down. A session.info that lands between the
            // submit and message.start must not pull the stop control out from
            // under a turn that is visibly streaming.
            if info.running {
                chat.isRunning = true
            } else if chat.messages.last?.isStreaming != true {
                chat.isRunning = false
            }

        case .toolGenerating(let name):
            guard !name.isEmpty else { return }
            let index = toolAnchor(in: chat, botID: botID)
            guard !chat.messages[index].toolCalls.contains(where: {
                $0.name == name && $0.state == .running
            }) else { return }
            chat.messages[index].toolCalls.append(
                ToolCall(id: ChatRuntime.generatingPrefix + name + "-\(UUID().uuidString.prefix(6))",
                         name: name, context: ""))

        case .toolStart(let tool):
            guard !tool.name.isEmpty || !tool.toolID.isEmpty else { return }
            startTool(tool, in: chat, botID: botID)

        case .toolComplete(let tool):
            completeTool(tool, payload: event.payload, in: chat)

        default:
            break
        }
    }

    /// The message a tool chip belongs under: the assistant bubble of the
    /// running turn, or a fresh one when tools fire before the first token.
    private func toolAnchor(in chat: ChatState, botID: String) -> Int {
        let floor = ChatRuntime.shared.turnFloor[botID] ?? chat.messages.count
        if let last = chat.messages.indices.last, chat.messages[last].author == .bot,
           chat.messages[last].isStreaming || last >= floor {
            return last
        }
        chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                         text: "", isStreaming: true))
        return chat.messages.count - 1
    }

    private func startTool(_ tool: ToolStartPayload, in chat: ChatState, botID: String) {
        let index = toolAnchor(in: chat, botID: botID)
        let id = tool.toolID.isEmpty ? UUID().uuidString : tool.toolID
        var calls = chat.messages[index].toolCalls

        if let pending = calls.firstIndex(where: {
            $0.id.hasPrefix(ChatRuntime.generatingPrefix) && $0.name == tool.name && $0.state == .running
        }) {
            // Promote the tool.generating placeholder rather than add a twin.
            calls[pending].id = id
            calls[pending].context = tool.context
        } else if let existing = calls.firstIndex(where: { $0.id == id }) {
            calls[existing].context = tool.context
        } else {
            calls.append(ToolCall(id: id, name: tool.name, context: tool.context))
        }
        chat.messages[index].toolCalls = calls
    }

    private func completeTool(_ tool: ToolCompletePayload, payload: JSONValue?, in chat: ChatState) {
        // Newest first, and only within reach of the running turn: a stale
        // chip further up the transcript must not be retro-completed by a
        // same-named tool running now.
        for index in chat.messages.indices.suffix(12).reversed() {
            guard !chat.messages[index].toolCalls.isEmpty else { continue }
            var calls = chat.messages[index].toolCalls
            let hit = calls.firstIndex { $0.id == tool.toolID && !tool.toolID.isEmpty }
                ?? calls.lastIndex { $0.state == .running && $0.name == tool.name }
            guard let hit else { continue }

            calls[hit].state = Self.toolFailed(payload: payload, summary: tool.summary,
                                               resultText: tool.resultText) ? .failed : .done
            calls[hit].summary = tool.summary
            // result_text only rides along in verbose mode; `result` is always
            // there, so fall back to a readable rendering of it.
            calls[hit].resultText = tool.resultText ?? Self.describeResult(payload?["result"])
            calls[hit].durationSeconds = tool.durationSeconds
            if calls[hit].context.isEmpty, let summary = tool.summary {
                calls[hit].context = summary
            }
            chat.messages[index].toolCalls = calls
            return
        }
    }

    /// A finished turn can hold no running tools — a stop or an error leaves
    /// chips spinning forever otherwise.
    /// Settle every tool chip still spinning in the recent tail. Internal
    /// rather than private because the liveness reaper owes the same debt when
    /// a turn ends off-socket (AppModelLive+Liveness.swift): one rule for what
    /// a chip left running means, in one place.
    func finishRunningTools(in chat: ChatState, interrupted: Bool) {
        for index in chat.messages.indices.suffix(12) {
            guard !chat.messages[index].toolCalls.isEmpty else { continue }
            for call in chat.messages[index].toolCalls.indices
            where chat.messages[index].toolCalls[call].state == .running {
                chat.messages[index].toolCalls[call].state = interrupted ? .failed : .done
            }
        }
    }

    /// The gateway has no explicit tool-failure flag (`_on_tool_complete`
    /// just ships the tool's own result), so read the result the way a person
    /// would: an `error` key, or text that opens with one.
    static func toolFailed(payload: JSONValue?, summary: String?, resultText: String?) -> Bool {
        if let result = payload?["result"], result["error"] != nil { return true }
        let text = (resultText ?? summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        for marker in ["error", "failed", "traceback", "exception", "permission denied"]
        where text.hasPrefix(marker) {
            return true
        }
        return false
    }

    /// Render a tool result for the expanded chip: strings verbatim, structured
    /// results as pretty JSON, both capped so one runaway result can't be
    /// carried around in memory forever.
    static func describeResult(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue {
            return text.isEmpty ? nil : String(text.prefix(20_000))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.prefix(20_000))
    }

    // MARK: - Sending: submit, or steer while a turn runs

    /// The composer's send. A turn already in flight takes the desktop path —
    /// `session.steer` injects the text into the running turn instead of
    /// `prompt.submit`, which would interrupt it.
    public func sendOrSteer(text: String, to botID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chat(for: botID)
        // Staged attachments are a turn on their own — composedPrompt supplies
        // the words for an image sent without any.
        guard !trimmed.isEmpty || !chat.attachments.isEmpty else { return }

        switch mode {
        case .demo:
            guard !trimmed.isEmpty else { return }
            chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: trimmed))
            startDemoTurn(botID: botID, chat: chat)
        case .live:
            let routeAvailable = !isOffline || GatewayBotRoute(qualifiedID: botID) != nil
            let turnInFlight = chat.isRunning || chat.isTyping
            if turnInFlight, routeAvailable {
                // `isTyping` is part of the same UI turn state as isRunning:
                // message.start and resume ordering can raise it first. Never
                // contradict the visible steer affordance by submitting a new
                // prompt in that window. Attachments alone also cannot steer.
                guard !trimmed.isEmpty else { return }
                // Deliberately mention-free. Desktop has no steer path at all
                // — its middleware only ever sees a fresh submit — so there is
                // no upstream answer for "@ops" typed into a turn already
                // running, and the conservative reading wins: steering is a
                // correction aimed at THIS bot mid-thought, and firing a
                // handoff out of one would send a half-sentence to a stranger.
                // The handle rides along as literal text, as it does today.
                if let sessionID = chat.sessionID {
                    steer(text: trimmed, botID: botID, sessionID: sessionID, chat: chat)
                } else {
                    steerAfterAttach(text: trimmed, botID: botID, chat: chat)
                }
            } else {
                // The composer middleware runs FIRST, on the raw draft, which
                // is where desktop registers it (plugin.js:8214 reads
                // `draft.text`). Order is not incidental: the attachment
                // rewrite below prepends "@file:<path>" refs, and a mention
                // scan downstream of it would read those as an @file handle.
                // Bot Mode's canonical chat is one conversation forever.
                // Desktop's composer middleware intercepts a bare `/new` or
                // `/reset` aimed at that pinned chat and runs `/compact`
                // instead (plugin.js:8215-8241). Scratch sessions keep the
                // commands unchanged, and an unresolved pin is deliberately
                // not guessed at.
                let pin = CanonicalChatRuntime.shared.pins[botID]
                let canonical = pin != nil && chat.storedSessionID == pin
                let guarded: String
                switch ForeverChatGuard.resolve(trimmed, isCanonicalChat: canonical) {
                case .run(let text):
                    guarded = text
                case .rewritten(let replacement):
                    guarded = replacement
                    toast(kind: .info,
                          title: theme.copy.toastNeverResetsTitle(theme.themeID),
                          message: theme.copy.toastNeverResetsBody(theme.themeID),
                          botID: botID)
                }
                let routed = routeMentions(in: guarded, from: botID)
                // Staged attachments only reach the agent if their "@file:"
                // refs ride the prompt (images ride the session) — the
                // attachments surface owns that rewrite.
                let prompt = composedPrompt(routed, botID: botID)
                // send() appends the user bubble and submits (or queues while
                // offline) — going around it would duplicate the bubble.
                if chat.sessionID == nil, LiveRuntime.shared.attachTasks[botID] != nil {
                    // A sessions-sheet selection owns the shared attach slot.
                    // Echo now, await that exact attach, then re-evaluate the
                    // resumed turn: an idle session receives a submit; a turn
                    // that resumed running receives a steer. Starting another
                    // ensureSession here used to race canonical resolution.
                    sendAfterAttach(text: prompt, botID: botID, chat: chat,
                                    routeAvailable: routeAvailable)
                } else {
                    ChatRuntime.shared.turnFloor[botID] = chat.messages.count + 1
                    chat.isRunning = routeAvailable
                    send(text: prompt, to: botID)
                    if routeAvailable { startWatchdog(botID) }
                }
                clearAttachments(botID: botID)
            }
        }
    }

    private func steer(text: String, botID: String, sessionID: String, chat: ChatState) {
        chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: text))
        deliverSteer(text: text, botID: botID, sessionID: sessionID)
    }

    private func deliverSteer(text: String, botID: String, sessionID: String) {
        Task { @MainActor in
            guard let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            let steered = (try? await client.steerTurn(sessionID: sessionID, text: text)) ?? ""
            if steered == "queued" { return }
            // Too late to steer: re-aim the turn, and failing that queue the
            // text behind it rather than interrupting what is running.
            let redirected = (try? await client.redirectTurn(sessionID: sessionID, text: text)) ?? ""
            if redirected == "redirected" || redirected == "queued" { return }
            try? await client.submitPrompt(sessionID: sessionID, text: text, queued: true)
        }
    }

    /// message.start/resume can raise the UI's steer state one MainActor turn
    /// before the runtime sid is published. Keep the user's correction,
    /// coalesce onto (or start) the one attach, then deliver it through the
    /// same steer/redirect/queued cascade; never downgrade it to a new
    /// unqueued prompt.
    private func steerAfterAttach(text: String, botID: String, chat: ChatState) {
        let optimistic = ChatMessage(author: .user, time: AppModel.clock(), text: text)
        chat.messages.append(optimistic)
        Task { @MainActor in
            do {
                let sessionID = try await ensureSession(botID: botID, hydrate: false)
                deliverSteer(text: text, botID: botID, sessionID: sessionID)
            } catch is CancellationError {
                recoverCancelledAttachIntent(
                    text: text, botID: botID, chat: chat,
                    optimisticID: optimistic.id, steering: true,
                    routeAvailable: true)
            } catch {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    /// Preserve a compose action issued while an explicit stored-session
    /// resume owns `LiveRuntime.attachTasks`. The user bubble is optimistic,
    /// but the wire verb is chosen only after the resume tells us whether a
    /// turn survived the switch.
    private func sendAfterAttach(text: String, botID: String, chat: ChatState,
                                 routeAvailable: Bool) {
        let optimistic = ChatMessage(author: .user, time: AppModel.clock(), text: text)
        chat.messages.append(optimistic)
        Task { @MainActor in
            do {
                let sessionID = try await ensureSession(botID: botID, hydrate: false)
                if chat.isRunning || chat.isTyping {
                    deliverSteer(text: text, botID: botID, sessionID: sessionID)
                } else {
                    ChatRuntime.shared.turnFloor[botID] = chat.messages.count
                    chat.isRunning = routeAvailable
                    liveSend(text: text, botID: botID, chat: chat)
                    if routeAvailable { startWatchdog(botID) }
                }
            } catch let error as GatewayError where error.code == -3 || error.code == -7 {
                chat.isRunning = false
                if GatewayBotRoute(qualifiedID: botID) == nil {
                    isOffline = true
                    composeQueue.append((botID, text))
                } else {
                    chat.messages.append(ChatMessage(author: .system, text: error.message))
                }
            } catch is CancellationError {
                recoverCancelledAttachIntent(
                    text: text, botID: botID, chat: chat,
                    optimisticID: optimistic.id, steering: false,
                    routeAvailable: routeAvailable)
            } catch {
                chat.isRunning = false
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    /// Cancellation has two meanings. An explicit selection clears the old
    /// optimistic row (and often replaces the ChatState), so it owns the
    /// outcome and this intent disappears with that transcript. A reconnect
    /// or generation reset leaves the exact row in the exact chat; recover it
    /// against an already rebound sid when possible, otherwise retain it in
    /// the visible compose queue for the reconnect flush.
    private func recoverCancelledAttachIntent(
        text: String, botID: String, chat: ChatState, optimisticID: UUID,
        steering: Bool, routeAvailable: Bool
    ) {
        guard let owner = chats[botID], owner === chat,
              chat.messages.contains(where: { $0.id == optimisticID }) else { return }

        if let sessionID = chat.sessionID,
           let route = gatewayRoute(for: botID),
           self.botID(forSession: sessionID, sourceGatewayID: route.gatewayID) == botID {
            if steering || chat.isRunning || chat.isTyping {
                deliverSteer(text: text, botID: botID, sessionID: sessionID)
            } else {
                ChatRuntime.shared.turnFloor[botID] = chat.messages.count
                chat.isRunning = routeAvailable
                liveSend(text: text, botID: botID, chat: chat)
                if routeAvailable { startWatchdog(botID) }
            }
            return
        }

        chat.isRunning = false
        composeQueue.append((botID, text))
    }

    /// Demo mode's scripted reply, owned here so the stop button can cancel it
    /// (AppModel's own demo reply is fire-and-forget).
    private func startDemoTurn(botID: String, chat: ChatState) {
        let runtime = ChatRuntime.shared
        runtime.demoTurns[botID]?.cancel()
        chat.isTyping = true
        chat.isRunning = true
        runtime.demoTurns[botID] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double.random(in: 0.9...1.8)))
            guard !Task.isCancelled else { return }
            chat.isTyping = false
            chat.isRunning = false
            let reply = DemoData.cannedReplies[botID]
                ?? DemoData.cannedReplies["default"]
                ?? "On it. I’ll report back here when it’s done."
            chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(), text: reply))
            ChatRuntime.shared.demoTurns[botID] = nil
        }
    }

    /// A submit whose turn never starts (accepted RPC, wedged gateway, socket
    /// lost) would otherwise strand the composer on Stop.
    private func startWatchdog(_ botID: String) {
        let runtime = ChatRuntime.shared
        runtime.submitWatchdogs[botID]?.cancel()
        runtime.submitWatchdogs[botID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            let chat = self.chat(for: botID)
            if chat.messages.last?.isStreaming != true { chat.isRunning = false }
            ChatRuntime.shared.submitWatchdogs[botID] = nil
        }
    }

    private func clearWatchdog(_ botID: String) {
        ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
        ChatRuntime.shared.submitWatchdogs[botID] = nil
    }

    // MARK: - Stop (session.interrupt)

    /// Halt the running turn. The gateway also cancels queued prompts, releases
    /// blocking clarify/sudo/secret prompts and denies every pending approval
    /// for the session (ws-protocol §6.2) — so the local approval cards for
    /// this bot go with it.
    public func stopTurn(botID: String) {
        let chat = chat(for: botID)
        let wasRunning = chat.isRunning || chat.isTyping
        chat.isRunning = false
        chat.isTyping = false
        clearWatchdog(botID)
        finishRunningTools(in: chat, interrupted: true)
        ChatRuntime.shared.demoTurns[botID]?.cancel()
        ChatRuntime.shared.demoTurns[botID] = nil

        guard wasRunning else { return }
        let note = theme.copy.stopNote(theme.themeID)

        guard mode == .live, let sessionID = chat.sessionID else {
            chat.messages.append(ChatMessage(author: .system, text: note))
            return
        }
        Task { @MainActor in
            do {
                guard let route = gatewayRoute(for: botID) else { throw GatewayRouteError.noRoute }
                let client = try await routedClient(for: route)
                try await client.interruptSession(sessionID)
                chat.messages.append(ChatMessage(author: .system, text: note))
                self.approvals.removeAll { $0.botID == botID }
            } catch {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    // MARK: - Reactions (message.react)

    /// This device's reaction on a message, for the badge under the bubble.
    public func reaction(for message: ChatMessage) -> String? {
        ChatRuntime.shared.reactions[message.id]
    }

    /// Reactions key on the durable `row_id`. A live bubble has none until it
    /// round-trips a resume, so the newest assistant row can still be named by
    /// role — anything older than that simply can't be addressed yet.
    public func canReact(to message: ChatMessage, in botID: String) -> Bool {
        guard message.author == .bot, !message.isStreaming else { return false }
        guard mode == .live else { return true }
        guard chat(for: botID).sessionID != nil else { return false }
        return message.rowID != nil || isNewestBotMessage(message, in: botID)
    }

    /// Toggle an emoji on a message (same emoji again retracts it, matching the
    /// gateway's Tapback semantics).
    public func react(to message: ChatMessage, in botID: String, emoji: String) {
        let runtime = ChatRuntime.shared
        let retracting = runtime.reactions[message.id] == emoji
        runtime.reactions[message.id] = retracting ? nil : emoji

        guard mode == .live, let sessionID = chat(for: botID).sessionID else { return }
        let rowID = message.rowID
        guard rowID != nil || isNewestBotMessage(message, in: botID) else { return }
        let role: String? = rowID == nil ? "assistant" : nil
        let payload: String? = retracting ? nil : emoji
        Task { @MainActor in
            guard let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            _ = try? await client.reactToMessage(sessionID: sessionID, rowID: rowID,
                                                 newestRole: role, emoji: payload)
        }
    }

    private func isNewestBotMessage(_ message: ChatMessage, in botID: String) -> Bool {
        chat(for: botID).messages.last(where: { $0.author == .bot })?.id == message.id
    }
}

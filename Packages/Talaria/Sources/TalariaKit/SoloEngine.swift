import Foundation

// Solo mode's agent loop — roadmap Phase 5, docs/SOLO-MODE.md.
//
// A gateway connection gives Talaria full bots: hermes profiles with shell,
// browser, MCP, skills and cron. Solo is the other half of the promise — a
// small native loop over whatever `InferenceProvider` this device can reach,
// with the iOS-permitted tool set and the *same* approval vocabulary.
//
// Division of labour with SoloTools.swift (another owner):
//
//   SoloTools.swift  the tools themselves, the two gates (permission, then
//                    approval), the approval centre that parks a turn until
//                    the person answers, and Solo's storage.
//   this file        the loop: assemble the conversation, ask the provider,
//                    let tools run, feed the results back, stop.
//
// The seam between them is `SoloToolbelt` below — descriptors in, one gated
// call out — deliberately three methods wide. The engine does not know what a
// permission is, and the tool layer does not know what a turn is.
//
// Two paths through the loop, and which one runs is a property of the backend
// rather than a setting:
//
//   * NATIVE — the provider calls tools itself. Apple's Foundation Models
//     framework does the whole thing in-framework with guided generation, so
//     the model *cannot* emit a malformed call. That is why it is Solo's
//     default tier and not merely its most convenient one.
//   * TEXT PROTOCOL — plain chat-completion backends (Nous Portal,
//     TalariaLocal's MLX provider) get the `<tool_call>` convention their
//     models are actually trained on (Hermes / Qwen function calling).
//     `SoloStreamFilter` keeps that protocol text out of the bubble.
//
// Bounded on purpose: `.research/profiles-runtime.md` §8.4 measured the
// envelope — prefill dominates long prompts, sustained decode throttles and
// drains — so the system prompt is short, history is clipped, and the tool
// loop has a step ceiling.
//
// No UI, no UIKit, and no dependency on TalariaLocal.

// MARK: - Engine identity (the honest badge)

/// Which engine produced an assistant message.
///
/// Talaria never lets a Solo reply be anonymous: an answer from the phone's
/// own ~3B system model and one from a hosted 70B are very different things,
/// and the transcript says which is which. Carried per message rather than per
/// conversation, because the engine can be switched mid-conversation.
public struct SoloEngineTag: Codable, Sendable, Equatable, Hashable {
    /// `InferenceProvider.providerID` — "apple-foundation-models", "nous-portal".
    public var providerID: String
    /// The model id handed to the provider.
    public var model: String
    /// Short label for the badge ("Apple on-device", "Nous Portal").
    public var label: String
    /// True when inference happened here and nothing left the device.
    public var isOnDevice: Bool

    public init(providerID: String, model: String, label: String, isOnDevice: Bool) {
        self.providerID = providerID
        self.model = model
        self.label = label
        self.isOnDevice = isOnDevice
    }
}

// MARK: - The tool seam

/// What a backend needs to know about one tool: its name, what it is for, and
/// the JSON Schema of its arguments. Everything else about a tool — which
/// permission owns it, whether it changes the device, what its approval card
/// says — is the tool layer's business and never crosses this line.
public struct SoloToolDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Written for a ≤4B model rather than for a reader; every character is
    /// prefill on every turn.
    public var description: String
    /// JSON Schema for the arguments object:
    /// `{"type":"object","properties":{…},"required":[…]}`.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Argument names, required ones first, for the text-protocol prompt and
    /// for a chip that has nothing better to show.
    public var argumentNames: [String] {
        let required = parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let all = parameters["properties"]?.objectValue?.keys.sorted() ?? []
        return required + all.filter { !required.contains($0) }
    }
}

/// One finished tool call, as the transcript and the model see it.
public struct SoloToolOutcome: Sendable, Equatable {
    /// What the model reads next — including "the person declined", which is
    /// a result rather than an error: a small model told merely "error" will
    /// try the same call again.
    public var text: String
    /// One line for the collapsed chip, the role `ToolCall.summary` plays for
    /// gateway tools.
    public var summary: String
    /// Whether it failed, was refused, or was never permitted.
    public var failed: Bool

    public init(text: String, summary: String, failed: Bool = false) {
        self.text = text
        self.summary = summary
        self.failed = failed
    }
}

/// The engine's whole view of the tool layer.
///
/// Implementations own both gates: `descriptors()` is the permission filter
/// (a switch that is off contributes no descriptor, so the model is never told
/// the tool exists), and `run` is where an approval parks the turn until the
/// person answers. Neither can be bypassed, because this is the only door the
/// loop has.
public protocol SoloToolbelt: Sendable {
    /// The tools this turn may use, resolved fresh — descriptions can name the
    /// folders and shortcuts that exist right now.
    func descriptors() async -> [SoloToolDescriptor]

    /// The human sentence for this specific call ("Fetch example.com"), for
    /// the transcript's chip. Empty when the arguments say nothing useful.
    func preview(name: String, arguments: JSONValue) async -> String

    /// Gate, then run. Never throws — every refusal and failure comes back as
    /// text the model can recover from.
    func run(name: String, arguments: JSONValue) async -> SoloToolOutcome
}

/// A Solo conversation with no tools at all — the "Chat" tier of
/// SOLO-MODE.md's three, and the honest state when every permission is off.
public struct SoloEmptyToolbelt: SoloToolbelt {
    public init() {}
    public func descriptors() async -> [SoloToolDescriptor] { [] }
    public func preview(name: String, arguments: JSONValue) async -> String { "" }
    public func run(name: String, arguments: JSONValue) async -> SoloToolOutcome {
        SoloToolOutcome(text: "No tools are available in this conversation.",
                        summary: "no tools", failed: true)
    }
}

// MARK: - Provider refinement

/// A backend that runs the tool loop itself.
///
/// Apple's Foundation Models framework calls tools in-framework and resumes
/// the same generation without a second round trip, which is why Solo prefers
/// it: a 3B model asked to hand-write `<tool_call>` JSON is precisely the
/// fragility SOLO-MODE.md rejects. `invoke` is where the approval lives — it
/// suspends until the person answers and returns the text the model reads.
public protocol SoloNativeToolProvider: InferenceProvider {
    func chat(messages: [InferenceMessage],
              model: String,
              tools: [SoloToolDescriptor],
              invoke: @escaping @Sendable (String, JSONValue) async -> String,
              stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String
}

// MARK: - Events

/// What the transcript needs to watch a Solo turn happen. Deliberately the
/// same shape as the gateway events the chat surface already renders (deltas,
/// reasoning, tool start/complete), so a Solo turn and a bot turn look alike.
public enum SoloEvent: Sendable {
    case delta(String)
    case reasoningDelta(String)
    /// A tool is about to be gated and run.
    case toolStart(id: String, name: String, preview: String)
    /// Terminal event for one tool.
    case toolEnd(id: String, summary: String, detail: String?, seconds: Double?, failed: Bool)
}

// MARK: - Errors

public enum SoloEngineError: Error, LocalizedError, Sendable, Equatable {
    /// No usable engine on this device. The UI must offer a way out — enable
    /// Apple Intelligence, sign in to Portal, connect a gateway — never a
    /// dead end.
    case noEngine
    /// The loop hit its step ceiling without the model ever answering.
    case toolLoopExhausted

    public var errorDescription: String? {
        switch self {
        case .noEngine: "no engine is available on this device"
        case .toolLoopExhausted: "the model kept calling tools without answering"
        }
    }
}

// MARK: - The engine

/// One Solo conversation's agent loop.
///
/// Stateless between turns on purpose: the conversation lives in the caller's
/// transcript (and, durably, in the session archive), which is what lets the
/// person switch engines mid-conversation without the history forking.
public actor SoloEngine {

    public struct Configuration: Sendable {
        /// Short by design — every token here is prefill on every turn.
        public var systemPrompt: String
        /// Tool round trips one turn may take before the loop gives up and
        /// answers with what it has.
        public var maxToolSteps: Int
        /// Prior messages carried into the prompt. The on-device window is
        /// small, and history is the easiest thing to spend it on badly.
        public var maxHistoryMessages: Int

        public init(systemPrompt: String = SoloEngine.defaultSystemPrompt,
                    maxToolSteps: Int = 4,
                    maxHistoryMessages: Int = 20) {
            self.systemPrompt = systemPrompt
            self.maxToolSteps = maxToolSteps
            self.maxHistoryMessages = maxHistoryMessages
        }
    }

    /// The badge every message this engine answers is stamped with.
    public let tag: SoloEngineTag

    private let provider: any InferenceProvider
    private let model: String
    private let toolbelt: any SoloToolbelt
    private let configuration: Configuration

    public init(provider: any InferenceProvider,
                model: String,
                tag: SoloEngineTag,
                toolbelt: any SoloToolbelt = SoloEmptyToolbelt(),
                configuration: Configuration = Configuration()) {
        self.provider = provider
        self.model = model
        self.tag = tag
        self.toolbelt = toolbelt
        self.configuration = configuration
    }

    // MARK: Running a turn

    /// Run one turn and return the assistant's final text.
    ///
    /// `history` is the conversation so far — no system message (the engine
    /// adds its own) and not the new prompt. Cancel the calling task to stop:
    /// both paths observe cancellation, and the tool layer is expected to
    /// resolve a parked approval rather than leave a thread waiting.
    @discardableResult
    public func run(history: [InferenceMessage],
                    prompt: String,
                    emit: @escaping @Sendable (SoloEvent) -> Void) async throws -> String {
        let clipped = Array(history.suffix(configuration.maxHistoryMessages))
        let tools = await toolbelt.descriptors()

        if let native = provider as? any SoloNativeToolProvider {
            return try await runNative(native, tools: tools,
                                       history: clipped, prompt: prompt, emit: emit)
        }
        return try await runTextProtocol(tools: tools,
                                         history: clipped, prompt: prompt, emit: emit)
    }

    // MARK: Native tool path

    private func runNative(_ native: any SoloNativeToolProvider,
                           tools: [SoloToolDescriptor],
                           history: [InferenceMessage],
                           prompt: String,
                           emit: @escaping @Sendable (SoloEvent) -> Void) async throws -> String {
        var messages: [InferenceMessage] = [.system(configuration.systemPrompt)]
        messages.append(contentsOf: history)
        messages.append(.user(prompt))

        // Called by the framework on its own executor whenever the model asks
        // for a tool. It must not return until both gates have run — which
        // includes waiting for a person to answer an approval card.
        let invoke: @Sendable (String, JSONValue) async -> String = { [weak self] name, arguments in
            guard let self else { return "Solo is no longer running." }
            return await self.callTool(name: name, arguments: arguments, emit: emit).text
        }

        return try await native.chat(messages: messages, model: model,
                                     tools: tools, invoke: invoke) { event in
            switch event {
            case .delta(let text): emit(.delta(text))
            case .reasoningDelta(let text): emit(.reasoningDelta(text))
            case .finished: break
            }
        }
    }

    // MARK: Text-protocol path

    /// Ask, watch the stream for a `<tool_call>` block, run it, feed the
    /// result back as `<tool_response>`, ask again.
    private func runTextProtocol(tools: [SoloToolDescriptor],
                                 history: [InferenceMessage],
                                 prompt: String,
                                 emit: @escaping @Sendable (SoloEvent) -> Void) async throws -> String {
        var messages: [InferenceMessage] = [
            .system(Self.textProtocolPrompt(base: configuration.systemPrompt, tools: tools))
        ]
        messages.append(contentsOf: history)
        messages.append(.user(prompt))

        var visible = ""
        for _ in 0...configuration.maxToolSteps {
            try Task.checkCancellation()

            // The filter holds back any tail that could still become a
            // `<tool_call>` marker, so protocol text never flashes in a bubble.
            let filter = SoloStreamFilterBox()
            let raw = try await provider.chat(messages: messages, model: model) { event in
                switch event {
                case .delta(let chunk):
                    let shown = filter.consume(chunk)
                    if !shown.isEmpty { emit(.delta(shown)) }
                case .reasoningDelta(let chunk):
                    emit(.reasoningDelta(chunk))
                case .finished:
                    break
                }
            }
            let tail = filter.flush()
            if !tail.isEmpty { emit(.delta(tail)) }

            // A provider that streamed nothing still returns the whole reply;
            // strip it the same way rather than showing the raw protocol.
            let spoken = filter.sawAnything ? filter.visibleText : Self.stripToolBlocks(raw)
            visible += spoken

            guard !tools.isEmpty,
                  let payload = filter.toolPayloads.first,
                  let request = Self.parseToolRequest(payload) else {
                return visible.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let outcome = await callTool(name: request.name, arguments: request.arguments,
                                         emit: emit)
            // The model's own turn has to carry the call it made, or the next
            // round trip reads as if the result appeared from nowhere.
            messages.append(.assistant(spoken + "\n" + Self.openTag + payload + Self.closeTag))
            messages.append(.user("<tool_response>\n" + outcome.text + "\n</tool_response>"))
        }

        // Out of steps. Whatever was said is more use than an error; only a
        // completely silent run is genuinely unrenderable.
        let settled = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if settled.isEmpty { throw SoloEngineError.toolLoopExhausted }
        return settled
    }

    // MARK: One tool call (shared by both paths)

    private func callTool(name: String, arguments: JSONValue,
                          emit: @escaping @Sendable (SoloEvent) -> Void) async -> SoloToolOutcome {
        let callID = UUID().uuidString
        let preview = await toolbelt.preview(name: name, arguments: arguments)
        emit(.toolStart(id: callID, name: name,
                        preview: preview.isEmpty ? Self.describeArguments(arguments) : preview))

        let started = Date()
        let outcome = await toolbelt.run(name: name, arguments: arguments)
        emit(.toolEnd(id: callID,
                      summary: outcome.summary,
                      detail: outcome.text.isEmpty ? nil : outcome.text,
                      seconds: Date().timeIntervalSince(started),
                      failed: outcome.failed))
        return outcome
    }

    // MARK: Prompts

    /// The default instructions. Short — see the header note on prefill — and
    /// honest about what Solo is, because a model that believes it has a shell
    /// will promise one.
    public static let defaultSystemPrompt = """
        You are Solo, a small assistant running privately on this iPhone. \
        You have no shell and no access to the person's other apps except \
        through your tools. Answer briefly and plainly. If something needs a \
        real machine, say so and point at their Hermes gateway.
        """

    /// The default prompt plus the `<tool_call>` contract, for backends that
    /// cannot call tools themselves. The format is the Hermes / Qwen
    /// function-calling convention the catalog's models (Qwen3, Llama 3.2) are
    /// trained on, rather than one invented here.
    static func textProtocolPrompt(base: String, tools: [SoloToolDescriptor]) -> String {
        guard !tools.isEmpty else { return base }
        let required = tools.map { tool -> String in
            let names = tool.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let optional = tool.argumentNames.filter { !names.contains($0) }
            let arguments = (names + optional.map { "\($0)?" }).joined(separator: ", ")
            return "- \(tool.name)(\(arguments)) — \(tool.description)"
        }
        return base + """


            To use a tool, emit one block and stop:
            \(openTag){"name": "<tool>", "arguments": {…}}\(closeTag)
            The result comes back as <tool_response>; then answer the person.
            Tools:
            """ + "\n" + required.joined(separator: "\n")
    }

    // MARK: Parsing helpers

    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    struct ToolRequest: Sendable, Equatable {
        var name: String
        var arguments: JSONValue
    }

    /// `{"name": …, "arguments": {…}}`, tolerating the shapes small models
    /// actually emit: `arguments` nested, the payload flattened, or the
    /// arguments handed back as a JSON *string*.
    static func parseToolRequest(_ payload: String) -> ToolRequest? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let object = value.objectValue,
              let name = (object["name"] ?? object["tool"])?.stringValue,
              !name.isEmpty else { return nil }
        if let nested = object["arguments"] ?? object["parameters"] {
            return ToolRequest(name: name, arguments: unwrap(nested))
        }
        var flattened = object
        flattened.removeValue(forKey: "name")
        flattened.removeValue(forKey: "tool")
        return ToolRequest(name: name, arguments: .object(flattened))
    }

    /// A JSON object that arrived as a string, parsed. Refusing these would be
    /// a self-inflicted failure mode — small models emit them often enough
    /// that `.research/profiles-runtime.md` §8.4 calls it out by name.
    static func unwrap(_ value: JSONValue) -> JSONValue {
        guard case .string(let raw) = value,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              decoded.objectValue != nil else { return value }
        return decoded
    }

    /// Remove every complete tool block from a finished string — the
    /// non-streaming safety net behind `SoloStreamFilter`.
    static func stripToolBlocks(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: openTag) {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: closeTag) else {
                return out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback chip line for a call whose tool layer offered no preview —
    /// the arguments as a person would read them, never raw JSON.
    static func describeArguments(_ arguments: JSONValue) -> String {
        guard let object = arguments.objectValue, !object.isEmpty else { return "" }
        return object.keys.sorted()
            .compactMap { key in object[key].map { "\(key): \(describe($0))" } }
            .joined(separator: " · ")
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "yes" : "no"
        case .null: return "—"
        case .array(let items): return "\(items.count) items"
        case .object(let fields): return "\(fields.count) fields"
        }
    }

    /// Provider failures as one detail line. The themed voice belongs to
    /// CopyPack; this is what goes under it.
    public static func describe(error: Error) -> String {
        switch error {
        case let inference as InferenceProviderError:
            switch inference {
            case .notReady(let why): return why
            case .modelUnavailable(let id): return "model \(id) is unavailable"
            case .http(_, let message): return message
            case .protocolError(let message): return message
            }
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Streaming tool-call filter

/// Splits a token stream into visible text and `<tool_call>` payloads.
///
/// The hard part is the boundary: a chunk can end mid-marker (`"…here <too"`),
/// and emitting that would flash protocol text into the bubble. So a tail that
/// is still a prefix of the open tag is held back, and released as soon as the
/// next chunk proves it was ordinary text.
public struct SoloStreamFilter: Sendable {
    private var buffer = ""
    private var inTool = false
    private var toolBuffer = ""

    public private(set) var toolPayloads: [String] = []
    /// Everything released so far, so the caller need not re-assemble it.
    public private(set) var visibleText = ""
    /// Whether any chunk was ever fed in — distinguishes "the model said
    /// nothing" from "this provider never streamed".
    public private(set) var sawAnything = false

    public init() {}

    /// Feed one delta; returns the text that is safe to show now.
    public mutating func consume(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        sawAnything = true
        buffer += chunk
        var shown = ""
        while true {
            if inTool {
                guard let close = buffer.range(of: SoloEngine.closeTag) else { break }
                toolBuffer += buffer[..<close.lowerBound]
                toolPayloads.append(toolBuffer)
                toolBuffer = ""
                buffer = String(buffer[close.upperBound...])
                inTool = false
                continue
            }
            if let open = buffer.range(of: SoloEngine.openTag) {
                shown += buffer[..<open.lowerBound]
                buffer = String(buffer[open.upperBound...])
                inTool = true
                continue
            }
            let hold = Self.openTagPrefixLength(atEndOf: buffer)
            if hold < buffer.count {
                shown += buffer.prefix(buffer.count - hold)
                buffer = String(buffer.suffix(hold))
            }
            break
        }
        visibleText += shown
        return shown
    }

    /// End of stream: release what was held back, and treat an unclosed tool
    /// block as a payload anyway — small models drop the closing tag.
    public mutating func flush() -> String {
        if inTool {
            toolBuffer += buffer
            buffer = ""
            let candidate = toolBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { toolPayloads.append(candidate) }
            toolBuffer = ""
            inTool = false
            return ""
        }
        let rest = buffer
        buffer = ""
        visibleText += rest
        return rest
    }

    /// Length of the longest suffix of `text` that is a proper prefix of the
    /// open tag; 0 when the tail cannot be the start of one.
    static func openTagPrefixLength(atEndOf text: String) -> Int {
        let tag = SoloEngine.openTag
        var length = min(tag.count - 1, text.count)
        while length > 0 {
            if text.hasSuffix(String(tag.prefix(length))) { return length }
            length -= 1
        }
        return 0
    }
}

/// Reference box so the streaming handler — a `@Sendable` closure the provider
/// owns and calls — can drive one filter without value semantics fighting it.
/// Confined to the single task running the turn.
final class SoloStreamFilterBox: @unchecked Sendable {
    private var filter = SoloStreamFilter()

    func consume(_ chunk: String) -> String { filter.consume(chunk) }
    func flush() -> String { filter.flush() }
    var toolPayloads: [String] { filter.toolPayloads }
    var visibleText: String { filter.visibleText }
    var sawAnything: Bool { filter.sawAnything }
}

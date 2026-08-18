import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple's on-device model behind Talaria's `InferenceProvider` seam — Solo
// mode's default tier (docs/SOLO-MODE.md §"Inference on device").
//
// Why this is the default rather than MLX:
//   * The weights are already on the device. Nothing to download, nothing to
//     cache, no gigabytes in Settings → Privacy & data.
//   * Tool calling is first-class. The framework runs the whole tool loop
//     in-process, with guided generation, and resumes the same generation
//     afterwards — so Solo never has to coax `<tool_call>` JSON out of a 3B
//     model. That is the `SoloNativeToolProvider` conformance below, and it
//     is the reason SOLO-MODE.md picked this tier.
//   * Apple owns the thermal and memory envelope, which is the part that
//     makes a hand-rolled 4B model miserable in a foreground app.
//
// Availability is a *runtime* question, not just a compile-time one: the
// device has to be eligible, Apple Intelligence has to be on, and the assets
// have to have finished downloading. Talaria targets iOS 17, so every entry
// point is gated three times — `#if canImport(FoundationModels)` for the SDK,
// `#available(iOS 26, *)` for the OS, and `SystemLanguageModel.availability`
// for the device. When any of them says no, the Solo surface hides this tier
// rather than showing an error nobody can act on.

/// `InferenceProvider` over `SystemLanguageModel`, plus the native tool path
/// `SoloEngine` prefers.
///
/// Stateless per call, like every provider on this seam: each `chat` builds a
/// fresh `LanguageModelSession` from the messages it was handed. That costs a
/// little prefill and buys the thing that matters — Solo's conversation has
/// exactly one home (`SoloSessionArchive`) instead of two that can disagree,
/// which is also what lets the person switch engines mid-conversation.
public actor FoundationModelsProvider: InferenceProvider, SoloNativeToolProvider {

    /// The only model id this provider serves. There is one system model and
    /// Apple does not version it in the API, so naming it after the tier is
    /// more honest than inventing a version string.
    public static let modelID = "apple-on-device"

    public nonisolated var providerID: String { "apple-foundation-models" }

    /// The badge the transcript shows for an answer from this engine.
    public nonisolated var tag: SoloEngineTag {
        SoloEngineTag(providerID: providerID, model: Self.modelID,
                      label: "Apple on-device", isOnDevice: true)
    }

    /// Ceiling on one reply. The system model's window is small and Solo is
    /// for short exchanges; an unbounded generation is how a phone gets hot.
    private let maximumResponseTokens: Int

    public init(maximumResponseTokens: Int = 900) {
        self.maximumResponseTokens = maximumResponseTokens
    }

    // MARK: Availability

    /// Runtime availability, probed fresh — Apple Intelligence can be switched
    /// on, and assets can finish downloading, while the app is running.
    ///
    /// `SoloEngineProbe.foundationModels()` is the MainActor-bound sibling the
    /// explainer screen calls. This one is `nonisolated` because the provider
    /// itself has to check on the generation path, which is not on the main
    /// actor and must not hop there to find out it cannot run.
    public nonisolated static var availability: SoloEngineAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            return .unavailable(.osTooOld)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        @unknown default:
            return .unavailable(.unknown)
        }
        #else
        // Built against an SDK without the framework: honest, and identical in
        // effect to running on an OS that does not have it.
        return .unavailable(.osTooOld)
        #endif
    }

    public nonisolated static var isAvailable: Bool { availability.isAvailable }

    /// Whether the model can answer in this device's language. Apple ships a
    /// bounded language set and an unsupported locale throws mid-turn, so the
    /// Solo surface asks up front instead of failing a person's first message.
    public nonisolated static func supportsCurrentLocale() -> Bool {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return false }
        return SystemLanguageModel.default.supportsLocale(.current)
        #else
        return false
        #endif
    }

    /// Warm the model so the first token of the first turn is not the slowest
    /// in the conversation. Cheap, and safe to call whenever Solo opens.
    public func prewarm() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *), Self.isAvailable else { return }
        LanguageModelSession().prewarm()
        #endif
    }

    // MARK: InferenceProvider

    public func models() async throws -> [String] {
        guard Self.isAvailable else { throw Self.notReady() }
        return [Self.modelID]
    }

    @discardableResult
    public func chat(messages: [InferenceMessage], model: String,
                     stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        try await generate(messages: messages, tools: [], invoke: nil, handler: handler)
    }

    // MARK: SoloNativeToolProvider

    /// The path Solo actually takes. The framework decides when to call a
    /// tool, suspends inside `invoke` while `SoloToolRegistry` runs its two
    /// gates (which includes waiting for a person to answer an approval card),
    /// then resumes the same generation — which is why Solo's loop does no
    /// JSON parsing at all on this tier.
    @discardableResult
    public func chat(messages: [InferenceMessage], model: String,
                     tools: [SoloToolDescriptor],
                     invoke: @escaping @Sendable (String, JSONValue) async -> String,
                     stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        try await generate(messages: messages, tools: tools, invoke: invoke, handler: handler)
    }

    // MARK: Generation

    private func generate(messages: [InferenceMessage],
                          tools: [SoloToolDescriptor],
                          invoke: (@Sendable (String, JSONValue) async -> String)?,
                          handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { throw Self.notReady() }
        guard Self.isAvailable else { throw Self.notReady() }

        let split = Self.split(messages)
        let bridged: [any FoundationModels.Tool] = invoke.map { call in
            tools.compactMap { BridgedTool(descriptor: $0, invoke: call) }
        } ?? []

        let session = LanguageModelSession(
            tools: bridged,
            transcript: Self.transcript(instructions: split.instructions,
                                        history: split.history,
                                        tools: tools))
        let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)

        var emitted = ""
        do {
            let stream = session.streamResponse(to: split.prompt, options: options)
            for try await snapshot in stream {
                try Task.checkCancellation()
                // Snapshots are cumulative, so the delta is whatever grew. The
                // prefix check is not paranoia: a guarded rewrite can replace
                // the tail rather than extend it, and re-emitting the whole
                // reply would double the bubble.
                let text = snapshot.content
                if text.hasPrefix(emitted) {
                    let delta = String(text.dropFirst(emitted.count))
                    if !delta.isEmpty { handler(.delta(delta)) }
                } else if text != emitted {
                    handler(.delta(text))
                }
                emitted = text
            }
        } catch let error as LanguageModelSession.GenerationError {
            handler(.finished(reason: "error"))
            throw Self.translate(error)
        }
        handler(.finished(reason: "stop"))
        return emitted
        #else
        _ = (messages, tools, invoke, handler)
        throw Self.notReady()
        #endif
    }

    private static func notReady() -> InferenceProviderError {
        .notReady(availability.reason?.rawValue ?? "unavailable")
    }
}

#if canImport(FoundationModels)

// MARK: - Messages → Transcript

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension FoundationModelsProvider {

    struct Split {
        /// Every system message, joined — the framework's `Instructions`.
        var instructions: String
        /// Prior user/assistant turns, oldest first.
        var history: [InferenceMessage]
        /// The message being answered.
        var prompt: String
    }

    /// The seam hands over one flat array per call; the framework wants
    /// instructions, a transcript and a prompt. Splitting here, rather than
    /// asking callers to, is what keeps `InferenceProvider` tiny.
    static func split(_ messages: [InferenceMessage]) -> Split {
        let instructions = messages.filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        var turns = messages.filter { $0.role != .system }
        guard let lastUser = turns.lastIndex(where: { $0.role == .user }) else {
            return Split(instructions: instructions, history: turns, prompt: "")
        }
        let prompt = turns[lastUser].content
        turns.remove(at: lastUser)
        return Split(instructions: instructions, history: turns, prompt: prompt)
    }

    static func transcript(instructions: String, history: [InferenceMessage],
                           tools: [SoloToolDescriptor]) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: instructions.isEmpty ? [] : [.text(.init(content: instructions))],
                toolDefinitions: tools.compactMap { descriptor in
                    guard let schema = BridgedTool.schema(for: descriptor) else { return nil }
                    return Transcript.ToolDefinition(name: descriptor.name,
                                                     description: descriptor.description,
                                                     parameters: schema)
                })))
        }
        for message in history {
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(.init(content: message.content))])))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [], segments: [.text(.init(content: message.content))])))
            case .system:
                continue
            }
        }
        return Transcript(entries: entries)
    }

    /// Framework errors in the seam's vocabulary. The reasons a person could
    /// act on keep their identity; the rest are transport failures. The
    /// user-facing wording is CopyPack's job, so these stay short tokens.
    static func translate(_ error: LanguageModelSession.GenerationError) -> InferenceProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .protocolError("context-window-exceeded")
        case .guardrailViolation, .refusal:
            return .protocolError("guardrail")
        case .unsupportedLanguageOrLocale:
            return .notReady("unsupported-language")
        case .assetsUnavailable:
            return .notReady("assets-unavailable")
        case .rateLimited:
            return .protocolError("rate-limited")
        default:
            return .protocolError(error.errorDescription ?? "generation failed")
        }
    }
}

// MARK: - Solo tool → FoundationModels.Tool

/// One Solo tool wearing the framework's `Tool` protocol.
///
/// `Arguments` is `GeneratedContent` rather than a `@Generable` struct because
/// Solo's tool list is assembled at runtime — it depends on which permissions
/// are on, which folders were granted and which shortcuts exist — and the
/// macro needs types at compile time. So the schema is built dynamically from
/// the tool's own JSON Schema and the arguments are read back as `JSONValue`,
/// which is the shape the rest of Talaria already speaks.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let invoke: @Sendable (String, JSONValue) async -> String

    init?(descriptor: SoloToolDescriptor,
          invoke: @escaping @Sendable (String, JSONValue) async -> String) {
        guard let schema = Self.schema(for: descriptor) else { return nil }
        self.name = descriptor.name
        self.description = descriptor.description
        self.parameters = schema
        self.invoke = invoke
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let decoded = (try? JSONDecoder().decode(JSONValue.self,
                                                 from: Data(arguments.jsonString.utf8)))
            ?? .object([:])
        return await invoke(name, decoded)
    }

    /// JSON Schema → `GenerationSchema`. This is the guided-generation half:
    /// once the schema is installed the model cannot emit a malformed call at
    /// all, which is the whole argument for this tier over hand-parsed JSON.
    ///
    /// Only the shapes `SoloSchema` actually produces are handled — a flat
    /// object of string / integer / boolean properties, optionally with an
    /// `enum` of string choices. Anything richer returns nil and the tool is
    /// left out rather than offered with a schema that does not describe it.
    static func schema(for descriptor: SoloToolDescriptor) -> GenerationSchema? {
        let required = Set(descriptor.parameters["required"]?.arrayValue?
            .compactMap(\.stringValue) ?? [])
        let properties = descriptor.parameters["properties"]?.objectValue ?? [:]

        var fields: [DynamicGenerationSchema.Property] = []
        for name in properties.keys.sorted() {
            guard let node = properties[name],
                  let value = valueSchema(node, name: name) else { return nil }
            fields.append(DynamicGenerationSchema.Property(
                name: name,
                description: node["description"]?.stringValue,
                schema: value,
                isOptional: !required.contains(name)))
        }
        let root = DynamicGenerationSchema(name: descriptor.name,
                                           description: descriptor.description,
                                           properties: fields)
        return try? GenerationSchema(root: root, dependencies: [])
    }

    private static func valueSchema(_ node: JSONValue, name: String) -> DynamicGenerationSchema? {
        if let options = node["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
            return DynamicGenerationSchema(name: "\(name)-choice", anyOf: options)
        }
        switch node["type"]?.stringValue {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return nil
        }
    }
}

#endif

import Foundation
import TalariaKit
import MLXLMCommon
import MLXLLM

// TalariaKit.InferenceProvider backed by an MLX language model running
// entirely on-device — the "pocket bot" backend. This is a plain
// chat-completion engine, deliberately NOT a hermes profile: no SOUL.md, no
// memory, no tools, no cron (see docs/LOCAL-INFERENCE.md for why the full
// runtime cannot live on a phone).
//
// Design constraints:
//   - One resident model at a time. Phone memory budgets (~3.5–4 GB usable
//     even with the Increased Memory Limit entitlement) do not fit two 4-bit
//     models plus KV cache; switching models drops the old container before
//     loading the new one.
//   - Stateless per call, like every InferenceProvider: the caller passes
//     the full message array each turn and MLX re-prefills. That is honest
//     about the context window and keeps this interchangeable with the
//     remote providers. (MLXLMCommon's ChatSession keeps hidden history and
//     a KV cache; we use the lower-level generate API instead so the
//     provider seam stays uniform.)
//   - Qwen-style reasoning is surfaced: `<think>…</think>` spans are routed
//     to `InferenceEvent.reasoningDelta` and never become part of the
//     returned message, matching how the Portal provider treats
//     `reasoning_content`.

public actor LocalModelProvider: InferenceProvider {
    public nonisolated var providerID: String { "local-mlx" }

    private let store: LocalModelStore
    /// The one resident model (hub id + loaded container).
    private var loaded: (hubID: String, container: ModelContainer)?
    /// Dedupes concurrent loads of the same model (weights are ~1–2.3 GB;
    /// loading twice in parallel would double peak memory).
    private var loadTask: (hubID: String, task: Task<ModelContainer, Error>)?

    /// Sampling defaults for pocket-bot chat. Tune via `setParameters`;
    /// applies to subsequent `chat` calls.
    public private(set) var parameters = GenerateParameters(
        maxTokens: 2048, temperature: 0.7, topP: 0.95)

    /// Replace the sampling parameters (actor-isolated; callable from any
    /// task via `await`).
    public func setParameters(_ parameters: GenerateParameters) {
        self.parameters = parameters
    }

    public init(store: LocalModelStore = LocalModelStore()) {
        self.store = store
    }

    // MARK: - InferenceProvider

    /// Models actually downloaded to this device (hub ids), catalog entries
    /// first. Unlike remote providers this never touches the network.
    public func models() async throws -> [String] {
        store.downloadedModelIDs()
    }

    @discardableResult
    public func chat(messages: [InferenceMessage], model: String,
                     stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String {
        let container = try await container(for: model)

        let chat: [Chat.Message] = messages.map { message in
            switch message.role {
            case .system: return .system(message.content)
            case .user: return .user(message.content)
            case .assistant: return .assistant(message.content)
            }
        }
        let parameters = self.parameters

        let assembled: String = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(chat: chat))
            var splitter = ReasoningTagSplitter()
            var visible = ""

            let stream = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context)
            for await generation in stream {
                // Breaking out of the iteration terminates the underlying
                // generation task (AsyncStream onTermination), so observing
                // cancellation here is what actually stops the GPU work.
                if Task.isCancelled { break }
                switch generation {
                case .chunk(let text):
                    for piece in splitter.consume(text) {
                        switch piece {
                        case .visible(let s):
                            visible += s
                            handler(.delta(s))
                        case .reasoning(let s):
                            handler(.reasoningDelta(s))
                        }
                    }
                default:
                    // .info (throughput stats) / .toolCall — the pocket bot
                    // has no tool loop; ignore.
                    break
                }
            }
            for piece in splitter.flush() {
                switch piece {
                case .visible(let s):
                    visible += s
                    handler(.delta(s))
                case .reasoning(let s):
                    handler(.reasoningDelta(s))
                }
            }
            return visible
        }

        try Task.checkCancellation()
        // MLX does not report an OpenAI-style finish_reason; nil is the
        // documented "backend doesn't say" value.
        handler(.finished(reason: nil))
        return assembled
    }

    // MARK: - Model lifecycle

    /// Load (or return the already-resident) container for `hubID`.
    public func preload(_ hubID: String) async throws {
        _ = try await container(for: hubID)
    }

    /// The hub id of the currently resident model, if any.
    public var residentModelID: String? { loaded?.hubID }

    /// Drop the resident model. Call from a memory-warning handler or when
    /// the local chat screen disappears — weights come back on next `chat`.
    public func unload() {
        loaded = nil
    }

    private func container(for hubID: String) async throws -> ModelContainer {
        if let loaded, loaded.hubID == hubID { return loaded.container }
        if let loadTask, loadTask.hubID == hubID { return try await loadTask.task.value }

        guard let directory = store.snapshotDirectoryIfDownloaded(for: hubID) else {
            if ModelCatalog.spec(for: hubID) == nil {
                throw InferenceProviderError.modelUnavailable(hubID)
            }
            throw InferenceProviderError.notReady("model \(hubID) is not downloaded")
        }

        // Free the previous model *before* loading the next; no phone fits
        // two sets of weights at once.
        loaded = nil
        loadTask?.task.cancel()

        let task = Task {
            try await LLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(directory: directory))
        }
        loadTask = (hubID, task)
        // Clear only our own entry — actor reentrancy means a newer load may
        // have replaced it while we were suspended.
        defer { if loadTask?.task == task { loadTask = nil } }
        let container = try await task.value
        loaded = (hubID, container)
        return container
    }
}

// MARK: - Streaming <think> splitter

/// Streaming splitter for reasoning tags. Qwen3 (and other reasoning-tuned
/// small models) open their answer with a `<think>…</think>` span; tokens
/// arrive in arbitrary chunk boundaries, so tags can be split across chunks.
/// The splitter holds back only the shortest suffix that could still be a
/// partial tag and emits everything else immediately.
struct ReasoningTagSplitter {
    enum Piece: Equatable {
        case visible(String)
        case reasoning(String)
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var inReasoning = false
    /// Swallow the cosmetic blank lines models emit right after `</think>`.
    private var dropLeadingNewlines = false

    mutating func consume(_ text: String) -> [Piece] {
        buffer += text
        var out: [Piece] = []

        while true {
            let tag = inReasoning ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                let before = String(buffer[buffer.startIndex..<range.lowerBound])
                emit(before, into: &out)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                inReasoning.toggle()
                dropLeadingNewlines = !inReasoning  // just closed a think span
                continue
            }
            break
        }

        // Emit all but the longest buffer suffix that is a prefix of the
        // next tag we are looking for (it may complete in the next chunk).
        let tag = inReasoning ? Self.closeTag : Self.openTag
        let hold = Self.longestSuffixPrefix(of: buffer, matching: tag)
        if buffer.count > hold {
            let cut = buffer.index(buffer.endIndex, offsetBy: -hold)
            emit(String(buffer[buffer.startIndex..<cut]), into: &out)
            buffer.removeSubrange(buffer.startIndex..<cut)
        }
        return out
    }

    /// Emit whatever is still held back (end of stream — a partial tag that
    /// never completed is just text).
    mutating func flush() -> [Piece] {
        var out: [Piece] = []
        emit(buffer, into: &out)
        buffer = ""
        return out
    }

    private mutating func emit(_ text: String, into out: inout [Piece]) {
        var text = text
        if dropLeadingNewlines, !inReasoning {
            text = String(text.drop(while: { $0 == "\n" || $0 == "\r" }))
            if !text.isEmpty { dropLeadingNewlines = false }
        }
        guard !text.isEmpty else { return }
        out.append(inReasoning ? .reasoning(text) : .visible(text))
    }

    /// Length of the longest suffix of `text` that is a proper prefix of
    /// `tag` (bounded by the tag length, so this is O(tagLength²)).
    private static func longestSuffixPrefix(of text: String, matching tag: String) -> Int {
        let maxLen = min(text.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for length in stride(from: maxLen, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(length)) { return length }
        }
        return 0
    }
}

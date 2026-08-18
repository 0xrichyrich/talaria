import Foundation

// The BYO-inference seam. A gateway connection gives Talaria full bots
// (profiles, tools, approvals, routines); an InferenceProvider gives it a
// plain chat-completion backend with no gateway at all — Nous Portal direct
// (NousPortalClient) or an on-device MLX model (TalariaLocal's
// LocalModelProvider). Both stream token deltas and return the assembled
// assistant message.
//
// The protocol is deliberately tiny: list models, run one chat turn. No
// sessions, no tools, no persistence — callers own conversation state and
// pass the full message array every turn (both backends are stateless per
// call, which also keeps the local provider honest about its context window).

// MARK: - Messages

/// One chat message in OpenAI wire shape ({role, content}).
public struct InferenceMessage: Codable, Sendable, Equatable, Hashable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> InferenceMessage {
        InferenceMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> InferenceMessage {
        InferenceMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> InferenceMessage {
        InferenceMessage(role: .assistant, content: content)
    }
}

// MARK: - Stream events

/// Incremental events delivered while a chat completion runs.
public enum InferenceEvent: Sendable, Equatable {
    /// A chunk of assistant text (OpenAI `choices[0].delta.content`).
    case delta(String)
    /// Reasoning-channel text for models that stream `reasoning_content`.
    /// Purely informational; never part of the returned message.
    case reasoningDelta(String)
    /// Terminal event. `reason` is the server's finish_reason when known
    /// ("stop", "length", …); nil for backends that don't report one.
    case finished(reason: String?)
}

// MARK: - Provider protocol

/// A chat-completion backend independent of any hermes gateway.
///
/// Implementations must be safe to call from any task. Cancellation follows
/// structured concurrency: cancel the task running `chat` and the provider
/// stops generating (and stops invoking `handler`) as soon as it observes
/// the cancellation.
public protocol InferenceProvider: Sendable {
    /// Stable machine id for this backend ("nous-portal", "local-mlx").
    var providerID: String { get }

    /// Model ids this provider can serve right now. For remote providers
    /// this is the server's model list; for the local provider it is the
    /// set of models actually downloaded to the device.
    func models() async throws -> [String]

    /// Run one chat completion over the full message array, streaming
    /// events to `handler` in arrival order, and return the complete
    /// assembled assistant message.
    @discardableResult
    func chat(messages: [InferenceMessage], model: String,
              stream handler: @escaping @Sendable (InferenceEvent) -> Void) async throws -> String
}

// MARK: - Common errors

/// Errors shared by inference backends. Providers may also throw their own
/// domain errors (see NousPortalError); UI should treat anything else as a
/// generic transport failure.
public enum InferenceProviderError: Error, Sendable, Equatable {
    /// The provider cannot serve yet (not signed in, model not downloaded).
    case notReady(String)
    /// The requested model id is unknown to this provider.
    case modelUnavailable(String)
    /// Non-200 HTTP response from a remote backend.
    case http(status: Int, message: String)
    /// The backend replied with something structurally unexpected.
    case protocolError(String)
}

import Foundation

/// Policy for Hermes' message-level `session.branch { count }` contract.
///
/// The count is not an index into Talaria's rendered bubbles. Hermes first
/// filters its complete display history to nonempty user/assistant rows, then
/// copies a prefix of that filtered sequence. Resolving against the fresh
/// `session.history` projection by durable `row_id` keeps hidden/tool rows and
/// duplicate text from changing the selected branch point.
public enum MessageBranching {
    public enum ResolutionError: Error, LocalizedError, Equatable, Sendable {
        case invalidTargetRowID
        case malformedHistory
        case targetNotFound
        case targetIsNotAssistant
        case duplicateTargetRowID

        public var errorDescription: String? {
            switch self {
            case .invalidTargetRowID:
                return "That message has no durable transcript address."
            case .malformedHistory:
                return "Hermes returned a malformed session history."
            case .targetNotFound:
                return "That message is no longer in the current session history."
            case .targetIsNotAssistant:
                return "That transcript row is no longer an assistant message."
            case .duplicateTargetRowID:
                return "Hermes returned an ambiguous transcript row identity."
            }
        }
    }

    /// A settled historical assistant bubble is eligible. The newest
    /// assistant remains the whole-tip branch handled by Sessions; a local or
    /// streaming bubble has no stable historical branch point.
    public static func isEligible(_ message: ChatMessage,
                                  in messages: [ChatMessage]) -> Bool {
        guard message.author == .bot, !message.isStreaming,
              let rowID = message.rowID, rowID > 0,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messages.contains(where: { $0.id == message.id }) else { return false }
        return isEligibleAssistant(rowID: rowID, in: messages)
    }

    /// Re-check eligibility by durable identity after an await. Hydration may
    /// rebuild local UUIDs while preserving the row address the user selected.
    public static func isEligibleAssistant(rowID: Int,
                                           in messages: [ChatMessage]) -> Bool {
        guard rowID > 0 else { return false }
        let matching = messages.filter {
            $0.rowID == rowID && $0.author == .bot && !$0.isStreaming
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard matching.count == 1,
              let newestAssistant = messages.last(where: { $0.author == .bot }) else {
            return false
        }
        return newestAssistant.rowID != rowID
    }

    /// Return Hermes' positive filtered-message count through one assistant
    /// row. `session.history` is the full ancestor-aware display projection;
    /// no rendered/local transcript is consulted here.
    public static func countThroughAssistant(rowID targetRowID: Int,
                                             history: JSONValue) throws -> Int {
        guard targetRowID > 0 else { throw ResolutionError.invalidTargetRowID }
        guard let rows = history["messages"]?.arrayValue else {
            throw ResolutionError.malformedHistory
        }

        var filteredCount = 0
        var targetRole: String?
        var targetCount: Int?
        for value in rows {
            guard let row = value.objectValue else { continue }
            guard row["display_kind"]?.stringValue != "hidden",
                  let role = row["role"]?.stringValue,
                  role == "user" || role == "assistant",
                  let text = row["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            filteredCount += 1
            guard exactInteger(row["row_id"]) == targetRowID else { continue }
            guard targetCount == nil else {
                throw ResolutionError.duplicateTargetRowID
            }
            targetRole = role
            targetCount = filteredCount
        }

        guard let targetCount else { throw ResolutionError.targetNotFound }
        guard targetRole == "assistant" else {
            throw ResolutionError.targetIsNotAssistant
        }
        return targetCount
    }

    private static func exactInteger(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        return Int(exactly: number)
    }
}

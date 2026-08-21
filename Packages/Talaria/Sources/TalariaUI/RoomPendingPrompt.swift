import Foundation
import TalariaKit

/// The in-memory address of a blocking prompt raised by one member of one
/// room. A bare profile is never enough: two retained gateways may both have
/// a `default` member, and a prompt must go back to the source that parked it.
public struct RoomPendingPromptKey: Hashable, Sendable, Identifiable {
    public var roomID: RoomID
    public var route: GatewayBotRoute
    public var member: GatewayBotRoute { route }
    public var id: Self { self }

    public init(roomID: RoomID, route: GatewayBotRoute) {
        self.roomID = roomID
        self.route = route
    }

    public init(roomID: RoomID, member: GatewayBotRoute) {
        self.init(roomID: roomID, route: member)
    }
}

/// One normalized question inside a pending clarify. Hermes' batch payloads
/// used both `qid` and `id` while the contract was being introduced, so the
/// parser keeps one stable `questionID` for either spelling. A nil id is the
/// ordinary, non-batch clarify and deliberately omits `question_id` on the
/// response wire.
public struct RoomPendingClarifyQuestion: Sendable, Equatable, Identifiable {
    public var questionID: String?
    public var qid: String? { questionID }
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool
    public var id: String { questionID ?? "__single__" }

    public init(questionID: String? = nil, question: String = "",
                choices: [String] = [], multiSelect: Bool = false) {
        self.questionID = Self.nonEmpty(questionID)
        self.question = question
        self.choices = Self.nonBlankChoices(choices)
        self.multiSelect = multiSelect
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonBlankChoices(_ values: [String]) -> [String] {
        values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Runtime-stable identity for one blocking prompt payload. Hermes request ids
/// are process-local and may be reused after a restart, so the durable room
/// producer fields alone cannot distinguish a replacement prompt within the
/// same attempt. Runtime session id and replayed answers are intentionally not
/// included: both may change while the same logical prompt survives resume.
public struct RoomPendingPromptFingerprint: Hashable, Sendable {
    public struct Question: Hashable, Sendable {
        public var id: String?
        public var text: String
        public var options: [String]
        public var multiSelect: Bool

        init(_ question: RoomPendingClarifyQuestion) {
            id = Self.normalized(question.questionID)
            text = Self.normalized(question.question)
            options = question.choices.compactMap(Self.normalizedNonempty)
            multiSelect = question.multiSelect
        }

        private static func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func normalizedNonempty(_ value: String) -> String? {
            let normalized = normalized(value)
            return normalized.isEmpty ? nil : normalized
        }
    }

    public var kind: RoomPendingPrompt.Kind
    public var headline: String
    public var questions: [Question]
    public var approvalChoices: [String]
    public var command: String

    init(_ prompt: RoomPendingPrompt) {
        kind = prompt.kind
        headline = Self.normalized(prompt.question)
        questions = prompt.kind == .clarify ? prompt.questions.map(Question.init) : []
        approvalChoices = prompt.kind == .approval
            ? prompt.approvalChoices.map { Self.normalized($0.rawValue) } : []
        command = prompt.kind == .approval ? Self.normalized(prompt.command) : ""
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A source-qualified response ready for a caller to send through the client
/// belonging to `route`. Keeping the route beside the RPC shape makes it much
/// harder for a room card to accidentally answer a similarly named member on
/// the active gateway.
public struct RoomPendingPromptResponse: Sendable, Equatable {
    public var route: GatewayBotRoute
    public var method: String
    public var params: JSONValue

    public init(route: GatewayBotRoute, method: String, params: JSONValue) {
        self.route = route
        self.method = method
        self.params = params
    }

    /// Hermes returns an integer count because a response may resolve more
    /// than one parked approval. Missing/malformed responses are not success.
    public static func resolvedCount(in result: JSONValue) -> Int {
        result["resolved"]?.intValue ?? 0
    }
}

/// Local validation failures for pending-room prompt parsing and response
/// construction. These stay distinct from a gateway rejection: no wire call
/// was made when one of these is thrown.
public enum RoomPendingPromptError: Error, Sendable, Equatable {
    case missingRequestID
    case missingRuntimeSessionID
    case wrongPromptKind
    case unknownQuestionID
    case questionIsNotMultiSelect
}

/// A non-persisted projection of a hidden member session's blocking state.
/// The durable room record intentionally does not store it: Hermes owns the
/// pending request and can expire it while Talaria is away. The exact attempt,
/// thread, epoch, and *current runtime SID* fence an answer to the member turn
/// that produced it.
public struct RoomPendingPrompt: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case clarify
        case approval
    }

    public typealias Key = RoomPendingPromptKey

    public var key: RoomPendingPromptKey
    public var attemptID: RoomAttemptID
    public var threadID: RoomThreadID
    public var epoch: UInt64
    /// The runtime SID that arrived in the same `session.resume` snapshot.
    /// Approval responses require it; a durable stored id is never valid for
    /// the `approval.respond` wire.
    public var runtimeSessionID: String
    public var requestID: String
    public var kind: Kind
    public var question: String
    public var command: String
    public var clarifyChoices: [String]
    public var approvalChoices: [ApprovalChoice]
    /// Always has one item for a clarify. A nil `questionID` means the normal
    /// one-question protocol; a non-nil id means a batch item.
    public var questions: [RoomPendingClarifyQuestion]
    /// Batch answers Hermes already accepted before this `session.resume`.
    /// This is deliberately runtime-only (RoomPendingPrompt is not Codable):
    /// answers can contain free-form user text and must never enter the room
    /// transcript or its on-disk record.
    public var lockedAnswersByQuestionID: [String: String]

    public var id: RoomPendingPromptKey { key }
    public var roomID: RoomID { key.roomID }
    public var route: GatewayBotRoute { key.route }
    public var member: GatewayBotRoute { key.route }
    public var botRoute: GatewayBotRoute { key.route }
    public var runtimeID: String { runtimeSessionID }
    public var sessionID: String { runtimeSessionID }
    public var choices: [String] {
        switch kind {
        case .clarify: clarifyChoices
        case .approval: approvalChoices.map(\.rawValue)
        }
    }
    public var multiSelect: Bool { questions.first?.multiSelect ?? false }
    public var isBatchClarify: Bool {
        kind == .clarify && questions.contains { $0.questionID != nil }
    }
    public var batchQuestions: [RoomPendingClarifyQuestion]? {
        isBatchClarify ? questions : nil
    }
    /// `accepted` is the server-side meaning of a locked batch answer. Both
    /// spellings make the UI/runtime intent explicit without exposing a fake
    /// durable state on RoomRecord.
    public var lockedQuestionIDs: Set<String> { Set(lockedAnswersByQuestionID.keys) }
    public var acceptedQuestionIDs: Set<String> { lockedQuestionIDs }
    public var hasLockedQuestions: Bool { !lockedAnswersByQuestionID.isEmpty }
    public var stableFingerprint: RoomPendingPromptFingerprint {
        RoomPendingPromptFingerprint(self)
    }

    public init(key: RoomPendingPromptKey, attemptID: RoomAttemptID,
                threadID: RoomThreadID, epoch: UInt64, runtimeSessionID: String,
                requestID: String, kind: Kind, question: String = "",
                command: String = "", clarifyChoices: [String] = [],
                approvalChoices: [ApprovalChoice] = [],
                questions: [RoomPendingClarifyQuestion] = [],
                multiSelect: Bool = false,
                lockedAnswersByQuestionID: [String: String] = [:]) {
        self.key = key
        self.attemptID = attemptID
        self.threadID = threadID
        self.epoch = epoch
        self.runtimeSessionID = runtimeSessionID
        self.requestID = requestID
        self.kind = kind
        self.question = question
        self.command = command
        self.clarifyChoices = clarifyChoices.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.approvalChoices = kind == .approval
            ? Self.normalizedApprovalChoices(approvalChoices)
            : []
        if kind == .clarify {
            self.questions = questions.isEmpty
                ? [RoomPendingClarifyQuestion(question: question,
                                              choices: clarifyChoices,
                                              multiSelect: multiSelect)]
                : questions
        } else {
            self.questions = []
        }
        let validQuestionIDs = Set(self.questions.compactMap(\.questionID))
        self.lockedAnswersByQuestionID = kind == .clarify
            ? lockedAnswersByQuestionID.reduce(into: [:]) { result, entry in
                let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard validQuestionIDs.contains(questionID) else { return }
                result[questionID] = entry.value
            }
            : [:]
    }

    /// Normalize the two replay fields carried by `session.resume`. A raw
    /// clarify object deliberately takes precedence over an approval object:
    /// clarifies are the outer blocking tool and presenting the nested
    /// approval instead would leave the visible question unresolved.
    public static func normalize(
        roomID: RoomID,
        route: GatewayBotRoute,
        attempt: RoomAttempt,
        snapshot: RoomMemberSessionSnapshot
    ) -> RoomPendingPrompt? {
        guard attempt.member == route else { return nil }
        return normalize(roomID: roomID, route: route, attemptID: attempt.id,
                         threadID: attempt.threadID, epoch: attempt.epoch,
                         runtimeSessionID: snapshot.runtimeID,
                         pendingClarify: snapshot.pendingClarify,
                         pendingApproval: snapshot.pendingApproval)
    }

    public static func normalize(roomID: RoomID, attempt: RoomAttempt,
                                 snapshot: RoomMemberSessionSnapshot) -> RoomPendingPrompt? {
        normalize(roomID: roomID, route: attempt.member, attempt: attempt, snapshot: snapshot)
    }

    /// Lower-level overload retained for reconciliation code that already has
    /// its exact attempt identity split into fields.
    public static func normalize(
        roomID: RoomID,
        route: GatewayBotRoute,
        attemptID: RoomAttemptID,
        threadID: RoomThreadID,
        epoch: UInt64,
        runtimeSessionID: String,
        pendingClarify: JSONValue?,
        pendingApproval: ApprovalRequest?
    ) -> RoomPendingPrompt? {
        guard let runtimeSessionID = nonEmpty(runtimeSessionID) else { return nil }
        let base = (key: RoomPendingPromptKey(roomID: roomID, route: route),
                    attemptID: attemptID, threadID: threadID, epoch: epoch,
                    runtimeSessionID: runtimeSessionID)

        // Do not fall through from a malformed clarify to an approval. The
        // clarify still owns the outer tool batch, and no safe response can be
        // made without its request id.
        if let clarify = pendingClarify?.objectValue {
            return clarifyPrompt(clarify, base: base)
        }
        if let pendingApproval {
            return approvalPrompt(pendingApproval, base: base)
        }
        return nil
    }

    /// The same predicate RoomMemberSessionSnapshot exposes as `awaitingUser`.
    /// It uses the parser rather than testing raw object presence, so malformed
    /// data never holds a room driver indefinitely.
    public static func isAwaitingUser(pendingClarify: JSONValue?,
                                      pendingApproval: ApprovalRequest?) -> Bool {
        let placeholderRoom = RoomID(rawValue: UUID())
        let placeholderRoute = GatewayBotRoute(gatewayID: "pending", profile: "pending")
        return normalize(roomID: placeholderRoom, route: placeholderRoute,
                         attemptID: RoomAttemptID(rawValue: UUID()),
                         threadID: RoomThreadID(rawValue: UUID()), epoch: 0,
                         runtimeSessionID: "pending-runtime",
                         pendingClarify: pendingClarify,
                         pendingApproval: pendingApproval) != nil
    }

    /// Build the exact source-qualified approval response. A caller must send
    /// it through `routedClient(for: response.route)`; its successful RPC
    /// result is decoded with `RoomPendingPromptResponse.resolvedCount(in:)`.
    public func approvalResponse(choice: ApprovalChoice) throws -> RoomPendingPromptResponse {
        guard kind == .approval else { throw RoomPendingPromptError.wrongPromptKind }
        guard let runtime = Self.nonEmpty(runtimeSessionID) else {
            throw RoomPendingPromptError.missingRuntimeSessionID
        }
        guard let requestID = Self.nonEmpty(requestID) else {
            throw RoomPendingPromptError.missingRequestID
        }
        return RoomPendingPromptResponse(
            route: route,
            method: "approval.respond",
            params: try Self.approvalResponseParameters(sessionID: runtime,
                                                        requestID: requestID,
                                                        choice: choice))
    }

    /// Build one clarify response. `questionID` is emitted only for a batch
    /// item; the normal one-question clarify protocol intentionally has no
    /// session id and no question id on the wire.
    public func clarifyResponse(answer: String,
                                questionID: String? = nil) throws -> RoomPendingPromptResponse {
        guard kind == .clarify else { throw RoomPendingPromptError.wrongPromptKind }
        let normalizedQuestionID = try validatedQuestionID(questionID,
                                                            requireMultiSelect: false)
        return try Self.clarifyResponse(route: route, requestID: requestID,
                                        answer: answer, questionID: normalizedQuestionID)
    }

    /// Multi-select values must cross as one JSON array string; comma joining
    /// corrupts an otherwise valid choice label such as `"red, blue"`.
    public func clarifyResponse(selections: [String],
                                questionID: String? = nil) throws -> RoomPendingPromptResponse {
        guard kind == .clarify else { throw RoomPendingPromptError.wrongPromptKind }
        let normalizedQuestionID = try validatedQuestionID(questionID,
                                                            requireMultiSelect: true)
        return try Self.clarifyResponse(route: route, requestID: requestID,
                                        selections: selections,
                                        questionID: normalizedQuestionID)
    }

    /// Whether this exact batch item already has a server-accepted answer in
    /// the replay snapshot. A nil question id is the ordinary single clarify
    /// and cannot be locked per-question.
    public func isQuestionLocked(_ question: RoomPendingClarifyQuestion) -> Bool {
        guard let questionID = question.questionID else { return false }
        return lockedAnswersByQuestionID[questionID] != nil
    }

    /// Kept for progress presentation only. The caller should not copy this
    /// into a transcript or durable store; it is free-form user input.
    public func lockedAnswer(for questionID: String) -> String? {
        lockedAnswersByQuestionID[questionID]
    }

    /// Parse the gateway's `resolved` acknowledgement for an approval response.
    public static func resolvedApprovalCount(in result: JSONValue) -> Int {
        RoomPendingPromptResponse.resolvedCount(in: result)
    }

    /// Public standalone builders are useful to a source router that holds a
    /// prompt's route separately from its card state.
    public static func approvalResponse(route: GatewayBotRoute, sessionID: String,
                                        requestID: String,
                                        choice: ApprovalChoice) throws -> RoomPendingPromptResponse {
        return RoomPendingPromptResponse(
            route: route,
            method: "approval.respond",
            params: try approvalResponseParameters(sessionID: sessionID,
                                                   requestID: requestID,
                                                   choice: choice))
    }

    public static func clarifyResponse(route: GatewayBotRoute, requestID: String,
                                       answer: String,
                                       questionID: String? = nil) throws -> RoomPendingPromptResponse {
        RoomPendingPromptResponse(
            route: route,
            method: "clarify.respond",
            params: try clarifyResponseParameters(requestID: requestID,
                                                  answer: answer,
                                                  questionID: questionID))
    }

    /// Exact `approval.respond` parameters, independent of which retained
    /// gateway client will carry them. Useful to the transport wrapper and to
    /// narrow wire-shape tests.
    public static func approvalResponseParameters(sessionID: String, requestID: String,
                                                  choice: ApprovalChoice) throws -> JSONValue {
        guard let sessionID = nonEmpty(sessionID) else {
            throw RoomPendingPromptError.missingRuntimeSessionID
        }
        guard let requestID = nonEmpty(requestID) else {
            throw RoomPendingPromptError.missingRequestID
        }
        let params: [String: JSONValue] = ["request_id": .string(requestID),
                                           "session_id": .string(sessionID),
                                           "choice": .string(choice.rawValue)]
        return .object(params)
    }

    /// Exact `clarify.respond` parameters. Hermes identifies this bridge by
    /// `request_id`; `question_id` exists only for a batched clarify.
    public static func clarifyResponseParameters(requestID: String, answer: String,
                                                 questionID: String? = nil) throws -> JSONValue {
        guard let requestID = nonEmpty(requestID) else {
            throw RoomPendingPromptError.missingRequestID
        }
        var params: [String: JSONValue] = ["request_id": .string(requestID),
                                           "answer": .string(answer)]
        if let questionID = nonEmpty(questionID) { params["question_id"] = .string(questionID) }
        return .object(params)
    }

    public static func clarifyResponse(route: GatewayBotRoute, requestID: String,
                                       selections: [String],
                                       questionID: String? = nil) throws -> RoomPendingPromptResponse {
        try clarifyResponse(route: route, requestID: requestID,
                            answer: multiSelectAnswer(selections), questionID: questionID)
    }

    /// JSONEncoder cannot fail for an array of strings in practice, but retain
    /// a deterministic valid JSON fallback rather than ever regressing to the
    /// lossy comma-delimited legacy encoding.
    public static func multiSelectAnswer(_ selections: [String]) -> String {
        guard let data = try? JSONEncoder().encode(selections) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func clarifyPrompt(
        _ clarify: [String: JSONValue],
        base: (key: RoomPendingPromptKey, attemptID: RoomAttemptID,
               threadID: RoomThreadID, epoch: UInt64, runtimeSessionID: String)
    ) -> RoomPendingPrompt? {
        guard let requestID = nonEmpty(clarify["request_id"]?.stringValue) else { return nil }
        let topLevelQuestion = clarify["question"]?.stringValue ?? ""
        let topLevelChoices = choices(in: clarify)
        let topLevelMultiSelect = multiSelect(in: clarify)

        if let rawQuestions = clarify["questions"]?.arrayValue, !rawQuestions.isEmpty {
            var questions: [RoomPendingClarifyQuestion] = []
            var ids = Set<String>()
            for rawQuestion in rawQuestions {
                guard let question = rawQuestion.objectValue,
                      let parsed = batchQuestion(question),
                      ids.insert(parsed.questionID ?? "").inserted
                else {
                    // A partially addressable batch cannot safely be answered:
                    // skipping one item would leave Hermes' tool parked.
                    return nil
                }
                questions.append(parsed)
            }
            guard !questions.isEmpty else { return nil }
            return RoomPendingPrompt(key: base.key, attemptID: base.attemptID,
                                     threadID: base.threadID, epoch: base.epoch,
                                     runtimeSessionID: base.runtimeSessionID,
                                     requestID: requestID, kind: .clarify,
                                     question: topLevelQuestion,
                                     clarifyChoices: topLevelChoices,
                                     questions: questions,
                                     multiSelect: topLevelMultiSelect,
                                     lockedAnswersByQuestionID: replayedAnswers(
                                        in: clarify,
                                        validQuestionIDs: Set(questions.compactMap(\.questionID))))
        }

        let single = RoomPendingClarifyQuestion(question: topLevelQuestion,
                                                choices: topLevelChoices,
                                                multiSelect: topLevelMultiSelect)
        return RoomPendingPrompt(key: base.key, attemptID: base.attemptID,
                                 threadID: base.threadID, epoch: base.epoch,
                                 runtimeSessionID: base.runtimeSessionID,
                                 requestID: requestID, kind: .clarify,
                                 question: topLevelQuestion,
                                 clarifyChoices: topLevelChoices,
                                 questions: [single],
                                 multiSelect: topLevelMultiSelect)
    }

    private static func approvalPrompt(
        _ approval: ApprovalRequest,
        base: (key: RoomPendingPromptKey, attemptID: RoomAttemptID,
               threadID: RoomThreadID, epoch: UInt64, runtimeSessionID: String)
    ) -> RoomPendingPrompt? {
        guard let requestID = nonEmpty(approval.requestID) else { return nil }
        let choices = approval.choices.compactMap { choice -> ApprovalChoice? in
            guard let raw = nonEmpty(choice) else { return nil }
            return ApprovalChoice(rawValue: raw)
        }
        return RoomPendingPrompt(key: base.key, attemptID: base.attemptID,
                                 threadID: base.threadID, epoch: base.epoch,
                                 runtimeSessionID: base.runtimeSessionID,
                                 requestID: requestID, kind: .approval,
                                 question: approval.description,
                                 command: approval.command,
                                 approvalChoices: choices)
    }

    private func validatedQuestionID(_ proposed: String?,
                                     requireMultiSelect: Bool) throws -> String? {
        let normalized = Self.nonEmpty(proposed)
        if isBatchClarify {
            guard let normalized,
                  let question = questions.first(where: { $0.questionID == normalized })
            else { throw RoomPendingPromptError.unknownQuestionID }
            if requireMultiSelect, !question.multiSelect {
                throw RoomPendingPromptError.questionIsNotMultiSelect
            }
            return normalized
        }
        guard normalized == nil else { throw RoomPendingPromptError.unknownQuestionID }
        if requireMultiSelect, questions.first?.multiSelect != true {
            throw RoomPendingPromptError.questionIsNotMultiSelect
        }
        return nil
    }

    private static func batchQuestion(_ value: [String: JSONValue]) -> RoomPendingClarifyQuestion? {
        guard let id = nonEmpty(value["qid"]?.stringValue)
                ?? nonEmpty(value["id"]?.stringValue)
        else { return nil }
        return RoomPendingClarifyQuestion(questionID: id,
                                          question: value["question"]?.stringValue ?? "",
                                          choices: choices(in: value),
                                          multiSelect: multiSelect(in: value))
    }

    private static func choices(in value: [String: JSONValue]) -> [String] {
        (value["choices"]?.arrayValue ?? []).compactMap(\.stringValue).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `pending_clarify.answers` is a replay-only snapshot of the batch locks
    /// Hermes has already accepted. Preserve literal strings (including an
    /// intentional empty answer), but ignore unknown ids and malformed values
    /// so an untrusted resume payload cannot lock or disclose another card's
    /// question.
    private static func replayedAnswers(in value: [String: JSONValue],
                                        validQuestionIDs: Set<String>) -> [String: String] {
        guard let rawAnswers = value["answers"]?.objectValue else { return [:] }
        return rawAnswers.reduce(into: [:]) { result, entry in
            let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validQuestionIDs.contains(questionID),
                  let answer = entry.value.stringValue else { return }
            result[questionID] = answer
        }
    }

    /// Both spellings appeared in 9ef9-adjacent gateway/plugin payloads.
    /// Accept only literal booleans so a malformed string cannot turn a radio
    /// answer into a JSON-array response.
    private static func multiSelect(in value: [String: JSONValue]) -> Bool {
        ["multi_select", "multiSelect", "multi-select"].contains {
            value[$0]?.boolValue == true
        }
    }

    private static func normalizedApprovalChoices(_ choices: [ApprovalChoice]) -> [ApprovalChoice] {
        var seen = Set<String>()
        let unique = choices.filter { seen.insert($0.rawValue).inserted }
        return unique.isEmpty ? [.once, .deny] : unique
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

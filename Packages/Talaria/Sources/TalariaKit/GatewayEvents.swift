import Foundation

// Server→client events on /api/ws. Envelope (tui_gateway/server.py:_event_frame):
//   {"jsonrpc":"2.0","method":"event","params":{"type":"<event>","session_id":"<sid>","payload":{...}}}
// session_id is the runtime UI sid (8 hex chars); "" marks a global broadcast.

public struct GatewayEvent: Sendable {
    public var type: String
    /// Runtime session id; empty string for global broadcasts.
    public var sessionID: String
    public var payload: JSONValue?
    /// Monotonic frame position assigned by the transport. Zero is reserved
    /// for synthetic/test events that predate sequencing.
    public var inboundSequence: UInt64

    public init(type: String, sessionID: String, payload: JSONValue?,
                inboundSequence: UInt64 = 0) {
        self.type = type; self.sessionID = sessionID; self.payload = payload
        self.inboundSequence = inboundSequence
    }

    public var isGlobal: Bool { sessionID.isEmpty }
}

/// Typed views over the events Talaria renders. Anything unlisted still flows
/// through as `.other` so screens can opt in without protocol churn.
public enum TypedGatewayEvent: Sendable {
    case gatewayReady(skin: JSONValue?, changeEvents: Bool)
    case messageStart
    case messageDelta(text: String)
    case messageInterim(text: String, alreadyStreamed: Bool)
    case thinkingDelta(text: String)
    case reasoningDelta(text: String)
    case messageComplete(MessageCompletePayload)
    case sessionUsage(Usage)
    case sessionInfo(SessionInfo)
    case sessionTitle(storedSessionID: String, title: String)
    case toolGenerating(name: String)
    case toolStart(ToolStartPayload)
    case toolComplete(ToolCompletePayload)
    case statusUpdate(kind: String, text: String)
    case approvalRequest(ApprovalRequest)
    case clarifyRequest(ClarifyRequest)
    case notificationShow(NotificationPayload)
    case notificationClear(key: String)
    case backgroundComplete(taskID: String, text: String)
    case voiceTranscript(text: String?, stopPhrase: Bool)
    case voiceStatus(state: String)
    case errorEvent(message: String)
    /// Global broadcasts: sessions.changed, cron.changed, platforms.changed…
    case changed(what: String)
    case other(GatewayEvent)

    public init(_ event: GatewayEvent) {
        let p = event.payload
        switch event.type {
        case "gateway.ready":
            self = .gatewayReady(skin: p?["skin"], changeEvents: p?["change_events"]?.boolValue ?? false)
        case "message.start":
            self = .messageStart
        case "message.delta":
            self = .messageDelta(text: p?["text"]?.stringValue ?? "")
        case "message.interim":
            self = .messageInterim(text: p?["text"]?.stringValue ?? "",
                                   alreadyStreamed: p?["already_streamed"]?.boolValue ?? false)
        case "thinking.delta":
            self = .thinkingDelta(text: p?["text"]?.stringValue ?? "")
        case "reasoning.delta":
            self = .reasoningDelta(text: p?["text"]?.stringValue ?? "")
        case "message.complete":
            self = .messageComplete(MessageCompletePayload(p))
        case "session.usage":
            self = .sessionUsage(Usage(p?["usage"]))
        case "session.info":
            self = .sessionInfo(SessionInfo(p))
        case "session.title":
            self = .sessionTitle(storedSessionID: p?["session_id"]?.stringValue ?? "",
                                 title: p?["title"]?.stringValue ?? "")
        case "tool.generating":
            self = .toolGenerating(name: p?["name"]?.stringValue ?? "")
        case "tool.start":
            self = .toolStart(ToolStartPayload(p))
        case "tool.complete":
            self = .toolComplete(ToolCompletePayload(p))
        case "status.update":
            self = .statusUpdate(kind: p?["kind"]?.stringValue ?? "",
                                 text: p?["text"]?.stringValue ?? "")
        case "approval.request":
            self = .approvalRequest(ApprovalRequest(p, sessionID: event.sessionID))
        case "clarify.request":
            self = .clarifyRequest(ClarifyRequest(p, sessionID: event.sessionID))
        case "notification.show":
            self = .notificationShow(NotificationPayload(p))
        case "notification.clear":
            self = .notificationClear(key: p?["key"]?.stringValue ?? "")
        case "background.complete":
            self = .backgroundComplete(taskID: p?["task_id"]?.stringValue ?? "",
                                       text: p?["text"]?.stringValue ?? "")
        case "voice.transcript":
            self = .voiceTranscript(text: p?["text"]?.stringValue,
                                    stopPhrase: p?["stop_phrase"]?.boolValue ?? false)
        case "voice.status":
            self = .voiceStatus(state: p?["state"]?.stringValue ?? "")
        case "error":
            self = .errorEvent(message: p?["message"]?.stringValue ?? "")
        case "sessions.changed", "cron.changed", "pet.changed", "platforms.changed",
             "pairing.changed", "skin.changed":
            self = .changed(what: event.type)
        default:
            self = .other(event)
        }
    }
}

// MARK: - Event payloads

public struct Usage: Sendable, Equatable {
    public var model: String?
    public var input: Int
    public var output: Int
    public var total: Int
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var activeSubagents: Int?

    public init(_ v: JSONValue?) {
        model = v?["model"]?.stringValue
        input = v?["input"]?.intValue ?? 0
        output = v?["output"]?.intValue ?? 0
        total = v?["total"]?.intValue ?? 0
        contextUsed = v?["context_used"]?.intValue
        contextMax = v?["context_max"]?.intValue
        contextPercent = v?["context_percent"]?.intValue
        activeSubagents = v?["active_subagents"]?.intValue
    }
}

public struct MessageCompletePayload: Sendable {
    public enum Status: String, Sendable { case complete, interrupted, error }
    public var text: String
    public var status: Status
    public var usage: Usage
    public var reasoning: String?
    public var warning: String?
    public var error: String?
    public var recoverable: Bool

    public init(_ v: JSONValue?) {
        text = v?["text"]?.stringValue ?? ""
        status = Status(rawValue: v?["status"]?.stringValue ?? "complete") ?? .complete
        usage = Usage(v?["usage"])
        reasoning = v?["reasoning"]?.stringValue
        warning = v?["warning"]?.stringValue
        error = v?["error"]?.stringValue
        recoverable = v?["recoverable"]?.boolValue ?? false
    }
}

public struct SessionInfo: Sendable, Equatable {
    public var model: String
    public var provider: String?
    public var yolo: Bool
    public var approvalMode: String
    public var cwd: String
    public var running: Bool
    public var title: String
    public var storedSessionID: String
    public var desktopContract: Int
    public var profileName: String
    public var usage: Usage
    public var raw: JSONValue?

    public init(_ v: JSONValue?) {
        model = v?["model"]?.stringValue ?? ""
        provider = v?["provider"]?.stringValue
        yolo = v?["yolo"]?.boolValue ?? false
        approvalMode = v?["approval_mode"]?.stringValue ?? "manual"
        cwd = v?["cwd"]?.stringValue ?? ""
        running = v?["running"]?.boolValue ?? false
        title = v?["title"]?.stringValue ?? ""
        storedSessionID = v?["stored_session_id"]?.stringValue ?? ""
        desktopContract = v?["desktop_contract"]?.intValue ?? 0
        profileName = v?["profile_name"]?.stringValue ?? "default"
        usage = Usage(v?["usage"])
        raw = v
    }
}

public struct ToolStartPayload: Sendable {
    public var toolID: String
    public var name: String
    /// ≤80-char argument preview.
    public var context: String

    public init(_ v: JSONValue?) {
        toolID = v?["tool_id"]?.stringValue ?? ""
        name = v?["name"]?.stringValue ?? ""
        context = v?["context"]?.stringValue ?? ""
    }
}

public struct ToolCompletePayload: Sendable {
    public var toolID: String
    public var name: String
    public var durationSeconds: Double?
    public var summary: String?
    public var resultText: String?

    public init(_ v: JSONValue?) {
        toolID = v?["tool_id"]?.stringValue ?? ""
        name = v?["name"]?.stringValue ?? ""
        durationSeconds = v?["duration_s"]?.doubleValue
        summary = v?["summary"]?.stringValue
        resultText = v?["result_text"]?.stringValue ?? v?["result"]?.stringValue
    }
}

/// A live approval request. The agent thread is blocked on this until the
/// client answers `approval.respond` (or the ~300 s timeout denies it).
public struct ApprovalRequest: Sendable, Identifiable, Equatable {
    public var id: String { requestID }
    public var sessionID: String
    public var requestID: String
    /// Redacted command / action text.
    public var command: String
    public var description: String
    public var patternKey: String?
    public var allowPermanent: Bool
    public var allowSession: Bool
    /// e.g. ["once","session","always","deny"]
    public var choices: [String]

    public init(_ v: JSONValue?, sessionID: String) {
        self.sessionID = sessionID
        requestID = v?["request_id"]?.stringValue ?? ""
        command = v?["command"]?.stringValue ?? ""
        description = v?["description"]?.stringValue ?? ""
        patternKey = v?["pattern_key"]?.stringValue
        allowPermanent = v?["allow_permanent"]?.boolValue ?? false
        allowSession = v?["allow_session"]?.boolValue ?? false
        choices = v?["choices"]?.arrayValue?.compactMap(\.stringValue) ?? ["once", "deny"]
    }
}

public enum ApprovalChoice: String, Sendable {
    case once, session, always, deny
}

public struct ClarifyRequest: Sendable, Equatable {
    public var sessionID: String
    public var requestID: String
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool

    public init(_ v: JSONValue?, sessionID: String) {
        self.sessionID = sessionID
        requestID = v?["request_id"]?.stringValue ?? ""
        question = v?["question"]?.stringValue ?? ""
        choices = v?["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        multiSelect = v?["multi_select"]?.boolValue ?? false
    }
}

/// The small, explicit part of a `session.resume` projection that can prove
/// an already-buffered event is represented by that projection. Hermes' cold
/// resume also carries inflight/tool/status/notification state, but those
/// shapes are not durable message rows and therefore must never be inferred
/// from a transport sequence alone.
public struct ResumeMessageEvidence: Sendable, Equatable {
    public let rowID: String?
    public let role: String
    public let text: String

    public init(_ value: JSONValue) {
        rowID = Self.identity(value["row_id"] ?? value["id"])
        role = value["role"]?.stringValue ?? ""
        text = value["text"]?.stringValue
            ?? value["content"]?.stringValue
            ?? ""
    }

    private static func identity(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue, !string.isEmpty { return string }
        if let number = value?.intValue { return String(number) }
        return nil
    }
}

/// Evidence carried by the authoritative `session.resume` response. This is
/// deliberately conservative: only events with an exact row/state match are
/// suppressible. Tool/status/notification/voice events are not represented
/// here and are always replayed even when their frame is older than resume.
public struct ResumeSnapshotEvidence: Sendable, Equatable {
    public let messages: [ResumeMessageEvidence]
    public let info: SessionInfo
    public let pendingApproval: ApprovalRequest?
    public let pendingClarify: JSONValue?

    public init(session: LiveSession) {
        messages = session.messages.map(ResumeMessageEvidence.init)
        info = session.info
        pendingApproval = session.pendingApproval
        pendingClarify = session.pendingClarify
    }

    /// A sequence position is only a replay-boundary hint; it is not evidence
    /// that an arbitrary event was included in the snapshot.
    public func represents(_ event: GatewayEvent) -> Bool {
        switch event.type {
        case "message.complete":
            let payload = event.payload
            let status = payload?["status"]?.stringValue ?? "complete"
            guard status == "complete" else { return false }
            let text = payload?["text"]?.stringValue
                ?? payload?["content"]?.stringValue
                ?? ""
            let rowID = payload?["row_id"]?.stringValue
                ?? payload?["id"]?.stringValue
                ?? payload?["row_id"]?.intValue.map(String.init)
                ?? payload?["id"]?.intValue.map(String.init)
            let matches = messages.filter { message in
                guard message.role == "assistant", message.text == text else {
                    return false
                }
                if let rowID { return message.rowID == rowID }
                return true
            }
            // Duplicate assistant text is not enough evidence without the
            // durable row id; retaining it is safer than dropping a message.
            return matches.count == 1

        case "session.info":
            return SessionInfo(event.payload) == info

        case "session.title":
            guard let stored = event.payload?["session_id"]?.stringValue,
                  stored == info.storedSessionID else { return false }
            return event.payload?["title"]?.stringValue == info.title

        case "session.usage":
            let usageValue = event.payload?["usage"] ?? event.payload
            return Usage(usageValue) == info.usage

        case "approval.request":
            guard let pendingApproval else { return false }
            return ApprovalRequest(event.payload, sessionID: event.sessionID)
                == pendingApproval

        case "clarify.request":
            return pendingClarify == event.payload

        default:
            // message.delta, tool.*, status.update, notifications, voice,
            // and every other event have no exact durable representation in
            // this snapshot and must not be filtered by sequence.
            return false
        }
    }
}

public struct NotificationPayload: Sendable {
    public var text: String
    public var level: String
    public var kind: String
    public var ttlMilliseconds: Int?
    public var key: String?
    public var id: String?

    public init(_ v: JSONValue?) {
        text = v?["text"]?.stringValue ?? ""
        level = v?["level"]?.stringValue ?? "info"
        kind = v?["kind"]?.stringValue ?? ""
        ttlMilliseconds = v?["ttl_ms"]?.intValue
        key = v?["key"]?.stringValue
        id = v?["id"]?.stringValue
    }
}

import Foundation

// Domain models for Talaria. Shapes mirror the design prototype's
// `hermes-data.js` (the design-approved data contract) and are re-mapped onto
// the live `hermes serve` RPC payloads in GatewayClient+Mapping.swift.

// MARK: - Avatars

/// The Bot Mode avatar language: geometric shape × hue, with blinking eyes
/// that scan while the bot works. Cosmetics are client-side only; profiles
/// stay clean.
public enum AvatarShape: String, Codable, CaseIterable, Sendable {
    case circle, squircle, hexagon, triangle, diamond, pentagon
}

public enum AvatarHue: String, Codable, CaseIterable, Sendable {
    case teal, violet, amber, green, pink, blue
    /// Reserved pseudo-hue for gateway-originated events in feeds.
    case gateway
}

// MARK: - Bots

public enum BotStatus: String, Codable, Sendable {
    /// Actively running a session turn.
    case working
    /// Blocked on a pending approval.
    case approval
    case idle
}

/// A bot is a Hermes profile (`~/.hermes/profiles/<name>/`) — isolated config,
/// memory, skills, credentials and history. Talaria is a window onto the same
/// roster as desktop Bot Mode; there is no separate store.
public struct Bot: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var job: String
    public var shape: AvatarShape
    public var hue: AvatarHue
    public var status: BotStatus
    /// Short description of the in-flight task while `status == .working`.
    public var task: String?
    /// Minutes elapsed on the current task.
    public var minutesElapsed: Int
    public var preview: String
    public var previewTime: String
    public var unread: Int
    public var mentionsYou: Bool
    public var description: String?
    /// Pinned model override for this profile (nil = gateway default).
    public var pinnedModel: String?
    /// User-set display title from desktop Bot Mode
    /// (`ui_meta["hermes-bots"].title`). Shared with desktop so a bot renamed
    /// there reads the same here.
    public var title: String?
    /// Explicit @handle when the roster precomputed one (multi-gateway rosters
    /// disambiguate duplicates as `name-device`).
    public var handleOverride: String?

    public init(id: String, job: String, shape: AvatarShape, hue: AvatarHue,
                status: BotStatus = .idle, task: String? = nil, minutesElapsed: Int = 0,
                preview: String = "", previewTime: String = "", unread: Int = 0,
                mentionsYou: Bool = false, description: String? = nil, pinnedModel: String? = nil,
                title: String? = nil, handleOverride: String? = nil) {
        self.id = id; self.job = job; self.shape = shape; self.hue = hue
        self.status = status; self.task = task; self.minutesElapsed = minutesElapsed
        self.preview = preview; self.previewTime = previewTime; self.unread = unread
        self.mentionsYou = mentionsYou; self.description = description; self.pinnedModel = pinnedModel
        self.title = title; self.handleOverride = handleOverride
    }
}

// MARK: - Identity (desktop Bot Mode parity)

// Desktop renders two stable identities per roster row: a customizable
// display name and the profile's @handle. Ported verbatim from
// apps/desktop/src/plugins/hermes-bots/plugin.js `displayName()` (2935) and
// `botHandle()` (2406) so the same profile reads identically in both apps.
public extension Bot {

    /// The friendly name. A user title wins; the primary profile is literally
    /// named "default", which "reads like nobody bothered", so it presents as
    /// Hermes; everything else is de-slugged and title-cased.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title.trimmingCharacters(in: .whitespaces)
        }
        if id.trimmingCharacters(in: .whitespaces).lowercased() == "default" {
            return "Hermes"
        }
        let spaced = id.replacingOccurrences(of: "[-_]+", with: " ",
                                             options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return spaced.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The @handle you tag the bot with — the profile name, except "default",
    /// which is tagged @hermes.
    var handle: String {
        if let handleOverride, handleOverride != id { return handleOverride }
        return id.trimmingCharacters(in: .whitespaces).lowercased() == "default" ? "hermes" : id
    }

    /// Desktop only shows the handle alongside the title when they differ.
    var showsHandle: Bool {
        displayTitle.lowercased() != handle.lowercased()
    }
}

// MARK: - Chat

public enum MessageAuthor: String, Codable, Sendable {
    case system = "sys"
    case bot
    case user
}

/// Inline rich cards a bot message can carry.
public enum MessageCard: Codable, Sendable, Equatable {
    case papers([Paper])
    case approvalRef(String)

    public struct Paper: Codable, Sendable, Equatable {
        public var title: String
        public var meta: String
        public var summary: String
        public init(title: String, meta: String, summary: String) {
            self.title = title; self.meta = meta; self.summary = summary
        }
    }
}

/// One tool invocation inside a turn, rendered as a collapsible chip in the
/// transcript (desktop shows these inline under the assistant message).
public struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, done, failed }

    /// The gateway's tool_id.
    public var id: String
    public var name: String
    /// ≤80-char argument preview from tool.start.
    public var context: String
    public var state: State
    /// One-line result summary from tool.complete.
    public var summary: String?
    /// Full result text, shown when the chip is expanded.
    public var resultText: String?
    public var durationSeconds: Double?

    public init(id: String, name: String, context: String, state: State = .running,
                summary: String? = nil, resultText: String? = nil,
                durationSeconds: Double? = nil) {
        self.id = id; self.name = name; self.context = context; self.state = state
        self.summary = summary; self.resultText = resultText
        self.durationSeconds = durationSeconds
    }
}

/// A file/image staged on the composer, consumed by the next prompt.submit.
public struct PendingAttachment: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case image, pdf, file }

    public var id: String
    public var kind: Kind
    public var name: String
    /// Gateway-side path returned by the attach RPC.
    public var path: String?
    /// Local thumbnail data for images (never sent again).
    public var thumbnail: Data?

    public init(id: String = UUID().uuidString, kind: Kind, name: String,
                path: String? = nil, thumbnail: Data? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.path = path; self.thumbnail = thumbnail
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var author: MessageAuthor
    public var time: String?
    public var text: String
    public var card: MessageCard?
    /// Set while tokens are still streaming in.
    public var isStreaming: Bool
    /// Model reasoning/thinking that preceded this message (reasoning.delta /
    /// thinking.delta accumulation, or the stored transcript's reasoning
    /// fields). Rendered as a collapsible "Thought" block, desktop parity.
    public var reasoning: String?
    /// Tools this turn ran, in call order (tool.start / tool.complete).
    public var toolCalls: [ToolCall]
    /// Durable transcript row id — needed for reactions and rewind.
    public var rowID: Int?

    public init(id: UUID = UUID(), author: MessageAuthor, time: String? = nil,
                text: String, card: MessageCard? = nil, isStreaming: Bool = false,
                reasoning: String? = nil, toolCalls: [ToolCall] = [], rowID: Int? = nil) {
        self.id = id; self.author = author; self.time = time
        self.text = text; self.card = card; self.isStreaming = isStreaming
        self.reasoning = reasoning; self.toolCalls = toolCalls; self.rowID = rowID
    }
}

// MARK: - Approvals

public enum ApprovalKind: String, Codable, Sendable {
    case email, command = "cmd", post, other
}

/// A pending approval request. Bots block before anything risky leaves —
/// outbound email, shell commands, public posts — and resume on approve/deny.
public struct Approval: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var kind: ApprovalKind
    public var title: String
    public var target: String
    public var subject: String
    public var body: String
    public var why: String
    public var age: String

    public init(id: String, botID: String, kind: ApprovalKind, title: String,
                target: String, subject: String, body: String, why: String, age: String) {
        self.id = id; self.botID = botID; self.kind = kind; self.title = title
        self.target = target; self.subject = subject; self.body = body
        self.why = why; self.age = age
    }
}

// MARK: - Routines

/// A scheduled routine, backed by Hermes cron with jobs namespaced
/// `[bot:<name>] <routine>`. Runs land in the bot's own chat.
public struct Routine: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var name: String
    public var schedule: String
    public var next: String
    public var last: String
    public var isOn: Bool

    public init(id: String, botID: String, name: String, schedule: String,
                next: String, last: String, isOn: Bool) {
        self.id = id; self.botID = botID; self.name = name
        self.schedule = schedule; self.next = next; self.last = last; self.isOn = isOn
    }
}

// MARK: - Activity feed

public enum ActivityKind: String, Codable, Sendable {
    case approval, mention, routine, task, gateway, approved
}

public struct ActivityItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var time: String
    public var botID: String
    public var kind: ActivityKind
    public var text: String
    public var subtext: String
    public var pending: Bool

    public init(id: UUID = UUID(), time: String, botID: String, kind: ActivityKind,
                text: String, subtext: String, pending: Bool = false) {
        self.id = id; self.time = time; self.botID = botID; self.kind = kind
        self.text = text; self.subtext = subtext; self.pending = pending
    }
}

public struct ActivityDay: Identifiable, Codable, Sendable, Equatable {
    public var id: String { day }
    public var day: String
    public var items: [ActivityItem]
    public init(day: String, items: [ActivityItem]) {
        self.day = day; self.items = items
    }
}

// MARK: - Agent Inbox (bot ⇄ bot)

/// Cross-profile handoffs run upstream as
/// `hermes -p <bot> chat -c "Agent Inbox" -q "..."` with attribution.
public struct A2AMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var fromBotID: String
    /// Receiving bot id, or "all" for a broadcast.
    public var toBotID: String
    public var time: String
    public var text: String

    public init(id: UUID = UUID(), fromBotID: String, toBotID: String, time: String, text: String) {
        self.id = id; self.fromBotID = fromBotID; self.toBotID = toBotID
        self.time = time; self.text = text
    }
}

// MARK: - Connections

public enum ConnectionKind: String, Codable, Sendable {
    case tailscale, lan, cloud
}

public enum ConnectionState: String, Codable, Sendable {
    case connected, asleep, offline, connecting
}

/// A named gateway connection — Tailscale/LAN URL or Hermes Cloud — matching
/// desktop's Settings → Connections registry.
public struct GatewayConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: ConnectionKind
    /// Host:port for tailscale/lan; org slug for cloud.
    public var address: String
    public var state: ConnectionState
    public var ping: String
    public var botCount: Int

    public init(id: String, name: String, kind: ConnectionKind, address: String,
                state: ConnectionState, ping: String, botCount: Int) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.state = state; self.ping = ping; self.botCount = botCount
    }
}

// MARK: - Notifications

public enum PushKind: String, Codable, CaseIterable, Sendable {
    case approval, routine, mention, task, gateway
}

public struct NotificationPref: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var kind: PushKind
    public var name: String
    public var subtitle: String
    public var isOn: Bool
    /// Critical alerts can break through Focus (approvals only).
    public var isCritical: Bool

    public init(id: String, kind: PushKind, name: String, subtitle: String,
                isOn: Bool, isCritical: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.subtitle = subtitle
        self.isOn = isOn; self.isCritical = isCritical
    }
}

// MARK: - Sessions

public struct SessionSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var when: String
    public var messageCount: Int

    public init(id: String, title: String, when: String, messageCount: Int) {
        self.id = id; self.title = title; self.when = when; self.messageCount = messageCount
    }
}

// MARK: - Artifacts

public enum ArtifactKind: String, Codable, Sendable {
    case image, file, link
}

public struct Artifact: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var kind: ArtifactKind
    /// Uppercased extension chip for files ("MD", "CSV", …).
    public var ext: String?
    public var title: String
    public var meta: String
    public var when: String

    public init(id: String, botID: String, kind: ArtifactKind, ext: String? = nil,
                title: String, meta: String, when: String) {
        self.id = id; self.botID = botID; self.kind = kind; self.ext = ext
        self.title = title; self.meta = meta; self.when = when
    }
}

// MARK: - Memory & context

public struct BotMemory: Codable, Sendable, Equatable {
    public var skillCount: Int
    public var memoryCount: Int
    public var recent: [String]

    public init(skillCount: Int, memoryCount: Int, recent: [String]) {
        self.skillCount = skillCount; self.memoryCount = memoryCount; self.recent = recent
    }
}

/// One segment of the context-window meter (same source as the desktop
/// status-bar meter).
public struct ContextSegment: Identifiable, Codable, Sendable, Equatable {
    public var id: String { label }
    public var label: String
    /// Percentage of the window, 0–100.
    public var percent: Int

    public init(label: String, percent: Int) {
        self.label = label; self.percent = percent
    }
}

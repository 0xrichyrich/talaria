import CryptoKit
import Foundation

// Room identity is intentionally independent from a display name. Renaming a
// room cannot re-key its transcript, attachments, sessions, or open view.
public struct RoomID: Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomThreadID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomEntryID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomAttemptID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomActivityID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A seat is always source-qualified. Bare profile names are never durable
/// room identity because two retained gateways may both expose `default`.
public struct RoomMember: Codable, Hashable, Sendable, Identifiable {
    public let route: GatewayBotRoute
    public var title: String?
    /// The durable raw friendly identity captured when this seat was selected.
    /// It survives a later roster disappearance so room mentions keep the
    /// same `@research-buddy` spelling instead of falling back to a mutable
    /// profile handle or a themed visual label.
    public var friendlyName: String?
    /// Core profile `display_name` captured independently of Bot Mode's
    /// friendly title. Both remain valid room aliases after the roster vanishes.
    public var rawDisplayName: String?
    public var handle: String
    public var sourceLabel: String?
    public var id: GatewayBotRoute { route }

    public init(route: GatewayBotRoute, title: String? = nil,
                handle: String? = nil, sourceLabel: String? = nil,
                friendlyName: String? = nil, rawDisplayName: String? = nil) {
        self.route = route
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.friendlyName = Self.normalizedFriendlyName(friendlyName)
        self.rawDisplayName = Self.normalizedFriendlyName(rawDisplayName)
        let proposed = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.handle = proposed.isEmpty
            ? (route.profile.lowercased() == "default" ? "hermes" : route.profile)
            : proposed
        self.sourceLabel = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The identity which produces room-friendly mention forms. New records
    /// use `friendlyName`; legacy records did not have it, so their retained
    /// title remains the safest compatible fallback. The profile is last: it
    /// is stable, but it is not necessarily what the user saw when choosing
    /// the member.
    public var friendlyMentionName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let title, !title.isEmpty { return title }
        return route.profile
    }

    /// All preserved friendly identity inputs. `friendlyName` selects the
    /// canonical insertion tag, while title/core display aliases stay valid
    /// resolvers so a later rename cannot strand an older room draft.
    public var friendlyMentionNames: [String] {
        let candidates = [friendlyName, title, rawDisplayName].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return [route.profile] }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }

    /// All safe spellings a room mention parser can map to this exact,
    /// source-qualified seat. Legacy handle/profile forms remain available;
    /// reserved words and unsafe friendly aliases never become destinations.
    public var mentionForms: Set<String> {
        var forms = Set<String>()
        for legacy in [route.profile, handle] {
            let normalized = legacy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            forms.insert(normalized)
            forms.insert(Self.collapsedMentionForm(normalized))
        }
        for name in friendlyMentionNames {
            forms.formUnion(BotMention.friendlyForms(from: name))
        }
        return forms
    }

    private enum CodingKeys: String, CodingKey {
        case route, title, friendlyName, rawDisplayName, handle, sourceLabel
    }

    /// `friendlyName` is additive. Decode all pre-existing identity fields
    /// exactly as their synthesized Codable representation did, while an old
    /// room that naturally has no new key receives nil rather than becoming
    /// unreadable. Invalid new optional data is ignored rather than allowed to
    /// claim a mention address.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        route = try values.decode(GatewayBotRoute.self, forKey: .route)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        handle = try values.decode(String.self, forKey: .handle)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        friendlyName = Self.normalizedFriendlyName(
            try? values.decodeIfPresent(String.self, forKey: .friendlyName))
        rawDisplayName = Self.normalizedFriendlyName(
            try? values.decodeIfPresent(String.self, forKey: .rawDisplayName))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(route, forKey: .route)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try values.encodeIfPresent(rawDisplayName, forKey: .rawDisplayName)
        try values.encode(handle, forKey: .handle)
        try values.encodeIfPresent(sourceLabel, forKey: .sourceLabel)
    }

    private static func normalizedFriendlyName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name which cannot produce a safe non-reserved tag is not durable
        // mention identity. Keep the seat and its legacy forms intact.
        return BotMention.friendlyTag(from: trimmed) == nil ? nil : trimmed
    }

    private static func collapsedMentionForm(_ value: String) -> String {
        value.replacingOccurrences(of: #"[._-]+"#, with: "",
                                   options: .regularExpression)
    }
}

public struct RoomAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var blobID: String
    public var fileName: String
    public var mediaType: String
    public var byteCount: Int64
    public var contentHash: String
    public var createdAt: Date

    public init(id: UUID = UUID(), blobID: String, fileName: String,
                mediaType: String, byteCount: Int64, contentHash: String,
                createdAt: Date = Date()) {
        self.id = id; self.blobID = blobID; self.fileName = fileName
        self.mediaType = mediaType; self.byteCount = byteCount
        self.contentHash = contentHash; self.createdAt = createdAt
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RoomThread: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomThreadID
    public var createdAt: Date
    public var lastActivityAt: Date

    public init(id: RoomThreadID = RoomThreadID(), createdAt: Date = Date(),
                lastActivityAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt ?? createdAt
    }
}

public enum RoomSpeakerKind: String, Codable, Sendable { case user, member }

public struct RoomEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomEntryID
    /// Optional only for decoding pre-thread room logs. RoomStore migrates it
    /// before returning the room and immediately persists the repaired record.
    public var threadID: RoomThreadID?
    public var speaker: RoomSpeakerKind
    public var memberRoute: GatewayBotRoute?
    public var speakerName: String
    public var sourceLabel: String?
    public var text: String
    public var at: Date
    public var attachments: [RoomAttachment]

    public init(id: RoomEntryID = RoomEntryID(), threadID: RoomThreadID? = nil,
                speaker: RoomSpeakerKind, memberRoute: GatewayBotRoute? = nil,
                speakerName: String, sourceLabel: String? = nil, text: String,
                at: Date = Date(), attachments: [RoomAttachment] = []) {
        self.id = id; self.threadID = threadID; self.speaker = speaker
        self.memberRoute = memberRoute; self.speakerName = speakerName
        self.sourceLabel = sourceLabel; self.text = text; self.at = at
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadID, speaker, memberRoute, speakerName, sourceLabel, text, at, attachments
    }

    /// Entries written before room attachments and threads shipped omitted
    /// those additive keys. Decode their safe empty/nil meanings here so the
    /// enclosing store can perform the deterministic thread migration.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomEntryID.self, forKey: .id)
        threadID = try values.decodeIfPresent(RoomThreadID.self, forKey: .threadID)
        speaker = try values.decode(RoomSpeakerKind.self, forKey: .speaker)
        memberRoute = try values.decodeIfPresent(GatewayBotRoute.self, forKey: .memberRoute)
        speakerName = try values.decode(String.self, forKey: .speakerName)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        text = try values.decode(String.self, forKey: .text)
        at = try values.decode(Date.self, forKey: .at)
        attachments = try values.decodeIfPresent([RoomAttachment].self, forKey: .attachments) ?? []
    }
}

public enum RoomAttemptState: String, Codable, Sendable {
    /// `accepted` means prompt.submit returned an acknowledgement. `uncertain`
    /// means the transport failed after send and MUST be reconciled by the
    /// attempt marker before any retry; it is not equivalent to `queued`.
    /// `waiting` proves no submit occurred because the member session was
    /// already busy. Relaunch reconciliation may submit this same persisted
    /// attempt once the session is read-only confirmed idle.
    case queued, waiting, accepted, uncertain, working, replied, passed, timedOut, failed, cancelled, delivered
}

/// Durable attempt identity makes a late reply reconcilable after a restart.
public struct RoomAttempt: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomAttemptID
    public let threadID: RoomThreadID
    public let member: GatewayBotRoute
    public let epoch: UInt64
    public var state: RoomAttemptState
    /// Exact persisted submit identity. The anchor finds this user row after
    /// acknowledgement loss; the hash detects a mismatched local record.
    public let promptAnchor: String
    public let promptHash: String
    public let promptText: String
    public var storedSessionID: String
    public var runtimeSessionID: String
    /// Gateway-side image/PDF queue paths survive an uncertain submit. They
    /// are detached only after exact reconciliation reaches a terminal state.
    public var stagedImagePaths: [String]
    /// Exact local blobs that belonged to this persisted prompt delta. A
    /// waiting attempt may outlive the transcript window that first referenced
    /// them, so durable descriptors (not only entry ids) are required to stage
    /// the same payload once the member session becomes idle.
    public var outboundAttachments: [RoomAttachment]
    public var baselineMessageCount: Int
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: RoomAttemptID = RoomAttemptID(), threadID: RoomThreadID,
                member: GatewayBotRoute, epoch: UInt64,
                promptText: String, storedSessionID: String, runtimeSessionID: String,
                stagedImagePaths: [String] = [],
                outboundAttachments: [RoomAttachment] = [],
                state: RoomAttemptState = .queued, baselineMessageCount: Int = 0,
                startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.threadID = threadID; self.member = member
        self.epoch = epoch; self.state = state
        self.promptAnchor = Self.anchor(for: id)
        self.promptHash = Self.hash(promptText)
        self.promptText = promptText
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.stagedImagePaths = stagedImagePaths
        self.outboundAttachments = outboundAttachments
        self.baselineMessageCount = baselineMessageCount
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    public static func anchor(for id: RoomAttemptID) -> String {
        "<!-- talaria-room-attempt:\(id.rawValue.uuidString.lowercased()) -->"
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadID, member, epoch, state, promptAnchor, promptHash, promptText
        case storedSessionID, runtimeSessionID, stagedImagePaths, outboundAttachments
        case baselineMessageCount, startedAt, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomAttemptID.self, forKey: .id)
        threadID = try values.decode(RoomThreadID.self, forKey: .threadID)
        member = try values.decode(GatewayBotRoute.self, forKey: .member)
        epoch = try values.decode(UInt64.self, forKey: .epoch)
        state = try values.decode(RoomAttemptState.self, forKey: .state)
        promptAnchor = try values.decode(String.self, forKey: .promptAnchor)
        promptHash = try values.decode(String.self, forKey: .promptHash)
        promptText = try values.decode(String.self, forKey: .promptText)
        storedSessionID = try values.decode(String.self, forKey: .storedSessionID)
        runtimeSessionID = try values.decode(String.self, forKey: .runtimeSessionID)
        stagedImagePaths = try values.decodeIfPresent([String].self,
                                                      forKey: .stagedImagePaths) ?? []
        outboundAttachments = try values.decodeIfPresent([RoomAttachment].self,
                                                          forKey: .outboundAttachments) ?? []
        baselineMessageCount = try values.decode(Int.self, forKey: .baselineMessageCount)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

public enum RoomActivityKind: String, Codable, Sendable {
    case queued, working, replied, passed, uncertain, timedOut, failed, cancelled, settled, delivered
}

public enum RoomDriveStatus: String, Codable, Sendable {
    case queued, running, settling
}

/// Relaunch-safe cursor for one thread drive. The runtime advances this only
/// at member boundaries and persists it with the room before taking the next
/// action, so reopening never starts the thread again from round zero.
public struct RoomDriveState: Codable, Hashable, Sendable, Identifiable {
    public let threadID: RoomThreadID
    public let epoch: UInt64
    public var round: Int
    /// Frozen source-qualified order for the current round. Mention parsing is
    /// recomputed between rounds, not after every member; persisting the list
    /// prevents a relaunch from reshaping the queue around replies already
    /// appended earlier in this same round.
    public var roundMembers: [GatewayBotRoute]
    public var nextMemberIndex: Int
    public var posted: Int
    /// Cumulative post count captured at the beginning of this round. On
    /// relaunch, `posted > roundStartPosted` proves somebody already spoke;
    /// without it a crash mid-round could falsely settle after later passes.
    public var roundStartPosted: Int
    public var status: RoomDriveStatus
    public var updatedAt: Date
    public var id: RoomThreadID { threadID }

    public init(threadID: RoomThreadID, epoch: UInt64, round: Int = 0,
                roundMembers: [GatewayBotRoute] = [],
                nextMemberIndex: Int = 0, posted: Int = 0,
                roundStartPosted: Int? = nil,
                status: RoomDriveStatus = .queued, updatedAt: Date = Date()) {
        self.threadID = threadID; self.epoch = epoch; self.round = round
        self.roundMembers = roundMembers
        self.nextMemberIndex = nextMemberIndex; self.posted = posted
        self.roundStartPosted = roundStartPosted ?? posted
        self.status = status; self.updatedAt = updatedAt
    }
}

public struct RoomActivity: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomActivityID
    public let epoch: UInt64
    public var kind: RoomActivityKind
    public var member: GatewayBotRoute?
    public var threadID: RoomThreadID?
    public var at: Date

    public init(id: RoomActivityID = RoomActivityID(), epoch: UInt64,
                kind: RoomActivityKind, member: GatewayBotRoute? = nil,
                threadID: RoomThreadID? = nil, at: Date = Date()) {
        self.id = id; self.epoch = epoch; self.kind = kind
        self.member = member; self.threadID = threadID; self.at = at
    }
}

public struct RoomRecord: Codable, Hashable, Sendable, Identifiable {
    /// Session-title identity version written with the room record. Rooms
    /// created before immutable session titles had no version and decode as
    /// `legacyNameSessionTitleVersion`; newly created rooms always use the
    /// stable `RoomID` title.
    public static let legacyNameSessionTitleVersion: UInt8 = 0
    public static let immutableIDSessionTitleVersion: UInt8 = 1

    public let id: RoomID
    public var name: String
    /// Version 0 is an on-disk compatibility marker, never a request to title
    /// a newly created member session by the editable display name. The room
    /// transport tries the immutable RoomID first, then the captured legacy
    /// title only while resolving an already-existing pre-version room.
    public var sessionTitleIdentityVersion: UInt8
    /// Exact display name used by pre-version `Group: <name>` sessions. It is
    /// captured during decode and deliberately does not change on rename.
    public var legacySessionTitleName: String?
    public var members: [RoomMember]
    /// Seats removed from the live responder roster but retained as durable
    /// transcript/attempt identities. They never receive new work.
    public var formerMembers: [RoomMember]
    /// Custom room portrait in the protected room blob directory.
    public var avatar: RoomAttachment?
    public var threads: [RoomThread]
    public var entries: [RoomEntry]
    public var attempts: [RoomAttempt]
    /// Usually one current drive; retained as an array because a new user send
    /// in a different thread may queue while the prior member reaches its safe
    /// cancellation boundary.
    public var drives: [RoomDriveState]
    public var activity: [RoomActivity]
    /// Stored-session ids keyed by `GatewayBotRoute.qualifiedID`.
    public var memberSessions: [String: String]
    /// Entry watermarks keyed by `<thread UUID>::<qualified member route>`.
    public var watermarks: [String: Int]
    public var epoch: UInt64
    public var needsUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: RoomID = RoomID(), name: String, members: [RoomMember],
                sessionTitleIdentityVersion: UInt8 = Self.immutableIDSessionTitleVersion,
                legacySessionTitleName: String? = nil,
                formerMembers: [RoomMember] = [],
                avatar: RoomAttachment? = nil,
                threads: [RoomThread] = [], entries: [RoomEntry] = [],
                attempts: [RoomAttempt] = [], drives: [RoomDriveState] = [],
                activity: [RoomActivity] = [],
                memberSessions: [String: String] = [:], watermarks: [String: Int] = [:],
                epoch: UInt64 = 0, needsUser: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name
        self.sessionTitleIdentityVersion = sessionTitleIdentityVersion
        self.legacySessionTitleName = sessionTitleIdentityVersion
            == Self.legacyNameSessionTitleVersion ? (legacySessionTitleName ?? name) : nil
        self.members = members
        self.formerMembers = formerMembers; self.avatar = avatar
        self.threads = threads; self.entries = entries; self.attempts = attempts
        self.drives = drives
        self.activity = activity; self.memberSessions = memberSessions
        self.watermarks = watermarks; self.epoch = epoch; self.needsUser = needsUser
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sessionTitleIdentityVersion, legacySessionTitleName
        case members, formerMembers, avatar, threads, entries, attempts, drives
        case activity, memberSessions, watermarks, epoch, needsUser, createdAt, updatedAt
    }

    /// Additive room-state fields decode to their original empty meanings.
    /// Stable identity, name, member routes, entries, and creation time remain
    /// required: inventing any of those would turn corrupt data into a
    /// different room rather than migrating the room the user actually had.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        sessionTitleIdentityVersion = try values.decodeIfPresent(
            UInt8.self, forKey: .sessionTitleIdentityVersion
        ) ?? Self.legacyNameSessionTitleVersion
        if sessionTitleIdentityVersion == Self.legacyNameSessionTitleVersion {
            legacySessionTitleName = try values.decodeIfPresent(
                String.self, forKey: .legacySessionTitleName
            ) ?? name
        } else {
            // A stale compatibility value must never opt a current/future
            // identity version back into mutable-name lookup.
            legacySessionTitleName = nil
        }
        members = try values.decode([RoomMember].self, forKey: .members)
        formerMembers = try values.decodeIfPresent([RoomMember].self, forKey: .formerMembers) ?? []
        avatar = try values.decodeIfPresent(RoomAttachment.self, forKey: .avatar)
        threads = try values.decodeIfPresent([RoomThread].self, forKey: .threads) ?? []
        entries = try values.decode([RoomEntry].self, forKey: .entries)
        attempts = try values.decodeIfPresent([RoomAttempt].self, forKey: .attempts) ?? []
        drives = try values.decodeIfPresent([RoomDriveState].self, forKey: .drives) ?? []
        activity = try values.decodeIfPresent([RoomActivity].self, forKey: .activity) ?? []
        memberSessions = try values.decodeIfPresent([String: String].self,
                                                    forKey: .memberSessions) ?? [:]
        watermarks = try values.decodeIfPresent([String: Int].self, forKey: .watermarks) ?? [:]
        epoch = try values.decodeIfPresent(UInt64.self, forKey: .epoch) ?? 0
        needsUser = try values.decodeIfPresent(Bool.self, forKey: .needsUser) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public var lastActivityAt: Date { entries.last?.at ?? createdAt }
}

public struct RoomMetadataMutation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case add, remove, rename }

    public static let maximumNameLength = 64

    public var id: UUID
    public var route: GatewayBotRoute
    public var kind: Kind
    public var oldName: String?
    public var newName: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), route: GatewayBotRoute, kind: Kind,
                oldName: String? = nil, newName: String? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.route = route; self.kind = kind
        self.oldName = oldName; self.newName = newName; self.createdAt = createdAt
    }

    /// Validate the durable server-metadata command before it can enter the
    /// outbox.  These records survive room deletion, so a malformed command
    /// must never become an immortal retry loop after the UI that created it
    /// is gone.
    public func isStructurallyValid() -> Bool {
        guard !route.gatewayID.isEmpty, !route.profile.isEmpty,
              route == GatewayBotRoute(qualifiedID: route.qualifiedID),
              route.gatewayID.count <= 512, route.profile.count <= 256 else { return false }
        func validName(_ value: String?) -> Bool {
            guard let value else { return false }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == trimmed && !trimmed.isEmpty && trimmed.count <= Self.maximumNameLength
        }
        switch kind {
        case .add:
            return oldName == nil && validName(newName)
        case .remove:
            return validName(oldName) && newName == nil
        case .rename:
            return validName(oldName) && validName(newName) && oldName != newName
        }
    }
}

public enum RoomValidationError: Error, Equatable, Sendable {
    case emptyName
    case memberCount(Int)
    case invalidRoute
    case duplicateMember(GatewayBotRoute)
    case duplicateIdentity
    case unknownThread
    case invalidSpeaker
    case invalidAttachment
    case invalidAttempt
    case invalidDrive
    case invalidWatermark
    case invalidBound
}

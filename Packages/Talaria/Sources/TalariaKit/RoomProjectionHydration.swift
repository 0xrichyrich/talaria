import CryptoKit
import Foundation

/// One atomically committed view of the protected rooms and their independent
/// bounded projection ledger. Projected image bytes are transient return data:
/// callers may hydrate an in-memory image cache without creating a second
/// plaintext persistence surface.
public struct RoomProjectionReconcileResult: Equatable, Sendable {
    public var rooms: [RoomRecord]
    public var roomProjection: RoomProjectionEnvelope
    public var projectedImages: [RoomID: Data]

    public init(rooms: [RoomRecord] = [],
                roomProjection: RoomProjectionEnvelope = RoomProjectionEnvelope(),
                projectedImages: [RoomID: Data] = [:]) {
        self.rooms = rooms
        self.roomProjection = roomProjection
        self.projectedImages = projectedImages
    }
}

/// Pure protected-state reconciliation. RoomStore supplies an already-merged
/// ledger and owns the single atomic disk commit around this result.
enum RoomProjectionHydration {
    struct Result {
        var rooms: [RoomID: RoomRecord]
        var projectedImages: [RoomID: Data]
        var deletedRoomIDs: Set<RoomID>
    }

    static func reconciling(
        projection: RoomProjectionEnvelope,
        tombstones: [String: UInt64],
        existing: [RoomID: RoomRecord],
        preservingRoomIDs: Set<RoomID>,
        allowedGatewayIDs: Set<String>
    ) -> Result {
        var rooms = existing
        var deletedRoomIDs = Set<RoomID>()
        var imageEligibleKeys = Set<String>()

        // Omission is never deletion. Only an observed explicit tombstone may
        // remove the matching rich record, and the caller can temporarily
        // preserve exact local ids while an in-flight local operation settles.
        for (key, revision) in tombstones.sorted(by: { $0.key < $1.key }) {
            guard RoomProjectionEnvelope.isRoomKey(key) else { continue }
            if key.hasPrefix("name:"),
               let surviving = projection.rooms[key], surviving.revision > revision {
                continue
            }
            for (id, room) in rooms where !preservingRoomIDs.contains(id) {
                guard tombstone(key, revision: revision, matches: room) else { continue }
                rooms.removeValue(forKey: id)
                deletedRoomIDs.insert(id)
            }
        }

        for key in projection.rooms.keys.sorted() {
            guard let projected = projection.rooms[key],
                  let roomID = RoomProjectionEnvelope.localRoomID(forProjectionKey: key)
            else { continue }

            if let current = rooms[roomID] {
                // A non-nil different raw key would require an impossible UUID
                // collision or corrupt state. Keep both rich state and ledger,
                // but never let one projection identity claim the other.
                guard current.rawProjectionRoomKey == nil
                        || current.rawProjectionRoomKey == key else { continue }
                let hydrated = hydrate(projected, key: key, into: current,
                                       allowedGatewayIDs: allowedGatewayIDs)
                rooms[roomID] = hydrated.room
                if hydrated.acceptedIdentityOverlay { imageEligibleKeys.insert(key) }
            } else if let hydrated = hydrateNew(
                projected, key: key, id: roomID,
                allowedGatewayIDs: allowedGatewayIDs
            ) {
                rooms[roomID] = hydrated
                imageEligibleKeys.insert(key)
            }
        }

        var images: [RoomID: Data] = [:]
        for key in imageEligibleKeys.sorted() {
            guard let projected = projection.rooms[key],
                  let id = RoomProjectionEnvelope.localRoomID(forProjectionKey: key),
                  let rich = rooms[id], rich.rawProjectionRoomKey == key,
                  projected.revision == rich.rawProjectionRevision,
                  let image = projected.image.flatMap(decodeImageDataURL)
            else { continue }
            images[id] = image
        }

        return Result(rooms: rooms, projectedImages: images,
                      deletedRoomIDs: deletedRoomIDs)
    }

    private static func tombstone(_ key: String, revision: UInt64,
                                  matches room: RoomRecord) -> Bool {
        if key.hasPrefix("id:") {
            return room.rawProjectionRoomKey == key
                || RoomProjectionEnvelope.localRoomID(forProjectionKey: key) == room.id
        }
        // Legacy name tombstones are revisioned and may only target a room
        // proven to have originated from that exact migration key. A local
        // same-name room is unrelated and must survive.
        return room.rawProjectionRoomKey == key
            && revision >= room.rawProjectionRevision
    }

    private static func hydrateNew(_ projected: RoomProjectionRoom,
                                   key: String, id: RoomID,
                                   allowedGatewayIDs: Set<String>) -> RoomRecord? {
        guard !projected.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let members = routableMembers(
                projected.members, preserving: [],
                allowedGatewayIDs: allowedGatewayIDs),
              members.count >= RoomEngine.minimumMembers else { return nil }

        let seed = RoomRecord(
            id: id, name: projected.name, members: members,
            rawProjectionRoomKey: key,
            rawProjectionRevision: projected.revision,
            createdAt: projected.log.first.map { date(milliseconds: $0.at) }
                ?? Date(timeIntervalSince1970: 0)
        )
        guard let hydrated = addingProjectedEntries(projected.log, key: key,
                                                    to: seed, strictAuthors: true)
        else { return nil }
        do { try RoomEngine.validate(hydrated) }
        catch { return nil }
        return hydrated
    }

    private struct ExistingHydration {
        var room: RoomRecord
        var acceptedIdentityOverlay: Bool
    }

    private static func hydrate(_ projected: RoomProjectionRoom,
                                key: String, into existing: RoomRecord,
                                allowedGatewayIDs: Set<String>) -> ExistingHydration {
        var room = existing
        room.rawProjectionRoomKey = key
        // A first exact-key association may safely consume revision zero. Once
        // associated, only a strictly newer revision may change identity.
        let revisionWins = existing.rawProjectionRoomKey == nil
            || projected.revision > existing.rawProjectionRevision
        var acceptedIdentityOverlay = existing.rawProjectionRoomKey == key
            && projected.revision == existing.rawProjectionRevision

        if revisionWins {
            if !projected.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let members = routableMembers(
                projected.members,
                preserving: existing.members + existing.formerMembers,
                allowedGatewayIDs: allowedGatewayIDs
            ), members.count >= RoomEngine.minimumMembers {
                var identityCandidate = room
                identityCandidate.name = projected.name
                let liveRoutes = Set(members.map(\.route))
                var former = existing.formerMembers.filter { !liveRoutes.contains($0.route) }
                for removed in existing.members where !liveRoutes.contains(removed.route)
                    && !former.contains(where: { $0.route == removed.route }) {
                    former.append(removed)
                }
                identityCandidate.members = members
                identityCandidate.formerMembers = former
                identityCandidate.rawProjectionRevision = projected.revision
                // Attempts, drives, sessions, watermarks, and historical rows
                // stay byte-for-byte intact. Validation is the safety proof
                // that the revisioned name/member/image overlay does not
                // strand them. The overlay advances as one unit or not at all.
                if (try? RoomEngine.validate(identityCandidate)) != nil {
                    room = identityCandidate
                    acceptedIdentityOverlay = true
                }
            }
        }

        // Missing stable-id messages are a union independent of room revision.
        // Existing same-id entries are authoritative in every rich field.
        if let withEntries = addingProjectedEntries(projected.log, key: key,
                                                    to: room, strictAuthors: false),
           (try? RoomEngine.validate(withEntries)) != nil {
            room = withEntries
        }
        return ExistingHydration(room: room,
                                 acceptedIdentityOverlay: acceptedIdentityOverlay)
    }

    private static func routableMembers(_ projected: [RoomProjectionMember],
                                        preserving rich: [RoomMember],
                                        allowedGatewayIDs: Set<String>) -> [RoomMember]? {
        var richByRoute: [GatewayBotRoute: RoomMember] = [:]
        for member in rich where richByRoute[member.route] == nil {
            richByRoute[member.route] = member
        }
        var result: [RoomMember] = []
        var routes = Set<GatewayBotRoute>()
        for value in projected {
            let gateway = value.connectionID?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let profile = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Modern descriptors must prove their source. Bare v1/v2 member
            // names remain in the ledger but cannot become routable seats.
            // Desktop connection ids are host-registry identities. They are
            // routable on this device only after the caller proves an exact
            // configured Talaria gateway id; labels are display data and must
            // never be used as an identity fallback.
            guard value.sourceScoped, allowedGatewayIDs.contains(gateway),
                  !gateway.isEmpty, !profile.isEmpty,
                  !gateway.contains(GatewayBotRoute.separator) else { continue }
            let route = GatewayBotRoute(gatewayID: gateway, profile: profile)
            guard GatewayBotRoute(qualifiedID: route.qualifiedID) == route,
                  routes.insert(route).inserted else { continue }
            if let rich = richByRoute[route] {
                result.append(rich)
                continue
            }
            let proposedHandle = value.handle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = safeHandle(proposedHandle) ?? safeHandle(profile)
                ?? "member-\(result.count + 1)"
            let label = value.connectionLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(RoomMember(route: route, handle: handle,
                                     sourceLabel: label?.isEmpty == false ? label : nil))
        }
        guard result.count <= RoomEngine.maximumMembers else { return nil }
        return result
    }

    private static func safeHandle(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.range(of: #"^[a-z0-9][a-z0-9._-]*$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return value
    }

    private static func addingProjectedEntries(
        _ projected: [RoomProjectionEntry], key: String,
        to original: RoomRecord, strictAuthors: Bool
    ) -> RoomRecord? {
        var room = original
        var entryIndices = Dictionary(uniqueKeysWithValues:
            room.entries.indices.map { (room.entries[$0].id, $0) })
        var threadTimes: [RoomThreadID: (first: Date, last: Date)] = [:]

        for value in projected {
            let entryID: RoomEntryID
            if let raw = value.id,
               let mapped = RoomProjectionEnvelope.localEntryID(forProjectionID: raw) {
                entryID = mapped
            } else {
                entryID = syntheticEntryID(value, roomKey: key)
            }

            let rawThread = value.thread
            let threadID = rawThread.flatMap {
                RoomProjectionEnvelope.localThreadID(forProjectionID: $0)
            } ?? syntheticThreadID(roomKey: key)

            if let index = entryIndices[entryID] {
                // Rich local payload wins. Only backfill a proven raw wire id
                // so a future projection cannot publish the mapped UUID.
                if room.entries[index].rawProjectionEntryID == nil,
                   let raw = value.id {
                    room.entries[index].rawProjectionEntryID = raw
                }
                if room.entries[index].rawProjectionThreadID == nil,
                   room.entries[index].threadID == threadID,
                   let rawThread {
                    room.entries[index].rawProjectionThreadID = rawThread
                }
                continue
            }

            let route: GatewayBotRoute?
            if value.from.kind == .member {
                guard let resolved = resolveAuthor(value.from,
                                                   members: room.members + room.formerMembers)
                else {
                    if strictAuthors { return nil }
                    continue
                }
                route = resolved.route
            } else {
                route = nil
            }
            let member = route.flatMap { route in
                (room.members + room.formerMembers).first { $0.route == route }
            }
            let at = date(milliseconds: value.at)
            room.entries.append(RoomEntry(
                id: entryID, threadID: threadID,
                rawProjectionEntryID: value.id,
                rawProjectionThreadID: rawThread,
                speaker: value.from.kind, memberRoute: route,
                speakerName: value.from.name,
                sourceLabel: member?.sourceLabel ?? value.from.source,
                text: value.text, at: at
            ))
            entryIndices[entryID] = room.entries.index(before: room.entries.endIndex)
            if let current = threadTimes[threadID] {
                threadTimes[threadID] = (min(current.first, at), max(current.last, at))
            } else {
                threadTimes[threadID] = (at, at)
            }
        }

        var threadIndices = Dictionary(uniqueKeysWithValues:
            room.threads.indices.map { (room.threads[$0].id, $0) })
        for (id, times) in threadTimes.sorted(by: {
            if $0.value.first != $1.value.first { return $0.value.first < $1.value.first }
            return $0.key.rawValue.uuidString < $1.key.rawValue.uuidString
        }) {
            if let index = threadIndices[id] {
                room.threads[index].lastActivityAt = max(
                    room.threads[index].lastActivityAt, times.last)
            } else {
                room.threads.append(RoomThread(id: id, createdAt: times.first,
                                               lastActivityAt: times.last))
                threadIndices[id] = room.threads.index(before: room.threads.endIndex)
            }
        }
        if let latest = room.entries.map(\.at).max() {
            room.updatedAt = max(room.updatedAt, latest)
        }
        return room
    }

    private static func resolveAuthor(_ author: RoomProjectionAuthor,
                                      members: [RoomMember]) -> RoomMember? {
        let source = author.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = members
        if let source, !source.isEmpty {
            candidates = candidates.filter {
                $0.route.gatewayID == source || $0.sourceLabel == source
            }
            guard !candidates.isEmpty else { return nil }
        }
        if candidates.count == 1 { return candidates[0] }

        let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let matches = candidates.filter { member in
            let forms = [member.route.profile, member.handle, member.title,
                         member.friendlyName, member.rawDisplayName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return forms.contains(name)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func syntheticThreadID(roomKey: String) -> RoomThreadID {
        let fingerprint = SHA256.hash(data: Data(roomKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return RoomProjectionEnvelope.localThreadID(
            forProjectionID: "\u{0}legacy-thread\u{0}\(fingerprint)")!
    }

    private static func syntheticEntryID(_ entry: RoomProjectionEntry,
                                         roomKey: String) -> RoomEntryID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(entry)) ?? Data()
        let fingerprint = SHA256.hash(data: Data(roomKey.utf8) + encoded)
            .map { String(format: "%02x", $0) }.joined()
        return RoomProjectionEnvelope.localEntryID(
            forProjectionID: "\u{0}legacy-entry\u{0}\(fingerprint)")!
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    /// Projection images never become attachment records here. Decode only a
    /// strict, canonical nonempty image data URL and keep the decoded result
    /// below the already-small projection character cap.
    private static func decodeImageDataURL(_ value: String) -> Data? {
        guard value.count <= RoomProjectionEnvelope.maximumImageCharacters,
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[..<comma])
        let prefix = "data:image/"
        let suffix = ";base64"
        guard header.hasPrefix(prefix), header.hasSuffix(suffix) else { return nil }
        let subtype = header.dropFirst(prefix.count).dropLast(suffix.count)
        guard !subtype.isEmpty, subtype.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "." || scalar == "+" || scalar == "-"
        }) else { return nil }
        let payload = String(value[value.index(after: comma)...])
        guard !payload.isEmpty, let data = Data(base64Encoded: payload), !data.isEmpty,
              data.count <= RoomProjectionEnvelope.maximumImageCharacters,
              data.base64EncodedString() == payload else { return nil }
        return data
    }
}

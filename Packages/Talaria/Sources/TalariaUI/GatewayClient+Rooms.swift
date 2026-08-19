import Foundation
import TalariaKit

// Gateway primitives used by the mobile room coordinator.  A room member
// always runs in its own hidden, persistent Hermes session on the member's
// source gateway; this file deliberately knows nothing about AppModel or the
// active connection so callers cannot accidentally route a remote member
// through the primary client.

public struct RoomOutboundAttachment: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case image, pdf, file }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var data: Data

    public init(id: UUID = UUID(), kind: Kind, name: String, data: Data) {
        self.id = id
        self.kind = kind
        self.name = name
        self.data = data
    }
}

/// A source-local member session read. `messageCount` is the pre-submit
/// baseline retained with a durable attempt; `containsAttempt` is the exact
/// acceptance proof used after a transport-uncertain submit.
public struct RoomMemberSessionSnapshot: Sendable {
    public var runtimeID: String
    public var storedID: String
    public var messages: [JSONValue]
    public var running: Bool

    public init(runtimeID: String, storedID: String, messages: [JSONValue], running: Bool) {
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.messages = messages
        self.running = running
    }

    public var messageCount: Int { messages.count }

    public func containsAttempt(_ attemptID: UUID) -> Bool {
        let marker = GatewayClient.roomAttemptMarker(attemptID)
        return messages.contains { message in
            guard message["role"]?.stringValue == "user" else { return false }
            return GatewayClient.roomMessageText(message).contains(marker)
        }
    }

    /// Strong reconciliation: the marker belongs to a user row whose prompt
    /// prefix matches the exact body persisted with this attempt.
    public func containsAttempt(_ attempt: RoomAttempt) -> Bool {
        messages.contains { message in
            guard message["role"]?.stringValue == "user" else { return false }
            let text = GatewayClient.roomMessageText(message)
            guard text.hasPrefix(attempt.promptAnchor + "\n") else { return false }
            let body = String(text.dropFirst(attempt.promptAnchor.count + 1))
            guard body.hasPrefix(attempt.promptText) else { return false }
            return RoomAttempt.hash(String(body.prefix(attempt.promptText.count))) == attempt.promptHash
        }
    }

    public func newestAssistant(after baseline: Int) -> String? {
        guard messages.count > baseline else { return nil }
        for message in messages[baseline...].reversed()
        where message["role"]?.stringValue == "assistant" {
            let text = GatewayClient.roomMessageText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }


    /// Assistant output causally following this exact anchored user row.
    public func assistantReply(for attempt: RoomAttempt) -> String? {
        guard let anchor = messages.firstIndex(where: { message in
            guard message["role"]?.stringValue == "user" else { return false }
            let text = GatewayClient.roomMessageText(message)
            return text.hasPrefix(attempt.promptAnchor + "\n")
                && text.dropFirst(attempt.promptAnchor.count + 1).hasPrefix(attempt.promptText)
        }), anchor + 1 < messages.count else { return nil }
        let start = anchor + 1
        let end = messages[start...].firstIndex(where: { $0["role"]?.stringValue == "user" })
            ?? messages.endIndex
        guard start < end else { return nil }
        for message in messages[start..<end].reversed()
        where message["role"]?.stringValue == "assistant" {
            let text = GatewayClient.roomMessageText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}

public enum RoomPromptAcceptance: Sendable, Equatable {
    /// The submit RPC acknowledged, or a post-error resume found the exact
    /// attempt marker in this member's transcript.
    case accepted
    /// The transport failed and the exact marker was not yet observable.
    /// This is durable uncertainty, never permission to submit again.
    case uncertain(String)
    /// The source was already running unrelated work. No submit occurred.
    case busy
    /// Attachment staging or a pre-acceptance validation failed. No prompt
    /// was accepted; queued image/PDF state was detached.
    case rejected(String)
}

public struct RoomPromptSubmission: Sendable, Equatable {
    public var acceptance: RoomPromptAcceptance
    public var runtimeID: String
    public var storedID: String
    public var baseline: Int
    /// Queued image/PDF paths retained only while submit acceptance is
    /// uncertain. Definite rejection detaches before returning.
    public var stagedImagePaths: [String]

    public init(acceptance: RoomPromptAcceptance, runtimeID: String,
                storedID: String, baseline: Int, stagedImagePaths: [String] = []) {
        self.acceptance = acceptance
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.baseline = baseline
        self.stagedImagePaths = stagedImagePaths
    }
}

enum RoomSessionResolver {
    /// Only Hermes' definitive durable-row absence (4007) permits moving to
    /// the next target or creating. Transport/auth/lifecycle failures keep the
    /// existing identity innocent and propagate to the caller.
    static func resolve<T>(storedID: String?, title: String,
                           resume: (String) async throws -> T,
                           create: () async throws -> T) async throws -> T {
        if let storedID, !storedID.isEmpty {
            do { return try await resume(storedID) }
            catch let error as GatewayError where error.code == GatewayError.storedSessionGone {}
        }
        do { return try await resume(title) }
        catch let error as GatewayError where error.code == GatewayError.storedSessionGone {}
        return try await create()
    }
}

public extension GatewayClient {
    static func roomAttemptMarker(_ attemptID: UUID) -> String {
        RoomAttempt.anchor(for: RoomAttemptID(rawValue: attemptID))
    }

    static func roomMessageText(_ message: JSONValue) -> String {
        if let content = message["content"]?.stringValue { return content }
        if let text = message["text"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { part in
            part.stringValue ?? part["text"]?.stringValue
        }.joined()
    }

    /// Resume by the durable id first, then by the exact `Group: …` title;
    /// create only when neither exists. Title fallback is required after a
    /// local room record survives while its cached stored id is lost.
    func ensureRoomSession(roomTitle: String, profile: String,
                           storedID: String?) async throws -> RoomMemberSessionSnapshot {
        let title = "Group: \(roomTitle)"
        let live = try await RoomSessionResolver.resolve(
            storedID: storedID, title: title,
            resume: { try await self.resumeSession($0, profile: profile) },
            create: { try await self.createSession(profile: profile, title: title, hidden: true) })
        guard !live.sessionID.isEmpty, !live.storedSessionID.isEmpty else {
            throw GatewayError(code: -8, message: "Room session resolution returned no durable identity.")
        }
        return RoomMemberSessionSnapshot(runtimeID: live.sessionID,
                                         storedID: live.storedSessionID,
                                         messages: live.messages,
                                         running: live.running || live.inflight != nil)
    }

    func readRoomSession(storedID: String, profile: String) async throws -> RoomMemberSessionSnapshot {
        let resumed = try await resumeSession(storedID, profile: profile)
        guard !resumed.sessionID.isEmpty, !resumed.storedSessionID.isEmpty else {
            throw GatewayError(code: -8, message: "Room session read returned no durable identity.")
        }
        return RoomMemberSessionSnapshot(runtimeID: resumed.sessionID,
                                         storedID: resumed.storedSessionID,
                                         messages: resumed.messages,
                                         running: resumed.running || resumed.inflight != nil)
    }

    func detachRoomStagedImages(_ paths: [String], sessionID: String) async {
        await detachRoomImages(paths, sessionID: sessionID)
    }

    /// Stage one responder's payload and submit exactly once. A caller must
    /// persist the attempt before entering this function. On a failed submit,
    /// queued images (including rendered PDF pages) are detached; file refs
    /// stay withheld because they are appended only to the submitted prompt.
    /// A transport error is reconciled against the exact marker and otherwise
    /// returned as uncertainty — it is never auto-retried.
    func submitRoomPrompt(
        attempt: RoomAttempt,
        session initial: RoomMemberSessionSnapshot,
        profile: String,
        attachments: [RoomOutboundAttachment]
    ) async -> RoomPromptSubmission {
        let baseline = initial.messageCount
        let baseResult = { (acceptance: RoomPromptAcceptance) in
            RoomPromptSubmission(acceptance: acceptance,
                                 runtimeID: initial.runtimeID,
                                 storedID: initial.storedID,
                                 baseline: baseline,
                                 stagedImagePaths: [])
        }

        // `prompt.submit` into a busy Hermes session redirects/interrupts
        // under some gateway policies. Rooms must never disturb that work.
        guard !initial.running else { return baseResult(.busy) }

        var queuedPaths: [String] = []
        var fileReferences: [String] = []
        do {
            for attachment in attachments {
                switch attachment.kind {
                case .image:
                    let staged = try await attachImageBytes(sessionID: initial.runtimeID,
                                                            data: attachment.data,
                                                            filename: attachment.name)
                    queuedPaths.append(contentsOf: staged.paths)
                case .pdf:
                    let staged = try await attachPDF(sessionID: initial.runtimeID,
                                                     data: attachment.data,
                                                     filename: attachment.name)
                    queuedPaths.append(contentsOf: staged.paths)
                case .file:
                    let staged = try await attachFile(sessionID: initial.runtimeID,
                                                      data: attachment.data,
                                                      filename: attachment.name)
                    if let ref = staged.refText, !ref.isEmpty {
                        fileReferences.append("\(attachment.name) → \(ref)")
                    }
                }
            }
        } catch {
            await detachRoomImages(queuedPaths, sessionID: initial.runtimeID)
            return baseResult(.rejected(error.localizedDescription))
        }

        let refs = fileReferences.isEmpty ? "" :
            "\n\nAttached files staged in your session workspace:\n" + fileReferences.joined(separator: "\n")
        let exactPrompt = attempt.promptAnchor + "\n" + attempt.promptText + refs

        do {
            // queued:true closes the resume→submit race without redirecting or
            // interrupting work that became busy after the preflight.
            try await submitPrompt(sessionID: initial.runtimeID, text: exactPrompt, queued: true)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: initial.runtimeID,
                                        storedID: initial.storedID,
                                        baseline: baseline,
                                        stagedImagePaths: [])
        } catch {
            // An error can happen after Hermes accepted the prompt but before
            // its acknowledgement reached the phone. Do one read-only exact
            // reconciliation. Never resubmit from this path.
            if let resumed = try? await readRoomSession(storedID: initial.storedID,
                                                        profile: profile),
               resumed.containsAttempt(attempt) {
                return RoomPromptSubmission(acceptance: .accepted,
                                            runtimeID: resumed.runtimeID,
                                            storedID: resumed.storedID,
                                            baseline: baseline,
                                            stagedImagePaths: [])
            }
            // Do not detach: Hermes may have accepted the prompt and not yet
            // persisted/returned. Paths ride the durable uncertain attempt.
            return RoomPromptSubmission(acceptance: .uncertain(error.localizedDescription),
                                        runtimeID: initial.runtimeID,
                                        storedID: initial.storedID,
                                        baseline: baseline,
                                        stagedImagePaths: queuedPaths)
        }
    }

    private func detachRoomImages(_ paths: [String], sessionID: String) async {
        for path in paths { _ = try? await detachImage(sessionID: sessionID, path: path) }
    }
}

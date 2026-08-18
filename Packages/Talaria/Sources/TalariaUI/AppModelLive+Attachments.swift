import Foundation
import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#endif

// Composer attachments: staging bytes on the gateway before the next
// prompt.submit consumes them (ws-protocol.md §9). The user-facing rules the
// gateway imposes and this file honors:
//
// - Images are per-session state. image.attach_bytes queues one; the next
//   prompt.submit hands them to the vision pipeline and clears the queue.
//   Removing one before sending needs image.detach, or it rides the next turn.
// - PDFs are images too: pdf.attach renders pages to PNG server-side and queues
//   every page, so one PDF can hold several detachable paths.
// - Files are not session state. file.attach writes them into the session
//   workspace and returns an "@file:" ref that only reaches the agent if the
//   submitted text carries it — see `composedPrompt(_:botID:)`.
//
// Themed copy for every failure lives with the tray (AttachmentTray.swift): the
// gateway's own messages are terse English and would break all three voices.

// MARK: - Runtime (side table)

/// Attachment book-keeping that has no home on `AppModel` (its stored
/// properties live in AppModel.swift, and extensions cannot add storage) —
/// same pattern as `LiveRuntime`. Observable because the tray presents its
/// pickers from these flags.
@MainActor
@Observable
final class AttachmentRuntime {
    static let shared = AttachmentRuntime()

    /// Bot whose source chooser is open (nil = closed).
    var chooserBotID: String?
    /// Bot whose photo-library picker is open.
    var photoBotID: String?
    /// Bot whose document importer is open.
    var fileBotID: String?
    /// Attachment id → what the gateway staged for it.
    var staged: [String: Staged] = [:]
    /// Attachment ids whose attach RPC is still in flight (tray spinner).
    var uploading: Set<String> = []

    struct Staged: Sendable {
        /// Queued image paths to hand image.detach on removal. Empty for
        /// file.attach, which has no detach RPC.
        var paths: [String]
        /// "@file:…" ref that must ride in the prompt text.
        var refText: String?
    }

    func forget(_ id: String) {
        staged.removeValue(forKey: id)
        uploading.remove(id)
    }
}

/// Transcoded image bytes plus the tray thumbnail, produced off the main actor.
private struct WireImage: Sendable {
    var data: Data
    var filename: String
    var thumbnail: Data?
}

extension AppModel {

    // MARK: - Picker presentation

    /// Open the attach flow for a bot. iOS offers photo library / documents /
    /// paste; macOS (build parity only) goes straight to the document importer,
    /// the one picker it has.
    public func presentAttachmentPicker(botID: String) {
        let runtime = AttachmentRuntime.shared
        #if os(iOS)
        runtime.chooserBotID = botID
        #else
        runtime.fileBotID = botID
        #endif
    }

    // MARK: - Staging

    /// Stage image bytes (photo picker, camera roll, paste). Normalizes the
    /// format first: the gateway's allow-list has no HEIC, so an iPhone photo
    /// would come back 4016 untouched.
    public func attachImageData(_ data: Data, filename: String, botID: String) async {
        let name = filename.isEmpty ? "photo.jpg" : filename
        // Decode + re-encode of a 12 MP photo is far too slow for the main
        // actor, and the tray must stay responsive while it happens.
        let wire = await Task.detached(priority: .userInitiated) { () -> WireImage? in
            guard let shaped = AttachmentEncoder.gatewayImage(from: data, filename: name) else { return nil }
            return WireImage(data: shaped.data, filename: shaped.filename,
                             thumbnail: AttachmentEncoder.thumbnail(from: shaped.data))
        }.value

        guard let wire else {
            noteAttachmentFailure(GatewayError(code: AttachmentErrorCode.badPayload,
                                               message: "undecodable image"),
                                  kind: .image, botID: botID)
            return
        }
        guard wire.data.count <= AttachmentLimits.imageBytes else {
            noteAttachmentFailure(GatewayError(code: AttachmentErrorCode.tooLarge, message: "image too large"),
                                  kind: .image, botID: botID)
            return
        }

        let pending = PendingAttachment(kind: .image, name: wire.filename, thumbnail: wire.thumbnail)
        stageLocally(pending, botID: botID)
        await stageOnGateway(pending, botID: botID) { client, sid in
            try await client.attachImageBytes(sessionID: sid, data: wire.data, filename: wire.filename)
        }
    }

    /// Stage a file picked from Files/iCloud. Routes by extension: images go
    /// through the image path (with transcoding), PDFs through pdf.attach, and
    /// everything else becomes a workspace file with an "@file:" ref.
    public func attachFileURL(_ url: URL, botID: String) async {
        // Security-scoped access is how a document-picker URL becomes readable;
        // without it Data(contentsOf:) fails with a permission error.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let isPDF = AttachmentEncoder.isPDF(filename: name)
        // Images are checked against the wire cap *after* transcoding — a 40 MB
        // HEIC or PNG still fits 25 MB once it is a downscaled JPEG — so the
        // read gate is only about what we are willing to pull into memory.
        let cap = isPDF ? AttachmentLimits.pdfBytes : AttachmentLimits.fileBytes

        // Size-check before reading: a multi-GB video should never land in
        // memory just to be rejected.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > cap {
            noteAttachmentFailure(GatewayError(code: AttachmentErrorCode.tooLarge, message: "file too large"),
                                  kind: isPDF ? .pdf : .file, botID: botID)
            return
        }
        // Off the main actor: a document-provider read can stall on iCloud
        // materialization, and the composer must not freeze behind it.
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            try? Data(contentsOf: url)
        }).value else {
            attachmentNote(theme.copy.attachUnreadable(theme.themeID), botID: botID)
            return
        }

        if AttachmentEncoder.isImage(filename: name) {
            await attachImageData(data, filename: name, botID: botID)
            return
        }
        if isPDF {
            await attachPDFData(data, filename: name, botID: botID)
            return
        }

        let pending = PendingAttachment(kind: .file, name: name)
        stageLocally(pending, botID: botID)
        await stageOnGateway(pending, botID: botID) { client, sid in
            try await client.attachFile(sessionID: sid, data: data, filename: name)
        }
    }

    /// Paste an image. The phone's own pasteboard is the common case; when it
    /// holds nothing, clipboard.paste reads the *gateway host's* clipboard,
    /// which is the desktop you copied on whenever Talaria points at your Mac.
    public func pasteAttachment(botID: String) async {
        #if canImport(UIKit)
        let board = UIPasteboard.general
        if board.hasImages, let image = board.image, let data = image.pngData() {
            await attachImageData(data, filename: "pasted.png", botID: botID)
            return
        }
        #endif
        guard mode == .live, !isOffline, let client else {
            attachmentNote(theme.copy.attachClipboardEmpty(theme.themeID), botID: botID)
            return
        }
        do {
            let sid = try await ensureSession(botID: botID, hydrate: false)
            guard let staged = try await client.pasteClipboardImage(sessionID: sid) else {
                attachmentNote(theme.copy.attachClipboardEmpty(theme.themeID), botID: botID)
                return
            }
            let pending = PendingAttachment(kind: .image, name: staged.name, path: staged.path)
            stageLocally(pending, botID: botID)
            AttachmentRuntime.shared.staged[pending.id] = .init(paths: staged.paths, refText: nil)
        } catch {
            noteAttachmentFailure(error, kind: .image, botID: botID)
        }
    }

    /// Drop one staged attachment. Queued images are live session state, so
    /// this detaches them server-side — otherwise they would ride the next
    /// turn the user sends. A file.attach has no detach RPC: forgetting its
    /// "@file:" ref is the removal.
    public func removeAttachment(id: String, botID: String) {
        let chat = chat(for: botID)
        let removed = chat.attachments.first { $0.id == id }
        chat.attachments.removeAll { $0.id == id }
        let runtime = AttachmentRuntime.shared
        let staged = runtime.staged.removeValue(forKey: id)
        runtime.uploading.remove(id)

        guard mode == .live, removed?.kind != .file,
              let paths = staged?.paths, !paths.isEmpty,
              let client, let sid = chats[botID]?.sessionID else { return }
        Task { @MainActor in
            for path in paths {
                _ = try? await client.detachImage(sessionID: sid, path: path)
            }
        }
    }

    /// Empty the tray after a submit consumed it. Deliberately silent:
    /// prompt.submit already cleared the gateway's queue, so detaching here
    /// would fight state that no longer exists. User-initiated removal goes
    /// through `removeAttachment`, which does detach.
    public func clearAttachments(botID: String) {
        guard let chat = chats[botID], !chat.attachments.isEmpty else { return }
        let runtime = AttachmentRuntime.shared
        for attachment in chat.attachments { runtime.forget(attachment.id) }
        chat.attachments.removeAll()
    }

    /// The text a submit should actually carry. Images ride the session, but a
    /// staged file only exists for the agent if its "@file:" ref is in the
    /// prompt — and an image sent with no words gets desktop's implicit
    /// question rather than an empty turn.
    public func composedPrompt(_ text: String, botID: String) -> String {
        let attachments = chats[botID]?.attachments ?? []
        guard !attachments.isEmpty else { return text }
        let runtime = AttachmentRuntime.shared
        let refs = attachments.compactMap { runtime.staged[$0.id]?.refText }.joined(separator: "\n")
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = [refs, visible].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !body.isEmpty { return body }
        return attachments.contains { $0.kind != .file }
            ? theme.copy.attachImageOnlyPrompt(theme.themeID)
            : text
    }

    // MARK: - Gateway staging

    private func stageLocally(_ pending: PendingAttachment, botID: String) {
        chat(for: botID).attachments.append(pending)
    }

    /// Run one attach RPC for an already-visible tray row. The row appears
    /// first and is withdrawn on failure, so the tray never lags the tap.
    private func stageOnGateway(
        _ pending: PendingAttachment, botID: String,
        _ attach: @escaping (GatewayClient, String) async throws -> StagedAttachment
    ) async {
        // Demo mode has no gateway: the staged row *is* the feature.
        guard mode == .live else { return }
        let runtime = AttachmentRuntime.shared
        runtime.uploading.insert(pending.id)
        defer { runtime.uploading.remove(pending.id) }

        guard !isOffline, let client else {
            dropStagedRow(pending.id, botID: botID)
            attachmentNote(theme.copy.attachOffline(theme.themeID), botID: botID)
            return
        }
        do {
            var sid = try await ensureSession(botID: botID, hydrate: false)
            let staged: StagedAttachment
            do {
                staged = try await attach(client, sid)
            } catch let error as GatewayError where error.code == GatewayError.sessionNotFound {
                // Attach runs before prompt.submit, so a runtime sid reaped
                // during the park window fails here first — where plain text
                // would have recovered inside submit. Re-attach and retry once.
                chat(for: botID).sessionID = nil
                sid = try await ensureSession(botID: botID, hydrate: false)
                staged = try await attach(client, sid)
            }
            record(staged, for: pending, botID: botID)
        } catch {
            dropStagedRow(pending.id, botID: botID)
            noteAttachmentFailure(error, kind: pending.kind, botID: botID)
        }
    }

    private func record(_ staged: StagedAttachment, for pending: PendingAttachment, botID: String) {
        let chat = chat(for: botID)
        guard let idx = chat.attachments.firstIndex(where: { $0.id == pending.id }) else {
            // Removed while the upload was in flight — undo it server-side so
            // the orphan doesn't ride the next turn.
            releaseStaged(staged, botID: botID)
            return
        }
        chat.attachments[idx].path = staged.path
        if !staged.name.isEmpty { chat.attachments[idx].name = staged.name }
        AttachmentRuntime.shared.staged[pending.id] = .init(paths: staged.paths, refText: staged.refText)
    }

    private func dropStagedRow(_ id: String, botID: String) {
        chat(for: botID).attachments.removeAll { $0.id == id }
        AttachmentRuntime.shared.forget(id)
    }

    private func releaseStaged(_ staged: StagedAttachment, botID: String) {
        guard mode == .live, !staged.paths.isEmpty,
              let client, let sid = chats[botID]?.sessionID else { return }
        Task { @MainActor in
            for path in staged.paths {
                _ = try? await client.detachImage(sessionID: sid, path: path)
            }
        }
    }

    private func attachPDFData(_ data: Data, filename: String, botID: String) async {
        guard data.count <= AttachmentLimits.pdfBytes else {
            noteAttachmentFailure(GatewayError(code: AttachmentErrorCode.tooLarge, message: "PDF too large"),
                                  kind: .pdf, botID: botID)
            return
        }
        let pending = PendingAttachment(kind: .pdf, name: filename)
        stageLocally(pending, botID: botID)
        await stageOnGateway(pending, botID: botID) { client, sid in
            try await client.attachPDF(sessionID: sid, data: data, filename: filename)
        }
    }

    // MARK: - Failure reporting

    private func attachmentNote(_ text: String, botID: String) {
        chat(for: botID).messages.append(ChatMessage(author: .system, text: text))
    }

    private func noteAttachmentFailure(_ error: Error, kind: PendingAttachment.Kind, botID: String) {
        attachmentNote(attachmentFailureText(error, kind: kind), botID: botID)
    }

    /// Map the gateway's 4xxx/5xxx attach codes (ws-protocol.md §9) onto the
    /// themed voice. Anything unrecognized degrades to the generic line rather
    /// than leaking a server string into a parchment ledger.
    private func attachmentFailureText(_ error: Error, kind: PendingAttachment.Kind) -> String {
        let copy = theme.copy
        let id = theme.themeID
        guard let gateway = error as? GatewayError else { return copy.attachFailed(id) }
        switch gateway.code {
        case AttachmentErrorCode.tooLarge:
            let cap = kind == .pdf ? AttachmentLimits.pdfBytes
                : kind == .image ? AttachmentLimits.imageBytes : AttachmentLimits.fileBytes
            return copy.attachTooLarge(id, limitMB: AttachmentLimits.megabytes(cap))
        case AttachmentErrorCode.tooManyPages:
            return copy.attachTooManyPages(id, pages: AttachmentLimits.pdfPages)
        case AttachmentErrorCode.unsupportedKind, AttachmentErrorCode.badPayload,
             AttachmentErrorCode.missingParam:
            return copy.attachUnsupported(id)
        case AttachmentErrorCode.renderFailed where kind == .pdf:
            return copy.attachNoPDFRenderer(id)
        case -3, -5, -7:
            // Transport codes from GatewayTransport: not connected / timed out
            // / connection lost.
            return copy.attachOffline(id)
        case -32601:
            return copy.attachGatewayTooOld(id)
        default:
            return copy.attachFailed(id)
        }
    }
}

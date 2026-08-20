import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Full-width mobile room composer. Attachments stay visible until the async
/// send has durably appended the user entry; a failed send never clears the
/// draft or loses the bytes needed for retry.
public struct RoomComposer: View {
    public let theme: ThemePack
    public let members: [RoomMember]
    public let placeholder: String
    public let submitLabel: String
    public let onSubmit: (String, [RoomOutboundAttachment]) async throws -> Void

    @State private var draft = ""
    @State private var attachments: [RoomOutboundAttachment] = []
    @State private var sending = false
    @State private var error: String?
    @State private var showAttachmentSources = false
    @State private var pendingAttachmentSource: AttachmentSourceAction?
    @State private var showFiles = false
    @State private var showPhotos = false
    @FocusState private var focused: Bool
    #if canImport(PhotosUI)
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    public init(theme: ThemePack, members: [RoomMember], placeholder: String,
                submitLabel: String = "Send",
                onSubmit: @escaping (String, [RoomOutboundAttachment]) async throws -> Void) {
        self.theme = theme; self.members = members; self.placeholder = placeholder
        self.submitLabel = submitLabel; self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty { attachmentTray }
            if let error {
                Text(error).font(theme.body(10)).foregroundStyle(theme.danger).lineLimit(2)
            }
            if !mentionOptions.isEmpty { mentionSuggestions }
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(theme.body(14)).lineLimit(1...6).focused($focused)
                .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                .disabled(sending)
                .accessibilityLabel(placeholder)
            HStack(spacing: 10) {
                Button { showAttachmentSources = true } label: {
                    Image(systemName: "paperclip").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(theme.ink.opacity(0.7)).disabled(sending)
                .accessibilityLabel("Add attachment")
                Spacer()
                if !mentionHint.isEmpty {
                    Text(mentionHint).font(theme.mono(9)).foregroundStyle(theme.faint).lineLimit(1)
                }
                Button(action: send) {
                    HStack(spacing: 5) {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up") }
                        Text(submitLabel).font(theme.body(12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(canSend ? theme.accent : theme.faint.opacity(0.2),
                                in: Capsule())
                    .foregroundStyle(canSend ? Color.white : theme.faint)
                }
                .buttonStyle(.plain).disabled(!canSend || sending)
            }
        }
        .sheet(isPresented: $showAttachmentSources, onDismiss: performPendingAttachmentSource) {
            AttachmentSourceSheet(
                theme: theme,
                allowsPaste: false,
                select: { action in
                    pendingAttachmentSource = action
                    showAttachmentSources = false
                },
                close: {
                    pendingAttachmentSource = nil
                    showAttachmentSources = false
                }
            )
        }
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        #endif
        #if canImport(UniformTypeIdentifiers)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data, .pdf, .image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in await loadFiles(urls) }
        }
        #endif
    }

    private func performPendingAttachmentSource() {
        guard let action = pendingAttachmentSource else { return }
        pendingAttachmentSource = nil
        switch action {
        case .photos:
            #if canImport(PhotosUI)
            showPhotos = true
            #endif
        case .files:
            showFiles = true
        case .pasteImage:
            break // Room composers intentionally offer photo and file sources only.
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var mentionHint: String {
        let handles = members.prefix(2).map { "@\($0.handle)" }.joined(separator: " ")
        return members.count > 2 ? "\(handles) …" : handles
    }

    private var mentionToken: String? {
        guard let token = draft.components(separatedBy: .whitespacesAndNewlines).last,
              token.hasPrefix("@") else { return nil }
        return String(token.dropFirst()).lowercased()
    }

    private var mentionOptions: [String] {
        guard let token = mentionToken else { return [] }
        let handles = ["everyone", "all"] + members.map(\.handle)
        return Array(handles.filter { token.isEmpty || $0.lowercased().hasPrefix(token) }.prefix(6))
    }

    private var mentionSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mentionOptions, id: \.self) { handle in
                    Button("@\(handle)") { insertMention(handle) }
                        .buttonStyle(.plain).font(theme.mono(10)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(theme.accent.opacity(0.09), in: Capsule())
                }
            }
        }.accessibilityLabel("Room mentions")
    }

    private func insertMention(_ handle: String) {
        guard let range = draft.range(of: #"@[^\s]*$"#, options: .regularExpression) else { return }
        draft.replaceSubrange(range, with: "@\(handle) ")
        focused = true
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.kind == .image ? "photo" :
                                attachment.kind == .pdf ? "doc.richtext" : "doc")
                        Text(attachment.name).lineLimit(1)
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(theme.body(10)).foregroundStyle(theme.ink.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(theme.ink.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private func send() {
        guard canSend, !sending else { return }
        let text = draft
        let payload = attachments
        sending = true; error = nil
        Task { @MainActor in
            do {
                try await onSubmit(text, payload)
                draft = ""; attachments = []; focused = false
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    #if canImport(PhotosUI)
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task { @MainActor in
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let shaped = AttachmentEncoder.gatewayImage(from: data, filename: "photo.heic") else {
                    continue
                }
                attachments.append(RoomOutboundAttachment(kind: .image,
                                                           name: "photo-\(attachments.count + 1).jpg",
                                                           data: shaped.data))
            }
        }
    }
    #endif

    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let kind: RoomOutboundAttachment.Kind = AttachmentEncoder.isPDF(filename: url.lastPathComponent)
                ? .pdf : AttachmentEncoder.isImage(filename: url.lastPathComponent) ? .image : .file
            let cap = kind == .pdf ? AttachmentLimits.pdfBytes
                : kind == .image ? AttachmentLimits.imageBytes : AttachmentLimits.fileBytes
            guard data.count <= cap else {
                error = "\(url.lastPathComponent) is too large to attach."
                continue
            }
            if kind == .image,
               let shaped = AttachmentEncoder.gatewayImage(from: data, filename: url.lastPathComponent) {
                attachments.append(RoomOutboundAttachment(kind: .image,
                                                           name: shaped.filename, data: shaped.data))
            } else {
                attachments.append(RoomOutboundAttachment(kind: kind,
                                                           name: url.lastPathComponent, data: data))
            }
        }
    }
}

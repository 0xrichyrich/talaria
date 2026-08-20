import SwiftUI
import TalariaKit
import TalariaTheme
import UniformTypeIdentifiers

#if os(iOS) && canImport(PhotosUI)
import PhotosUI
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The composer's staged-attachment row: image thumbnails and file/PDF chips
// waiting for the next submit, each with its own detach control. It is also
// where the pickers live — `AppModel.presentAttachmentPicker(botID:)` flips a
// flag on AttachmentRuntime and the tray presents from it, so the composer
// needs no picker state of its own.
//
// Empty is invisible: the row collapses to nothing, but the view stays in the
// hierarchy because it hosts the picker presentations.

public struct AttachmentTray: View {
    private let model: AppModel
    private let botID: String

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Read through `chats` rather than `chat(for:)` — the latter inserts a
    /// ChatState, which a view body must never do.
    private var attachments: [PendingAttachment] {
        model.chats[botID]?.attachments ?? []
    }

    public var body: some View {
        // Read the picker flags *here*: Observation only tracks property reads
        // made while a body evaluates, so a flag read inside a presentation
        // binding's getter would never invalidate this view and the picker
        // would silently fail to open.
        let runtime = AttachmentRuntime.shared
        let chooserOpen = runtime.chooserBotID == botID
        let filesOpen = runtime.fileBotID == botID
        let photosOpen = runtime.photoBotID == botID

        return Group {
            if attachments.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                row
            }
        }
        .animation(.easeOut(duration: 0.2), value: attachments.count)
        .modifier(AttachmentSourceChooser(model: model, botID: botID, isPresented: chooserOpen))
        .modifier(AttachmentFileImporter(model: model, botID: botID, isPresented: filesOpen))
        .modifier(AttachmentPhotoPicker(model: model, botID: botID, isPresented: photosOpen))
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        theme: theme, copy: copy, attachment: attachment,
                        uploading: AttachmentRuntime.shared.uploading.contains(attachment.id),
                        remove: { model.removeAttachment(id: attachment.id, botID: botID) })
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .frame(height: 72)
        .overlay(alignment: .top) {
            // Ink rules its trays off from the composer; the other packs float.
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            }
        }
    }
}

// MARK: - Chip

/// One staged attachment: a thumbnail tile for images, a kind+name chip for
/// PDFs and files, with the detach badge riding its top-trailing corner.
private struct AttachmentChip: View {
    var theme: ThemePack
    var copy: CopyPack
    var attachment: PendingAttachment
    var uploading: Bool
    var remove: () -> Void

    private var tileSide: CGFloat { 54 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(height: tileSide)
                .background(theme.panel)
                .overlay { if uploading { uploadingVeil } }
                .clipShape(shape)
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .shadow(color: shadowColor, radius: theme.glowRadius > 0 ? 7 : 3,
                        y: theme.id == .soft ? 2 : 0)
            removeBadge
                .offset(x: 7, y: -7)
        }
        .padding(.top, 8)
        .padding(.trailing, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.name)
        .accessibilityAction(named: Text(copy.attachRemove(theme.id)), remove)
    }

    @ViewBuilder private var content: some View {
        switch attachment.kind {
        case .image: imageTile
        case .pdf, .file: fileChip
        }
    }

    // MARK: Image

    @ViewBuilder private var imageTile: some View {
        if let data = attachment.thumbnail, let image = Self.platformImage(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: tileSide, height: tileSide)
                .clipped()
        } else {
            // A clipboard.paste image lives only on the gateway — there are no
            // local bytes to preview, so the kind tag stands in for it.
            VStack(spacing: 3) {
                Text(verbatim: "IMG")
                    .font(theme.mono(8.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.accent)
                Text(attachment.name)
                    .font(theme.mono(7.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(width: tileSide, height: tileSide)
        }
    }

    // MARK: File / PDF

    private var fileChip: some View {
        HStack(spacing: 8) {
            Text(kindTag)
                .font(theme.mono(8.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(tagColor)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(tagColor.opacity(0.13), in: tagShape)
            Text(attachment.name)
                .font(nameFont)
                .tracking(theme.id == .ink ? 0.5 : 0)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: 200)
    }

    /// "PDF" / "CSV" / "FILE" — the extension is the honest label.
    private var kindTag: String {
        if attachment.kind == .pdf { return "PDF" }
        let ext = AttachmentEncoder.fileExtension(of: attachment.name)
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }

    private var tagColor: Color {
        attachment.kind == .pdf ? theme.accent : theme.sub
    }

    private var tagShape: AnyShape {
        theme.chipIsCapsule
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 4))
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .semibold)
        case .control: theme.mono(10.5)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    // MARK: Chrome

    private var shape: RoundedRectangle {
        // Tile-scale radius from the pack's card radius: soft rounds, control
        // clips at 10, ink stays square.
        RoundedRectangle(cornerRadius: min(theme.cardRadius, 14), style: .continuous)
    }

    private var borderColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.08)
        case .control: theme.lineStrong
        case .ink: theme.ink.opacity(0.4)
        }
    }

    private var shadowColor: Color {
        if theme.glowRadius > 0 { return theme.accent.opacity(uploading ? 0.3 : 0.14) }
        return theme.id == .soft ? theme.ink.opacity(0.06) : .clear
    }

    private var uploadingVeil: some View {
        ZStack {
            theme.bg.opacity(0.62)
            Text(copy.attachUploading(theme.id))
                .font(theme.mono(8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(theme.accent)
                .glowPulse(period: 1.4)
        }
    }

    private var removeBadge: some View {
        Button(action: remove) {
            Text(verbatim: "✕")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(theme.bg)
                .frame(width: 18, height: 18)
                .background(badgeFill, in: badgeShape)
                .overlay(badgeShape.strokeBorder(theme.bg.opacity(0.55), lineWidth: 1))
                .contentShape(badgeShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copy.attachRemove(theme.id)))
    }

    private var badgeFill: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.8)
        case .control: theme.danger
        case .ink: theme.ink
        }
    }

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18 * theme.iconCornerFraction, style: .continuous)
    }

    /// SwiftUI has no cross-platform `Image(data:)`.
    private static func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

// MARK: - Pickers

/// The iOS source chooser. `presentAttachmentPicker` opens it; each choice
/// hands off to one of the pickers below (or straight to the paste path).
private struct AttachmentSourceChooser: ViewModifier {
    let model: AppModel
    let botID: String
    let isPresented: Bool

    @State private var pendingAction: AttachmentSourceAction?

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { isPresented },
                set: { if !$0 { AttachmentRuntime.shared.chooserBotID = nil } }
            ),
            onDismiss: performPendingAction
        ) {
            AttachmentSourceSheet(
                theme: model.theme.pack,
                supportsPhotoLibrary: Self.supportsPhotoLibrary,
                allowsPaste: true,
                select: { action in
                    pendingAction = action
                    AttachmentRuntime.shared.chooserBotID = nil
                },
                close: {
                    pendingAction = nil
                    AttachmentRuntime.shared.chooserBotID = nil
                }
            )
        }
    }

    /// AttachmentPhotoPicker is iOS-only, even where PhotosUI is otherwise
    /// importable. Keep the chooser capability in lockstep with that picker.
    private static var supportsPhotoLibrary: Bool {
        #if os(iOS) && canImport(PhotosUI)
        true
        #else
        false
        #endif
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .photos:
            guard Self.supportsPhotoLibrary else {
                assertionFailure("Photo Library was selected without a picker")
                return
            }
            AttachmentRuntime.shared.photoBotID = botID
        case .files:
            AttachmentRuntime.shared.fileBotID = botID
        case .pasteImage:
            Task { await model.pasteAttachment(botID: botID) }
        }
    }
}

/// Documents, iCloud Drive, anything a file provider vends — the only picker
/// macOS gets in this build.
private struct AttachmentFileImporter: ViewModifier {
    let model: AppModel
    let botID: String
    let isPresented: Bool

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: Binding(
                get: { isPresented },
                set: { if !$0 { AttachmentRuntime.shared.fileBotID = nil } }),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { @MainActor in
                // Sequential: each attach is its own RPC and the gateway
                // queues them in call order.
                for url in urls {
                    await model.attachFileURL(url, botID: botID)
                }
            }
        }
    }
}

#if os(iOS) && canImport(PhotosUI)
/// PhotosPicker over the photo library. Items arrive as raw camera-roll bytes
/// (HEIC on any modern iPhone); `attachImageData` transcodes them.
private struct AttachmentPhotoPicker: ViewModifier {
    let model: AppModel
    let botID: String
    let isPresented: Bool

    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: Binding(
                    get: { isPresented },
                    set: { if !$0 { AttachmentRuntime.shared.photoBotID = nil } }),
                selection: $selection,
                maxSelectionCount: 6,
                matching: .images,
                photoLibrary: .shared())
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                Task { @MainActor in
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        await model.attachImageData(data, filename: Self.filename(for: item), botID: botID)
                    }
                }
            }
    }

    /// A PhotosPickerItem carries no filename; its content type names the
    /// container, which is what the transcoder needs to decide.
    private static func filename(for item: PhotosPickerItem) -> String {
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "heic"
        return "photo-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
    }
}
#else
/// macOS builds for compile parity only and has no photo library picker; the
/// document importer covers it.
private struct AttachmentPhotoPicker: ViewModifier {
    let model: AppModel
    let botID: String
    let isPresented: Bool

    func body(content: Content) -> some View { content }
}
#endif

// MARK: - Attachment copy (three voices, same shape as CopyPack proper)

extension CopyPack {
    func attachSourceTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Attach"
        case .control: "ATTACH PAYLOAD"
        case .ink: "affix a thing"
        }
    }

    func attachPhotos(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Photo library"
        case .control: "PHOTO LIBRARY"
        case .ink: "from the album"
        }
    }

    func attachFiles(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Files"
        case .control: "FILES"
        case .ink: "from the archive"
        }
    }

    func attachPaste(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Paste image"
        case .control: "PASTE IMAGE"
        case .ink: "from the clipboard"
        }
    }

    func attachRemove(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove attachment"
        case .control: "DETACH"
        case .ink: "unbind it"
        }
    }

    func attachUploading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "sending"
        case .control: "UPLINK"
        case .ink: "bearing"
        }
    }

    /// Desktop's implicit question when an image is sent with no words.
    func attachImageOnlyPrompt(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What do you see in this image?"
        case .control: "DESCRIBE THIS IMAGE."
        case .ink: "What do you make of this image?"
        }
    }

    func attachTooLarge(_ t: ThemeID, limitMB: Int) -> String {
        switch t {
        case .soft: "Too large to send — the gateway caps attachments at \(limitMB) MB."
        case .control: "PAYLOAD REJECTED — \(limitMB) MB CAP."
        case .ink: "Too heavy to carry — the way admits \(limitMB) MB at most."
        }
    }

    func attachTooManyPages(_ t: ThemeID, pages: Int) -> String {
        switch t {
        case .soft: "Too many pages — \(pages) per PDF is the limit."
        case .control: "PAGE RANGE REJECTED — \(pages) PAGE CAP."
        case .ink: "Too many leaves — \(pages) to a volume."
        }
    }

    func attachUnsupported(_ t: ThemeID) -> String {
        switch t {
        case .soft: "That file type can’t be attached."
        case .control: "UNSUPPORTED FORMAT — NOT ATTACHED."
        case .ink: "That thing cannot be affixed."
        }
    }

    func attachUnreadable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t read that file."
        case .control: "READ FAILED — FILE UNREADABLE."
        case .ink: "The file would not open to be read."
        }
    }

    /// pdf.attach 5028 — the gateway host has no poppler-utils, so it cannot
    /// render pages for the vision pipeline.
    func attachNoPDFRenderer(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway can’t read PDFs — it needs poppler-utils (pdftoppm) installed."
        case .control: "NO PDF RENDERER ON GATEWAY — INSTALL POPPLER-UTILS."
        case .ink: "This way cannot open volumes — poppler-utils is wanting."
        }
    }

    func attachOffline(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No link to the gateway — attach again once it’s back."
        case .control: "LINK DOWN — ATTACH ABORTED."
        case .ink: "The way is severed — affix it when the way returns."
        }
    }

    func attachClipboardEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing to paste — no image on the clipboard."
        case .control: "CLIPBOARD EMPTY — NO IMAGE."
        case .ink: "Nothing waits upon the clipboard."
        }
    }

    /// -32601 unknown method: an older backend without the attach surface.
    func attachGatewayTooOld(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway is too old to take attachments."
        case .control: "BACKEND CONTRACT TOO LOW — NO ATTACH SURFACE."
        case .ink: "This way is of an older making and takes no attachments."
        }
    }

    func attachFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t attach that."
        case .control: "ATTACH FAILED."
        case .ink: "It would not be affixed."
        }
    }
}

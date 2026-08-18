import SwiftUI
import TalariaKit
import TalariaTheme

#if os(iOS)
import PhotosUI
#endif

// The avatar picker — desktop Bot Mode's shape × color grid, its portrait
// generator and its image upload, in three themed voices.
//
// Ported from apps/desktop/src/plugins/hermes-bots/plugin.js `AvatarPicker`
// (1755-1968): tab pills over a 4-column shape grid whose cells preview in the
// CURRENT color, a 5-column color grid, a Generate tab with a free-text
// description (`image.generate`, 1786-1817), and an Upload tab that
// square-crops and downscales before it ever leaves the device (1663-1708).
// Desktop's fourth tab is the petdex gallery; pets have their own surface in
// Talaria and are deliberately not duplicated here.
//
// Two rules from the source carry over verbatim:
//
//   * **Everything is staged.** No tap writes to the gateway. Generate,
//     upload and remove all land in an `AvatarDraft` that Save commits — so
//     Cancel actually cancels (plugin.js:2056-2060).
//   * **A `false` availability probe is never sticky** (plugin.js:1710-1731):
//     the gateway may have been restarted with an image backend since, so
//     landing on the Generate tab re-asks.
//
// One deliberate deviation: desktop clears the image when a shape is tapped
// ("picking a shape drops the photo"). On a phone a stray tap while browsing
// hues would then quietly delete a portrait on the next Save, so the shape and
// hue stay live as the face *under* the portrait, and removing the portrait is
// its own explicit button.

@MainActor
public struct AvatarPicker: View {
    private let model: AppModel
    /// nil while the profile does not exist yet — a portrait needs something to
    /// hang off, so Generate and Upload wait for the first Save.
    private let botID: String?
    private let seedName: String
    private let seedJob: String
    private let seedSoul: String
    @Binding private var shape: AvatarShape
    @Binding private var hue: AvatarHue
    @Binding private var draft: AvatarDraft

    private enum Tab: String, CaseIterable { case look, generate, upload }

    @State private var tab: Tab = .look
    @State private var describe = ""
    @State private var generating = false
    @State private var note: PortraitFailure?
    /// nil = not probed yet (desktop's `$imagenAvailable` starts null).
    @State private var imagen: Bool?
    @State private var uploadFailed = false
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    #endif

    public init(model: AppModel, botID: String?,
                name: String, job: String, soul: String,
                shape: Binding<AvatarShape>, hue: Binding<AvatarHue>,
                draft: Binding<AvatarDraft>) {
        self.model = model
        self.botID = botID
        self.seedName = name
        self.seedJob = job
        self.seedSoul = soul
        _shape = shape
        _hue = hue
        _draft = draft
    }

    private var theme: ThemePack { model.theme.pack }

    /// The six roster hues in the prototype's DB.HUES order (no gateway grey).
    private static let hues: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]

    /// A portrait is on this bot's face right now — staged here, or already
    /// stored on the gateway and not marked for removal.
    private var hasImage: Bool {
        if draft.image != nil { return true }
        if draft.clearsImage { return false }
        guard let botID else { return false }
        return ProfileAssetStore.shared.hasPortrait(botID)
    }

    /// Portraits need a profile to attach to and a gateway to ask.
    private var portraitsPossible: Bool { botID != nil && model.mode == .live }

    private var tabs: [Tab] {
        #if os(iOS)
        portraitsPossible ? Tab.allCases : [.look]
        #else
        portraitsPossible ? [.look, .generate] : [.look]
        #endif
    }

    /// The tab actually rendered. A gateway that drops out mid-sheet takes
    /// Generate and Upload with it; the selection falls back rather than
    /// leaving the sheet on a tab that no longer has a row to click.
    private var activeTab: Tab { tabs.contains(tab) ? tab : .look }

    public var body: some View {
        VStack(spacing: 12) {
            if tabs.count > 1 { tabRow }
            switch activeTab {
            case .look: lookTab
            case .generate: generateTab
            case .upload: uploadTab
            }
            if hasImage {
                Button {
                    draft.image = nil
                    draft.clearsImage = true
                } label: {
                    Text(CopyPack.avatarRemoveImage(theme.id))
                        .font(subFont)
                        .foregroundStyle(theme.sub)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let note {
                Text(CopyPack.portraitFailure(note, theme.id))
                    .font(noteFont)
                    .foregroundStyle(theme.warn)
                    .multilineTextAlignment(.center)
            }
            if uploadFailed {
                Text(CopyPack.avatarUploadFailed(theme.id))
                    .font(noteFont)
                    .foregroundStyle(theme.warn)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: activeTab)
        #if os(iOS)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await stageUpload(item) }
        }
        #endif
    }

    // MARK: - Tabs

    private var tabRow: some View {
        HStack(spacing: 6) {
            ForEach(tabs, id: \.self) { candidate in
                let on = activeTab == candidate
                Button {
                    tab = candidate
                    // A stale "no image backend" is re-probed on arrival: the
                    // gateway may have restarted with one since.
                    if candidate == .generate, imagen != true { Task { await probe() } }
                } label: {
                    Text(CopyPack.avatarTab(candidate.rawValue, theme.id))
                        .font(tabFont)
                        .tracking(theme.id == .soft ? 0 : 1)
                        .foregroundStyle(on ? theme.ink : theme.faint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(tabBackground(on: on))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func tabBackground(on: Bool) -> some View {
        switch theme.id {
        case .soft:
            Capsule().fill(on ? theme.accent.opacity(0.12) : .clear)
        case .control:
            let cell = RoundedRectangle(cornerRadius: 5, style: .continuous)
            cell.fill(on ? theme.panel : .clear)
                .overlay(cell.stroke(on ? theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        case .ink:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(on ? theme.ink : .clear).frame(height: 1.5)
            }
        }
    }

    // MARK: - Look (shapes × hues)

    private var lookTab: some View {
        VStack(spacing: 12) {
            // Two rows of three rather than desktop's 4×2: six silhouettes at a
            // 44 pt touch target, which is the phone's floor, not a grid choice.
            VStack(spacing: 8) {
                ForEach(Array(shapeRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { candidate in
                            shapeCell(candidate)
                        }
                    }
                }
            }
            HStack(spacing: 9) {
                ForEach(Self.hues, id: \.self) { candidate in
                    hueSwatch(candidate)
                }
            }
            if hasImage {
                Text(CopyPack.avatarPortraitShowing(theme.id))
                    .font(noteFont)
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var shapeRows: [[AvatarShape]] {
        let all = AvatarShape.allCases
        return stride(from: 0, to: all.count, by: 3).map { Array(all[$0..<min($0 + 3, all.count)]) }
    }

    /// Cells preview in the CURRENT hue, so the grid answers "what would this
    /// bot look like" rather than showing six grey stencils (plugin.js:1878).
    private func shapeCell(_ candidate: AvatarShape) -> some View {
        let on = shape == candidate
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { shape = candidate }
        } label: {
            AvatarSilhouette(candidate)
                // Every cell wears the CURRENT hue, ghosted when unpicked, so
                // the grid answers "what would this bot look like" while still
                // reading at a glance as one chosen and five offered.
                .fill(theme.color(for: hue).opacity(on ? 1 : 0.45))
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .background(shapeWrap(on: on))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(candidate.rawValue))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Selection chrome per theme: soft = tinted rounded pad, control =
    /// terminal cell with accent border, ink = a 2 pt rule under the glyph.
    @ViewBuilder private func shapeWrap(on: Bool) -> some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? theme.accent.opacity(0.12) : .clear)
        case .control:
            let cell = RoundedRectangle(cornerRadius: 7, style: .continuous)
            cell.fill(theme.panel)
                .overlay(cell.stroke(on ? theme.accent.opacity(0.5) : theme.line, lineWidth: 1))
        case .ink:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(on ? theme.ink : .clear).frame(height: 2)
            }
        }
    }

    private func hueSwatch(_ candidate: AvatarHue) -> some View {
        let on = hue == candidate
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { hue = candidate }
        } label: {
            swatchShape
                .fill(theme.color(for: candidate))
                .frame(width: 26, height: 26)
                .overlay(swatchRing(on: on))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(candidate.rawValue))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Control renders square telemetry swatches; the others are dots.
    private var swatchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 13, style: .continuous)
    }

    /// Ink signals selection with a parchment gap + ink halo; the others use a
    /// plain ink border.
    @ViewBuilder private func swatchRing(on: Bool) -> some View {
        if on {
            if theme.id == .ink {
                swatchShape.inset(by: -2).stroke(theme.bg, lineWidth: 2)
                swatchShape.inset(by: -3.25).stroke(theme.ink, lineWidth: 1.5)
            } else {
                swatchShape.stroke(theme.ink, lineWidth: 2.5)
            }
        }
    }

    // MARK: - Generate (image.generate, staged)

    @ViewBuilder private var generateTab: some View {
        switch imagen {
        case .some(true):
            VStack(spacing: 8) {
                TextField(CopyPack.avatarDescribePlaceholder(theme.id), text: $describe,
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .font(fieldFont)
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    .background(fieldChrome)

                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 7) {
                        if generating { ProgressView().controlSize(.small) }
                        Text(generating ? CopyPack.portraitWorking(theme.id)
                                        : CopyPack.portraitGenerate(theme.id))
                            .font(actionFont)
                            .tracking(theme.id == .soft ? 0 : 1)
                    }
                    .foregroundStyle(generating ? theme.faint : theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(fieldChrome)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(generating)

                if describe.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(CopyPack.avatarBlankPromptNote(theme.id))
                        .font(noteFont)
                        .foregroundStyle(theme.faint)
                        .multilineTextAlignment(.center)
                }
            }
        case .some(false):
            Text(CopyPack.avatarNoImageBackend(theme.id))
                .font(noteFont)
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 6)
        case nil:
            Text(CopyPack.avatarProbing(theme.id))
                .font(noteFont)
                .foregroundStyle(theme.faint)
                .task { await probe() }
        }
    }

    private func probe() async {
        let available = await model.portraitGenerationAvailable()
        imagen = available
    }

    private func generate() async {
        guard let botID, !generating else { return }
        generating = true
        note = nil
        let typed = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank means "from the agent's name and description", exactly as the
        // hint under the field promises (plugin.js:1938-1942).
        let prompt = typed.isEmpty
            ? AppModel.portraitPrompt(name: seedName.isEmpty ? botID : seedName,
                                      job: seedJob, soul: seedSoul,
                                      shape: shape, hue: hue)
            : AppModel.portraitPrompt(describe: typed)
        switch await model.makePortrait(prompt: prompt) {
        case .image(let bytes):
            draft.image = bytes
            draft.clearsImage = false
        case .failure(let failure):
            note = failure
            // "No image provider" is the one failure that changes what the tab
            // should even offer.
            if failure == .unavailable { imagen = false }
        }
        generating = false
    }

    // MARK: - Upload

    @ViewBuilder private var uploadTab: some View {
        #if os(iOS)
        VStack(spacing: 8) {
            Button {
                showPhotoPicker = true
            } label: {
                Text(CopyPack.avatarChooseImage(theme.id))
                    .font(actionFont)
                    .tracking(theme.id == .soft ? 0 : 1)
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(fieldChrome)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(CopyPack.avatarUploadNote(theme.id))
                .font(noteFont)
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
        }
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Camera-roll bytes are HEIC and multi-megapixel; square-crop and
    /// downscale on the device before anything is staged, so the preview, the
    /// memory cost and the upload are all the same small JPEG.
    private func stageUpload(_ item: PhotosPickerItem) async {
        uploadFailed = false
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let normalized = AppModel.normalizedAvatarImage(raw) else {
            uploadFailed = true
            return
        }
        draft.image = normalized
        draft.clearsImage = false
        note = nil
    }
    #endif

    // MARK: - Fonts + chrome

    private var tabFont: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var subFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.body(13).italic()
        }
    }

    private var noteFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13).italic()
        }
    }

    private var actionFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .semibold)
        case .control: theme.mono(11, weight: .bold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var fieldFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5)
        case .control: theme.mono(12.5)
        case .ink: theme.body(15)
        }
    }

    @ViewBuilder private var fieldChrome: some View {
        switch theme.id {
        case .soft, .control:
            let shape = RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
            shape.fill(theme.panel).overlay(shape.stroke(theme.line, lineWidth: 1))
        case .ink:
            Rectangle().stroke(theme.lineStrong, lineWidth: 1)
        }
    }
}

// MARK: - Picker copy (the three voices)

extension CopyPack {

    static func avatarTab(_ id: String, _ t: ThemeID) -> String {
        switch (id, t) {
        case ("look", .soft): "Look"
        case ("look", .control): "LOOK"
        case ("look", .ink): "GUISE"
        case ("generate", .soft): "Portrait"
        case ("generate", .control): "GENERATE"
        case ("generate", .ink): "SITTING"
        case ("upload", .soft): "Photo"
        case ("upload", .control): "UPLOAD"
        case ("upload", .ink): "LIKENESS"
        default: id
        }
    }

    static func avatarDescribePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Describe the portrait you want…"
        case .control: "DESCRIBE THE PORTRAIT…"
        case .ink: "describe the likeness you would have drawn…"
        }
    }

    static func avatarBlankPromptNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Leave blank to paint from the bot’s name, job and soul."
        case .control: "BLANK = GENERATE FROM NAME · JOB · SOUL.MD"
        case .ink: "Left blank, the limner works from the familiar’s own papers."
        }
    }

    static func avatarNoImageBackend(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "This gateway has no image model. If you just enabled one, restart the gateway and come back."
        case .control:
            "NO IMAGE BACKEND ON GATEWAY. ENABLE ONE AND RESTART THE GATEWAY."
        case .ink:
            "This gateway keeps no limner. Engage one and wake the gateway anew."
        }
    }

    static func avatarProbing(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Checking for an image model…"
        case .control: "PROBING IMAGE BACKEND…"
        case .ink: "asking after a limner…"
        }
    }

    static func avatarChooseImage(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Choose a photo"
        case .control: "CHOOSE AN IMAGE"
        case .ink: "offer a likeness"
        }
    }

    static func avatarUploadNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Cropped square and shrunk on this phone before it is saved to the profile."
        case .control: "SQUARE-CROPPED + DOWNSCALED ON DEVICE BEFORE UPLOAD."
        case .ink: "Trimmed square and made small here, before it is entrusted to the profile."
        }
    }

    static func avatarUploadFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "That image couldn’t be read. Try another one."
        case .control: "IMAGE UNREADABLE — TRY ANOTHER."
        case .ink: "That likeness could not be read. Offer another."
        }
    }

    static func avatarRemoveImage(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove portrait — use the shape"
        case .control: "CLEAR PORTRAIT — USE SHAPE"
        case .ink: "take down the likeness — keep the guise"
        }
    }

    static func avatarPortraitShowing(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A portrait is this bot’s face right now; the shape and colour sit under it."
        case .control: "PORTRAIT ACTIVE — SHAPE + HUE ARE THE FALLBACK FACE."
        case .ink: "A likeness stands in for the guise; the sign beneath it is kept."
        }
    }
}

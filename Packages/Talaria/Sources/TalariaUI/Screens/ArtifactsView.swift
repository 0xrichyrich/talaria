import SwiftUI
import AVKit
import TalariaKit
import TalariaTheme

// The Artifacts tab — Artifacts / Vault / The Relics. A two-column grid of
// everything the roster produced: images show the real thumbnail once the
// bytes land, files an extension chip in the owner bot's color, links an
// accented URL. Ported from Talaria.dc.html `data-screen-label="Artifacts"`.
//
// Two halves, and they are honest about being different things:
//
//  · The INDEX is derived (AppModelLive+Feeds.swift). There is no artifacts
//    endpoint on the gateway; desktop builds its /artifacts gallery client-side
//    by scanning session transcripts (artifact-utils.ts) and so does this —
//    recent sessions per profile → GET /api/sessions/<id>/messages → produced
//    files, images and links, plus anything a tool.complete announces live.
//  · The BYTES are real (AppModelLive+Artifacts.swift). Tapping a card fetches
//    the file from the gateway host over its authenticated media/file routes
//    and previews it: image viewer, text/code viewer, share-sheet export.
//
// The footnote says both out loud, because "6 artifacts" that came from a regex
// over transcripts is a different claim from "6 artifacts the server has on
// file", and "previewed on your phone" is a different claim from "stored there".

public struct ArtifactsView: View {
    private let model: AppModel

    @State private var filter: ArtifactKind?
    @State private var opened: Artifact?

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var feeds: FeedsRuntime { FeedsRuntime.shared }

    private var shown: [Artifact] {
        guard let filter else { return model.artifacts }
        return model.artifacts.filter { $0.kind == filter }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, artifact in
                        ArtifactCard(model: model,
                                     artifact: artifact,
                                     owner: model.bot(artifact.botID),
                                     theme: theme) {
                            opened = artifact
                        }
                        .modifier(RowEntrance(delay: Double(min(index, 12)) * 0.045))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if shown.isEmpty { emptyState }
                footnote
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .sheet(item: $opened) { artifact in
            ArtifactDetailSheet(model: model, artifact: artifact)
        }
        .task {
            model.attachActivityRouter()
            await model.refreshArtifacts()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if theme.showsKicker {
                        Text(verbatim: "\(copy.kickerArtifacts) · \(model.artifacts.count)")
                            .font(theme.mono(9.5, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                            .padding(.bottom, theme.id == .control ? 3 : 1)
                    }
                    Text(copy.titleArtifacts)
                        .font(titleFont)
                        .tracking(theme.smallCapsTitles ? 0.5 : -0.5)
                        .foregroundStyle(theme.ink)
                }
                Spacer(minLength: 6)
                if model.mode == .live {
                    HeaderIconButton(theme: theme, size: 32) {
                        Task { await model.refreshArtifacts(force: true) }
                    } glyph: {
                        Text(verbatim: "↻")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                            .opacity(feeds.artifactsScanning ? 0.4 : 1)
                    }
                    .disabled(feeds.artifactsScanning)
                }
            }
            Text(copy.artifactsLead)
                .font(leadFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .padding(.top, 4)
            filterRow
                .padding(.top, 9)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Type filters, desktop's /artifacts chips. Hidden while there is nothing
    /// to filter so an empty tab stays quiet.
    @ViewBuilder private var filterRow: some View {
        if !model.artifacts.isEmpty {
            HStack(spacing: 7) {
                ForEach(Array([nil, ArtifactKind.image, .media, .file, .link].enumerated()), id: \.offset) { _, kind in
                    let count = kind.map { k in model.artifacts.filter { $0.kind == k }.count }
                        ?? model.artifacts.count
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { filter = kind }
                    } label: {
                        Text(verbatim: "\(copy.artifactFilter(theme.id, kind: kind)) \(count)")
                            .font(theme.id == .control ? theme.mono(9.5, weight: .semibold)
                                                       : theme.body(11.5, weight: .semibold))
                            .foregroundStyle(filter == kind ? theme.accent : theme.sub)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .chipShell(theme)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(feeds.artifactsScanning ? copy.scanningLabel(theme.id)
                                         : copy.artifactsEmptyTitle(theme.id))
                .font(theme.id == .control ? theme.mono(12, weight: .bold)
                                           : theme.body(15, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(copy.artifactsEmptyBody(theme.id))
                .font(footFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.faint)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 26)
    }

    /// Honest provenance, in two sentences: the index is derived on-device, and
    /// the bytes are pulled from the gateway on demand. Only shown once a live
    /// sweep has actually run — the empty state carries the explanation before
    /// that, and demo content makes no such claim.
    @ViewBuilder private var footnote: some View {
        if model.mode == .live, !feeds.artifactsNote.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(feeds.artifactsNote)
                Text(copy.artifactsFetchNote(theme.id))
            }
            .font(footFont)
            .italic(theme.id == .ink)
            .foregroundStyle(theme.faint)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 120) // clear the tab bar
        } else {
            Color.clear.frame(height: 120)
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.display(31)
        case .control: theme.display(27)
        case .ink: theme.display(28).smallCaps()
        }
    }

    private var leadFont: Font {
        theme.body(theme.id == .ink ? 14 : 12.5)
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

// MARK: - Card

private struct ArtifactCard: View {
    let model: AppModel
    let artifact: Artifact
    let owner: Bot?
    let theme: ThemePack
    let open: () -> Void

    @State private var copied = false

    private var copy: CopyPack { model.theme.copy }

    private var ownerColor: Color {
        theme.color(for: owner?.hue ?? .teal)
    }

    private var location: String { model.artifactLocation(artifact) }

    /// The directory the file sits in — the half `title` throws away. Shown so
    /// two same-named outputs from different runs can be told apart.
    private var locationLine: String {
        guard artifact.kind != .link else { return "" }
        let label = ArtifactScan.label(of: location)
        guard location != label else { return "" }
        return String(location.dropLast(label.count))
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                figure
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
                    .overlay(alignment: .bottom) {
                        theme.artCardBorder.frame(height: 1)
                    }
                caption
            }
        }
        .buttonStyle(.plain)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.artCardBorder, lineWidth: 1)
        )
        .shadow(color: theme.rowStyle == .card ? theme.ink.opacity(0.04) : .clear,
                radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .contextMenu {
            Button(copy.artifactCopyPath(theme.id, kind: artifact.kind)) {
                model.copyArtifactLocation(artifact)
                copied = true
            }
            Button(copy.artifactOpenSession(theme.id)) { model.openArtifact(artifact) }
        }
        // Thumbnails are pulled per card, not in one gallery-wide sweep: the
        // grid is lazy, so only what you actually scrolled to costs a request.
        .task(id: artifact.id) { model.prefetchArtifactThumbnail(artifact) }
    }

    @ViewBuilder
    private var figure: some View {
        switch artifact.kind {
        case .image:
            ZStack {
                if let thumb = model.artifactThumbnail(artifact) {
                    thumb
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Striped placeholder (the design's artStripe token) while
                    // the bytes are in flight, or when the gateway will not
                    // serve them — the detail sheet says which.
                    DiagonalStripes(stripeWidth: 8)
                        .fill(theme.artStripeStrong)
                        .background(theme.artStripeFaint)
                    Text(artifact.title)
                        .font(theme.mono(9))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
            }
            .clipped()
        case .file:
            Text(artifact.ext ?? "FILE")
                .font(theme.mono(10, weight: .heavy))
                .tracking(1)
                .foregroundStyle(ownerColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(ownerColor, lineWidth: 1.5))
        case .media:
            Text(artifact.ext ?? "MEDIA")
                .font(theme.mono(10, weight: .heavy))
                .tracking(1)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: 1.5))
        case .link:
            Text(artifact.title)
                .font(theme.mono(10))
                .underline()
                .foregroundStyle(theme.accent)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 10)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artifact.title)
                .font(titleFont)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if copied {
                Text(copy.artifactCopied(theme.id))
                    .font(theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(theme.ok)
                    .lineLimit(1)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
            } else if !locationLine.isEmpty {
                Text(locationLine)
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(artifact.meta)
                    .font(theme.id == .control ? theme.mono(10)
                                               : theme.body(theme.id == .ink ? 13 : 12))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 5) {
                if let owner {
                    AvatarView(shape: owner.shape, hue: owner.hue, size: 14, theme: theme)
                }
                // `owner` is the roster row when the bot is still listed; the
                // id alone still resolves through the one identity path.
                Text(TalariaVoice.displayName(owner, id: artifact.botID, theme.id))
                    .font(ownerNameFont)
                    .foregroundStyle(ownerColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(artifact.when)
                    .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.faint)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Links keep their mono/URL identity in the caption too.
    private var titleFont: Font {
        if artifact.kind == .link { return theme.mono(theme.id == .ink ? 12 : 11.5, weight: .semibold) }
        switch theme.id {
        case .soft: return theme.body(13.5, weight: .semibold)
        case .control: return theme.body(13, weight: .semibold)
        case .ink: return theme.body(15.5, weight: .semibold)
        }
    }

    private var ownerNameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15, weight: .bold).smallCaps()
        }
    }
}

// MARK: - Detail (the preview + the verbs)

/// One artifact, opened. Image artifacts get a pinch-zoom viewer, text and code
/// a monospaced reader with the gateway's own language hint, everything else an
/// export path — and links are offered to the browser rather than inlined.
@MainActor
private struct ArtifactDetailSheet: View {
    let model: AppModel
    let artifact: Artifact

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var fetched: ArtifactBody?
    @State private var exported: ExportedFile?
    @State private var exporting = false
    @State private var note: String?

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var location: String { model.artifactLocation(artifact) }
    private var owner: Bot? { model.bot(artifact.botID) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(theme: theme, kicker: kicker, title: artifact.title) {
                HeaderIconButton(theme: theme, action: { dismiss() }) {
                    Text(verbatim: "✕")
                        .font(theme.body(13, weight: .bold))
                        .foregroundStyle(theme.id == .ink ? theme.ink : theme.sub)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    preview
                    locationCard
                    if let note {
                        Text(note)
                            .font(theme.id == .control ? theme.mono(10) : theme.body(12))
                            .foregroundStyle(theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .presentationDetents([.large])
        .sheet(item: $exported) { file in
            #if os(iOS)
            TalariaShareSheet(items: [file.url]) { exported = nil }
            #else
            EmptyView()
            #endif
        }
        .task(id: artifact.id) {
            // Links are never fetched — see AppModelLive+Artifacts.swift. An
            // image URL is, because opening the card IS the user asking for it.
            fetched = await model.loadArtifact(artifact, allowRemote: artifact.kind == .image || artifact.kind == .media)
        }
    }

    private var kicker: String {
        artifact.meta.isEmpty ? copy.kickerArtifacts : artifact.meta
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        switch fetched {
        case .none:
            loadingCard
        case .image(let data):
            if let image = ArtifactImaging.full(data) {
                ZoomableImage(image: image)
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
                    .background(theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
            } else {
                noticeCard(copy.artifactBinaryBody(theme.id), tone: theme.sub)
            }
        case .text(let text, let language, let truncated, let bytes):
            textCard(text, language: language, truncated: truncated, bytes: bytes)
        case .binary(_, let mime):
            noticeCard(copy.artifactBinaryBody(theme.id), tone: theme.sub, detail: mime)
        case .media(let url):
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .unavailable(let why):
            noticeCard(copy.artifactUnavailable(theme.id, why),
                       tone: why == .remoteLink ? theme.sub : theme.warn)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(theme.accent)
            Text(copy.artifactLoading(theme.id))
                .font(theme.id == .control ? theme.mono(10.5) : theme.body(12.5))
                .foregroundStyle(theme.sub)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    private func noticeCard(_ text: String, tone: Color, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text)
                .font(theme.id == .control ? theme.mono(10.5) : theme.body(12.5))
                .italic(theme.id == .ink)
                .foregroundStyle(tone)
                .lineSpacing(3)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(theme.mono(9.5))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 13, bottom: 13, trailing: 13))
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    /// Code and prose alike: monospaced, horizontally scrollable so a long line
    /// is not reflowed into nonsense, and selectable so a snippet can be lifted
    /// straight back into the composer.
    private func textCard(_ text: String, language: String, truncated: Bool,
                          bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.uppercased())
                    .font(theme.mono(9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 6)
                Text(copy.artifactSize(theme.id, bytes: bytes))
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.inset)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }

            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(theme.mono(11))
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)

            if truncated {
                Text(copy.artifactTruncated(theme.id))
                    .font(theme.id == .control ? theme.mono(9) : theme.body(11))
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { theme.line.frame(height: 1) }
            }
        }
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    /// The full path or URL. `title` is only the last component, so this is the
    /// line that tells two same-named outputs apart.
    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location)
                .font(theme.mono(10))
                .foregroundStyle(theme.sub)
                .textSelection(.enabled)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let owner {
                    AvatarView(shape: owner.shape, hue: owner.hue, size: 13, theme: theme)
                }
                Text(TalariaVoice.displayName(owner, id: artifact.botID, theme.id))
                    .font(theme.id == .control ? theme.mono(10, weight: .bold)
                                               : theme.body(12, weight: .bold))
                    .foregroundStyle(theme.color(for: owner?.hue ?? .teal))
                Spacer(minLength: 4)
                Text(artifact.when)
                    .font(theme.mono(9.5))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .background(theme.inset,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    // MARK: Verbs

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            if artifact.kind == .link || isRemote {
                ThemedPrimaryButton(theme: theme, title: copy.artifactOpenLink(theme.id)) {
                    guard let url = URL(string: location) else { return }
                    openURL(url)
                }
            }
            if canShare {
                actionRow(copy.artifactShare(theme.id), busy: exporting) { share() }
            }
            actionRow(copy.artifactCopyPath(theme.id, kind: artifact.kind)) {
                model.copyArtifactLocation(artifact)
                withAnimation(.easeOut(duration: 0.2)) { note = copy.artifactCopied(theme.id) }
            }
            actionRow(copy.artifactOpenSession(theme.id)) {
                dismiss()
                model.openArtifact(artifact)
            }
        }
        .padding(.top, 2)
    }

    private var isRemote: Bool {
        location.hasPrefix("http://") || location.hasPrefix("https://")
    }

    /// Share only when there is something to hand over — a link has no bytes,
    /// and a failed fetch must not offer an export that cannot happen.
    private var canShare: Bool {
        switch fetched {
        case .image, .text, .binary, .media: return true
        case .none, .unavailable: return false
        }
    }

    private func actionRow(_ title: String, busy: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                               : theme.body(13.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.small).tint(theme.accent)
                } else {
                    Text(verbatim: "›")
                        .font(theme.body(13, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
            .frame(maxWidth: .infinity)
            .background(theme.panel,
                        in: RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private func share() {
        guard !exporting else { return }
        exporting = true
        Task { @MainActor in
            let result = await model.artifactShareFile(artifact)
            exporting = false
            switch result {
            case .success(let url):
                #if os(iOS)
                exported = ExportedFile(url: url)
                #else
                // No share sheet on the Mac build; the staged copy's path is
                // the useful answer there.
                withAnimation(.easeOut(duration: 0.2)) { note = url.path }
                #endif
            case .failure(let why):
                withAnimation(.easeOut(duration: 0.2)) {
                    note = copy.artifactUnavailable(theme.id, why)
                }
            }
        }
    }
}

// MARK: - Zoomable image

/// Pinch to zoom, drag to pan, double-tap to fit. Deliberately gesture-only —
/// a generated render is the payoff of a whole turn, and the phone should get
/// out of its way.
private struct ZoomableImage: View {
    let image: Image

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(committed * value.magnification, 1), maxScale)
                        }
                        .onEnded { _ in
                            committed = scale
                            if scale <= 1 { reset() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: committedOffset.width + value.translation.width,
                                            height: committedOffset.height + value.translation.height)
                        }
                        .onEnded { _ in committedOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.22)) {
                        if scale > 1 { reset() } else { scale = 2.5; committed = 2.5 }
                    }
                }
                .clipped()
        }
    }

    private func reset() {
        scale = 1; committed = 1
        offset = .zero; committedOffset = .zero
    }
}

// MARK: - Striped placeholder pattern (the design's `artStripe` token)

private struct DiagonalStripes: Shape {
    var stripeWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period = stripeWidth * 2
        // 45° bands: each stripe is a parallelogram sheared by rect.height.
        var x = rect.minX - rect.height - period
        while x < rect.maxX + period {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripeWidth + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.closeSubpath()
            x += period
        }
        return path
    }
}

private extension ThemePack {
    /// Strong stripe of the image-placeholder pattern, derived from the pack.
    var artStripeStrong: Color {
        switch id {
        case .soft: ink.opacity(0.07)
        case .control: accent.opacity(0.10)
        case .ink: ink.opacity(0.12)
        }
    }

    /// Faint stripe (the pattern's background band).
    var artStripeFaint: Color {
        switch id {
        case .soft: ink.opacity(0.02)
        case .control: accent.opacity(0.03)
        case .ink: ink.opacity(0.04)
        }
    }

    /// Card outline for artifact tiles (ink draws a full ledger rule).
    var artCardBorder: Color {
        switch id {
        case .soft: ink.opacity(0.06)
        case .control: lineStrong.opacity(0.7)
        case .ink: lineStrong
        }
    }
}

// MARK: - Shared row helpers (file-scoped copies; each screen file keeps its own)

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4).delay(delay)) { shown = true }
            }
    }
}

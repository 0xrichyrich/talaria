import SwiftUI
import TalariaKit
import TalariaTheme

// The Artifacts tab — Artifacts / Vault / The Relics. A two-column grid of
// everything the roster produced: images get a striped placeholder thumb,
// files an extension chip in the owner bot's color, links an accented URL.
// Ported from Talaria.dc.html `data-screen-label="Artifacts"`.
//
// Live derivation (AppModelLive+Feeds.swift): there is NO artifacts endpoint on
// the gateway. Desktop builds its /artifacts gallery client-side by scanning
// session transcripts (artifact-utils.ts), and so does this: recent sessions
// per profile → GET /api/sessions/<id>/messages → produced files, images and
// links pulled out of assistant prose and producer-tool results, plus anything
// a tool.complete announces while the app is open. The footnote says so out
// loud, because "6 artifacts" that came from a regex over transcripts is a
// different claim from "6 artifacts the server has on file".

public struct ArtifactsView: View {
    private let model: AppModel

    @State private var filter: ArtifactKind?

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
                        ArtifactCard(artifact: artifact,
                                     owner: model.bot(artifact.botID),
                                     theme: theme) {
                            model.openArtifact(artifact)
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
                ForEach(Array([nil, ArtifactKind.image, .file, .link].enumerated()), id: \.offset) { _, kind in
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

    /// Honest provenance: this index is derived on-device, not served. Only
    /// shown once a live sweep has actually run — the empty state carries the
    /// explanation before that, and demo content makes no such claim.
    @ViewBuilder private var footnote: some View {
        if model.mode == .live, !feeds.artifactsNote.isEmpty {
            Text(feeds.artifactsNote)
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
    let artifact: Artifact
    let owner: Bot?
    let theme: ThemePack
    let open: () -> Void

    private var ownerColor: Color {
        theme.color(for: owner?.hue ?? .teal)
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
    }

    @ViewBuilder
    private var figure: some View {
        switch artifact.kind {
        case .image:
            // Striped placeholder thumb (the design's artStripe token). The
            // bytes live on the gateway host; nothing is fetched here.
            ZStack {
                DiagonalStripes(stripeWidth: 8)
                    .fill(theme.artStripeStrong)
                    .background(theme.artStripeFaint)
                Text(artifact.title)
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
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
            Text(artifact.meta)
                .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.sub)
                .lineLimit(1)
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

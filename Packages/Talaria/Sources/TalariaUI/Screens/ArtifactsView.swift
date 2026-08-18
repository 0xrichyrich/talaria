import SwiftUI
import TalariaKit
import TalariaTheme

// The Artifacts tab — Artifacts / Vault / The Relics. A two-column grid of
// everything the roster produced: images get a striped placeholder thumb,
// files an extension chip in the owner bot's color, links an accented URL.
// Tapping a card jumps to the owning bot's chat.
// Ported from Talaria.dc.html `data-screen-label="Artifacts"`.

public struct ArtifactsView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(model.artifacts.enumerated()), id: \.element.id) { index, artifact in
                        ArtifactCard(artifact: artifact,
                                     owner: model.bot(artifact.botID),
                                     theme: theme) {
                            openOwnerChat(of: artifact)
                        }
                        .modifier(RowEntrance(delay: Double(index) * 0.045))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
    }

    private var header: some View {
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
            Text(copy.artifactsLead)
                .font(leadFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
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

    private func openOwnerChat(of artifact: Artifact) {
        model.selectedTab = .home
        model.openBotID = artifact.botID
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
            // Striped placeholder thumb (the design's artStripe token).
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
                .truncationMode(.tail)
            Text(artifact.meta)
                .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.sub)
                .lineLimit(1)
            HStack(alignment: .center, spacing: 5) {
                if let owner {
                    AvatarView(shape: owner.shape, hue: owner.hue, size: 14, theme: theme)
                }
                Text(themedBotName(artifact.botID, theme: theme))
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

private func themedBotName(_ id: String, theme: ThemePack) -> String {
    theme.id == .ink ? id.prefix(1).uppercased() + id.dropFirst() : "@" + id
}

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

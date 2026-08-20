import SwiftUI
import TalariaTheme

/// A source selected in Talaria's attachment sheet. The presenting composer
/// dismisses the sheet first, then opens the corresponding system picker from
/// its `onDismiss` callback. That explicit handoff avoids stacked
/// presentations and timing-dependent delays.
public enum AttachmentSourceAction: String, CaseIterable, Equatable, Sendable {
    case photos
    case files
    case pasteImage
}

public struct AttachmentSourceOption: Identifiable, Equatable, Sendable {
    public let action: AttachmentSourceAction
    public let title: String
    public let detail: String
    public let systemImage: String

    public var id: AttachmentSourceAction { action }
}

/// Presentation data is kept outside the view so the available actions and
/// accessibility copy can be certified without presenting PhotosUI in tests.
public enum AttachmentSourcePresentation {
    public static let title = "Add to message"
    public static let minimumRowHeight: CGFloat = 56

    /// Only advertise sources the presenter can actually open. Keeping this
    /// explicit avoids a dead Photo Library row on targets without PhotosUI.
    public static func options(
        supportsPhotoLibrary: Bool = false,
        allowsPaste: Bool
    ) -> [AttachmentSourceOption] {
        var result: [AttachmentSourceOption] = []
        if supportsPhotoLibrary {
            result.append(AttachmentSourceOption(
                action: .photos,
                title: "Photo Library",
                detail: "Choose up to 6 photos",
                systemImage: "photo.on.rectangle.angled"
            ))
        }
        result.append(
            AttachmentSourceOption(
                action: .files,
                title: "Files",
                detail: "Browse files and documents",
                systemImage: "folder"
            )
        )
        if allowsPaste {
            result.append(AttachmentSourceOption(
                action: .pasteImage,
                title: "Paste Image",
                detail: "Use an image from the clipboard",
                systemImage: "doc.on.clipboard"
            ))
        }
        return result
    }
}

/// Talaria-owned source chooser. The actual photo and document surfaces remain
/// Apple's system pickers; this sheet only replaces the cramped action menu.
public struct AttachmentSourceSheet: View {
    public let theme: ThemePack
    public let supportsPhotoLibrary: Bool
    public let allowsPaste: Bool
    public let select: (AttachmentSourceAction) -> Void
    public let close: () -> Void

    @Environment(\.talariaReducedMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var headingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var rowTitleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 38
    @AccessibilityFocusState private var headingFocused: Bool

    public init(
        theme: ThemePack,
        supportsPhotoLibrary: Bool = false,
        allowsPaste: Bool = true,
        select: @escaping (AttachmentSourceAction) -> Void,
        close: @escaping () -> Void
    ) {
        self.theme = theme
        self.supportsPhotoLibrary = supportsPhotoLibrary
        self.allowsPaste = allowsPaste
        self.select = select
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AttachmentSourcePresentation.title)
                    .font(theme.body(headingSize, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(theme.inset, in: Circle())
                        .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close attachment options")
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle().fill(theme.line).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(AttachmentSourcePresentation.options(
                        supportsPhotoLibrary: supportsPhotoLibrary,
                        allowsPaste: allowsPaste
                    )) { option in
                        sourceRow(option)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(theme.ink)
        .background(theme.bg.ignoresSafeArea())
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(theme.bg)
        .transaction { transaction in
            if reducedMotion { transaction.animation = nil }
        }
        .onAppear { headingFocused = true }
    }

    private func sourceRow(_ option: AttachmentSourceOption) -> some View {
        Button { select(option.action) } label: {
            HStack(spacing: 14) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: iconSide, height: iconSide)
                    .background(theme.accent.opacity(0.12), in: iconShape)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(theme.body(rowTitleSize, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(option.detail)
                        .font(theme.body(detailSize))
                        .foregroundStyle(theme.faint)
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: AttachmentSourcePresentation.minimumRowHeight,
                   alignment: .leading)
            .background(theme.panel, in: rowShape)
            .overlay(rowShape.strokeBorder(theme.line, lineWidth: 1))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        // The button supplies its label and hint below. Ignoring the visual
        // children prevents VoiceOver from announcing the title/detail twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.detail)
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(12, min(theme.cardRadius, 20)), style: .continuous)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(8, iconSide * theme.iconCornerFraction), style: .continuous)
    }
}

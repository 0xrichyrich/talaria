import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(EventKit)
import EventKit
#endif
#if os(iOS)
import UIKit
#endif

// Solo settings — roadmap Phase 5, docs/SOLO-MODE.md.
//
// Three jobs, in the order a person needs them:
//
//   1. WHICH ENGINE. Apple's on-device model, a model you downloaded, or Nous
//      Portal — each row showing what it actually is on THIS device rather than
//      what it is in general. An unavailable tier says why and, where the cause
//      is fixable, offers the fix.
//   2. THE MODEL. The MLX catalogue with its measured download size, peak
//      memory and whether this phone can hold it, plus delete.
//   3. WHAT SOLO MAY TOUCH. The seven permissions, each with its own switch,
//      its own "how often does it ask", and the concrete things it is scoped to
//      — the folders you granted, the images you shared, the shortcuts you
//      named. Then the standing "always" grants, with a way to take them back.
//
// The screen's own rule: a control that cannot do anything is not shown as a
// control. If this build does not link the MLX package the download buttons are
// absent and the catalogue is labelled as information; if this build has no
// EventKit usage description the calendar switch says so rather than offering a
// toggle that would terminate the app when flipped.
//
// Everything here is device-local. There is no gateway RPC on this screen
// because Solo has no gateway — which is also why nothing on it is guarded on
// `model.mode == .live`.

public struct SoloSettingsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var foundation: SoloEngineAvailability = .unavailable(.unknown)
    @State private var localeSupported = true
    @State private var portalSignedIn = false

    public init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    engineSection
                        .settingsEntrance(delay: 0, reduced: reducedMotion)
                    modelSection
                        .settingsEntrance(delay: 0.05, reduced: reducedMotion)
                    SoloPermissionsSection(model: model)
                        .settingsEntrance(delay: 0.1, reduced: reducedMotion)
                    SoloAllowlistSection(model: model)
                        .settingsEntrance(delay: 0.15, reduced: reducedMotion)
                    SoloStorageSection(model: model)
                        .settingsEntrance(delay: 0.2, reduced: reducedMotion)
                    explainerSection
                        .settingsEntrance(delay: 0.24, reduced: reducedMotion)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .talariaTextSize(model)
        .task { probe() }
    }

    private func probe() {
        foundation = SoloEngineProbe.foundationModels()
        localeSupported = FoundationModelsProvider.supportsCurrentLocale()
        portalSignedIn = NousPortalTokenStore()
            .load(portalURL: PortalDirectoryAPI.resolvedPortalURL) != nil
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(backShape)
                    .overlay(backShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copy.settingsBack(theme.id)))

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.soloKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(copy.soloSettingsTitle(theme.id))
                    .font(titleFont)
                    .foregroundStyle(theme.ink)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var backShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    // MARK: Engine

    private var store: SoloSettingsStore { SoloSettingsStore.shared }

    private var engineSection: some View {
        SettingsSection(theme: theme, title: copy.soloEngineSection(theme.id),
                        footnote: copy.soloEnginePickNote(theme.id)) {
            SettingsSegmented(theme: theme,
                              options: SoloEngineID.allCases.map {
                                  ($0, copy.soloEngineShort($0, theme.id))
                              },
                              selection: store.engine) { store.engine = $0 }

            SettingsGroup(theme: theme) {
                engineRow(.foundation, availability: foundation, isLast: false)
                engineRow(.mlx, availability: SoloEngineProbe.mlx(), isLast: false)
                engineRow(.portal, availability: SoloEngineProbe.portal(isSignedIn: portalSignedIn),
                          isLast: true)
            }

            // Availability is not the only way the default can fail a person:
            // Apple ships a bounded language set, and an unsupported locale
            // throws mid-turn rather than at the door. Saying it here is the
            // difference between a setting and a trap.
            if foundation.isAvailable, !localeSupported {
                noticeLine(copy.soloLocaleUnsupported(theme.id))
            }
        }
    }

    private func engineRow(_ engine: SoloEngineID, availability: SoloEngineAvailability,
                           isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.soloEngineName(engine, theme.id))
                        .font(SettingsType.rowTitle(theme))
                        .foregroundStyle(theme.ink)
                    Text(copy.soloEngineDetail(engine, theme.id))
                        .font(SettingsType.rowSubtitle(theme))
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Circle()
                        .fill(availability.isAvailable ? theme.ok : theme.faint)
                        .frame(width: 6, height: 6)
                    Text(availability.isAvailable
                         ? copy.soloReady(theme.id)
                         : copy.soloReasonTag(availability.reason ?? .unknown, theme.id))
                        .font(theme.mono(9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(availability.isAvailable ? theme.ok : theme.faint)
                }
            }

            if let action = remedy(for: engine, availability: availability) {
                SoloSmallButton(theme: theme, title: action.title, tone: theme.accent,
                                action: action.run)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private struct Remedy {
        var title: String
        var run: () -> Void
    }

    /// Only offered where there is something a person can actually do from
    /// here. "Device not eligible" gets no button, because a button that cannot
    /// help is worse than the plain sentence beside it.
    private func remedy(for engine: SoloEngineID,
                        availability: SoloEngineAvailability) -> Remedy? {
        guard let reason = availability.reason else { return nil }
        switch (engine, reason) {
        #if os(iOS)
        case (.foundation, .appleIntelligenceOff):
            return Remedy(title: copy.soloOpenSystemSettings(theme.id)) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        #endif
        case (.portal, .notSignedIn):
            return Remedy(title: copy.soloPortalSignIn(theme.id)) {
                if let onBack { onBack() } else { dismiss() }
                NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
            }
        default:
            return nil
        }
    }

    private func noticeLine(_ text: String) -> some View {
        Text(text)
            .font(theme.mono(10.5))
            .foregroundStyle(theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: Model management

    private var modelSection: some View {
        SoloModelSection(model: model)
    }

    // MARK: Explainer

    private var explainerSection: some View {
        SettingsSection(theme: theme, title: copy.soloExplainerSection(theme.id),
                        footnote: copy.soloExplainerNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme, title: copy.soloExplainerRow(theme.id),
                            subtitle: copy.soloExplainerRowSub(theme.id),
                            showsChevron: true, isLast: true) {
                    NotificationCenter.default.post(name: .talariaOpenSoloExplainer, object: nil)
                }
            }
        }
    }
}

// MARK: - Model management

/// The MLX catalogue.
///
/// `SoloToolHost.modelHost` is the seam: `TalariaLocal` is a separate package so
/// MLX's Metal kernels never enter the default app target
/// (docs/LOCAL-INFERENCE.md), and it installs itself here when the build links
/// it. With no host the catalogue is still worth showing — the sizes and the
/// fit test are real facts about this device and this phone's storage — but it
/// is labelled as information and carries no buttons, because a Download button
/// with nothing behind it is the worst row on any screen.
struct SoloModelSection: View {
    let model: AppModel

    @State private var downloaded: [String] = []
    @State private var progress: [String: Double] = [:]
    @State private var busy: String?
    @State private var failure: String?
    @State private var deleting: SoloModelSpec?

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var host: (any SoloModelHost)? { SoloToolHost.shared.modelHost }

    var body: some View {
        SettingsSection(theme: theme, title: copy.soloModelSection(theme.id),
                        footnote: host == nil ? copy.soloModelNoHost(theme.id)
                                              : copy.soloModelNote(theme.id)) {
            SettingsGroup(theme: theme) {
                ForEach(Array(SoloModelCatalog.all.enumerated()), id: \.element.id) { index, spec in
                    row(spec, isLast: index == SoloModelCatalog.all.count - 1)
                }
            }
            if let failure {
                Text(failure)
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .task { refresh() }
        .confirmationDialog(deleting?.name ?? "",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            if let spec = deleting {
                Button(copy.soloDeleteModel(theme.id), role: .destructive) { delete(spec) }
                Button(copy.cancel, role: .cancel) { deleting = nil }
            }
        } message: {
            Text(copy.soloDeleteModelNote(theme.id))
        }
    }

    private func row(_ spec: SoloModelSpec, isLast: Bool) -> some View {
        let fits = spec.fits()
        let isDownloaded = downloaded.contains(spec.id)
        let running = progress[spec.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                        .font(SettingsType.rowTitle(theme))
                        .foregroundStyle(fits ? theme.ink : theme.faint)
                    Text(copy.soloModelFacts(spec, theme.id))
                        .font(SettingsType.rowValue(theme))
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isDownloaded {
                    Text(copy.soloModelOnDisk(theme.id))
                        .font(theme.mono(9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.ok)
                }
            }

            // The reason a model is unavailable is more useful than its absence:
            // an OOM kill looks like an app crash to the person it happens to.
            if !fits {
                Text(copy.soloModelTooBig(spec, theme.id))
                    .font(SettingsType.rowSubtitle(theme))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if spec.needsIncreasedMemoryLimit {
                Text(copy.soloModelEntitlement(theme.id))
                    .font(SettingsType.rowSubtitle(theme))
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let running {
                SoloProgressBar(theme: theme, value: running)
            }

            if host != nil, fits {
                HStack(spacing: 8) {
                    if isDownloaded {
                        SoloSmallButton(theme: theme, title: copy.soloDeleteModel(theme.id),
                                        tone: theme.danger, disabled: busy != nil) {
                            deleting = spec
                        }
                    } else {
                        // The size is on the button on purpose: SOLO-MODE.md
                        // says the first run must be a deliberate choice with
                        // the number printed on it, never an auto-download.
                        SoloSmallButton(theme: theme,
                                        title: copy.soloDownloadModel(
                                            theme.id,
                                            size: AppModel.formattedBytes(spec.downloadBytes)),
                                        tone: theme.accent,
                                        disabled: busy != nil) {
                            download(spec)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private func refresh() {
        downloaded = host?.downloadedModelIDs ?? []
    }

    private func download(_ spec: SoloModelSpec) {
        guard let host else { return }
        busy = spec.id
        failure = nil
        progress[spec.id] = 0
        Task { @MainActor in
            defer {
                busy = nil
                progress[spec.id] = nil
                refresh()
            }
            do {
                try await host.download(spec.id) { fraction in
                    progress[spec.id] = fraction
                }
                // A downloaded model is only useful if something selects it,
                // and the person who just waited for 2 GB meant to use it.
                SoloSettingsStore.shared.modelID = spec.id
                SoloSettingsStore.shared.engine = .mlx
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func delete(_ spec: SoloModelSpec) {
        deleting = nil
        guard let host else { return }
        do {
            try host.delete(spec.id)
            if SoloSettingsStore.shared.modelID == spec.id {
                SoloSettingsStore.shared.modelID = ""
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

/// A themed determinate bar. Deliberately not `ProgressView`: a multi-gigabyte
/// download is the longest wait in the app and the three packs should own how
/// it looks, the same way they own every other surface.
struct SoloProgressBar: View {
    var theme: ThemePack
    var value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                shape.fill(theme.inset)
                shape.fill(theme.accent)
                    .frame(width: max(2, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .overlay(shape.strokeBorder(theme.id == .soft ? .clear : theme.line, lineWidth: 1))
        .accessibilityValue(Text("\(Int(min(max(value, 0), 1) * 100))%"))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 1 : 3, style: .continuous)
    }
}

// MARK: - Permissions

/// The seven switches, each with what it is actually scoped to underneath it.
///
/// A permission row is three things stacked: the switch, the "how often does it
/// ask" control, and the concrete grants — because "Solo can read files" is
/// meaningless without "…these two folders", and a person auditing this screen
/// is asking the second question, not the first.
struct SoloPermissionsSection: View {
    let model: AppModel

    @State private var importingFolder = false
    @State private var editingMemory = false
    @State private var memoryDraft = ""
    @State private var shortcutDraft = ""
    @State private var addingShortcut = false
    @State private var addingPhotos = false
    #if canImport(PhotosUI)
    @State private var photoSelection: [PhotosPickerItem] = []
    #endif

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var store: SoloSettingsStore { SoloSettingsStore.shared }

    var body: some View {
        SettingsSection(theme: theme, title: copy.soloToolsSection(theme.id),
                        footnote: copy.soloToolsNote(theme.id,
                                                     count: SoloToolRegistry.shared.toolCount())) {
            ForEach(SoloPermission.allCases.filter(\.isCompiledIn)) { permission in
                // Compiled-in but un-askable families still get a row — it says
                // why there is no switch, which is more useful than a family
                // that silently vanishes on one build and not another.
                permissionBlock(permission)
            }
        }
        .fileImporter(isPresented: $importingFolder,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            try? SoloFileScopes.shared.add(url)
        }
        #if canImport(PhotosUI) && os(iOS)
        .photosPicker(isPresented: $addingPhotos, selection: $photoSelection,
                      maxSelectionCount: 10, matching: .images, photoLibrary: .shared())
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { @MainActor in
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        continue
                    }
                    let ext = item.supportedContentTypes.first?
                        .preferredFilenameExtension ?? "heic"
                    let name = "image-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
                    // One unreadable item must not abandon the rest of the batch.
                    _ = try? SoloPhotoShelf.shared.add(data: data, name: name)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func permissionBlock(_ permission: SoloPermission) -> some View {
        let isOn = store.isEnabled(permission) && canRequest(permission)
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(theme: theme) {
                if canRequest(permission) {
                    SettingsToggleRow(theme: theme,
                                      title: copy.soloPermTitle(permission, theme.id),
                                      subtitle: subtitle(for: permission),
                                      isOn: isOn,
                                      isLast: !isOn) {
                        store.setEnabled(permission, !isOn)
                    }
                } else {
                    // A switch this build cannot honour is worse than no switch:
                    // flipping it would put tools in the registry that fail at
                    // call time with something the person cannot act on.
                    SettingsRow(theme: theme,
                                title: copy.soloPermTitle(permission, theme.id),
                                subtitle: copy.soloPermCannotAsk(theme.id),
                                isLast: true)
                }

                if isOn {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(copy.soloAskLabel(theme.id))
                            .font(theme.mono(9, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(theme.faint)
                        SettingsSegmented(theme: theme,
                                          options: SoloAskPolicy.allCases.map {
                                              ($0, copy.soloAskOption($0, theme.id))
                                          },
                                          selection: store.askPolicy(for: permission)) {
                            store.setAskPolicy($0, for: permission)
                        }
                        if store.askPolicy(for: permission) == .never {
                            Text(copy.soloAskNeverWarning(theme.id))
                                .font(SettingsType.rowSubtitle(theme))
                                .foregroundStyle(theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        detail(for: permission)
                    }
                    .modifier(SettingsRowChrome(theme: theme, isLast: true))
                }
            }
        }
    }

    /// False when this build has no Info.plist usage description for the OS
    /// permission the family needs. Asking EventKit without one terminates the
    /// process, so the tools stay out of reach and the row says why. Shared with
    /// the explainer through `SoloPermission`, so the switch and its disclosure
    /// cannot disagree about what this build can do.
    private func canRequest(_ permission: SoloPermission) -> Bool {
        permission.isUsableInThisBuild
    }

    /// The second gate, stated where the first one is flipped: a switch that is
    /// on but that the OS has not been asked about yet is a different state from
    /// one that is on and allowed, and pretending otherwise is how "why did
    /// nothing happen" begins.
    private func subtitle(for permission: SoloPermission) -> String {
        guard permission.needsSystemPermission else {
            return copy.soloPermDetail(permission, theme.id)
        }
        #if canImport(EventKit)
        return SoloEventKitGate.isGranted(permission) ? copy.soloPermSystemGranted(theme.id)
                                                      : copy.soloPermSystemPending(theme.id)
        #else
        return copy.soloPermDetail(permission, theme.id)
        #endif
    }

    // MARK: What each permission is scoped to

    @ViewBuilder
    private func detail(for permission: SoloPermission) -> some View {
        switch permission {
        case .files: filesDetail
        case .photos: photosDetail
        case .shortcuts: shortcutsDetail
        case .memory: memoryDetail
        case .web, .calendar, .reminders: EmptyView()
        }
    }

    private var filesDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(SoloFileScopes.shared.scopes) { scope in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scope.name)
                            .font(SettingsType.rowValue(theme))
                            .foregroundStyle(theme.ink)
                        // The workspace lives inside the app container, whose
                        // path is a UUID nobody can use; the granted folders
                        // have paths a person recognises, so those are shown.
                        Text(scope.isStale ? copy.soloFolderStale(theme.id)
                             : scope.name == SoloFileScopes.workspaceName
                                ? copy.soloWorkspaceNote(theme.id) : scope.displayPath)
                            .font(theme.mono(9))
                            .foregroundStyle(scope.isStale ? theme.warn : theme.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // The workspace is Solo's own directory and is not a grant,
                    // so there is nothing to revoke.
                    if scope.name != SoloFileScopes.workspaceName {
                        SoloSmallButton(theme: theme, title: copy.soloRemove(theme.id),
                                        tone: theme.danger) {
                            SoloFileScopes.shared.remove(scope.name)
                        }
                    }
                }
            }
            SoloSmallButton(theme: theme, title: copy.soloAddFolder(theme.id), tone: theme.accent) {
                importingFolder = true
            }
        }
    }

    private var photosDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            let items = SoloPhotoShelf.shared.items
            Text(items.isEmpty
                 ? copy.soloNoImages(theme.id)
                 : copy.soloImageCount(theme.id, count: items.count,
                                       size: AppModel.formattedBytes(
                                        SoloPhotoShelf.shared.totalBytes)))
                .font(SettingsType.rowSubtitle(theme))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                #if canImport(PhotosUI) && os(iOS)
                SoloSmallButton(theme: theme, title: copy.soloAddImages(theme.id),
                                tone: theme.accent) {
                    addingPhotos = true
                }
                #endif
                if !items.isEmpty {
                    SoloSmallButton(theme: theme, title: copy.soloClearImages(theme.id),
                                    tone: theme.danger) {
                        SoloPhotoShelf.shared.removeAll()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// iOS gives an app no way to enumerate a person's shortcuts, so this list
    /// is typed rather than discovered — which is also the safety property:
    /// nothing runs that they did not both write and name here.
    private var shortcutsDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(SoloShortcutBook.shared.names, id: \.self) { name in
                HStack(spacing: 8) {
                    Text(name)
                        .font(SettingsType.rowValue(theme))
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SoloSmallButton(theme: theme, title: copy.soloRemove(theme.id),
                                    tone: theme.danger) {
                        SoloShortcutBook.shared.remove(name)
                    }
                }
            }

            if addingShortcut {
                HStack(spacing: 8) {
                    TextField("", text: $shortcutDraft,
                              prompt: Text(copy.soloShortcutPlaceholder(theme.id))
                                .foregroundStyle(theme.faint))
                        .textFieldStyle(.plain)
                        .font(theme.body(13))
                        .foregroundStyle(theme.ink)
                        .tint(theme.accent)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(theme.panel, in: inputShape)
                        .overlay(inputShape.strokeBorder(
                            theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

                    SoloSmallButton(theme: theme, title: copy.soloAdd(theme.id),
                                    tone: theme.accent,
                                    disabled: shortcutDraft.trimmingCharacters(
                                        in: .whitespacesAndNewlines).isEmpty) {
                        SoloShortcutBook.shared.add(shortcutDraft)
                        shortcutDraft = ""
                        addingShortcut = false
                    }
                }
            } else {
                SoloSmallButton(theme: theme, title: copy.soloAddShortcut(theme.id),
                                tone: theme.accent) {
                    addingShortcut = true
                }
            }

            GatewayFootnote(theme: theme, text: copy.soloShortcutNote(theme.id))
        }
    }

    private var memoryDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(copy.soloMemoryFacts(theme.id,
                                      characters: SoloMemory.characterCount,
                                      conversations: SoloSessionArchive.shared.sessionCount()))
                .font(SettingsType.rowSubtitle(theme))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            if editingMemory {
                TextEditor(text: $memoryDraft)
                    .font(theme.mono(12))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(theme.panel, in: inputShape)
                    .overlay(inputShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

                HStack(spacing: 8) {
                    SoloSmallButton(theme: theme, title: copy.soloSaveMemory(theme.id),
                                    tone: theme.accent) {
                        try? SoloMemory.write(memoryDraft)
                        editingMemory = false
                    }
                    SoloSmallButton(theme: theme, title: copy.cancel, tone: theme.ink) {
                        editingMemory = false
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    SoloSmallButton(theme: theme, title: copy.soloEditMemory(theme.id),
                                    tone: theme.accent) {
                        memoryDraft = SoloMemory.read()
                        editingMemory = true
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
    }
}

// MARK: - Standing grants

/// Everything "always" has been said to, and the way to unsay it.
///
/// This is the phone's `command_allowlist` (tools/approval.py:2931-2957), and
/// it exists for the same reason the desktop's does: "always" is granted in a
/// hurry, often from a lock screen, and the surface that took the grant owes
/// you somewhere to give it back.
struct SoloAllowlistSection: View {
    let model: AppModel

    @State private var confirmingClear = false

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        let entries = SoloApprovalCenter.shared.allowlist
        SettingsSection(theme: theme, title: copy.soloAllowlistSection(theme.id),
                        footnote: copy.soloAllowlistNote(theme.id)) {
            SettingsGroup(theme: theme) {
                if entries.isEmpty {
                    SettingsRow(theme: theme, title: copy.soloAllowlistEmpty(theme.id),
                                isLast: true)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element) { index, key in
                        HStack(spacing: 10) {
                            Text(SoloApprovalCenter.describe(scopeKey: key))
                                .font(SettingsType.rowTitle(theme))
                                .foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            SoloSmallButton(theme: theme, title: copy.soloRevoke(theme.id),
                                            tone: theme.danger) {
                                SoloApprovalCenter.shared.revoke(key)
                            }
                        }
                        .modifier(SettingsRowChrome(theme: theme,
                                                    isLast: index == entries.count - 1))
                    }
                }
            }
            if !entries.isEmpty {
                SettingsGroup(theme: theme) {
                    SettingsActionRow(theme: theme, title: copy.soloRevokeAll(theme.id),
                                      isDestructive: true, isLast: true) {
                        confirmingClear = true
                    }
                }
            }
        }
        .confirmationDialog(copy.soloRevokeAll(theme.id), isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button(copy.soloRevokeAll(theme.id), role: .destructive) {
                SoloApprovalCenter.shared.clearAllowlist()
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.soloRevokeAllNote(theme.id))
        }
    }
}

// MARK: - Storage

/// What Solo has written, measured. The same honesty Settings → Privacy owes
/// for the gateway path, owed here for the local one — and with the one
/// difference stated: Solo's memory and transcripts have no server copy, so
/// erasing them here erases them.
struct SoloStorageSection: View {
    let model: AppModel

    @State private var bytes: Int64 = 0
    @State private var isMeasuring = false
    @State private var confirmingErase = false

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        SettingsSection(theme: theme, title: copy.soloStorageSection(theme.id),
                        footnote: copy.soloStorageNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme, title: copy.soloStorageTotal(theme.id),
                            subtitle: copy.soloStorageWhere(theme.id),
                            // "Zero KB" is the formatter's answer and it is
                            // noise — PrivacySettings avoids printing it for the
                            // same reason.
                            value: isMeasuring ? copy.settingsMeasuring(theme.id)
                                : bytes > 0 ? AppModel.formattedBytes(bytes)
                                            : copy.soloStorageEmpty(theme.id))
                SettingsActionRow(theme: theme, title: copy.soloEraseAll(theme.id),
                                  subtitle: copy.soloEraseAllSub(theme.id),
                                  isDestructive: true, isLast: true) {
                    confirmingErase = true
                }
            }
        }
        .task { await measure() }
        .confirmationDialog(copy.soloEraseAll(theme.id), isPresented: $confirmingErase,
                            titleVisibility: .visible) {
            Button(copy.soloEraseAll(theme.id), role: .destructive) {
                Task { await erase() }
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.soloEraseAllConfirm(theme.id))
        }
    }

    private func measure() async {
        isMeasuring = true
        // Walking a directory tree is disk work, not view work.
        let measured = await Task.detached(priority: .utility) { SoloStore.totalBytes }.value
        bytes = measured
        isMeasuring = false
    }

    /// Order matters: the in-memory stores are emptied FIRST, because each of
    /// them writes an index back on the way out and would otherwise recreate
    /// the directory tree the wipe had just removed.
    private func erase() async {
        SoloPhotoShelf.shared.removeAll()
        SoloFileScopes.shared.removeAll()
        SoloStore.eraseEverything()
        await measure()
    }
}

// MARK: - Small button

/// The compact action button this screen uses inside rows. Same silhouette as
/// the one Models & providers keeps for the identical job; kept file-local for
/// the same reason it is there — it is row furniture, not a shared control.
struct SoloSmallButton: View {
    var theme: ThemePack
    var title: String
    var tone: Color
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(theme.mono(10.5, weight: .bold))
                .foregroundStyle(tone)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.inset, in: shape)
                .overlay(shape.strokeBorder(tone.opacity(0.4), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - Embeddable section

/// Three rows for the main Settings screen, so Solo is reachable from where a
/// person looks for it. `SettingsView` adds it with one line:
///
///     SoloSettingsSection(model: model)
///         .settingsEntrance(delay: 0.2, reduced: reducedMotion)
///
/// It is deliberately not the whole screen inlined: Settings is already long,
/// and Solo's own screen is where its controls belong. The first row is the
/// only door into the Solo *conversation* anywhere in the app, so it leads —
/// a settings screen for a chat nobody can open is not a feature.
public struct SoloSettingsSection: View {
    private let model: AppModel

    @State private var foundation: SoloEngineAvailability = .unavailable(.unknown)

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        // `soloIsPossible` spans both reachable tiers, so the tag is honest on a
        // phone too old for Apple's model but signed in to Portal. The reason,
        // when there is none, is the on-device tier's — it is the actionable one.
        let ready = model.soloIsPossible
        return SettingsSection(theme: theme, title: copy.soloSettingsTitle(theme.id),
                               footnote: copy.soloSectionNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme, title: copy.soloOpenChat(theme.id),
                            subtitle: copy.soloOpenChatSub(theme.id),
                            value: ready
                                ? copy.soloReady(theme.id)
                                : copy.soloReasonTag(foundation.reason ?? .unknown, theme.id),
                            valueTone: ready ? theme.ok : theme.faint,
                            showsChevron: true) {
                    model.requestSolo()
                }
                SettingsRow(theme: theme, title: copy.soloOpenSettings(theme.id),
                            subtitle: copy.soloEngineName(SoloSettingsStore.shared.engine,
                                                          theme.id),
                            showsChevron: true) {
                    NotificationCenter.default.post(name: .talariaOpenSoloSettings, object: nil)
                }
                SettingsRow(theme: theme, title: copy.soloExplainerRow(theme.id),
                            subtitle: copy.soloExplainerRowSub(theme.id),
                            showsChevron: true, isLast: true) {
                    NotificationCenter.default.post(name: .talariaOpenSoloExplainer, object: nil)
                }
            }
        }
        .task { foundation = SoloEngineProbe.foundationModels() }
    }
}

// MARK: - Presentation

public extension Notification.Name {
    /// Post to open Solo settings.
    static let talariaOpenSoloSettings = Notification.Name("bot.talaria.openSoloSettings")
}

/// Hosts Solo settings for whoever owns the screen graph. Mount once, beside
/// the explainer:
///
///     TalariaRootView(model: model)
///         .talariaSoloSettings(model: model)
///         .talariaSoloExplainer(model: model)
public struct TalariaSoloSettingsPresenter: ViewModifier {
    private let model: AppModel

    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel) { self.model = model }

    private var pushAnimation: Animation {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
            ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        model.theme.pack.bg.ignoresSafeArea()
                        SoloSettingsView(model: model, onBack: {
                            withAnimation(pushAnimation) { isPresented = false }
                        })
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    // Above Settings (14), below the explainer (16): Settings
                    // opens this, and this opens the explainer.
                    .zIndex(15)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSoloSettings)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
                guard isPresented else { return }
                withAnimation(pushAnimation) { isPresented = false }
            }
    }
}

public extension View {
    /// Mount Solo settings on this view tree.
    func talariaSoloSettings(model: AppModel) -> some View {
        modifier(TalariaSoloSettingsPresenter(model: model))
    }
}

// MARK: - Copy

public extension CopyPack {

    func soloSettingsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo"
        case .control: "SOLO"
        case .ink: "The Solitary"
        }
    }

    /// The row that opens the Solo conversation itself.
    func soloOpenChat(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open Solo"
        case .control: "OPEN SOLO"
        case .ink: "speak to the solitary"
        }
    }

    func soloOpenChatSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A conversation that runs on this phone, with no gateway"
        case .control: "ON-DEVICE CONVERSATION — NO GATEWAY REQUIRED"
        case .ink: "a discourse held here alone, with no gateway attending"
        }
    }

    func soloOpenSettings(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo settings"
        case .control: "SOLO CONFIGURATION"
        case .ink: "the solitary’s settings"
        }
    }

    func soloSectionNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "An agent that runs entirely on this phone, for when there is no gateway to reach."
        case .control: "ON-DEVICE AGENT TIER. NO GATEWAY REQUIRED, REDUCED CAPABILITY."
        case .ink: "A familiar kept wholly upon this device, for when no gateway answers."
        }
    }

    // MARK: Engine

    func soloEngineShort(_ engine: SoloEngineID, _ t: ThemeID) -> String {
        switch (engine, t) {
        case (.foundation, .ink): "Apple’s"
        case (.foundation, _): "APPLE"
        case (.mlx, .ink): "your own"
        case (.mlx, _): "DOWNLOAD"
        case (.portal, .ink): "the Portal"
        case (.portal, _): "PORTAL"
        }
    }

    func soloEnginePickNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Your choice is a preference, not a promise — if the one you pick isn’t available when you send a message, Solo falls back to one that is rather than failing."
        case .control: "SELECTION IS A PREFERENCE. RESOLUTION FALLS THROUGH TO THE NEXT AVAILABLE TIER AT SEND TIME."
        case .ink: "Your choice is a preference and not a vow — should it not serve when you speak, Solo turns to whichever will, rather than failing you."
        }
    }

    func soloOpenSystemSettings(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open system settings"
        case .control: "OPEN SYSTEM SETTINGS"
        case .ink: "open the device’s settings"
        }
    }

    func soloPortalSignIn(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in to Portal"
        case .control: "SIGN IN TO PORTAL"
        case .ink: "swear to the Portal"
        }
    }

    func soloLocaleUnsupported(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Apple’s on-device model does not support this device’s language yet. It will refuse mid-answer rather than at the start, so pick another engine for now."
        case .control: "SYSTEM MODEL DOES NOT SUPPORT THE CURRENT LOCALE. FAILS AT GENERATION TIME — SELECT ANOTHER TIER."
        case .ink: "Apple’s model does not yet have this device’s tongue. It will break off mid-answer rather than refuse at the door; choose another for now."
        }
    }

    // MARK: Models

    func soloModelSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Downloaded models"
        case .control: "LOCAL WEIGHTS"
        case .ink: "models of your own"
        }
    }

    func soloModelNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Downloaded once and kept on the phone. Use Wi-Fi — these are gigabytes, and nothing downloads unless you tap it."
        case .control: "USER-INITIATED DOWNLOAD ONLY, NEVER AUTOMATIC. MULTI-GIGABYTE — PREFER WI-FI."
        case .ink: "Fetched once and kept here. Use a good connection — these are gigabytes, and none is fetched but at your word."
        }
    }

    func soloModelNoHost(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This build of Talaria doesn’t include the on-device model engine, so these can’t be downloaded here. The sizes are listed so you know what the feature would cost."
        case .control: "TalariaLocal NOT LINKED IN THIS BUILD — NO DOWNLOAD PATH. CATALOGUE SHOWN AS REFERENCE."
        case .ink: "This copy does not carry the engine for such models, so none may be fetched here. Their weights are set down so you know the cost of it."
        }
    }

    func soloModelFacts(_ spec: SoloModelSpec, _ t: ThemeID) -> String {
        let download = AppModel.formattedBytes(spec.downloadBytes)
        let peak = AppModel.formattedBytes(spec.peakMemoryBytes)
        switch t {
        case .soft: return "\(download) to download · about \(peak) of memory while running"
        case .control: return "\(download) ON DISK · \(peak) PEAK RSS"
        case .ink: return "\(download) to fetch · some \(peak) of memory in use"
        }
    }

    func soloModelOnDisk(_ t: ThemeID) -> String {
        switch t {
        case .soft: "ON DEVICE"
        case .control: "RESIDENT"
        case .ink: "KEPT"
        }
    }

    func soloModelTooBig(_ spec: SoloModelSpec, _ t: ThemeID) -> String {
        let need = AppModel.formattedBytes(Int64(spec.minimumDeviceMemoryBytes))
        switch t {
        case .soft: return "Too large for this device — it wants \(need) of memory. Running it would be killed by the system mid-answer."
        case .control: return "EXCEEDS THIS HOST — REQUIRES \(need) PHYSICAL MEMORY. WOULD OOM AT RUNTIME."
        case .ink: return "Beyond this device — it asks \(need) of memory, and would be struck down mid-answer."
        }
    }

    func soloModelEntitlement(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The largest tier also needs the increased-memory entitlement in the build."
        case .control: "REQUIRES com.apple.developer.kernel.increased-memory-limit."
        case .ink: "The greatest of them also asks a special leave of the system."
        }
    }

    func soloDownloadModel(_ t: ThemeID, size: String) -> String {
        switch t {
        case .soft: "Download \(size)"
        case .control: "DOWNLOAD \(size.uppercased())"
        case .ink: "fetch \(size)"
        }
    }

    func soloDeleteModel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "DELETE"
        case .ink: "let it go"
        }
    }

    func soloDeleteModelNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Frees the space now. You can download it again later."
        case .control: "RECLAIMS DISK IMMEDIATELY. RE-DOWNLOADABLE."
        case .ink: "The room is given back at once. It may be fetched anew."
        }
    }

    // MARK: Tools & permissions

    func soloToolsSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What Solo may touch"
        case .control: "TOOL PERMISSIONS"
        case .ink: "WHAT THE FAMILIAR MAY TOUCH"
        }
    }

    func soloToolsNote(_ t: ThemeID, count: Int) -> String {
        switch t {
        case .soft:
            return "Solo is given \(count) tool\(count == 1 ? "" : "s") right now. Anything switched off isn’t refused — it is never mentioned to the model at all, which also makes answers faster."
        case .control:
            return "\(count) TOOL SCHEMA\(count == 1 ? "" : "S") IN THE REGISTRY. DISABLED FAMILIES ARE OMITTED FROM THE PROMPT, NOT REFUSED AT CALL TIME — LOWER PREFILL, HIGHER RELIABILITY."
        case .ink:
            return "\(count) gift\(count == 1 ? "" : "s") are granted at present. What is withheld is not refused but never spoken of, which quickens the answer besides."
        }
    }

    func soloPermDetail(_ permission: SoloPermission, _ t: ThemeID) -> String {
        switch (permission, t) {
        case (.files, .soft): "Read and write inside Solo’s own folder and any folder you add below."
        case (.files, .control): "READ/WRITE — SOLO WORKSPACE + GRANTED BOOKMARK SCOPES."
        case (.files, .ink): "To read and to write within Solo’s own room and such rooms as you grant."
        case (.web, .soft): "Fetch one page at a time and read its text. Approved per site."
        case (.web, .control): "HTTP(S) GET, READABLE-TEXT EXTRACTION. APPROVAL SCOPED PER HOST."
        case (.web, .ink): "To fetch a page and read its words. Allowed house by house."
        case (.calendar, .soft): "Read your events, and create one when you approve it."
        case (.calendar, .control): "EVENTKIT — READ EVENTS, CREATE ON APPROVAL."
        case (.calendar, .ink): "To read your appointments, and to set one down when you allow it."
        case (.reminders, .soft): "Read your reminders, and add one when you approve it."
        case (.reminders, .control): "EVENTKIT — READ REMINDERS, CREATE ON APPROVAL."
        case (.reminders, .ink): "To read what you owe, and add to it at your word."
        case (.photos, .soft): "Read the text inside images you hand it. It cannot see your photo library."
        case (.photos, .control): "OCR OVER THE SHARED SHELF ONLY. NO PHOTO-LIBRARY ACCESS."
        case (.photos, .ink): "To read the words within pictures you hand over. Your gallery stays closed."
        case (.shortcuts, .soft): "Run shortcuts you name below — the closest thing iOS has to a shell."
        case (.shortcuts, .control): "shortcuts://run-shortcut, ALLOWLISTED NAMES ONLY. THE iOS SHELL ANALOGUE."
        case (.shortcuts, .ink): "To run such devisings as you name below — the nearest thing this device has to a shell."
        case (.memory, .soft): "Keep notes across conversations, and search what was said before."
        case (.memory, .control): "MEMORY NOTE + TERM SEARCH OVER SOLO'S OWN TRANSCRIPTS."
        case (.memory, .ink): "To keep notes between meetings, and to recall what was said before."
        }
    }

    func soloPermSystemGranted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Allowed by iOS. Solo asks you again per action, below."
        case .control: "OS AUTHORIZATION: FULL ACCESS. TALARIA-SIDE GATE STILL APPLIES."
        case .ink: "The device permits it. Solo asks your leave besides, as set below."
        }
    }

    func soloPermSystemPending(_ t: ThemeID) -> String {
        switch t {
        case .soft: "iOS will ask you the first time Solo uses it."
        case .control: "OS AUTHORIZATION NOT YET REQUESTED — PROMPTED AT FIRST USE."
        case .ink: "The device will ask you when first it is wanted."
        }
    }

    /// The build genuinely cannot raise the OS prompt. Said plainly, because
    /// the alternative — asking anyway — terminates the app.
    func soloPermCannotAsk(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This build of Talaria can’t request this permission, so these tools stay off."
        case .control: "NO Info.plist USAGE DESCRIPTION IN THIS BUILD — CANNOT REQUEST. TOOLS WITHHELD."
        case .ink: "This copy cannot ask the device for this leave, so the gifts stay withheld."
        }
    }

    func soloAskLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Ask me"
        case .control: "APPROVAL POLICY"
        case .ink: "when to ask"
        }
    }

    func soloAskOption(_ policy: SoloAskPolicy, _ t: ThemeID) -> String {
        switch (policy, t) {
        case (.always, .ink): "always"
        case (.always, _): "EVERY TIME"
        case (.changes, .ink): "for changes"
        case (.changes, _): "FOR CHANGES"
        case (.never, .ink): "never"
        case (.never, _): "NEVER"
        }
    }

    func soloAskNeverWarning(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo will use these without asking, including the ones that change things. Standing grants below still apply."
        case .control: "UNGATED — INCLUDING WRITE AND EGRESS CALLS. NO CARD WILL BE RAISED."
        case .ink: "Solo will act without asking, changes and all. No card will be raised."
        }
    }

    func soloFolderStale(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This folder has moved or the grant lapsed — remove and add it again"
        case .control: "BOOKMARK STALE — RE-GRANT REQUIRED"
        case .ink: "this room has moved, or the leave has lapsed — grant it anew"
        }
    }

    func soloWorkspaceNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo\u{2019}s own folder, inside the app"
        case .control: "APP CONTAINER \u{00B7} SOLO WORKSPACE"
        case .ink: "Solo\u{2019}s own room, within the app"
        }
    }

    func soloAddFolder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add a folder"
        case .control: "GRANT A FOLDER"
        case .ink: "grant a room"
        }
    }

    func soloRemove(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove"
        case .control: "REVOKE"
        case .ink: "withdraw"
        }
    }

    func soloAdd(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add"
        case .control: "ADD"
        case .ink: "set down"
        }
    }

    func soloNoImages(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No images shared yet."
        case .control: "SHELF EMPTY."
        case .ink: "no pictures handed over yet."
        }
    }

    func soloImageCount(_ t: ThemeID, count: Int, size: String) -> String {
        switch t {
        case .soft: "\(count) image\(count == 1 ? "" : "s") shared · \(size)"
        case .control: "\(count) IMAGE\(count == 1 ? "" : "S") · \(size.uppercased())"
        case .ink: "\(count) picture\(count == 1 ? "" : "s") given · \(size)"
        }
    }

    func soloAddImages(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Share images"
        case .control: "ADD IMAGES"
        case .ink: "hand over pictures"
        }
    }

    func soloClearImages(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove all"
        case .control: "CLEAR SHELF"
        case .ink: "take them back"
        }
    }

    func soloAddShortcut(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Allow a shortcut"
        case .control: "ALLOWLIST A SHORTCUT"
        case .ink: "permit a devising"
        }
    }

    func soloShortcutPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Shortcut name, exactly as in Shortcuts"
        case .control: "EXACT SHORTCUT NAME"
        case .ink: "its name, exactly as written"
        }
    }

    func soloShortcutNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "iOS won’t let an app list your shortcuts, so you name them. Running one leaves Talaria for the Shortcuts app and comes back with whatever it returns."
        case .control: "NO ENUMERATION API — NAMES ARE USER-SUPPLIED. EXECUTION BACKGROUNDS TALARIA; OUTPUT RETURNS VIA x-callback-url."
        case .ink: "The device will not let an app read your devisings, so you name them yourself. Running one takes you to Shortcuts and returns with whatever it yields."
        }
    }

    func soloMemoryFacts(_ t: ThemeID, characters: Int, conversations: Int) -> String {
        switch t {
        case .soft:
            return "\(characters) characters of notes · \(conversations) past conversation\(conversations == 1 ? "" : "s") searchable"
        case .control:
            return "MEMORY \(characters) CHARS · \(conversations) ARCHIVED SESSION\(conversations == 1 ? "" : "S") INDEXED"
        case .ink:
            return "\(characters) characters of notes · \(conversations) past meeting\(conversations == 1 ? "" : "s") that may be recalled"
        }
    }

    func soloEditMemory(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Edit notes"
        case .control: "EDIT MEMORY"
        case .ink: "amend the notes"
        }
    }

    func soloSaveMemory(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save"
        case .control: "WRITE"
        case .ink: "set it down"
        }
    }

    // MARK: Allowlist

    func soloAllowlistSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Always allowed"
        case .control: "STANDING GRANTS"
        case .ink: "STANDING LEAVE"
        }
    }

    func soloAllowlistNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Every time you tap “always” on a Solo approval it lands here — scoped to that one site, file or shortcut, never to everything."
        case .control: "POPULATED BY THE 'ALWAYS' CHOICE. SCOPED PER HOST / PER FILE / PER SHORTCUT — NEVER PER TOOL."
        case .ink: "Each time you grant “always” to Solo it is written here — bound to that one house, paper or devising, and never to all."
        }
    }

    func soloAllowlistEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing has standing permission."
        case .control: "NO STANDING GRANTS."
        case .ink: "Nothing holds standing leave."
        }
    }

    func soloRevoke(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Revoke"
        case .control: "REVOKE"
        case .ink: "recall"
        }
    }

    func soloRevokeAll(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Revoke everything"
        case .control: "CLEAR ALL GRANTS"
        case .ink: "recall every leave"
        }
    }

    func soloRevokeAllNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo will ask again next time, for each one."
        case .control: "ALL SUBSEQUENT CALLS RE-PROMPT."
        case .ink: "Solo will ask anew for each, when next it is wanted."
        }
    }

    // MARK: Storage

    func soloStorageSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Solo’s storage"
        case .control: "SOLO FOOTPRINT"
        case .ink: "WHAT THE SOLITARY KEEPS"
        }
    }

    func soloStorageTotal(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On this device"
        case .control: "TOTAL ON DISK"
        case .ink: "kept here"
        }
    }

    func soloStorageWhere(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Notes, conversations, shared images and Solo’s workspace"
        case .control: "memory.md + SESSION JSONL + IMAGE SHELF + WORKSPACE"
        case .ink: "notes, discourses, given pictures and Solo’s own room"
        }
    }

    func soloStorageNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unlike your bots, none of this exists anywhere else. There is no gateway holding a copy — if you erase it here, it is gone."
        case .control: "NO SERVER-SIDE COPY EXISTS. ERASURE IS TERMINAL, UNLIKE GATEWAY-BACKED PROFILE DATA."
        case .ink: "Unlike your familiars, none of this is kept elsewhere. No gateway holds a copy — unmade here, it is unmade."
        }
    }

    func soloStorageEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing yet"
        case .control: "EMPTY"
        case .ink: "nothing yet"
        }
    }

    func soloEraseAll(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Erase everything Solo has"
        case .control: "WIPE SOLO STATE"
        case .ink: "unmake all the solitary keeps"
        }
    }

    func soloEraseAllSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Notes, every past conversation, shared images and granted folders"
        case .control: "MEMORY + ARCHIVE + SHELF + FOLDER GRANTS"
        case .ink: "notes, every past discourse, given pictures and granted rooms"
        }
    }

    func soloEraseAllConfirm(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This cannot be undone and nothing is stored anywhere else. Your gateway bots are untouched."
        case .control: "IRREVERSIBLE. NO REMOTE COPY. GATEWAY PROFILES UNAFFECTED."
        case .ink: "There is no undoing it, and nothing is kept elsewhere. Your gateway familiars are untouched."
        }
    }

    // MARK: Explainer pointer

    func soloExplainerSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Before you rely on it"
        case .control: "CAPABILITY DISCLOSURE"
        case .ink: "BEFORE YOU LEAN UPON IT"
        }
    }

    func soloExplainerRow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What Solo can and can’t do"
        case .control: "CAPABILITY COMPARISON"
        case .ink: "what the solitary may and may not do"
        }
    }

    func soloExplainerRowSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On device vs with a gateway, and what it costs on this phone"
        case .control: "ON-DEVICE vs GATEWAY, PLUS MEASURED COST ON THIS HOST"
        case .ink: "here against the gateway, and the price of it on this device"
        }
    }

    func soloExplainerNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Kept here rather than shown once at the start, so the trade-off stays checkable."
        case .control: "PERSISTENT DISCLOSURE, NOT A FIRST-RUN MODAL."
        case .ink: "Kept here rather than shown once and taken away, so the bargain may be re-read."
        }
    }
}

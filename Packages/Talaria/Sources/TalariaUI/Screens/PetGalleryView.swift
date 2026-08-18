import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The pet surface — desktop's Appearance → Pets picker, phone-shaped.
//
// Three stacked sections, each of which vanishes when the gateway has nothing
// to put in it (AppModelLive+Pets decides; see its header for the fail-open
// contract):
//
//   On duty  — the active mascot playing live at hero size, its mood row so you
//              can see every animation the sheet actually has, the master scale
//              slider, rename, and the switch that turns pets off.
//   Menagerie— the petdex gallery merged with what is installed, drawn from
//              `pet.thumb` crops (kilobytes) and never from spritesheets
//              (megabytes). Tap to adopt; long-press an installed pet to rename
//              or delete it.
//   Hatching — prompt → drafts → pick one and name it → hatch → adopt.
//
// The hatch deliberately is not a progress bar. `pet.hatch` generates every
// animation row one at a time and rasters them into a sheet: minutes of work
// with a real, discrete beat (`pet.hatch.progress` names the row it is drawing).
// So it is drawn as an egg that wobbles faster and cracks further with each
// row, and it ends with a burst and the new pet standing there — the one moment
// in this app that is allowed to be a small event.

@MainActor
public struct PetGalleryView: View {
    private let model: AppModel
    /// Profile (bot id) whose pet this is — `display.pet.*` is per-profile.
    private let botID: String

    @Environment(\.dismiss) private var dismiss

    @State private var surface: PetSurfaceState
    /// Which animation row the hero plays; the mood chips drive it.
    @State private var preview: PetState = .idle
    @State private var scaleDraft: Double = Pet.defaultScale
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var pendingRemoval: PetGalleryEntry?
    @State private var adopting = false
    /// Gallery filter + window. petdex is thousands of pets and every rendered
    /// tile costs a `pet.thumb` round trip, so the grid is explicitly windowed
    /// (desktop does the same for the same reason: mounting an image per pet
    /// froze its dialog).
    @State private var query = ""
    @State private var limit = Self.pageSize
    /// The ranked+filtered list, recomputed only when the gallery or the query
    /// moves — not on every repaint, because dragging the scale slider repaints
    /// this view continuously and the manifest can be thousands of rows.
    @State private var ranked: [PetGalleryEntry] = []
    @FocusState private var renameFocused: Bool

    private static let pageSize = 24

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
        _surface = State(initialValue: model.pets(for: botID))
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }

    private struct RenameTarget: Identifiable, Equatable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let notice = surface.notice {
                            noticeCard(notice)
                        }
                        sectionLabel(copy.petActiveSec(themeID))
                        activeCard
                        sectionLabel(copy.petGallerySec(themeID))
                        gallerySection
                        sectionLabel(copy.petHatchSec(themeID))
                        hatchSection
                        Text(copy.petFootnote(themeID))
                            .font(footnoteFont)
                            .foregroundStyle(theme.faint)
                            .lineSpacing(3)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 60)
                }
            }
            if renaming != nil {
                renameOverlay
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .confirmationDialog(
            copy.petRemoveTitle(themeID, pendingRemoval?.displayName ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(copy.petRemove(themeID), role: .destructive) {
                if let entry = pendingRemoval {
                    Task { await model.removePet(slug: entry.slug, profile: botID) }
                }
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.petRemoveBody(themeID))
        }
        .task { await load() }
        .onChange(of: surface.gallery.pets) { _, _ in rerank() }
        .onChange(of: surface.pet?.slug) { _, _ in
            scaleDraft = surface.pet?.scale ?? Pet.defaultScale
            preview = .idle
        }
        .onChange(of: surface.generation.phase) { _, phase in
            if phase == .preview { celebrate() }
        }
    }

    private func load() async {
        await model.probePets(profile: botID)
        scaleDraft = surface.pet?.scale ?? Pet.defaultScale
        rerank()
        await model.loadPetGalleryProgressively(profile: botID)
        rerank()
    }

    /// The hatch lands with a haptic — it is the payoff for minutes of waiting.
    private func celebrate() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(themeID == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(themeID == .ink ? Color.clear : theme.panel)
                    .clipShape(iconShape)
                    .overlay(iconShape.strokeBorder(
                        themeID == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.petKicker(themeID))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(themeID == .control ? 2.5 : 2)
                        .foregroundStyle(themeID == .ink ? theme.sub : theme.accent)
                        .lineLimit(1)
                }
                Text(copy.petTitle(themeID))
                    .font(themeID == .ink ? theme.display(24).smallCaps()
                                          : theme.body(21, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if surface.isRenderable {
                Button {
                    Task { await model.disablePets(profile: botID) }
                } label: {
                    Text(copy.petOff(themeID))
                        .font(themeID == .control ? theme.mono(10, weight: .bold)
                                                  : theme.body(12, weight: .semibold))
                        .tracking(themeID == .soft ? 0 : 1)
                        .foregroundStyle(theme.sub)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 11)
                        .chipShell(theme)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 31 * theme.iconCornerFraction, style: .continuous)
    }

    // MARK: - On duty

    @ViewBuilder private var activeCard: some View {
        if let pet = surface.pet, let sheet = surface.sheet, surface.isRenderable {
            VStack(alignment: .leading, spacing: 12) {
                // Stage tall enough for the widest the hero band allows
                // (104 × 1.25 plus the stage's padding and contact shadow), so
                // a 3.0-scale pet still stands inside its card.
                PetStage(theme: theme, height: 168) {
                    PetSpriteView(sheet: sheet, state: preview, scale: pet.scale,
                                  size: .hero(104))
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pet.displayName)
                        .font(themeID == .ink ? theme.body(18, weight: .bold).smallCaps()
                                              : theme.body(16, weight: .bold))
                        .foregroundStyle(theme.ink)
                    Text(pet.slug)
                        .font(theme.mono(themeID == .ink ? 8.5 : 10))
                        .foregroundStyle(theme.faint)
                    Spacer(minLength: 4)
                    Button {
                        renameText = pet.displayName
                        renaming = RenameTarget(slug: pet.slug, name: pet.displayName)
                        renameFocused = true
                    } label: {
                        Text(copy.petRename(themeID))
                            .font(theme.body(12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                moodChips(sheet: sheet)
                scaleControl(pet: pet)
            }
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 13, trailing: 13))
            .modifier(PetCardChrome(theme: theme))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(surface.hasLoaded ? copy.petNone(themeID) : copy.petLoading(themeID))
                    .font(themeID == .control ? theme.mono(11) : theme.body(13))
                    .foregroundStyle(theme.sub)
                if surface.hasLoaded, surface.hasPets {
                    Text(copy.petNoneHint(themeID))
                        .font(footnoteFont)
                        .foregroundStyle(theme.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 13, bottom: 13, trailing: 13))
            .modifier(PetCardChrome(theme: theme))
        }
    }

    /// One chip per animation row this sheet actually carries. A legacy 8-row
    /// atlas has no `waiting`, and a trimmed row can be empty — neither should
    /// be offered as something to look at.
    private func moodChips(sheet: PetSpriteSheet) -> some View {
        let moods = PetState.allCases.filter { state in
            state == .idle || sheet.geometry.frameCount(row: sheet.geometry.rowName(for: state)) > 0
        }
        return DetailChipFlow(spacing: 6) {
            ForEach(moods, id: \.self) { mood in
                DetailChip(text: copy.petMood(mood, themeID),
                           selected: preview == mood, theme: theme) {
                    withAnimation(.easeOut(duration: 0.2)) { preview = mood }
                }
            }
        }
    }

    /// `display.pet.scale` — one knob resizes the mascot on every surface,
    /// this app's roster included. The gateway clamps and returns what it
    /// stored, so the slider follows the truth on release.
    private func scaleControl(pet: Pet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(copy.petScale(themeID))
                    .font(theme.mono(themeID == .ink ? 8.5 : 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 8)
                Text(String(format: "%.2f×", scaleDraft))
                    .font(theme.mono(themeID == .ink ? 9 : 10))
                    .foregroundStyle(theme.sub)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { scaleDraft },
                                  set: { value in
                                      scaleDraft = value
                                      model.previewPetScale(value, profile: botID)
                                  }),
                   in: Pet.minScale...Pet.maxScale) { editing in
                guard !editing else { return }
                Task { await model.commitPetScale(scaleDraft, profile: botID) }
            }
            .tint(theme.accent)
        }
    }

    // MARK: - Menagerie

    @ViewBuilder private var gallerySection: some View {
        if surface.gallery.pets.isEmpty {
            emptyLine(surface.hasLoaded ? copy.petGalleryEmpty(themeID) : copy.petLoading(themeID))
        } else {
            if surface.gallery.pets.count > 12 {
                searchField
            }
            // Only a *search* can legitimately empty a non-empty gallery; an
            // empty ranking with no query just means the first rerank hasn't
            // run yet, and must not flash "no matches".
            if ranked.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyLine(copy.petNoMatches(themeID))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(ranked.prefix(limit)) { entry in
                        galleryCell(entry)
                    }
                }
                if ranked.count > limit {
                    Button {
                        limit += Self.pageSize
                    } label: {
                        Text(copy.petShowMore(themeID, min(limit, ranked.count), ranked.count))
                            .font(themeID == .control ? theme.mono(10, weight: .semibold)
                                                      : theme.body(12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func rerank() {
        ranked = rankedGallery()
    }

    /// Desktop's order, which is also the useful one: what you already have,
    /// then petdex's hand-picked set, then the long tail — stable within each
    /// rank so the list never shuffles under a scroll.
    private func rankedGallery() -> [PetGalleryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = needle.isEmpty ? surface.gallery.pets : surface.gallery.pets.filter {
            $0.displayName.lowercased().contains(needle) || $0.slug.lowercased().contains(needle)
        }
        return matches.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private func rank(_ entry: PetGalleryEntry) -> Int {
        if entry.installed { return 0 }
        if entry.curated { return 1 }
        return 2
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text(verbatim: "⌕")
                .font(theme.mono(15, weight: .semibold))
                .foregroundStyle(theme.faint)
            TextField(copy.petSearch(themeID, surface.gallery.pets.count), text: $query)
                .textFieldStyle(.plain)
                .font(themeID == .control ? theme.mono(12) : theme.body(13.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: query) { _, _ in
                    limit = Self.pageSize
                    rerank()
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Text(verbatim: "✕")
                        .font(theme.body(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.inset,
                    in: RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    private func galleryCell(_ entry: PetGalleryEntry) -> some View {
        let isActive = entry.slug == surface.pet?.slug && surface.enabled
        let busy = surface.isBusy("select:\(entry.slug)")
        return Button {
            guard !busy else { return }
            Task { await model.selectPet(slug: entry.slug, profile: botID) }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    PetThumbView(model: model, entry: entry, profile: botID, theme: theme)
                    if busy {
                        ProgressView().controlSize(.small).tint(theme.accent)
                    }
                }
                .frame(height: 74)
                .frame(maxWidth: .infinity)
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))

                Text(entry.displayName)
                    .font(themeID == .control ? theme.mono(9.5) : theme.body(11.5, weight: .medium))
                    .foregroundStyle(isActive ? theme.accent : theme.sub)
                    .lineLimit(1)
                if let badge = badgeText(entry) {
                    Text(badge)
                        .font(theme.mono(themeID == .ink ? 7.5 : 8))
                        .tracking(1.2)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: theme.rowRadius + 4, style: .continuous)
                .strokeBorder(isActive ? theme.accent : Color.clear,
                              lineWidth: themeID == .soft ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if entry.installed {
                Button(copy.petRename(themeID)) {
                    renameText = entry.displayName
                    renaming = RenameTarget(slug: entry.slug, name: entry.displayName)
                    renameFocused = true
                }
                Button(copy.petRemove(themeID), role: .destructive) {
                    pendingRemoval = entry
                }
            }
        }
    }

    private func badgeText(_ entry: PetGalleryEntry) -> String? {
        if entry.slug == surface.pet?.slug, surface.enabled { return copy.petOnDuty(themeID) }
        if entry.generated { return copy.petHatchedBadge(themeID) }
        if entry.curated { return copy.petCurated(themeID) }
        if entry.installed { return copy.petInstalled(themeID) }
        return nil
    }

    // MARK: - Hatching

    @ViewBuilder private var hatchSection: some View {
        if !surface.generation.available {
            emptyLine(copy.petNoBackend(themeID))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                switch surface.generation.phase {
                case .idle: promptForm
                case .drafting: draftingBlock
                case .choosing: choosingBlock
                case .hatching: hatchingBlock
                case .preview: previewBlock
                }
                if let error = surface.generation.error, !error.isEmpty {
                    Text(error)
                        .font(footnoteFont)
                        .foregroundStyle(theme.danger)
                        .textSelection(.enabled)
                }
            }
            .padding(EdgeInsets(top: 13, leading: 13, bottom: 13, trailing: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(PetCardChrome(theme: theme))
            .animation(.easeInOut(duration: 0.3), value: surface.generation.phase)
        }
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(copy.petPrompt(themeID),
                      text: Binding(get: { surface.generation.prompt },
                                    set: { surface.generation.prompt = $0 }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(themeID == .control ? theme.mono(12) : theme.body(13.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))

            HStack(spacing: 8) {
                Text(copy.petCount(themeID))
                    .font(theme.mono(themeID == .ink ? 8.5 : 9.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(theme.faint)
                ForEach(1...4, id: \.self) { count in
                    DetailChip(text: String(count),
                               selected: surface.generation.count == count, theme: theme) {
                        surface.generation.count = count
                    }
                }
            }

            if surface.generation.providers.count > 1 {
                DetailChipFlow(spacing: 6) {
                    ForEach(surface.generation.providers) { provider in
                        DetailChip(text: provider.label,
                                   selected: surface.generation.provider == provider.name,
                                   theme: theme) {
                            surface.generation.provider = provider.name
                        }
                    }
                }
            }

            ThemedPrimaryButton(theme: theme, title: copy.petGenerate(themeID)) {
                model.startPetGeneration(profile: botID)
            }
            .opacity(promptIsEmpty ? 0.45 : 1)
            .disabled(promptIsEmpty)

            Text(copy.petGenerateNote(themeID))
                .font(footnoteFont)
                .foregroundStyle(theme.faint)
                .lineSpacing(3)
        }
    }

    private var promptIsEmpty: Bool {
        surface.generation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.accent)
                Text(copy.petDrafting(themeID, surface.generation.drafts.count,
                                      max(surface.generation.expectedDrafts,
                                          surface.generation.drafts.count)))
                    .font(themeID == .control ? theme.mono(11) : theme.body(13))
                    .foregroundStyle(theme.sub)
            }
            draftGrid(selectable: false)
            ThemedSecondaryButton(theme: theme, title: copy.petStop(themeID),
                                  compact: true, fillsWidth: true) {
                model.cancelPetRun(profile: botID)
            }
        }
    }

    private var choosingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.petPick(themeID))
                .font(themeID == .control ? theme.mono(11) : theme.body(13))
                .foregroundStyle(theme.sub)
            draftGrid(selectable: true)

            TextField(copy.petNamePlaceholder(themeID),
                      text: Binding(get: { surface.generation.name },
                                    set: { surface.generation.name = $0 }))
                .textFieldStyle(.plain)
                .font(themeID == .control ? theme.mono(12) : theme.body(13.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))

            HStack(spacing: 10) {
                Button(copy.petStartOver(themeID)) {
                    model.resetPetGeneration(profile: botID)
                }
                .font(theme.body(13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                ThemedPrimaryButton(theme: theme, title: copy.petHatchGo(themeID), compact: true) {
                    model.hatchPet(profile: botID)
                }
                .frame(maxWidth: 170)
                .opacity(canHatch ? 1 : 0.45)
                .disabled(!canHatch)
            }
        }
    }

    private var canHatch: Bool {
        surface.generation.selectedDraft != nil
            && !surface.generation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func draftGrid(selectable: Bool) -> some View {
        let expected = max(surface.generation.expectedDrafts, surface.generation.drafts.count)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(surface.generation.drafts) { draft in
                Button {
                    guard selectable else { return }
                    surface.generation.selectedDraft = draft.index
                } label: {
                    PetDataURIImage(uri: draft.dataURI, theme: theme)
                        .frame(height: 104)
                        .frame(maxWidth: .infinity)
                        .background(theme.inset,
                                    in: RoundedRectangle(cornerRadius: theme.rowRadius,
                                                         style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                            .strokeBorder(surface.generation.selectedDraft == draft.index && selectable
                                          ? theme.accent : theme.line,
                                          lineWidth: surface.generation.selectedDraft == draft.index
                                          && selectable ? 2 : 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Slots for the drafts still being drawn, so the grid keeps its
            // shape instead of reflowing under the user four times.
            ForEach(surface.generation.drafts.count..<max(surface.generation.drafts.count, expected),
                    id: \.self) { _ in
                RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .fill(theme.inset)
                    .frame(height: 104)
                    .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
                    .overlay(Text(verbatim: "···")
                        .font(theme.mono(13))
                        .foregroundStyle(theme.faint))
                    .glowPulse(period: 1.8)
            }
        }
    }

    private var hatchingBlock: some View {
        VStack(spacing: 14) {
            HatchingEgg(theme: theme,
                        progress: surface.generation.progress?.fraction ?? 0,
                        settling: surface.generation.progress?.event == "compose"
                            || surface.generation.progress?.event == "save")
                .frame(height: 168)
                .frame(maxWidth: .infinity)

            Text(hatchCaption)
                .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                          : theme.body(13, weight: .semibold))
                .tracking(themeID == .control ? 1 : 0)
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.25), value: hatchCaption)

            ThemedSecondaryButton(theme: theme, title: copy.petStop(themeID),
                                  compact: true, fillsWidth: true) {
                model.cancelPetRun(profile: botID)
            }
        }
    }

    /// The egg's caption, in the gateway's own beats: which row is being drawn,
    /// then the compose and save phases.
    private var hatchCaption: String {
        guard let progress = surface.generation.progress else {
            return copy.petHatchWaking(themeID)
        }
        switch progress.event {
        case "row":
            // The engine names rows in the atlas's own taxonomy ("waving",
            // "running-left"); resolve it back through the alias chain, and
            // failing that show the row name it actually sent.
            let mood = PetState.allCases
                .first { $0.rowAliases.contains(progress.rowState) }
                .map { copy.petMood($0, themeID) } ?? progress.rowState
            return copy.petHatchRow(themeID, mood, progress.done, progress.total)
        case "compose": return copy.petHatchCompose(themeID)
        case "save": return copy.petHatchSave(themeID)
        default: return copy.petHatchWaking(themeID)
        }
    }

    @ViewBuilder private var previewBlock: some View {
        VStack(spacing: 12) {
            ZStack {
                PetStage(theme: theme, height: 176) {
                    if let sheet = surface.hatchedSheet {
                        PetSpriteView(sheet: sheet, state: .wave,
                                      scale: surface.hatchedPet?.scale ?? Pet.defaultScale,
                                      size: .hero(112))
                    }
                }
                HatchBurst(theme: theme)
                    .allowsHitTesting(false)
            }

            Text(copy.petHatched(themeID, surface.generation.hatched?.displayName ?? ""))
                .font(themeID == .ink ? theme.display(19, weight: .bold).smallCaps()
                                      : theme.body(15, weight: .bold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)

            if !surface.generation.warnings.isEmpty {
                Text(copy.petWarningsLead(themeID) + " " +
                     surface.generation.warnings.joined(separator: " · "))
                    .font(footnoteFont)
                    .foregroundStyle(theme.warn)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button(copy.petDiscard(themeID)) {
                    Task { await model.discardHatchedPet(profile: botID) }
                }
                .font(theme.body(13, weight: .semibold))
                .foregroundStyle(theme.sub)
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                ThemedPrimaryButton(theme: theme,
                                    title: adopting ? copy.petAdopting(themeID)
                                                    : copy.petAdopt(themeID),
                                    compact: true) {
                    guard !adopting else { return }
                    adopting = true
                    Task {
                        await model.adoptHatchedPet(profile: botID)
                        adopting = false
                    }
                }
                .frame(maxWidth: 170)
            }
        }
    }

    // MARK: - Rename (themed; a system alert would break all three looks)

    private var renameOverlay: some View {
        ZStack {
            theme.bg.opacity(themeID == .control ? 0.86 : 0.72)
                .ignoresSafeArea()
                .onTapGesture { renaming = nil }

            VStack(alignment: .leading, spacing: 12) {
                Text(copy.petRenameTitle(themeID))
                    .font(themeID == .ink ? theme.display(20, weight: .bold).smallCaps()
                                          : theme.body(16, weight: .heavy))
                    .foregroundStyle(theme.ink)

                TextField(copy.petNamePlaceholder(themeID), text: $renameText)
                    .textFieldStyle(.plain)
                    .font(themeID == .control ? theme.mono(13) : theme.body(14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                    .background(theme.inset,
                                in: RoundedRectangle(cornerRadius: theme.inputRadius,
                                                     style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))

                HStack(spacing: 12) {
                    Button(copy.cancel) { renaming = nil }
                        .font(theme.body(13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    ThemedPrimaryButton(theme: theme, title: copy.petRenameOK(themeID),
                                        compact: true) {
                        commitRename()
                    }
                    .frame(maxWidth: 150)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: 340)
            .background(theme.panel,
                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(themeID == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private func commitRename() {
        guard let target = renaming else { return }
        let name = renameText
        renaming = nil
        renameFocused = false
        Task { await model.renamePet(slug: target.slug, to: name, profile: botID) }
    }

    // MARK: - Small parts

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(themeID == .soft ? theme.body(11, weight: .heavy)
                  : themeID == .control ? theme.mono(9, weight: .bold) : theme.mono(8.5))
            .tracking(themeID == .soft ? 1 : 2)
            .foregroundStyle(theme.faint)
            .padding(.top, 4)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(themeID == .control ? theme.mono(10.5) : theme.body(12.5))
            .foregroundStyle(theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
            .modifier(PetCardChrome(theme: theme))
    }

    private func noticeCard(_ notice: String) -> some View {
        Text(copy.petNoticeLead(themeID) + " — " + notice)
            .font(footnoteFont)
            .foregroundStyle(theme.warn)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(theme.warn.opacity(themeID == .soft ? 0.08 : 0.06),
                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.warn.opacity(0.4), lineWidth: 1))
    }

    private var footnoteFont: Font {
        switch themeID {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13).italic()
        }
    }
}

// MARK: - Stage

/// The floor a pet stands on: an inset panel with a soft contact shadow, so a
/// transparent sprite reads as standing rather than floating in a void.
private struct PetStage<Content: View>: View {
    let theme: ThemePack
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .fill(theme.inset)
                .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                Ellipse()
                    .fill(theme.ink.opacity(theme.id == .control ? 0.35 : 0.1))
                    .frame(width: 62, height: 8)
                    .blur(radius: 4)
                    .padding(.top, 2)
            }
            .padding(.vertical, 12)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The egg

/// The hatch, as an event.
///
/// `pet.hatch.progress` reports a real beat — one animation row generated and
/// rastered at a time — so the egg wobbles faster and cracks further with each
/// one, and goes still while the sheet is composed and saved. The motion is
/// derived from the timeline's clock rather than a chain of `withAnimation`
/// calls, so intensity can change mid-flight without restarting anything.
private struct HatchingEgg: View {
    let theme: ThemePack
    /// 0…1 across the sheet's rows.
    let progress: Double
    /// The row work is done; the sheet is being composed and written.
    let settling: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let clamped = min(1, max(0, progress))
            // Still while composing — the shaking is the *drawing*, and it has
            // stopped. Otherwise faster and wider as the rows pile up.
            let speed = settling ? 1.4 : 3.0 + clamped * 9
            let amplitude = settling ? 0.8 : 1.6 + clamped * 5
            let angle = sin(time * speed) * amplitude

            ZStack {
                halo(intensity: clamped)
                    .scaleEffect(1 + 0.04 * sin(time * 1.7))
                EggShape()
                    .fill(shell)
                    .overlay(EggShape().strokeBorder(theme.id == .ink ? theme.ink : theme.lineStrong,
                                                     lineWidth: theme.id == .soft ? 1 : 1.2))
                    .overlay(
                        CrackShape()
                            .trim(from: 0, to: max(0.02, clamped))
                            .stroke(theme.id == .ink ? theme.ink : theme.accent,
                                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                                       lineJoin: .round))
                            .opacity(0.85)
                    )
                    .frame(width: 92, height: 118)
                    .rotationEffect(.degrees(angle), anchor: .bottom)
                    .shadow(color: theme.glowRadius > 0 ? theme.accent.opacity(0.35) : .clear,
                            radius: 10)
            }
        }
    }

    private var shell: LinearGradient {
        LinearGradient(colors: [theme.panel, theme.inset],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Light leaking out through the cracks, brighter with every finished row.
    private func halo(intensity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [theme.accent.opacity(0.05 + 0.3 * intensity), .clear],
                                 center: .center, startRadius: 6, endRadius: 90))
            .frame(width: 190, height: 190)
    }
}

/// An egg: an ellipse with a narrower top.
private struct EggShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> EggShape {
        EggShape(inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let width = box.width, height = box.height
        var path = Path()
        path.move(to: CGPoint(x: box.midX, y: box.minY))
        path.addCurve(to: CGPoint(x: box.maxX, y: box.minY + height * 0.62),
                      control1: CGPoint(x: box.midX + width * 0.30, y: box.minY),
                      control2: CGPoint(x: box.maxX, y: box.minY + height * 0.24))
        path.addCurve(to: CGPoint(x: box.midX, y: box.maxY),
                      control1: CGPoint(x: box.maxX, y: box.minY + height * 0.88),
                      control2: CGPoint(x: box.midX + width * 0.30, y: box.maxY))
        path.addCurve(to: CGPoint(x: box.minX, y: box.minY + height * 0.62),
                      control1: CGPoint(x: box.midX - width * 0.30, y: box.maxY),
                      control2: CGPoint(x: box.minX, y: box.minY + height * 0.88))
        path.addCurve(to: CGPoint(x: box.midX, y: box.minY),
                      control1: CGPoint(x: box.minX, y: box.minY + height * 0.24),
                      control2: CGPoint(x: box.midX - width * 0.30, y: box.minY))
        path.closeSubpath()
        return path
    }
}

/// The fracture line, drawn a little further with every finished row.
private struct CrackShape: Shape {
    private static let points: [CGPoint] = [
        CGPoint(x: 0.52, y: 0.16), CGPoint(x: 0.36, y: 0.30), CGPoint(x: 0.58, y: 0.42),
        CGPoint(x: 0.34, y: 0.54), CGPoint(x: 0.60, y: 0.66), CGPoint(x: 0.40, y: 0.78),
        CGPoint(x: 0.56, y: 0.88),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in Self.points.enumerated() {
            let location = CGPoint(x: rect.minX + rect.width * point.x,
                                   y: rect.minY + rect.height * point.y)
            if index == 0 {
                path.move(to: location)
            } else {
                path.addLine(to: location)
            }
        }
        return path
    }
}

/// The shell going everywhere — one shot, on appear.
private struct HatchBurst: View {
    let theme: ThemePack
    @State private var fired = false

    private static let rays = 12

    var body: some View {
        ZStack {
            ForEach(0..<Self.rays, id: \.self) { index in
                Capsule()
                    .fill(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 3, height: 13)
                    .offset(y: fired ? -78 : -18)
                    .rotationEffect(.degrees(Double(index) / Double(Self.rays) * 360))
                    .opacity(fired ? 0 : 0.9)
                    .scaleEffect(fired ? 0.4 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { fired = true }
        }
    }
}

// MARK: - Images

/// One gallery thumbnail: a `pet.thumb` crop, fetched once and memoized on the
/// pet store. Never a spritesheet — that is the whole point of the RPC.
private struct PetThumbView: View {
    let model: AppModel
    let entry: PetGalleryEntry
    let profile: String
    let theme: ThemePack

    @State private var image: Image?
    @State private var missing = false

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(6)
            } else if missing {
                Text(verbatim: "◇")
                    .font(theme.mono(16))
                    .foregroundStyle(theme.faint)
            } else {
                ProgressView().controlSize(.small).tint(theme.accent)
            }
        }
        .task(id: entry.slug) {
            guard image == nil else { return }
            let data = await model.loadPetThumbnail(entry, profile: profile)
            guard let data, let decoded = petImage(from: data) else {
                missing = true
                return
            }
            image = decoded
        }
    }
}

/// A `data:image/png;base64,…` draft, decoded off the main actor once per URI.
private struct PetDataURIImage: View {
    let uri: String
    let theme: ThemePack

    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(4)
            } else {
                ProgressView().controlSize(.small).tint(theme.accent)
            }
        }
        .task(id: uri) {
            guard image == nil, let data = await decodeDataURI(uri) else { return }
            image = petImage(from: data)
        }
    }
}

/// Base64 is a memcpy-sized job on a megapixel PNG; keep it off the main actor.
private func decodeDataURI(_ uri: String) async -> Data? {
    await Task.detached(priority: .userInitiated) { () -> Data? in
        guard let marker = uri.range(of: "base64,") else { return nil }
        return Data(base64Encoded: String(uri[marker.upperBound...]),
                    options: .ignoreUnknownCharacters)
    }.value
}

@MainActor
private func petImage(from data: Data) -> Image? {
    #if canImport(UIKit)
    return UIImage(data: data).map { Image(uiImage: $0) }
    #elseif canImport(AppKit)
    return NSImage(data: data).map { Image(nsImage: $0) }
    #else
    return nil
    #endif
}

// MARK: - Chrome

private struct PetCardChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        content
            .background(shape.fill(theme.panel))
            .clipShape(shape)
            .overlay(shape.stroke(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 1.5, y: 1)
    }
}

// MARK: - Pet copy (the three voices)

public extension CopyPack {

    func petKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "BOT MODE"
        case .control: "SPRITE UNIT"
        case .ink: "A SMALL LIVING THING"
        }
    }

    func petTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pets"
        case .control: "Mascot"
        case .ink: "The Familiar"
        }
    }

    /// The row that opens this screen from the bot sheet.
    func petRow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pet & appearance"
        case .control: "MASCOT SPRITE"
        case .ink: "its familiar"
        }
    }

    func petActiveSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On duty"
        case .control: "ACTIVE SPRITE"
        case .ink: "in attendance"
        }
    }

    func petGallerySec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Adopt one"
        case .control: "SPRITE LIBRARY"
        case .ink: "the menagerie"
        }
    }

    func petHatchSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Make your own"
        case .control: "SYNTHESIS"
        case .ink: "the quickening"
        }
    }

    func petNone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No pet on duty. Adopt one below and it appears beside this bot while it works."
        case .control: "NO ACTIVE SPRITE. ADOPT ONE — IT RIDES THE ROSTER WHILE THE AGENT RUNS."
        case .ink: "No familiar attends this one. Choose below, and it will keep watch as the work is done."
        }
    }

    func petNoneHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pets are installed but switched off for this bot — adopting one turns them back on."
        case .control: "SPRITES INSTALLED, DISPLAY OFF — ADOPTING RE-ENABLES display.pet."
        case .ink: "The creatures are here but unbidden; call one and it wakes."
        }
    }

    func petLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading…"
        case .control: "READING…"
        case .ink: "looking…"
        }
    }

    func petGalleryEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing to adopt — the petdex is unreachable and nothing is installed."
        case .control: "LIBRARY EMPTY — MANIFEST UNREACHABLE, NO LOCAL SPRITES."
        case .ink: "The menagerie is empty; no creature answers."
        }
    }

    /// Placeholder interpolates the real count — petdex is thousands of pets
    /// and the number is the point.
    func petSearch(_ t: ThemeID, _ count: Int) -> String {
        switch t {
        case .soft: "Search \(count) pets…"
        case .control: "FILTER \(count) SPRITES…"
        case .ink: "seek among \(count) creatures…"
        }
    }

    func petNoMatches(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No pets match."
        case .control: "NO MATCHES."
        case .ink: "none answer to that name."
        }
    }

    func petShowMore(_ t: ThemeID, _ shown: Int, _ total: Int) -> String {
        switch t {
        case .soft: "Show more — \(shown) of \(total)"
        case .control: "LOAD MORE — \(shown)/\(total)"
        case .ink: "show more — \(shown) of \(total)"
        }
    }

    func petOff(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Turn off"
        case .control: "DISABLE"
        case .ink: "dismiss"
        }
    }

    func petScale(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Size"
        case .control: "SCALE"
        case .ink: "stature"
        }
    }

    func petRename(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "RENAME"
        case .ink: "rename"
        }
    }

    func petRenameTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name your pet"
        case .control: "RENAME SPRITE"
        case .ink: "give it a true name"
        }
    }

    func petRenameOK(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save"
        case .control: "APPLY"
        case .ink: "inscribe"
        }
    }

    func petRemove(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "DELETE"
        case .ink: "release it"
        }
    }

    func petRemoveTitle(_ t: ThemeID, _ name: String) -> String {
        switch t {
        case .soft: "Delete \(name)?"
        case .control: "DELETE \(name.uppercased())?"
        case .ink: "Release \(name)?"
        }
    }

    func petRemoveBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Its sprite files are deleted from the gateway. A petdex pet can be adopted again; a hatched one is gone."
        case .control: "SPRITE DIRECTORY REMOVED ON THE GATEWAY. PETDEX ENTRIES RE-ADOPTABLE; HATCHED ONES ARE NOT."
        case .ink: "Its likeness is struck from the gateway. What came from the menagerie may return; what was hatched here cannot."
        }
    }

    func petOnDuty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "ON DUTY"
        case .control: "ACTIVE"
        case .ink: "ATTENDING"
        }
    }

    func petInstalled(_ t: ThemeID) -> String {
        switch t {
        case .soft: "INSTALLED"
        case .control: "LOCAL"
        case .ink: "IN THE HOUSE"
        }
    }

    func petCurated(_ t: ThemeID) -> String {
        switch t {
        case .soft: "PETDEX PICK"
        case .control: "CURATED"
        case .ink: "OF THE CANON"
        }
    }

    func petHatchedBadge(_ t: ThemeID) -> String {
        switch t {
        case .soft: "HATCHED HERE"
        case .control: "SYNTHESIZED"
        case .ink: "QUICKENED HERE"
        }
    }

    func petNoBackend(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway has no image backend configured, so it can’t draw a new pet. Add one in Capabilities."
        case .control: "NO REFERENCE-CAPABLE IMAGE BACKEND — SYNTHESIS UNAVAILABLE. CONFIGURE ONE UNDER CAPABILITIES."
        case .ink: "No hand here can draw a new creature. Grant the gateway an image backend first."
        }
    }

    func petPrompt(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Describe your pet — “a small brass owl with a lantern”"
        case .control: "SPRITE CONCEPT — \"SMALL BRASS OWL, LANTERN\""
        case .ink: "describe the creature — “a small brass owl, bearing a lantern”"
        }
    }

    func petCount(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Drafts"
        case .control: "DRAFTS"
        case .ink: "sketches"
        }
    }

    func petGenerate(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Draw some drafts"
        case .control: "GENERATE DRAFTS"
        case .ink: "sketch it"
        }
    }

    func petGenerateNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Drafts are generated on the gateway, one at a time — a few minutes. They appear here as they land."
        case .control: "GENERATED SERIALLY ON THE GATEWAY OVER A THIRD-PARTY API — MINUTES, NOT SECONDS. DRAFTS STREAM IN."
        case .ink: "Each sketch is drawn in turn upon the gateway; it takes some minutes. They appear as they are finished."
        }
    }

    func petDrafting(_ t: ThemeID, _ done: Int, _ total: Int) -> String {
        switch t {
        case .soft: "Drawing drafts… \(done)/\(total)"
        case .control: "GENERATING \(done)/\(total)…"
        case .ink: "sketching… \(done) of \(total)"
        }
    }

    func petPick(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pick the one you like, give it a name, and hatch it."
        case .control: "SELECT A BASE DRAFT, ASSIGN A NAME, RUN SYNTHESIS."
        case .ink: "Choose a likeness, name it, and let it quicken."
        }
    }

    func petNamePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name"
        case .control: "SPRITE NAME"
        case .ink: "its name"
        }
    }

    func petHatchGo(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Hatch it"
        case .control: "SYNTHESIZE"
        case .ink: "quicken it"
        }
    }

    func petStartOver(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Start over"
        case .control: "RESET"
        case .ink: "begin again"
        }
    }

    func petStop(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Stop"
        case .control: "ABORT"
        case .ink: "stay your hand"
        }
    }

    func petHatchWaking(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Something is stirring…"
        case .control: "PIPELINE WARMING…"
        case .ink: "something stirs within…"
        }
    }

    /// The egg's caption while a single animation row is being drawn.
    func petHatchRow(_ t: ThemeID, _ mood: String, _ done: Int, _ total: Int) -> String {
        switch t {
        case .soft: "Drawing its \(mood)… \(done)/\(total)"
        case .control: "ROW \(done)/\(total) — \(mood.uppercased())"
        case .ink: "drawing its \(mood) — \(done) of \(total)"
        }
    }

    func petHatchCompose(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Putting the sheet together…"
        case .control: "COMPOSING ATLAS…"
        case .ink: "binding the leaves together…"
        }
    }

    func petHatchSave(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Almost out…"
        case .control: "WRITING SPRITE…"
        case .ink: "it is nearly here…"
        }
    }

    func petHatched(_ t: ThemeID, _ name: String) -> String {
        switch t {
        case .soft: "\(name) hatched!"
        case .control: "\(name.uppercased()) SYNTHESIZED"
        case .ink: "\(name) has quickened"
        }
    }

    func petWarningsLead(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rough edges:"
        case .control: "WARNINGS:"
        case .ink: "imperfections:"
        }
    }

    func petAdopt(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Adopt it"
        case .control: "ACTIVATE"
        case .ink: "take it in"
        }
    }

    func petAdopting(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Adopting…"
        case .control: "ACTIVATING…"
        case .ink: "taking it in…"
        }
    }

    func petDiscard(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Discard"
        case .control: "DISCARD"
        case .ink: "let it go"
        }
    }

    /// Animation-row names, in each voice.
    func petMood(_ state: PetState, _ t: ThemeID) -> String {
        switch (t, state) {
        case (.soft, .idle): "idle"
        case (.soft, .wave): "wave"
        case (.soft, .run): "run"
        case (.soft, .failed): "oops"
        case (.soft, .review): "thinking"
        case (.soft, .jump): "cheer"
        case (.soft, .waiting): "waiting"
        case (.control, .idle): "IDLE"
        case (.control, .wave): "WAVE"
        case (.control, .run): "RUN"
        case (.control, .failed): "FAULT"
        case (.control, .review): "REVIEW"
        case (.control, .jump): "JUMP"
        case (.control, .waiting): "HOLD"
        case (.ink, .idle): "repose"
        case (.ink, .wave): "greeting"
        case (.ink, .run): "errand"
        case (.ink, .failed): "dismay"
        case (.ink, .review): "study"
        case (.ink, .jump): "delight"
        case (.ink, .waiting): "vigil"
        }
    }

    func petNoticeLead(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway balked"
        case .control: "PET RPC FAULT"
        case .ink: "the gateway demurs"
        }
    }

    func petFootnote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pets live on the gateway under this bot’s profile — the same mascot your desktop and terminal show."
        case .control: "SPRITES ARE PROFILE-SCOPED ON THE GATEWAY (display.pet.*) — SHARED WITH DESKTOP + TUI SURFACES."
        case .ink: "The familiar is kept with this profile upon the gateway; desktop and terminal see the same creature."
        }
    }
}

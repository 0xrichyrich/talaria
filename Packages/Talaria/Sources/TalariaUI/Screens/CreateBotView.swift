import SwiftUI
import TalariaKit
import TalariaTheme

// New Bot / Edit look & soul sheet — design-map.md §9 "New Bot" (prototype
// screen `create`).
//
// Cancel / title / Create header (Create lights up once a name is set), a
// live avatar preview inside the slow "summoning ring" (control + ink), the
// shape and hue pickers, the grouped @name / job / soul form, the Advanced
// disclosure (model pin + skills + toolsets + MCP) and the profiles.create
// footnote.
//
// Live-mode contract (the fix for the audit's one data-loss bug): edit mode
// opens by reading profiles.describe and prefills EVERYTHING from it — the
// real SOUL.md, the disabled-skill set, the model+provider pin, the toolset
// pin, the MCP list. Save then sends only the sections the user actually
// changed (ProfileEdit, GatewayClient+Profiles.swift). If the describe call
// fails the sheet refuses to write soul/skills/toolsets at all, because it
// has nothing true to diff against — profiles.configure replaces whole
// sections, so a blank field would erase the file.
//
// Cosmetics take the other road (ROADMAP decision #3): title, shape and colour
// are written back into desktop Bot Mode's own ui_meta["hermes-bots"] block
// through AppModelLive+Cosmetics, which read-merges the live block first so a
// phone edit can never clobber the canonical-chat pin or a key it does not
// own. That is a separate configure call from the text sections above,
// deliberately — the merge needs a fresh read that the dirty diff does not.
//
// Demo mode keeps working throughout: the same snapshot shape is synthesized
// from DemoData and every write stays local.

@MainActor
public struct CreateBotView: View {
    @Environment(\.dismiss) private var dismiss
    private let model: AppModel
    /// Non-nil = edit mode, prefilled from this bot + profiles.describe.
    private let editing: Bot?

    /// How far the profiles.describe prefill got. Nothing that replaces a
    /// gateway-side section may be written before `.loaded`.
    private enum Load: Equatable { case loading, loaded, failed }

    @State private var name: String
    /// The user-set display title — desktop's Edit Profile "Title" field,
    /// stored in ui_meta["hermes-bots"].title and read back by
    /// `Bot.displayTitle`. Blank means "keep the derived name", which is why
    /// the placeholder shows what that derived name would be.
    @State private var title: String
    @State private var job: String
    @State private var soul: String
    @State private var shape: AvatarShape
    @State private var hue: AvatarHue
    @State private var showAdvanced = false
    /// Staged avatar bytes (generated or uploaded) — written only by Save.
    @State private var avatar = AvatarDraft()

    // Live catalogs (empty until the gateway answers).
    @State private var modelChoices: [ModelChoice] = []
    @State private var pinnedModel: ModelChoice?
    /// The chip row preselects the gateway's current model; only an actual
    /// tap turns that into a written pin on create.
    @State private var pinTouched = false
    @State private var skillRows: [ProfileSnapshot.Skill] = []
    @State private var disabledSkills: Set<String> = []
    @State private var toolsetRows: [ProfileSnapshot.Toolset] = []
    @State private var enabledToolsets: Set<String> = []
    @State private var mcpRows: [ProfileSnapshot.MCPServer] = []

    /// The gateway's own answer, kept verbatim as the dirty-diff baseline.
    @State private var baseline: ProfileSnapshot?
    @State private var load: Load = .loading

    @State private var saving = false
    @State private var saveFailed = false
    /// Set when the gateway took the profile edit but could not store the look
    /// — an older build with no ui_meta support. Not an error (nothing was
    /// lost that the gateway ever held), but the user should know why the
    /// laptop will not show it.
    @State private var lookUnsupported = false
    @State private var portraitNote: PortraitFailure?

    public init(model: AppModel, editing: Bot? = nil) {
        self.model = model
        self.editing = editing
        _name = State(initialValue: editing?.id ?? "")
        _title = State(initialValue: editing?.title ?? "")
        _job = State(initialValue: editing?.job ?? "")
        // Soul stays EMPTY until profiles.describe answers with the real
        // SOUL.md. It used to be seeded from the profile description, which
        // is what an untouched save then wrote over the file.
        _soul = State(initialValue: "")
        _shape = State(initialValue: editing?.shape ?? .circle)
        _hue = State(initialValue: editing?.hue ?? .teal)
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var style: CreateStyle { CreateStyle(t: theme) }

    private var isEditing: Bool { editing != nil }

    /// Who a generated portrait is of — the name being typed right now, not
    /// the one the profile was saved under, so a rename and a new face can be
    /// decided in the same sitting.
    private var promptName: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return editing?.displayTitle ?? name
    }

    private var canCreate: Bool {
        guard !name.isEmpty, !saving else { return false }
        // A new profile id must be free; edits keep their id.
        guard isEditing || model.bot(name) == nil else { return false }
        // Never let an edit save race the prefill it diffs against.
        return !isEditing || load != .loading
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    avatarPreview
                    AvatarPicker(model: model, botID: editing?.id,
                                 name: promptName, job: job, soul: soul,
                                 shape: $shape, hue: $hue, draft: $avatar)
                    if !isEditing {
                        Text(CopyPack.portraitAfterCreate(theme.id))
                            .font(style.aSubFont)
                            .foregroundStyle(theme.faint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    if isEditing, load != .loaded { prefillBanner }
                    formGroup
                    advancedRow
                    if showAdvanced { advancedBoxes }
                    if saveFailed {
                        Text(CopyPack.editorSaveFailed(theme.id))
                            .font(style.footNoteFont)
                            .foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if lookUnsupported {
                        Text(CopyPack.lookNotStored(theme.id))
                            .font(style.footNoteFont)
                            .foregroundStyle(theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let portraitNote {
                        Text(CopyPack.portraitFailure(portraitNote, theme.id))
                            .font(style.footNoteFont)
                            .foregroundStyle(theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(copy.createNote)
                        .font(style.footNoteFont)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 6, leading: 20, bottom: 60, trailing: 20))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .task { await prefill() }
    }

    // MARK: - Prefill (profiles.describe + model.options)

    /// Edit mode reads the profile it is about to write. Create mode reads
    /// the gateway's default profile purely for a skills catalog — a new
    /// profile is born with the same bundled skills.
    private func prefill() async {
        guard load == .loading else { return }

        async let catalogTask = model.modelChoices()

        let snapshot: ProfileSnapshot?
        if let editing {
            // The stored portrait has to be in the cache before the picker can
            // offer to remove it, and before the preview can show what this
            // bot's face actually is today. Idempotent and cached.
            await model.refreshAvatar(botID: editing.id)
            snapshot = await model.profileSnapshot(botID: editing.id)
        } else if let seed = LiveRuntime.shared.defaultBotID ?? model.bots.first?.id {
            snapshot = await model.profileSnapshot(botID: seed)
        } else {
            snapshot = nil
        }

        modelChoices = await catalogTask

        if isEditing {
            guard let snapshot else {
                load = .failed
                return
            }
            baseline = snapshot
            soul = snapshot.soul
            if job.isEmpty { job = snapshot.description }
            skillRows = snapshot.skills
            disabledSkills = Set(snapshot.disabledSkills)
            toolsetRows = snapshot.toolsets
            enabledToolsets = Set(snapshot.toolsets.filter(\.enabled).map(\.name))
            mcpRows = snapshot.mcpServers
            pinnedModel = resolvedPin(model: snapshot.model, provider: snapshot.provider)
        } else {
            // Catalog only — a not-yet-created profile has no snapshot to diff.
            skillRows = snapshot?.skills ?? []
            toolsetRows = []
            mcpRows = []
            // The gateway's current model reads as picked (prototype default),
            // but an untouched chip row is NOT written as a pin: profiles.create
            // inherits the launch profile's provider+model when none is given.
            pinnedModel = modelChoices.first(where: \.isCurrent) ?? modelChoices.first
        }
        load = .loaded
    }

    /// Match the profile's pin against the live catalog so the chip row
    /// shows it selected; fall back to the profile's own model+provider when
    /// the gateway no longer offers it (a deconfigured provider, say).
    private func resolvedPin(model modelID: String, provider: String) -> ModelChoice? {
        guard !modelID.isEmpty else { return nil }
        if let match = modelChoices.first(where: { $0.model == modelID }) {
            return match.provider.isEmpty && !provider.isEmpty
                ? ModelChoice(model: modelID, provider: provider, providerName: provider)
                : match
        }
        let orphan = ModelChoice(model: modelID, provider: provider, providerName: provider)
        modelChoices.insert(orphan, at: 0)
        return orphan
    }

    // MARK: - Header (Cancel · title · Create)

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text(copy.cancel)
                    .font(style.hdrBtnFont)
                    .tracking(style.hdrTracking)
                    .foregroundStyle(style.cancelFg)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(isEditing ? copy.editLook : copy.createTitle)
                .font(style.sheetTitleFont)
                .tracking(style.sheetTitleTracking)
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                Task { await commit() }
            } label: {
                Group {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(copy.createOk)
                            .font(style.hdrBtnStrongFont)
                            .tracking(style.hdrTracking)
                            .foregroundStyle(canCreate ? theme.accent : theme.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 10, trailing: 18))
    }

    // MARK: - Avatar preview (reacts live to picks, staged image included)

    /// What this bot's face will be once Save lands: the staged image if the
    /// user just generated or chose one, the stored portrait if there is one
    /// and it is not being removed, else the shape × hue silhouette.
    private var avatarPreview: some View {
        ZStack {
            if theme.id != .soft {
                SummonRing(theme: theme)
                    .frame(width: 112, height: 112)
            }
            if let image = previewImage {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(AvatarSilhouette(shape))
                    .overlay(AvatarSilhouette(shape)
                        .stroke(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            } else {
                AvatarView(shape: shape, hue: hue, size: 84, theme: theme)
            }
        }
        .frame(width: 112, height: 112)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var previewImage: Image? {
        if let staged = avatar.image { return ProfileAssetStore.image(from: staged) }
        guard !avatar.clearsImage, let editing,
              let data = ProfileAssetStore.shared.portrait(for: editing.id) else { return nil }
        return ProfileAssetStore.image(from: data)
    }

    // MARK: - Prefill banner (loading / gateway unreadable)

    private var prefillBanner: some View {
        Text(load == .loading ? CopyPack.editorLoading(theme.id)
                              : CopyPack.editorLoadFailed(theme.id))
            .font(style.aSubFont)
            .foregroundStyle(load == .loading ? theme.faint : theme.warn)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
            .modifier(CreateBoxChrome(theme: theme, kind: .box))
    }

    // MARK: - Form (@name · job · soul)

    private var formGroup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("@")
                    .font(style.atFont)
                    .foregroundStyle(theme.accent)
                TextField(copy.phName, text: $name)
                    .textFieldStyle(.plain)
                    .font(style.fieldFont)
                    .foregroundStyle(isEditing ? theme.faint : theme.ink)
                    .tint(theme.accent)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                #endif
                    .disabled(isEditing) // profile ids are immutable post-create
                    .onChange(of: name) { _, newValue in
                        // The name is the profile id: lowercase [a-z0-9-] only.
                        let filtered = String(newValue.lowercased().filter {
                            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
                        })
                        if filtered != newValue { name = filtered }
                    }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))

            Rectangle().fill(theme.line).frame(height: 1)

            // Desktop's Title field (plugin.js:5076-5083). Its placeholder is
            // the DERIVED display name, so leaving it blank visibly means
            // "keep the name Talaria works out" rather than "unnamed".
            TextField(derivedTitle, text: $title)
                .textFieldStyle(.plain)
                .font(style.fieldFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))

            Rectangle().fill(theme.line).frame(height: 1)

            TextField(copy.phJob, text: $job)
                .textFieldStyle(.plain)
                .font(style.fieldFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))

            Rectangle().fill(theme.line).frame(height: 1)

            TextField(soulPlaceholder, text: $soul, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...10)
                .font(style.fieldFont)
                .foregroundStyle(soulEditable ? theme.ink : theme.faint)
                .tint(theme.accent)
                .lineSpacing(3)
                .disabled(!soulEditable)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
        .modifier(CreateBoxChrome(theme: theme, kind: .form))
    }

    /// SOUL.md is only editable once we hold the real file (or on create,
    /// where there is nothing to overwrite).
    private var soulEditable: Bool { !isEditing || load == .loaded }

    private var soulPlaceholder: String {
        guard isEditing else { return copy.phDesc }
        switch load {
        case .loading: return CopyPack.soulLoading(theme.id)
        case .failed: return CopyPack.soulUnavailable(theme.id)
        case .loaded: return copy.phDesc
        }
    }

    /// What the roster would call this bot with no title set — the same rule
    /// every other surface renders (`Bot.displayTitle`), so the placeholder is
    /// literally what blank means.
    private var derivedTitle: String {
        let id = name.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return CopyPack.titleFieldPlaceholder(theme.id) }
        return Bot.unlisted(id: id).displayTitle
    }

    // MARK: - Advanced disclosure

    private var advancedRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) { showAdvanced.toggle() }
        } label: {
            HStack {
                Text(copy.advTitle)
                    .font(style.advTitleFont)
                    .tracking(style.advTitleTracking)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                Text(advHint)
                    .font(style.advHintFont)
                    .tracking(style.advHintTracking)
                    .foregroundStyle(theme.faint)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CreateBoxChrome(theme: theme, kind: .box))
    }

    /// Disclosure hint, ported from the prototype's advHint (not in CopyPack).
    private var advHint: String {
        if showAdvanced {
            switch theme.id {
            case .soft: "hide"
            case .control: "HIDE"
            case .ink: "CONCEAL"
            }
        } else {
            switch theme.id {
            case .soft: "model pin · skills · SOUL.md"
            case .control: "MODEL · SKILLS · SOUL.MD"
            case .ink: "MODEL · GIFTS · SOUL.MD"
            }
        }
    }

    private var advancedBoxes: some View {
        VStack(spacing: 11) {
            advBox {
                secLabel(copy.modelSec)
                if modelChoices.isEmpty {
                    emptyLine(catalogLine(CopyPack.noModels(theme.id)))
                } else {
                    DetailChipFlow(spacing: 7) {
                        ForEach(modelChoices) { candidate in
                            DetailChip(text: candidate.model,
                                       selected: pinnedModel?.model == candidate.model,
                                       theme: theme) {
                                pinnedModel = candidate
                                pinTouched = true
                            }
                        }
                    }
                }
                if let pinnedModel, pinnedModel.provider.isEmpty, isEditing || pinTouched {
                    Text(CopyPack.modelProviderUnknown(theme.id))
                        .font(style.aSubFont)
                        .foregroundStyle(theme.warn)
                        .padding(.top, 1)
                }
            }
            advBox {
                secLabel(copy.skillsSec)
                if skillRows.isEmpty {
                    emptyLine(catalogLine(CopyPack.noSkills(theme.id)))
                } else {
                    DetailChipFlow(spacing: 7) {
                        ForEach(skillRows) { skill in
                            let off = disabledSkills.contains(skill.name)
                            DetailChip(text: skill.name, selected: !off, struck: off,
                                       theme: theme) {
                                guard skillsEditable else { return }
                                if off { disabledSkills.remove(skill.name) }
                                else { disabledSkills.insert(skill.name) }
                            }
                        }
                    }
                    .opacity(skillsEditable ? 1 : 0.5)
                }
                Text(copy.skillsNote)
                    .font(style.aSubFont)
                    .foregroundStyle(theme.sub)
                    .padding(.top, 1)
            }
            if !toolsetRows.isEmpty {
                advBox {
                    secLabel(CopyPack.toolsetsSec(theme.id))
                    DetailChipFlow(spacing: 7) {
                        ForEach(toolsetRows) { toolset in
                            let on = enabledToolsets.contains(toolset.name)
                            DetailChip(text: toolset.label, selected: on, struck: !on,
                                       theme: theme) {
                                guard skillsEditable else { return }
                                if on { enabledToolsets.remove(toolset.name) }
                                else { enabledToolsets.insert(toolset.name) }
                            }
                        }
                    }
                    .opacity(skillsEditable ? 1 : 0.5)
                    Text(CopyPack.toolsetsNote(theme.id))
                        .font(style.aSubFont)
                        .foregroundStyle(theme.sub)
                        .padding(.top, 1)
                }
            }
            if !mcpRows.isEmpty {
                advBox {
                    secLabel(CopyPack.mcpSec(theme.id))
                    ForEach(mcpRows) { server in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(server.enabled ? theme.ok : theme.faint)
                                .frame(width: 6, height: 6)
                            Text(server.name)
                                .font(style.aSubPlainFont)
                                .foregroundStyle(theme.ink)
                            Spacer(minLength: 8)
                            Text(server.transport.uppercased())
                                .font(style.advHintFont)
                                .tracking(1)
                                .foregroundStyle(theme.faint)
                        }
                    }
                    Text(CopyPack.mcpNote(theme.id))
                        .font(style.aSubFont)
                        .foregroundStyle(theme.sub)
                        .padding(.top, 1)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Skill/toolset toggles are replace-semantics writes: only offer them
    /// once the current sets came back from the gateway.
    private var skillsEditable: Bool { !isEditing || load == .loaded }

    /// An empty catalog means three different things — still loading, the
    /// gateway could not be read, or it genuinely has none. Say which.
    private func catalogLine(_ absent: String) -> String {
        if load == .loading { return CopyPack.catalogLoading(theme.id) }
        if isEditing, load == .failed { return CopyPack.catalogUnavailable(theme.id) }
        return absent
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(style.aSubFont)
            .foregroundStyle(theme.faint)
    }

    private func advBox(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .modifier(CreateBoxChrome(theme: theme, kind: .box))
    }

    private func secLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(style.secLabelFont)
            .tracking(style.secLabelTracking)
            .foregroundStyle(theme.faint)
    }

    // MARK: - Commit

    private func commit() async {
        guard canCreate else { return }
        saving = true
        saveFailed = false
        lookUnsupported = false
        portraitNote = nil
        let ok = isEditing ? await applyEdit() : await create()
        saving = false
        // A failed cosmetics write is reported in place rather than dismissing
        // on a lie; everything else that succeeded has already landed.
        if ok, !lookUnsupported, portraitNote == nil { dismiss() }
        if !ok { saveFailed = true }
    }

    /// Create: profiles.create (description + SOUL.md + model pin) then a
    /// configure pass for the sections create does not take — including the
    /// look, in both vocabularies, with the `created` stamp that floats a
    /// brand-new bot to the top of the roster (plugin.js:5399-5401).
    private func create() async -> Bool {
        let created = await model.createBotProfileWithFeedback(
            id: name,
            job: job.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: soul.trimmingCharacters(in: .whitespacesAndNewlines),
            model: pinTouched ? pinnedModel : nil,
            disabledSkills: Array(disabledSkills).sorted(),
            enabledToolsets: nil,
            uiMeta: model.newBotUIMeta(shape: shape, hue: hue, title: title))
        guard created else { return false }
        // A portrait staged before the profile existed can only be written now
        // that it does — the asset store is keyed by profile name.
        await commitAvatar(botID: name)
        return true
    }

    /// Edit: the dirty diff. Every section is compared against the gateway's
    /// own snapshot, and untouched sections are simply not sent.
    private func applyEdit() async -> Bool {
        guard let editing else { return false }
        var edit = ProfileEdit()

        let jobText = job.trimmingCharacters(in: .whitespacesAndNewlines)
        let soulText = soul

        if let baseline {
            if jobText != baseline.description { edit.description = jobText }
            if soulText != baseline.soul { edit.soul = soulText }
            if let pinnedModel,
               pinnedModel.model != baseline.model || pinnedModel.provider != baseline.provider {
                edit.model = pinnedModel.model
                edit.provider = pinnedModel.provider.isEmpty ? baseline.provider : pinnedModel.provider
            }
            let disabled = Array(disabledSkills).sorted()
            if disabled != baseline.disabledSkills { edit.disabledSkills = disabled }
            let baselineToolsets = Set(baseline.toolsets.filter(\.enabled).map(\.name))
            if enabledToolsets != baselineToolsets {
                edit.enabledToolsets = Array(enabledToolsets).sorted()
            }
        } else {
            // No snapshot: cosmetics and the fields the user typed here, only.
            // Soul, skills and toolsets are deliberately left untouched.
            if jobText != (editing.job) { edit.description = jobText }
            if let pinnedModel, !pinnedModel.provider.isEmpty,
               pinnedModel.model != editing.pinnedModel {
                edit.model = pinnedModel.model
                edit.provider = pinnedModel.provider
            }
        }

        if !edit.isEmpty {
            guard await model.saveProfileEditWithFeedback(botID: editing.id, edit: edit) else {
                return false
            }
        }

        // The look is its own write. It has to read the live
        // ui_meta["hermes-bots"] block and merge into it — the dirty diff above
        // has no way to do that, and a bare block would delete the bot's
        // canonical-chat pin, its group and its pin-to-top flag.
        if lookChanged(from: editing) {
            // The feedback wrapper adds desktop's two beats and the ledger row;
            // the three outcomes it returns are the same ones this switch has
            // always handled, and `.unsupported` retracts its own card so the
            // once-per-gateway notice below stays the only thing said.
            switch await model.saveBotLookWithFeedback(botID: editing.id, shape: shape,
                                                       hue: hue, title: title) {
            case .persisted:
                break
            case .unsupported:
                // Said once per gateway and then never again: an old gateway
                // would otherwise hold this sheet open on every single save,
                // which is precisely the trap desktop's three-way outcome
                // exists to avoid (plugin.js:248-262).
                if !RosterSignals.shared.lookUnsupportedNoticed {
                    RosterSignals.shared.lookUnsupportedNoticed = true
                    lookUnsupported = true
                }
            case .failed:
                return false
            }
        }
        await commitAvatar(botID: editing.id)
        return true
    }

    private func lookChanged(from bot: Bot) -> Bool {
        shape != bot.shape || hue != bot.hue
            || title.trimmingCharacters(in: .whitespacesAndNewlines) != (bot.title ?? "")
    }

    /// Write the staged portrait (generated, uploaded, or removed). Bytes go to
    /// the profile asset store, never into ui_meta — the block is 64 KB-capped
    /// and rides every profiles.list (plugin.js:217-227).
    private func commitAvatar(botID: String) async {
        guard !avatar.isEmpty else { return }
        portraitNote = await model.commitAvatarDraft(botID: botID, draft: avatar)
        if portraitNote == nil { avatar = AvatarDraft() }
    }
}

// MARK: - Editor copy (the three voices)

extension CopyPack {

    static func editorLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reading this profile from the gateway — SOUL.md, skills and model pin."
        case .control: "READING PROFILE — SOUL.MD · SKILLS · MODEL PIN"
        case .ink: "The familiar’s papers are being fetched — soul, gifts and chosen mind."
        }
    }

    static func editorLoadFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "Couldn’t read this profile from the gateway. Look and job can still be saved — SOUL.md, skills and toolsets are left exactly as they are."
        case .control:
            "PROFILE READ FAILED. COSMETICS + JOB WRITABLE; SOUL.MD / SKILLS / TOOLSETS UNTOUCHED."
        case .ink:
            "The papers could not be read. Guise and office may still be set; the soul, the gifts and the tools remain as they were."
        }
    }

    /// Placeholder for the Title field before there is a name to derive one
    /// from (the create sheet, first keystroke).
    static func titleFieldPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Display name (optional)"
        case .control: "DISPLAY NAME (OPTIONAL)"
        case .ink: "the name you will call it"
        }
    }

    /// The save landed, but this gateway cannot store ui_meta — the look holds
    /// on this phone until the next roster poll and never reaches desktop.
    /// Desktop stays silent here because its plugin-local store keeps the look;
    /// Talaria has no such store, so saying it once is the honest thing.
    static func lookNotStored(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "This gateway is too old to store looks, so the shape, colour and display name won’t reach your desktop. Update Hermes to keep them."
        case .control:
            "GATEWAY CANNOT STORE UI_META — LOOK IS LOCAL ONLY. UPDATE HERMES TO SYNC."
        case .ink:
            "This gateway keeps no register of guises; the look will not travel to your desk. A newer gateway would remember it."
        }
    }

    static func editorSaveFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused the save — nothing was changed. Try again when it answers."
        case .control: "SAVE REJECTED BY GATEWAY — NO CHANGES WRITTEN."
        case .ink: "The gateway would not take the inscription. Nothing was altered."
        }
    }

    static func soulLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "reading SOUL.md…"
        case .control: "READING SOUL.MD…"
        case .ink: "the soul is being read…"
        }
    }

    static func soulUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "SOUL.md unavailable — left untouched"
        case .control: "SOUL.MD UNREADABLE — LEFT UNTOUCHED"
        case .ink: "the soul could not be read — it is left as it stands"
        }
    }

    static func toolsetsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Toolsets"
        case .control: "TOOLSETS"
        case .ink: "IMPLEMENTS (TOOLSETS)"
        }
    }

    static func toolsetsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap to enable or disable a toolset for this profile."
        case .control: "TAP TO ARM / DISARM A TOOLSET FOR THIS PROFILE."
        case .ink: "Strike through an implement to set it aside."
        }
    }

    static func mcpSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "MCP servers"
        case .control: "MCP SERVERS"
        case .ink: "OUTSIDE SERVANTS (MCP)"
        }
    }

    static func mcpNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "From profiles.describe — add or edit MCP servers on the gateway."
        case .control: "SOURCE: PROFILES.DESCRIBE — EDIT SERVERS GATEWAY-SIDE."
        case .ink: "As the profile records them; their hiring is done at the gateway."
        }
    }

    static func noModels(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway offered no models — it has no inference provider configured yet."
        case .control: "NO MODELS FROM MODEL.OPTIONS — GATEWAY HAS NO PROVIDER."
        case .ink: "No minds are on offer; the gateway keeps no provider yet."
        }
    }

    static func catalogLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "reading…"
        case .control: "READING…"
        case .ink: "being read…"
        }
    }

    static func catalogUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unreadable — left untouched"
        case .control: "UNREADABLE — LEFT UNTOUCHED"
        case .ink: "unreadable — left as it stands"
        }
    }

    static func noSkills(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No skills installed on this profile."
        case .control: "NO SKILLS INSTALLED."
        case .ink: "This one carries no gifts yet."
        }
    }

    static func modelProviderUnknown(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway didn’t name a provider for this model, so the pin can’t be written."
        case .control: "NO PROVIDER SLUG FOR THIS MODEL — PIN NOT WRITABLE."
        case .ink: "No house claims this mind, so the choice cannot be inscribed."
        }
    }

    static func portraitGenerate(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Generate a portrait"
        case .control: "GENERATE PORTRAIT"
        case .ink: "sit for a portrait"
        }
    }

    static func portraitWorking(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Painting…"
        case .control: "GENERATING…"
        case .ink: "the likeness is being drawn…"
        }
    }

    static func portraitAfterCreate(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Portraits are painted after the profile exists — create it, then open Edit look & soul."
        case .control: "PORTRAIT AVAILABLE POST-DEPLOY — EDIT LOOK & SOUL."
        case .ink: "A likeness is drawn only once the familiar is summoned."
        }
    }

    static func portraitFailure(_ failure: PortraitFailure, _ t: ThemeID) -> String {
        switch failure {
        case .notLive:
            switch t {
            case .soft: "Portraits need a live gateway."
            case .control: "PORTRAIT REQUIRES LIVE LINK."
            case .ink: "A likeness requires an open way."
            }
        case .unavailable:
            switch t {
            case .soft: "This gateway has no image provider configured."
            case .control: "NO IMAGE PROVIDER ON GATEWAY."
            case .ink: "This gateway keeps no limner."
            }
        case .noBytes:
            switch t {
            case .soft: "The image stayed on the gateway host — nothing to store as an avatar."
            case .control: "IMAGE RETURNED AS HOST PATH — NO BYTES TO STORE."
            case .ink: "The likeness never left the gateway’s own hall."
            }
        case .tooLarge:
            switch t {
            case .soft: "The portrait came back too large to store (2 MB limit)."
            case .control: "PORTRAIT EXCEEDS 2 MB ASSET LIMIT."
            case .ink: "The likeness is too great a weight to keep (2 MB)."
            }
        case .failed(let message):
            switch t {
            case .soft: "Portrait failed — \(message)"
            case .control: "PORTRAIT FAILED — \(message.uppercased())"
            case .ink: "The portrait failed — \(message)"
            }
        }
    }
}

// MARK: - Summoning ring (prototype ringU 14s; hidden in soft)

fileprivate struct SummonRing: View {
    let theme: ThemePack
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.lineStrong, lineWidth: 1)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(theme.ink, lineWidth: 1)
                .rotationEffect(.degrees(spinning ? 270 : -90))
                .animation(.linear(duration: 14).repeatForever(autoreverses: false),
                           value: spinning)
        }
        .onAppear { spinning = true }
    }
}

// MARK: - Per-theme styles (ported from the prototype's create-screen CSS)

fileprivate struct CreateStyle {
    let t: ThemePack

    // Header
    var cancelFg: Color { t.id == .soft ? t.accent : t.sub }

    var hdrBtnFont: Font {
        switch t.id {
        case .soft: t.body(14, weight: .semibold)
        case .control: t.mono(11, weight: .semibold)
        case .ink: t.body(14, weight: .semibold).smallCaps()
        }
    }

    var hdrBtnStrongFont: Font {
        switch t.id {
        case .soft: t.body(14, weight: .heavy)
        case .control: t.mono(11, weight: .bold)
        case .ink: t.body(14, weight: .bold).smallCaps()
        }
    }

    var hdrTracking: CGFloat { t.id == .soft ? 0 : 1 }

    var sheetTitleFont: Font {
        switch t.id {
        case .soft: t.body(16, weight: .heavy)
        case .control: t.body(15, weight: .heavy)
        case .ink: t.display(20).smallCaps()
        }
    }

    var sheetTitleTracking: CGFloat { t.id == .ink ? 1 : 0 }

    // Form
    var atFont: Font {
        switch t.id {
        case .soft: t.body(14.5, weight: .bold)
        case .control: t.mono(13, weight: .bold)
        case .ink: t.mono(12)
        }
    }

    var fieldFont: Font {
        switch t.id {
        case .soft: t.body(14.5)
        case .control: t.mono(13.5)
        case .ink: t.body(16)
        }
    }

    // Advanced
    var advTitleFont: Font {
        switch t.id {
        case .soft: t.body(14, weight: .bold)
        case .control: t.mono(11, weight: .bold)
        case .ink: t.body(15, weight: .bold).smallCaps()
        }
    }

    var advTitleTracking: CGFloat {
        switch t.id {
        case .soft: 0
        case .control: 1.5
        case .ink: 1
        }
    }

    var advHintFont: Font {
        switch t.id {
        case .soft: t.body(12, weight: .semibold)
        case .control: t.mono(9.5)
        case .ink: t.mono(8.5)
        }
    }

    var advHintTracking: CGFloat { t.id == .ink ? 1 : 0 }

    var secLabelFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .heavy)
        case .control: t.mono(9, weight: .bold)
        case .ink: t.mono(8.5)
        }
    }

    var secLabelTracking: CGFloat { t.id == .soft ? 1 : 2 }

    var aSubFont: Font {
        switch t.id {
        case .soft: t.body(12)
        case .control: t.mono(10)
        case .ink: t.body(13).italic()
        }
    }

    var aSubPlainFont: Font {
        switch t.id {
        case .soft: t.body(13)
        case .control: t.body(12.5)
        case .ink: t.body(14.5)
        }
    }

    var footNoteFont: Font {
        switch t.id {
        case .soft: t.body(11.5)
        case .control: t.mono(9.5)
        case .ink: t.body(13).italic()
        }
    }
}

// MARK: - Box chrome (prototype formCss / advRowCss / advBoxCss)

fileprivate struct CreateBoxChrome: ViewModifier {
    enum Kind {
        /// The name/job/soul group — ink rules it top + bottom only.
        case form
        /// Advanced row and boxes — ink draws a full square border.
        case box
    }

    let theme: ThemePack
    let kind: Kind

    @ViewBuilder func body(content: Content) -> some View {
        switch theme.id {
        case .soft, .control:
            let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            content
                .background(shape.fill(theme.panel))
                .clipShape(shape)
                .overlay(shape.stroke(theme.line, lineWidth: 1))
                .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear,
                        radius: 1.5, y: 1)
        case .ink:
            switch kind {
            case .form:
                content
                    .overlay(alignment: .top) {
                        Rectangle().fill(theme.lineStrong).frame(height: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.lineStrong).frame(height: 1)
                    }
            case .box:
                content
                    .overlay(Rectangle().stroke(theme.lineStrong, lineWidth: 1))
            }
        }
    }
}

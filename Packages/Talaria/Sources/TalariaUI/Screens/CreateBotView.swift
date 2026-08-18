import SwiftUI
import TalariaKit
import TalariaTheme

// New Bot / Edit look & soul sheet — design-map.md §9 "New Bot" (prototype
// screen `create`).
//
// Cancel / title / Create header (Create lights up once a name is set), a
// live avatar preview inside the slow "summoning ring" (control + ink), the
// shape and hue pickers, the grouped @name / job / soul form, the Advanced
// disclosure (model pin + skills chips) and the profiles.create footnote.
//
// Demo mode appends to the roster; live mode drives profiles.create +
// profiles.configure (ui_meta carries talaria:{shape,hue}) then refreshes the
// roster. Edit mode ("Edit look & soul") prefills from the bot and calls
// profiles.configure only — the profile id itself is immutable here, matching
// the CLI-only lifecycle noted on the profile sheet.

@MainActor
public struct CreateBotView: View {
    @Environment(\.dismiss) private var dismiss
    private let model: AppModel
    /// Non-nil = edit mode, prefilled from this bot.
    private let editing: Bot?

    @State private var name: String
    @State private var job: String
    @State private var soul: String
    @State private var shape: AvatarShape
    @State private var hue: AvatarHue
    @State private var pinnedModel: String?
    @State private var excludedSkills: Set<String> = []
    @State private var showAdvanced = false

    public init(model: AppModel, editing: Bot? = nil) {
        self.model = model
        self.editing = editing
        _name = State(initialValue: editing?.id ?? "")
        _job = State(initialValue: editing?.job ?? "")
        _soul = State(initialValue: editing?.description ?? "")
        _shape = State(initialValue: editing?.shape ?? .circle)
        _hue = State(initialValue: editing?.hue ?? .teal)
        _pinnedModel = State(initialValue: editing?.pinnedModel)
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var style: CreateStyle { CreateStyle(t: theme) }

    /// The six roster hues, in the prototype's DB.HUES order (no gateway grey).
    private static let hues: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]

    private var isEditing: Bool { editing != nil }

    private var canCreate: Bool {
        guard !name.isEmpty else { return false }
        // A new profile id must be free; edits keep their id.
        return isEditing || model.bot(name) == nil
    }

    /// Prototype default: the first model chip reads as picked until changed.
    private var effectiveModel: String? { pinnedModel ?? model.models.first }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    avatarPreview
                    shapePicker
                    huePicker
                    formGroup
                    advancedRow
                    if showAdvanced { advancedBoxes }
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
                commit()
            } label: {
                Text(copy.createOk)
                    .font(style.hdrBtnStrongFont)
                    .tracking(style.hdrTracking)
                    .foregroundStyle(canCreate ? theme.accent : theme.faint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 10, trailing: 18))
    }

    // MARK: - Avatar preview (reacts live to shape/hue picks)

    private var avatarPreview: some View {
        ZStack {
            if theme.id != .soft {
                SummonRing(theme: theme)
                    .frame(width: 112, height: 112)
            }
            AvatarView(shape: shape, hue: hue, size: 84, theme: theme)
        }
        .frame(width: 112, height: 112)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Shape picker

    private var shapePicker: some View {
        HStack(spacing: 8) {
            ForEach(AvatarShape.allCases, id: \.self) { candidate in
                let on = shape == candidate
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { shape = candidate }
                } label: {
                    AvatarSilhouette(candidate)
                        .fill(on ? theme.color(for: hue) : theme.faint)
                        .frame(width: 20, height: 20)
                        .frame(width: 34, height: 34)
                        .background(shapeWrap(on: on))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Selection chrome per theme: soft = tinted rounded pad, control =
    /// terminal cell with accent border, ink = a 2pt rule under the glyph.
    @ViewBuilder private func shapeWrap(on: Bool) -> some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? theme.accent.opacity(0.12) : .clear)
        case .control:
            let cell = RoundedRectangle(cornerRadius: 7, style: .continuous)
            cell.fill(theme.panel)
                .overlay(cell.stroke(on ? theme.accent.opacity(0.5) : theme.line, lineWidth: 1))
        case .ink:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(on ? theme.ink : .clear)
                    .frame(height: 2)
            }
        }
    }

    // MARK: - Hue picker

    private var huePicker: some View {
        HStack(spacing: 9) {
            ForEach(Self.hues, id: \.self) { candidate in
                let on = hue == candidate
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { hue = candidate }
                } label: {
                    swatchShape
                        .fill(theme.color(for: candidate))
                        .frame(width: 23, height: 23)
                        .overlay(swatchRing(on: on))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Control renders square telemetry swatches; the others are dots.
    private var swatchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 11.5, style: .continuous)
    }

    /// Ink signals selection with a parchment gap + ink halo; the others use
    /// a plain ink border.
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

            TextField(copy.phJob, text: $job)
                .textFieldStyle(.plain)
                .font(style.fieldFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))

            Rectangle().fill(theme.line).frame(height: 1)

            TextField(copy.phDesc, text: $soul, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .font(style.fieldFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .lineSpacing(3)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
        .modifier(CreateBoxChrome(theme: theme, kind: .form))
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
                DetailChipFlow(spacing: 7) {
                    ForEach(model.models, id: \.self) { candidate in
                        DetailChip(text: candidate,
                                   selected: effectiveModel == candidate,
                                   theme: theme) {
                            pinnedModel = candidate
                        }
                    }
                }
            }
            advBox {
                secLabel(copy.skillsSec)
                DetailChipFlow(spacing: 7) {
                    ForEach(model.skills, id: \.self) { skill in
                        let off = excludedSkills.contains(skill)
                        DetailChip(text: skill, selected: !off, struck: off, theme: theme) {
                            if off { excludedSkills.remove(skill) }
                            else { excludedSkills.insert(skill) }
                        }
                    }
                }
                Text(copy.skillsNote)
                    .font(style.aSubFont)
                    .foregroundStyle(theme.sub)
                    .padding(.top, 1)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
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

    private func commit() {
        guard canCreate else { return }
        let soulText = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            applyEdit(to: editing, soul: soulText)
        } else {
            create(soul: soulText)
        }
        dismiss()
    }

    /// Demo: joins the roster immediately. Live: same optimistic append, then
    /// profiles.create + profiles.configure (ui_meta) and a roster refresh.
    private func create(soul: String) {
        // Fallback job + preview copy ported from the prototype (not in CopyPack).
        let bot = Bot(id: name,
                      job: job.isEmpty ? "General agent" : job,
                      shape: shape, hue: hue, status: .idle,
                      preview: "Profile created. Say hello.", previewTime: "new",
                      unread: 0,
                      description: soul.isEmpty ? nil : soul,
                      pinnedModel: pinnedModel)
        model.bots.append(bot)

        guard model.mode == .live, let client = model.client else { return }
        let meta = uiMeta
        let disabled = excludedSkills.isEmpty ? nil : Array(excludedSkills).sorted()
        Task { @MainActor in
            try? await client.createProfile(name: bot.id, description: bot.job,
                                            soul: soul.isEmpty ? nil : soul,
                                            model: pinnedModel)
            try? await client.configureProfile(name: bot.id,
                                              disabledSkills: disabled,
                                              uiMeta: meta)
            try? await model.refreshRoster()
        }
    }

    /// Edit look & soul: mutate the roster entry in place (status, preview and
    /// unread state survive), then profiles.configure under the original id.
    private func applyEdit(to editing: Bot, soul: String) {
        if let idx = model.bots.firstIndex(where: { $0.id == editing.id }) {
            if !job.isEmpty { model.bots[idx].job = job }
            model.bots[idx].shape = shape
            model.bots[idx].hue = hue
            model.bots[idx].description = soul.isEmpty ? nil : soul
            model.bots[idx].pinnedModel = pinnedModel
        }

        guard model.mode == .live, let client = model.client else { return }
        let meta = uiMeta
        let disabled = excludedSkills.isEmpty ? nil : Array(excludedSkills).sorted()
        let jobText = job
        Task { @MainActor in
            try? await client.configureProfile(name: editing.id,
                                              description: jobText.isEmpty ? nil : jobText,
                                              soul: soul.isEmpty ? nil : soul,
                                              model: pinnedModel,
                                              disabledSkills: disabled,
                                              uiMeta: meta)
            try? await model.refreshRoster()
        }
    }

    /// Shape × hue rides along in profile ui_meta so every client renders the
    /// same look; AppModel+Live reads the same keys back on roster refresh.
    private var uiMeta: JSONValue {
        ["talaria": ["shape": .string(shape.rawValue), "hue": .string(hue.rawValue)]]
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

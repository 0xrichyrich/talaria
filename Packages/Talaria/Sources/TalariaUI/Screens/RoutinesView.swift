import SwiftUI
import TalariaKit
import TalariaTheme

// Routines — pushed from a bot's chat. This bot's routines (with themed
// toggles, run-now and delete), a "+ new routine" composer, an "Other bots"
// ledger, and the Hermes-cron footnote. Ported from Talaria.dc.html
// `data-screen-label="Routines"`.
//
// Live wiring (AppModelLive+Feeds.swift + GatewayClient+Cron.swift):
//   list   → cron.manage {action:"list", include_disabled:true, profile?}
//   toggle → cron.manage {action:"pause"|"resume", name:<job_id>}  ← the
//            gateway's real vocabulary; there is no enable/disable action.
//   create → cron.manage {action:"add", name:"[bot:<id>] <title>", schedule,
//            prompt, profile}
//   delete → cron.manage {action:"remove", name:<job_id>}
//   run    → POST /api/cron/jobs/<job_id>/trigger (no WS equivalent exists)
// Demo mode keeps flipping the canned rows locally and hides the live actions.

public struct RoutinesView: View {
    private let model: AppModel
    private let botID: String
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var showCompose = false
    @State private var busyRoutineID: String?
    @State private var actionError: String?
    @State private var actionNote: String?

    public init(model: AppModel, botID: String, onBack: (() -> Void)? = nil) {
        self.model = model
        self.botID = botID
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var feeds: FeedsRuntime { FeedsRuntime.shared }

    private var mine: [Routine] { model.routines.filter { $0.botID == botID } }
    private var others: [Routine] { model.routines.filter { $0.botID != botID } }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
                    if let message = actionError ?? feeds.routinesError {
                        noticeLine(message, tone: theme.danger)
                    } else if let actionNote {
                        noticeLine(actionNote, tone: theme.ok)
                    }

                    ForEach(Array(mine.enumerated()), id: \.element.id) { index, routine in
                        RoutineRow(routine: routine, theme: theme, copy: copy,
                                   isBusy: busyRoutineID == routine.id,
                                   showsActions: model.mode == .live,
                                   toggle: { model.setRoutineEnabled(routine, enabled: !routine.isOn) },
                                   runNow: { runNow(routine) },
                                   remove: { remove(routine) })
                            .modifier(RowEntrance(delay: Double(index) * 0.055))
                    }

                    if mine.isEmpty {
                        emptyLine
                    }

                    newRoutineRow

                    if !others.isEmpty {
                        Text(copy.otherBots)
                            .font(theme.mono(theme.id == .soft ? 11 : 9, weight: .heavy))
                            .tracking(theme.id == .soft ? 1 : 2)
                            .textCase(.uppercase)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                            .padding(.top, 12)
                            .padding(.horizontal, 2)

                        ForEach(others) { routine in
                            otherBotRow(routine)
                        }
                    }

                    Text(copy.cronNote)
                        .font(footnoteFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                        .padding(.top, 8)

                    if model.mode == .live, !feeds.routinesNote.isEmpty {
                        Text(feeds.routinesNote)
                            .font(footnoteFont)
                            .foregroundStyle(theme.faint)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            model.attachActivityRouter()
            await model.refreshRoutinesLive()
        }
        .sheet(isPresented: $showCompose) {
            NewRoutineSheet(model: model, botID: botID)
        }
    }

    // MARK: Actions

    private func runNow(_ routine: Routine) {
        busyRoutineID = routine.id
        actionError = nil
        actionNote = nil
        Task { @MainActor in
            defer { busyRoutineID = nil }
            do {
                // A finished-inline run is the exception; the usual answer is
                // "claimed and running", which is not an error to report.
                _ = try await model.runRoutineNow(routine)
                actionNote = copy.routineRunStarted(theme.id)
            } catch {
                actionError = (error as? GatewayError)?.message ?? error.localizedDescription
            }
        }
    }

    private func remove(_ routine: Routine) {
        busyRoutineID = routine.id
        actionError = nil
        actionNote = nil
        Task { @MainActor in
            defer { busyRoutineID = nil }
            do {
                try await model.deleteRoutine(routine)
            } catch {
                actionError = (error as? GatewayError)?.message ?? error.localizedDescription
            }
        }
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
                    .clipShape(iconButtonShape)
                    .overlay(iconButtonShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.kickerRoutines)
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(verbatim: "\(copy.titleRoutines) \(model.botName(botID, theme.id))")
                    .font(subtitleFont)
                    .foregroundStyle(theme.ink)
            }

            Spacer(minLength: 6)

            if model.mode == .live {
                Button {
                    Task { await model.refreshRoutinesLive(force: true) }
                } label: {
                    Text(verbatim: "↻")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                        .frame(width: 31, height: 31)
                        .background(theme.id == .ink ? Color.clear : theme.panel)
                        .clipShape(iconButtonShape)
                        .overlay(iconButtonShape.strokeBorder(
                            theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
                        .opacity(feeds.routinesBusy ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(feeds.routinesBusy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var iconButtonShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    private var footnoteFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }

    private func noticeLine(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(footnoteFont)
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var emptyLine: some View {
        Text(model.mode == .live ? copy.scheduleHelp(theme.id) : copy.cronNote)
            .font(footnoteFont)
            .italic(theme.id == .ink)
            .foregroundStyle(theme.faint)
            .padding(.vertical, 10)
    }

    // MARK: Rows

    private var newRoutineRow: some View {
        Button {
            showCompose = true
        } label: {
            Text(copy.newRoutine)
                .font(newRoutineFont)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(12)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.rowRadius > 0 ? theme.cardRadius : 0,
                                     style: .continuous)
                        .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.dashColor,
                                      style: StrokeStyle(lineWidth: theme.id == .soft ? 1.5 : 1,
                                                         dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newRoutineFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private func otherBotRow(_ routine: Routine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(model.botName(routine.botID, theme.id))
                .font(otherNameFont)
                .foregroundStyle(theme.color(for: model.bot(routine.botID)?.hue ?? .teal))
            Text(routine.name)
                .font(theme.body(theme.id == .ink ? 14.5 : (theme.id == .control ? 12.5 : 13)))
                .foregroundStyle(theme.sub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(routine.schedule)
                .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(theme.id == .ink ? 9 : 10))
                .foregroundStyle(theme.faint)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var otherNameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }
}

// MARK: - One routine row with themed toggle + actions

private struct RoutineRow: View {
    let routine: Routine
    let theme: ThemePack
    let copy: CopyPack
    let isBusy: Bool
    let showsActions: Bool
    let toggle: () -> Void
    let runNow: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name)
                    .font(nameFont)
                    .foregroundStyle(theme.ink)
                Text(verbatim: scheduleLine)
                    .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                    .foregroundStyle(theme.sub)
                if !routine.last.isEmpty {
                    Text(routine.last)
                        .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                        .italic(theme.id == .ink)
                        .foregroundStyle(routine.isOn ? theme.ok : theme.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsActions {
                Menu {
                    Button(copy.runNow(theme.id), action: runNow)
                    Button(copy.deleteRoutineLabel(theme.id), role: .destructive, action: remove)
                } label: {
                    Text(verbatim: "···")
                        .font(theme.mono(13, weight: .bold))
                        .foregroundStyle(theme.faint)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .fixedSize()
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
            }

            ThemedToggle(isOn: routine.isOn, theme: theme, action: toggle)
        }
        .modifier(RoutineRowChrome(theme: theme))
        .contextMenu {
            if showsActions {
                Button(copy.runNow(theme.id), action: runNow)
                Button(copy.deleteRoutineLabel(theme.id), role: .destructive, action: remove)
            }
        }
    }

    /// "every 30m · next in 22h 18m" — the next column is empty for a paused
    /// job, so the separator only appears when there is something to separate.
    private var scheduleLine: String {
        routine.next.isEmpty ? routine.schedule
                             : "\(routine.schedule) · \(copy.next) \(routine.next)"
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(14, weight: .bold)
        case .ink: theme.body(17.5, weight: .bold)
        }
    }
}

// MARK: - New routine composer

/// Schedule + prompt, the two things a Hermes cron job needs. The schedule
/// field takes the phrases people actually type and normalizes them into the
/// gateway's narrow grammar (HermesSchedule), showing the result before send.
private struct NewRoutineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let botID: String

    @State private var title = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var repeatForever = true
    @State private var continuity = false
    @State private var saving = false
    @State private var error: String?

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private static let presets: [(soft: String, control: String, ink: String, value: String)] = [
        ("every morning at 7", "0 7 * * *", "every morning at seven", "0 7 * * *"),
        ("weekdays at 9", "0 9 * * 1-5", "weekdays at nine", "0 9 * * 1-5"),
        ("every hour", "every 1h", "hourly", "every 1h"),
        ("every 30m", "every 30m", "every half hour", "every 30m"),
    ]

    private var normalized: String? { HermesSchedule.normalize(schedule) }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && normalized != nil && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field(copy.routineNamePlaceholder(theme.id), text: $title, lines: 1)
                    field(copy.routineSchedulePlaceholder(theme.id), text: $schedule, lines: 1)
                    presetRow
                    scheduleEcho
                    field(copy.routinePromptPlaceholder(theme.id), text: $prompt, lines: 4)
                    optionRow(copy.repeatForever(theme.id), isOn: $repeatForever)
                    optionRow(copy.continuityLabel(theme.id), isOn: $continuity)
                    if let error {
                        Text(error)
                            .font(footFont)
                            .foregroundStyle(theme.danger)
                    }
                    Text(copy.cronNote)
                        .font(footFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button(copy.cancel) { dismiss() }
                .buttonStyle(.plain)
                .font(headerButtonFont)
                .foregroundStyle(theme.id == .soft ? theme.accent : theme.sub)
            Spacer()
            Text(copy.newRoutineTitle(theme.id))
                .font(titleFont)
                .foregroundStyle(theme.ink)
            Spacer()
            Button(copy.createOk) { create() }
                .buttonStyle(.plain)
                .font(headerButtonFont)
                .foregroundStyle(canCreate ? (theme.id == .ink ? theme.accent : theme.accent) : theme.faint)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Self.presets, id: \.value) { preset in
                    let label = theme.id == .soft ? preset.soft
                        : theme.id == .control ? preset.control : preset.ink
                    Button {
                        schedule = preset.value
                    } label: {
                        Text(label)
                            .font(theme.id == .control ? theme.mono(10) : theme.body(12))
                            .foregroundStyle(schedule == preset.value ? theme.accent : theme.sub)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 11)
                            .chipShell(theme)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder private var scheduleEcho: some View {
        if schedule.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if let normalized {
            Text(verbatim: "→ \(normalized)")
                .font(theme.mono(theme.id == .ink ? 10 : 10.5))
                .foregroundStyle(theme.ok)
        } else {
            Text(copy.scheduleHelp(theme.id))
                .font(footFont)
                .foregroundStyle(theme.warn)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, lines: Int) -> some View {
        TextField(placeholder, text: text, axis: lines > 1 ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .lineLimit(lines > 1 ? lines...(lines + 6) : 1...1)
            .font(fieldFont)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .autocorrectionDisabled(lines == 1)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(theme.id == .ink ? Color.clear : theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: theme.inputRadius > 100 ? 14 : theme.inputRadius,
                                        style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.inputRadius > 100 ? 14 : theme.inputRadius,
                                      style: .continuous)
                .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
    }

    private func optionRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(theme.id == .control ? theme.mono(11) : theme.body(theme.id == .ink ? 14.5 : 13))
                .foregroundStyle(theme.sub)
            Spacer(minLength: 8)
            ThemedToggle(isOn: isOn.wrappedValue, theme: theme) { isOn.wrappedValue.toggle() }
        }
        .padding(.vertical, 2)
    }

    private func create() {
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await model.createRoutine(botID: botID, title: title,
                                              schedule: schedule, prompt: prompt,
                                              repeatCount: repeatForever ? nil : 1,
                                              continuity: continuity)
                dismiss()
            } catch {
                self.error = (error as? GatewayError)?.message ?? error.localizedDescription
            }
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(17, weight: .heavy)
        case .control: theme.mono(13, weight: .bold)
        case .ink: theme.display(20, weight: .bold).smallCaps()
        }
    }

    private var headerButtonFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.mono(11, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var fieldFont: Font {
        switch theme.id {
        case .soft: theme.body(14)
        case .control: theme.mono(12)
        case .ink: theme.body(15.5)
        }
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

/// Row chrome per rowStyle: soft = floating card, control = terminal panel,
/// ink = ruled ledger line.
private struct RoutineRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

/// The design's 46×27 custom switch (trackOn/trackOff/knobCss tokens).
private struct ThemedToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.strokeBorder(trackBorder, lineWidth: 1))
                knobShape
                    .fill(knobFill)
                    .frame(width: 21, height: 21)
                    .shadow(color: theme.id == .soft ? Color.black.opacity(0.2) : .clear,
                            radius: 1.5, y: 1)
                    .offset(x: isOn ? 21 : 2.5)
            }
            .frame(width: 46, height: 27)
            .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var knobShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 10.5, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackBorder: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.lineStrong
        case .ink: theme.lineStrong
        }
    }

    private var knobFill: Color {
        switch theme.id {
        case .soft: theme.panel
        case .control: theme.ink
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.35)
        }
    }
}

// MARK: - Shared row helpers (file-scoped copies; each screen file keeps its own)

private extension ThemePack {
    var dashColor: Color {
        switch id {
        case .soft: ink.opacity(0.15)
        case .control: accent.opacity(0.25)
        case .ink: lineStrong
        }
    }
}

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.38).delay(delay)) { shown = true }
            }
    }
}

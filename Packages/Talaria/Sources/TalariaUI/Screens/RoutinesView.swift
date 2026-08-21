import SwiftUI
import TalariaKit
import TalariaTheme

// Routines — pushed from a bot's chat. This bot's routines (with themed
// toggles, a state pip, run-now and delete), a "+ new routine" composer, an
// "Other bots" ledger, and the Hermes-cron footnote. Ported from
// Talaria.dc.html `data-screen-label="Routines"`.
//
// Live wiring (AppModelLive+Feeds.swift, AppModelLive+Cron2.swift,
// GatewayClient+Cron.swift, GatewayClient+Cron2.swift):
//   list   → cron.manage {action:"list", include_disabled:true, profile?}
//   toggle → cron.manage {action:"pause"|"resume", name:<job_id>}  ← the
//            gateway's real vocabulary; there is no enable/disable action.
//   create → cron.manage {action:"add", …} then PUT for deliver/model, which
//            the socket's add cannot carry
//   delete → cron.manage {action:"remove", name:<job_id>}
//   run    → POST /api/cron/jobs/<job_id>/trigger (no WS equivalent exists)
//   detail → GET  /api/cron/jobs/<job_id> (+ /runs) — the editor screen
// Demo mode keeps flipping the canned rows locally and hides the live actions.
//
// One security behaviour lives here rather than in the editor: a routine
// carrying the PRE-v2 delegation wrapper interpolated unescaped text into a
// shell command, so every armed one is paused on sight and can never be
// re-armed from the phone (AppModel.quarantineLegacyRoutines; desktop does the
// same at plugin.js:5990).

public struct RoutinesView: View {
    private let model: AppModel
    private let botID: String
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var composing = false
    @State private var editing: Routine?
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

    private var pushTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    public var body: some View {
        ZStack {
            listScreen

            // The detail/editor screen, pushed over the list. RoutinesView is
            // itself a push from chat, so this keeps the same gesture grammar
            // rather than stacking a sheet on top of a pushed screen.
            if let routine = editing {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    RoutineEditorView(model: model, mode: .edit(routine), botID: botID) {
                        withAnimation(.easeOut(duration: 0.32)) { editing = nil }
                    }
                }
                .transition(pushTransition)
            }

            if composing {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    RoutineEditorView(model: model, mode: .create, botID: botID) {
                        withAnimation(.easeOut(duration: 0.32)) { composing = false }
                    }
                }
                .transition(pushTransition)
            }
        }
    }

    private var listScreen: some View {
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
                                   state: state(of: routine),
                                   quarantined: model.routineIsQuarantined(routine),
                                   isBusy: busyRoutineID == routine.id,
                                   showsActions: model.mode == .live
                                       && model.routineHasFullManagement(routine),
                                   runNowAvailable: model.cronRESTReady(routineID: routine.id),
                                   open: { open(routine) },
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
            model.attachCronDetailRouter()
            await model.refreshRoutinesLive()
            await model.quarantineLegacyRoutines()
        }
        .onChange(of: CronDetailRuntime.shared.changeTick) {
            // A job added from the CLI or desktop lands here as cron.changed;
            // the quarantine has to see it too, not just what was on screen at
            // first paint. It is a no-op when nothing matches.
            Task { await model.quarantineLegacyRoutines() }
        }
    }

    // MARK: Actions

    /// Demo mode opens the same screen; it just has nothing live to read, so
    /// the REST-backed sections stay hidden and nothing can be saved.
    private func open(_ routine: Routine) {
        actionError = nil
        actionNote = nil
        guard model.routineHasFullManagement(routine) else { return }
        withAnimation(.easeOut(duration: 0.32)) { editing = routine }
    }

    private func runNow(_ routine: Routine) {
        guard model.cronRESTReady(routineID: routine.id) else {
            actionError = copy.needsRESTNote(theme.id)
            actionNote = nil
            return
        }
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
                actionError = AppModel.reason(error)
            }
        }
    }

    private func remove(_ routine: Routine) {
        busyRoutineID = routine.id
        actionError = nil
        actionNote = nil
        Task { @MainActor in
            defer { busyRoutineID = nil }
            // Routines is a pushed screen rather than a sheet, so the toast is
            // actually visible here — and it is the only thing that puts a
            // routine deletion into the Activity ledger. `cron.manage` reports
            // its own failures inside a successful envelope, which the wrapper
            // surfaces in the gateway's own words.
            actionError = await model.deleteRoutineWithFeedback(routine)
        }
    }

    /// The row's lifecycle state, from the socket listing. Desktop keys its
    /// status pip off the same field (`jobState`, app/cron/job-state.ts:16).
    private func state(of routine: Routine) -> String {
        guard let job = feeds.cronJobs[routine.id] else {
            return routine.isOn ? "scheduled" : "disabled"
        }
        if (job.lastStatus ?? "").lowercased() == "error"
            || (job.lastStatus ?? "") == "blocked_config" { return "error" }
        let state = job.state.trimmingCharacters(in: .whitespaces)
        return state.isEmpty ? (job.enabled ? "scheduled" : "disabled") : state
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
            withAnimation(.easeOut(duration: 0.32)) { composing = true }
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
    /// Lifecycle state as the gateway reports it, for the status pip.
    let state: String
    /// A pre-v2 delegated routine: readable and deletable, never re-armable.
    let quarantined: Bool
    let isBusy: Bool
    let showsActions: Bool
    let runNowAvailable: Bool
    let open: () -> Void
    let toggle: () -> Void
    let runNow: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Pinned to the title line, not the row's vertical centre — the
            // pip answers "what state is this in", which reads as part of the
            // name rather than of the schedule underneath it.
            Circle()
                .fill(pipTone)
                .frame(width: 6, height: 6)
                .padding(.top, pipDrop)
                .frame(maxHeight: .infinity, alignment: .top)

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(nameFont)
                        .foregroundStyle(theme.ink)
                    Text(verbatim: scheduleLine)
                        .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                        .foregroundStyle(theme.sub)
                    if quarantined {
                        Text(copy.routineQuarantineWhy(theme.id))
                            .font(theme.id == .control ? theme.mono(9) : theme.body(theme.id == .ink ? 12.5 : 11))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !routine.last.isEmpty {
                        Text(routine.last)
                            .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12))
                            .italic(theme.id == .ink)
                            .foregroundStyle(routine.isOn ? theme.ok : theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsActions {
                Menu {
                    Button(copy.routineEditAction(theme.id), action: open)
                    if runNowAvailable {
                        Button(copy.runNow(theme.id), action: runNow).disabled(quarantined)
                    } else {
                        Text(copy.needsRESTNote(theme.id))
                    }
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

            // A quarantined routine's switch is dead on purpose: re-arming it
            // would run the unescaped shell wrapper it was written with.
            RoutineSwitch(isOn: routine.isOn && !quarantined, theme: theme) {
                guard !quarantined else { return }
                toggle()
            }
            .opacity(quarantined ? 0.4 : 1)
        }
        .modifier(RoutineRowChrome(theme: theme))
        .contextMenu {
            if showsActions {
                Button(copy.routineEditAction(theme.id), action: open)
                if runNowAvailable {
                    Button(copy.runNow(theme.id), action: runNow).disabled(quarantined)
                } else {
                    Text(copy.needsRESTNote(theme.id))
                }
                Button(copy.deleteRoutineLabel(theme.id), role: .destructive, action: remove)
            }
        }
    }

    /// Where the pip sits relative to the row's top edge, so it lands on the
    /// title's x-height in each theme's type scale.
    private var pipDrop: CGFloat {
        switch theme.id {
        case .soft: 7
        case .control: 7
        case .ink: 9
        }
    }

    /// Desktop's STATE_DOT palette (app/cron/job-state.ts:5) in theme tokens:
    /// live states take the accent, paused amber, error destructive, and a
    /// spent or disabled job goes quiet.
    private var pipTone: Color {
        if quarantined { return theme.danger }
        switch state.lowercased() {
        case "error": return theme.danger
        case "paused": return theme.warn
        case "completed", "disabled": return theme.faint
        default: return routine.isOn ? theme.accent : theme.faint
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

/// The design's 46×27 custom switch (trackOn/trackOff/knobCss tokens). Shared
/// with the routine editor's option rows.
struct RoutineSwitch: View {
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

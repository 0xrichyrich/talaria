import SwiftUI
import TalariaKit
import TalariaTheme

// One routine, whole: what it does, when, where its output goes, which model it
// runs on, why it stopped firing — and every run it has ever produced, each one
// a tap away from the transcript it wrote.
//
// This is the screen the routines list could never be. `cron.manage list`
// projects jobs through `_format_job` (tools/cronjob_tools.py:620), which
// truncates the prompt at 100 characters and drops `last_error`,
// `provider_snapshot` and `model_snapshot` entirely — so the list can say
// "failed" and nothing more. The REST cron router returns the stored record and
// the run sessions (GatewayClient+Cron2.swift documents both), and this screen
// is what those two reads are for.
//
// Everything REST-only hides when the gateway has no cron router: the fields
// stay readable, editing/history/pinning disappear, and pause/resume/delete —
// which ride the socket — keep working.

public struct RoutineEditorView: View {

    public enum Mode: Equatable {
        /// Compose a new routine for `botID`.
        case create
        /// Open an existing one. Carries the list row so the screen has
        /// something true to render before the detail read lands.
        case edit(Routine)
    }

    private let model: AppModel
    private let mode: Mode
    private let botID: String
    private let onBack: () -> Void

    // Draft state, plus the values it was seeded with. `cron.changed` can land
    // mid-edit (another client saved, a run finished), so a refresh reseeds
    // only while the draft still matches what was last read — comparing against
    // the baseline is exact where a "user typed something" flag is not: seeding
    // the fields itself trips every onChange the flag would listen to.
    @State private var title = ""
    @State private var schedule = ""
    @State private var instruction = ""
    @State private var deliver: [String] = ["local"]
    @State private var modelPin = ""
    @State private var providerPin = ""
    /// Exact draft spelling. Unknown stored values stay here unchanged until
    /// this one control is deliberately changed; unrelated saves omit the
    /// field entirely.
    @State private var reasoningEffort = ""
    @State private var continuity = false
    @State private var repeatForever = true
    @State private var seeded = false
    @State private var baseline: RoutineDraft?

    @State private var saving = false
    @State private var busy = false
    @State private var errorLine: String?
    @State private var noteLine: String?
    @State private var confirmingDelete = false

    public init(model: AppModel, mode: Mode, botID: String, onBack: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.botID = botID
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var runtime: CronDetailRuntime { CronDetailRuntime.shared }

    private var routine: Routine? {
        if case .edit(let r) = mode { return r }
        return nil
    }

    /// The authoritative record once the detail read lands.
    private var job: CronJobDetail? {
        guard let routine else { return nil }
        return runtime.detail[routine.id]
    }

    /// The socket projection remains useful on a legacy gateway without the
    /// REST detail router: current Hermes includes a non-empty per-job effort
    /// pin in this row, so it can still be inspected even when it cannot be
    /// edited from the phone.
    private var listingJob: CronJobRecord? {
        guard let routine else { return nil }
        return FeedsRuntime.shared.cronJobs[routine.id]
    }

    /// Editing, history and pinning all ride the REST cron router; without it
    /// this screen is a reader with a toggle, which is still worth having.
    private var restAvailable: Bool {
        model.cronRESTReady(routineID: routine?.id, botID: botID)
    }

    private var deliveryTargets: [CronDeliveryTarget] {
        model.cronDeliveryTargets(routineID: routine?.id, botID: botID)
    }

    private var isCreating: Bool { mode == .create }

    /// A script job's prompt belongs to a file on the gateway host; the phone
    /// must not offer to overwrite it with an empty string.
    private var scriptOnly: Bool { job?.isScriptOnly ?? false }

    /// A pre-v2 delegated routine is quarantined: readable, deletable, never
    /// re-armed from here.
    private var quarantined: Bool {
        if let job { return AppModel.isLegacyDelegated(job) }
        if let routine { return model.routineIsQuarantined(routine) }
        return false
    }

    private var normalizedSchedule: String? { HermesSchedule.normalize(schedule) }

    /// Everything a person can change on this screen, in one comparable value.
    private struct RoutineDraft: Equatable {
        var title: String
        var schedule: String
        var instruction: String
        var deliver: [String]
        var model: String
        var provider: String
        var reasoningEffort: String
        var continuity: Bool
    }

    private var draft: RoutineDraft {
        RoutineDraft(title: title, schedule: schedule, instruction: instruction,
                     deliver: deliver, model: modelPin, provider: providerPin,
                     reasoningEffort: reasoningEffort,
                     continuity: continuity)
    }

    private var dirty: Bool {
        guard let baseline else { return false }
        return baseline != draft
    }

    /// nil is the preservation instruction sent to `saveRoutine`. In
    /// particular, an unseeded form must never interpret its blank local state
    /// as authority to clear a raw server value.
    private var reasoningEffortMutation: String? {
        CronReasoningEffort.authoredMutation(
            draft: reasoningEffort, baseline: baseline?.reasoningEffort)
    }

    private var canSubmit: Bool {
        guard !saving, !busy else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard scriptOnly || !instruction.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isCreating { return normalizedSchedule != nil }
        return restAvailable && !quarantined && dirty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    noticeBlock
                    healthBlock
                    editorBlock
                    inferenceBlock
                    scheduleFactsBlock
                    historyBlock
                    footnotes
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 72)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            model.attachCronDetailRouter()
            await load(initial: true)
        }
        .onChange(of: runtime.changeTick) {
            // cron.changed fires when a run lands, a job is paused, or the
            // store is rewritten — all three change what this screen shows.
            Task { await load(initial: false) }
        }
        .confirmationDialog(copy.routineDeleteConfirm(theme.id),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(copy.deleteRoutineLabel(theme.id), role: .destructive) { remove() }
            Button(copy.cancel, role: .cancel) { }
        }
    }

    // MARK: - Loading

    private func load(initial: Bool) async {
        if isCreating {
            await model.loadCronDeliveryTargets(botID: botID)
            if initial { seedForCreate() }
            return
        }
        guard let routine else { return }
        await model.loadCronDeliveryTargets(routineID: routine.id)
        let detail = await model.loadRoutineDetail(routine.id)
        await model.loadRoutineRuns(routine.id)
        // A background refresh must never eat an in-progress edit; the first
        // seed after the detail lands is the only one that overwrites fields.
        if let detail {
            if !dirty || !seeded { seed(from: detail) }
        } else if !seeded {
            // No cron REST router on this gateway: show what the socket list
            // already told us rather than an empty form.
            seed(fromListing: routine)
        }
    }

    private func seedForCreate() {
        guard !seeded else { return }
        seeded = true
        apply(RoutineDraft(title: "", schedule: "", instruction: "", deliver: ["local"],
                           model: "", provider: "", reasoningEffort: "", continuity: false))
    }

    /// Fallback seed from the `cron.manage list` projection. The prompt there
    /// is `prompt_preview` — truncated at 100 characters — so it is shown but
    /// never saved: `canSubmit` requires the REST surface this path lacks.
    private func seed(fromListing routine: Routine) {
        seeded = true
        let preview = FeedsRuntime.shared.cronJobs[routine.id]?.promptPreview ?? ""
        apply(RoutineDraft(title: routine.name, schedule: routine.schedule,
                           instruction: AppModel.routineInstruction(in: preview) ?? preview,
                           deliver: ["local"], model: "", provider: "",
                           reasoningEffort: listingJob?.reasoningEffortRaw ?? "",
                           continuity: false))
    }

    private func seed(from detail: CronJobDetail) {
        seeded = true
        var route = detail.deliver.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if route.isEmpty { route = ["local"] }
        apply(RoutineDraft(title: detail.displayTitle,
                           schedule: detail.scheduleDisplay,
                           instruction: AppModel.routineInstruction(in: detail.prompt) ?? detail.prompt,
                           deliver: route,
                           model: detail.model ?? "",
                           provider: detail.provider ?? "",
                           reasoningEffort: detail.reasoningEffortRaw ?? "",
                           continuity: detail.continuity))
    }

    /// One writer for the draft fields, so the baseline can be recorded from
    /// the same value that was written rather than read back out of `@State`.
    private func apply(_ draft: RoutineDraft) {
        title = draft.title
        schedule = draft.schedule
        instruction = draft.instruction
        deliver = draft.deliver
        modelPin = draft.model
        providerPin = draft.provider
        reasoningEffort = draft.reasoningEffort
        continuity = draft.continuity
        baseline = draft
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onBack) {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(theme.id == .ink ? Color.clear : theme.panel)
                    .clipShape(iconShape)
                    .overlay(iconShape.strokeBorder(
                        theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(isCreating ? copy.routineNewTitle(theme.id) : copy.routineDetailKicker(theme.id))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                }
                Text(headerTitle)
                    .font(headerFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !isCreating, model.mode == .live { rowMenu }

            Button {
                submit()
            } label: {
                Text(isCreating ? copy.createOk : copy.routineSaveAction(theme.id))
                    .font(actionFont)
                    .foregroundStyle(canSubmit ? theme.accent : theme.faint)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var headerTitle: String {
        if isCreating { return copy.routineNewTitle(theme.id) }
        let name = job?.displayTitle ?? routine?.name ?? ""
        return name.isEmpty ? copy.routineDetailKicker(theme.id) : name
    }

    @ViewBuilder private var rowMenu: some View {
        Menu {
            Button(copy.runNow(theme.id)) { runNow() }
                .disabled(quarantined)
            Button(copy.deleteRoutineLabel(theme.id), role: .destructive) {
                confirmingDelete = true
            }
        } label: {
            Text(verbatim: "···")
                .font(theme.mono(13, weight: .bold))
                .foregroundStyle(theme.faint)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
    }

    // MARK: - Notices

    @ViewBuilder private var noticeBlock: some View {
        // A read that failed against a gateway that DOES have the cron router
        // is worth reporting — pulling to refresh or leaving and returning
        // retries it. A gateway with no router at all never lands here; that
        // path hides the surface instead.
        if let errorLine {
            noticeLine(errorLine, tone: theme.danger)
        } else if let noteLine {
            noticeLine(noteLine, tone: theme.ok)
        } else if let routine, let failure = runtime.detailError[routine.id] {
            noticeLine(failure, tone: theme.danger)
        }
    }

    private func noticeLine(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(footFont)
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Health

    @ViewBuilder private var healthBlock: some View {
        if quarantined {
            healthCard(title: copy.routineQuarantined(theme.id),
                       body: copy.routineQuarantineWhy(theme.id),
                       tone: theme.danger)
        } else if let job {
            let health = CronJobHealth(job)
            if health.isProblem {
                healthCard(title: healthTitle(health.condition),
                           body: healthBody(health),
                           tone: healthTone(health.condition),
                           action: pinAction(for: job, health: health))
            }
        }
    }

    private func healthTitle(_ condition: CronJobCondition) -> String {
        switch condition {
        case .driftSkipped: copy.routineDriftTitle(theme.id)
        case .blockedConfig: copy.routineBlockedTitle(theme.id)
        case .fireUnreachable: copy.routineFireErrorTitle(theme.id)
        case .failed: copy.routineFailedTitle(theme.id)
        case .deliveryFailed: copy.routineDeliveryFailedTitle(theme.id)
        case .paused: copy.routinePausedTitle(theme.id)
        case .ok: ""
        }
    }

    private func healthTone(_ condition: CronJobCondition) -> Color {
        switch condition {
        case .driftSkipped, .blockedConfig, .paused: theme.warn
        case .fireUnreachable, .failed: theme.danger
        case .deliveryFailed: theme.warn
        case .ok: theme.ok
        }
    }

    /// The server writes its own remediation into `last_error` (a `hermes cron
    /// edit …` line for drift, a "set the provider API key" line for a blocked
    /// config). It is the most actionable text available, so it is shown
    /// verbatim rather than replaced with our own guess.
    private func healthBody(_ health: CronJobHealth) -> String {
        var lines = [health.detail]
        if health.failureStreak > 1 {
            lines.append(copy.routineFailureStreak(theme.id, count: health.failureStreak))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Drift has exactly one fix, and the phone can do it in a tap: pin the
    /// axes to the values the job was created against.
    private func pinAction(for job: CronJobDetail, health: CronJobHealth) -> (String, () -> Void)? {
        guard health.condition == .driftSkipped, canPin(job) else { return nil }
        return (copy.routinePinAction(theme.id), { pin(job) })
    }

    /// True when at least one axis is unpinned AND carries a snapshot — i.e.
    /// the drift guard is armed on it and there is a recorded value to pin to.
    private func canPin(_ job: CronJobDetail) -> Bool {
        guard restAvailable, !quarantined else { return false }
        return (job.model == nil && job.modelSnapshot != nil)
            || (job.provider == nil && job.providerSnapshot != nil)
    }

    private func healthCard(title: String, body: String, tone: Color,
                            action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(tone).frame(width: 7, height: 7)
                    .offset(y: -1)
                Text(title)
                    .font(theme.id == .control ? theme.mono(11, weight: .bold)
                                               : theme.body(theme.id == .ink ? 15 : 13, weight: .bold))
                    .foregroundStyle(tone)
            }
            if !body.isEmpty {
                Text(body)
                    .font(footFont)
                    .foregroundStyle(theme.sub)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button { action.1() } label: {
                    Text(action.0)
                        .font(chipFont)
                        .foregroundStyle(theme.accent)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 11)
                        .chipShell(theme)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 12, trailing: 12))
        .background(theme.id == .ink ? Color.clear : tone.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(tone.opacity(theme.id == .ink ? 0.55 : 0.3), lineWidth: 1))
    }

    // MARK: - Editor

    private var editorBlock: some View {
        // Editing an existing routine needs the REST PUT; without it the
        // fields would take input that could never be saved.
        let editable = isCreating || (restAvailable && !quarantined)

        return VStack(alignment: .leading, spacing: 7) {
            sectionLabel(copy.routineTitleLabel(theme.id))
            field(copy.routineNamePlaceholder(theme.id), text: $title, lines: 1, editable: editable)

            sectionLabel(copy.routineWhenLabel(theme.id))
            field(copy.routineSchedulePlaceholder(theme.id), text: $schedule, lines: 1,
                  editable: editable)
            if editable {
                presetRow
                scheduleEcho
            }

            sectionLabel(copy.routineDoLabel(theme.id))
            if scriptOnly {
                Text(job?.script ?? "")
                    .font(theme.mono(theme.id == .ink ? 10.5 : 11))
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                    .background(theme.id == .ink ? Color.clear : theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))
                Text(copy.routineScriptNote(theme.id))
                    .font(footFont)
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                field(copy.routinePromptPlaceholder(theme.id), text: $instruction, lines: 4,
                      editable: editable)
            }

            optionRows(editable: editable)
            deliveryBlock(editable: editable)
        }
    }

    @ViewBuilder private func optionRows(editable: Bool) -> some View {
        if isCreating {
            optionRow(copy.repeatForever(theme.id), isOn: $repeatForever, editable: true)
        } else if let job, job.repeatTimes != nil {
            factRow(copy.routineRepeatCap(theme.id),
                    value: "\(job.repeatCompleted)/\(job.repeatTimes ?? 0)")
        }
        if !scriptOnly {
            optionRow(copy.continuityLabel(theme.id), isOn: $continuity, editable: editable)
        }
    }

    // MARK: - Delivery

    @ViewBuilder private func deliveryBlock(editable: Bool) -> some View {
        let targets = deliveryTargets
        if !targets.isEmpty {
            sectionLabel(copy.routineDeliverLabel(theme.id))
            FlowChips(items: offeredTargets) { id in
                let target = targets.first { $0.id == id }
                let selected = deliver.contains(id)
                Button {
                    guard editable else { return }
                    toggleDelivery(id)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(id == "local" ? copy.routineDeliverLocal(theme.id)
                                           : (target?.name ?? id))
                            .font(chipFont)
                            .foregroundStyle(selected ? theme.accent : theme.sub)
                        if let target, !target.homeTargetSet {
                            Text(copy.routineDeliverUnset(theme.id))
                                .font(theme.mono(theme.id == .ink ? 8.5 : 9))
                                .foregroundStyle(theme.warn)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 11)
                    .chipShell(theme)
                    .overlay { selectionRing(selected) }
                }
                .buttonStyle(.plain)
                .disabled(!editable)
            }
        }
    }

    /// Discovered targets, plus any route this job already carries that
    /// discovery no longer returns. A platform that was disconnected after the
    /// job was written must stay visible and selected — dropping it silently on
    /// the next save would re-route the job without anyone asking.
    private var offeredTargets: [String] {
        var ids = deliveryTargets.map(\.id)
        for saved in deliver where !ids.contains(saved) { ids.append(saved) }
        return ids
    }

    /// The chip shell's own geometry, so a selected chip's ring traces it
    /// exactly instead of guessing a radius.
    @ViewBuilder private func selectionRing(_ selected: Bool) -> some View {
        if selected {
            if theme.chipIsCapsule {
                Capsule().strokeBorder(theme.accent, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: theme.id == .ink ? theme.inputRadius
                                                                : theme.buttonRadius)
                    .strokeBorder(theme.accent, lineWidth: 1)
            }
        }
    }

    /// `local` is the floor: the server rewrites an empty route to it anyway
    /// (web_server.py:12302), so the picker never lets the last one go.
    private func toggleDelivery(_ id: String) {
        if deliver.contains(id) {
            guard deliver.count > 1 else { return }
            deliver.removeAll { $0 == id }
        } else {
            deliver.append(id)
        }
    }

    // MARK: - Inference (the fail-closed axis)

    @ViewBuilder private var inferenceBlock: some View {
        if restAvailable, !scriptOnly {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(copy.routineInferenceLabel(theme.id))
                field(providerPlaceholder, text: $providerPin, lines: 1, editable: !quarantined)
                field(modelPlaceholder, text: $modelPin, lines: 1, editable: !quarantined)
                reasoningEffortBlock(editable: !quarantined, scriptOnly: false)
                if let job, job.model == nil || job.provider == nil {
                    Text(copy.routineFollowsGateway(theme.id))
                        .font(footFont)
                        .foregroundStyle(theme.sub)
                    if canPin(job) {
                        Text(snapshotLine(job))
                            .font(theme.mono(theme.id == .ink ? 10 : 10.5))
                            .foregroundStyle(theme.faint)
                        Text(copy.routineSnapshotWhy(theme.id))
                            .font(footFont)
                            .foregroundStyle(theme.faint)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { pin(job) } label: {
                            Text(copy.routinePinAction(theme.id))
                                .font(chipFont)
                                .foregroundStyle(theme.accent)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 11)
                                .chipShell(theme)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || quarantined)
                    }
                }
            }
        } else if !isCreating,
                  let raw = job?.reasoningEffortRaw ?? listingJob?.reasoningEffortRaw {
            // A script-only job can carry a historical pin, but run_job exits
            // through its no-agent branch before constructing an LLM. A
            // current gateway without REST can expose the pin in its socket
            // listing but offers no authoritative mutation path. Both are
            // inspect-only, and both need an explicit truthful explanation.
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(copy.routineReasoningLabel(theme.id))
                reasoningEffortReadout(CronReasoningEffort(raw: raw), scriptOnly: scriptOnly)
            }
        }
    }

    @ViewBuilder
    private func reasoningEffortBlock(editable: Bool, scriptOnly: Bool) -> some View {
        sectionLabel(copy.routineReasoningLabel(theme.id))
        if editable {
            Menu {
                Button {
                    reasoningEffort = ""
                } label: {
                    effortMenuLabel(
                        copy.routineReasoningFollowConfig(theme.id),
                        selected: reasoningPickerFollowsConfiguration)
                }
                Divider()
                ForEach(CronReasoningEffort.canonicalValues, id: \.self) { value in
                    Button {
                        reasoningEffort = value
                    } label: {
                        effortMenuLabel(reasoningChoiceLabel(value),
                                        selected: CronReasoningEffort(
                                            raw: reasoningEffort).pinnedValue == value)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(reasoningPickerLabel)
                        .font(fieldFont)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous)
                    .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy.routineReasoningLabel(theme.id))
            .accessibilityValue(reasoningPickerLabel)
            .accessibilityHint(copy.routineReasoningPickerHint(theme.id))
        }
        reasoningEffortReadout(CronReasoningEffort(raw: reasoningEffort), scriptOnly: scriptOnly)
    }

    @ViewBuilder
    private func effortMenuLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }

    private var reasoningPickerLabel: String {
        switch CronReasoningEffort(raw: reasoningEffort) {
        case .followsConfiguration:
            return copy.routineReasoningFollowConfig(theme.id)
        case .pinned(let value):
            return reasoningChoiceLabel(value)
        case .unknown(let raw):
            return copy.routineReasoningUnknown(theme.id, value: raw)
        }
    }

    private var reasoningPickerFollowsConfiguration: Bool {
        if case .followsConfiguration = CronReasoningEffort(raw: reasoningEffort) { return true }
        return false
    }

    private func reasoningChoiceLabel(_ value: String) -> String {
        value == "none" ? copy.routineReasoningOff(theme.id)
                        : ModelLabels.effortLabel(value)
    }

    private func reasoningEffortReadout(_ status: CronReasoningEffort,
                                        scriptOnly: Bool) -> some View {
        let text: String
        let tone: Color
        if scriptOnly {
            text = copy.routineReasoningUnusedForScript(theme.id,
                                                        value: reasoningStatusLabel(status))
            tone = theme.faint
        } else {
            switch status {
            case .followsConfiguration:
                text = copy.routineReasoningConfigPrecedence(theme.id)
                tone = theme.sub
            case .pinned(let value):
                text = copy.routineReasoningPinned(theme.id,
                                                    value: reasoningChoiceLabel(value))
                tone = theme.sub
            case .unknown(let raw):
                text = copy.routineReasoningInvalid(theme.id, value: raw)
                tone = theme.warn
            }
        }
        return Text(text)
            .font(footFont)
            .foregroundStyle(tone)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    private func reasoningStatusLabel(_ status: CronReasoningEffort) -> String {
        switch status {
        case .followsConfiguration: return copy.routineReasoningFollowConfig(theme.id)
        case .pinned(let value): return reasoningChoiceLabel(value)
        case .unknown(let raw): return copy.routineReasoningUnknown(theme.id, value: raw)
        }
    }

    /// "recorded as anthropic · claude-sonnet-4" — the resolution the drift
    /// guard compares against on every tick.
    private func snapshotLine(_ job: CronJobDetail) -> String {
        let parts = [job.providerSnapshot, job.modelSnapshot].compactMap { $0 }
        return copy.routineRecordedAs(theme.id) + " " + parts.joined(separator: " · ")
    }

    /// The snapshot doubles as the placeholder: it is literally what this
    /// routine resolves to today, so it is the most useful ghost text there is.
    private var providerPlaceholder: String {
        job?.providerSnapshot ?? copy.routineProviderPlaceholder(theme.id)
    }

    private var modelPlaceholder: String {
        job?.modelSnapshot ?? copy.routineModelPlaceholder(theme.id)
    }

    // MARK: - Schedule facts

    @ViewBuilder private var scheduleFactsBlock: some View {
        if let job {
            VStack(alignment: .leading, spacing: 0) {
                factRow(copy.next, value: job.nextRun.map { AppModel.runStamp($0) } ?? "—")
                factRow(lastLabel, value: job.lastRun.map { AppModel.runStamp($0) } ?? "—")
            }
        }
    }

    private var lastLabel: String {
        switch theme.id {
        case .soft: "last"
        case .control: "LAST"
        case .ink: "last kept"
        }
    }

    private func factRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13.5 : 12))
                .foregroundStyle(theme.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(theme.id == .soft ? theme.body(12, weight: .medium)
                                        : theme.mono(theme.id == .ink ? 10 : 10.5))
                .foregroundStyle(theme.sub)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    // MARK: - Run history

    @ViewBuilder private var historyBlock: some View {
        if let routine, restAvailable {
            let runs = runtime.runs[routine.id]
            // Three states, and the third is not an error: a history that has
            // not been read yet says so, and one that failed to read says
            // nothing at all rather than claiming the job never ran.
            VStack(alignment: .leading, spacing: 7) {
                if let runs, !runs.isEmpty {
                    sectionLabel(historyLabel(count: runs.count))
                    VStack(alignment: .leading, spacing: historyGap) {
                        ForEach(runs) { run in
                            runRow(run, jobID: routine.id, botID: routine.botID)
                        }
                    }
                    Text(copy.routineOpenRunHint(theme.id))
                        .font(footFont)
                        .foregroundStyle(theme.faint)
                } else if runs != nil {
                    sectionLabel(historyLabel(count: 0))
                    Text(copy.routineNoRuns(theme.id))
                        .font(footFont)
                        .italic(theme.id == .ink)
                        .foregroundStyle(theme.faint)
                } else if runtime.loadingRuns.contains(routine.id) {
                    sectionLabel(historyLabel(count: 0))
                    Text(copy.routineLoadingRuns(theme.id))
                        .font(footFont)
                        .foregroundStyle(theme.faint)
                }
            }
        }
    }

    private var historyGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 6
        case .card: 6
        }
    }

    private func historyLabel(count: Int) -> String {
        count > 0 ? "\(copy.routineRunHistory(theme.id)) · \(count)"
                  : copy.routineRunHistory(theme.id)
    }

    private func runRow(_ run: CronRun, jobID: String, botID: String) -> some View {
        Button {
            model.openRoutineRun(run, jobID: jobID, fallbackBotID: botID)
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Circle().fill(runTone(run)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.label)
                        .font(theme.id == .soft ? theme.body(13, weight: .semibold)
                                                : theme.body(theme.id == .ink ? 15 : 12.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(runSubtitle(run))
                        .font(theme.id == .control ? theme.mono(9.5) : theme.body(theme.id == .ink ? 12.5 : 11))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(AppModel.runStamp(run.startedAt))
                    .font(theme.mono(theme.id == .ink ? 9.5 : 10))
                    .foregroundStyle(theme.faint)
            }
            .modifier(RoutineDetailRowChrome(theme: theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runTone(_ run: CronRun) -> Color {
        switch run.outcome {
        case .running: theme.accent
        case .finished: theme.ok
        case .interrupted: theme.warn
        }
    }

    /// "finished · 2m 14s · 6 messages" — what the session record can actually
    /// prove about the run, and nothing more.
    private func runSubtitle(_ run: CronRun) -> String {
        var parts: [String] = []
        switch run.outcome {
        case .running: parts.append(copy.routineRunRunning(theme.id))
        case .finished: parts.append(copy.routineRunFinished(theme.id))
        case .interrupted: parts.append(copy.routineRunInterrupted(theme.id))
        }
        if let duration = run.duration { parts.append(AppModel.runDuration(duration)) }
        if run.toolCallCount > 0 { parts.append("\(run.toolCallCount) ⚒") }
        else if run.messageCount > 0 { parts.append("\(run.messageCount) ✉") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footnotes

    @ViewBuilder private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !scriptOnly, isDelegated {
                Text(copy.routineWrapperNote(theme.id))
                    .font(footFont)
                    .foregroundStyle(theme.faint)
                    .lineSpacing(3)
            }
            Text(copy.cronNote)
                .font(footFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .lineSpacing(3)
        }
        .padding(.top, 4)
    }

    /// True when this routine's stored prompt is (or will be) the cross-profile
    /// hand-off rather than the bare instruction. Unknown without a live link:
    /// which profile the gateway launched in is what decides it.
    private var isDelegated: Bool {
        guard model.mode == .live else { return false }
        if let job { return job.prompt.hasPrefix(AppModel.safeRoutineMarker) }
        return AppModel.delegatedPrompt(botID: botID, title: "?", instruction: "?")
            .hasPrefix(AppModel.safeRoutineMarker)
    }

    // MARK: - Actions

    private func submit() {
        if isCreating { create() } else { save() }
    }

    private func create() {
        saving = true; errorLine = nil; noteLine = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await model.scheduleRoutineWithFeedback(
                    botID: botID, title: title, schedule: schedule, instruction: instruction,
                    repeatForever: repeatForever, continuity: continuity,
                    deliver: restAvailable ? deliver : [],
                    model: restAvailable ? modelPin : nil,
                    provider: restAvailable ? providerPin : nil,
                    reasoningEffort: restAvailable && !reasoningEffort.isEmpty
                        ? reasoningEffort : nil)
                onBack()
            } catch {
                errorLine = AppModel.reason(error)
            }
        }
    }

    private func save() {
        guard let job else { return }
        saving = true; errorLine = nil; noteLine = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await model.saveRoutineWithFeedback(
                    job, routineID: routine?.id ?? job.id, botID: botID,
                    title: title, schedule: schedule,
                    instruction: instruction,
                    deliver: deliveryTargets.isEmpty ? nil : deliver,
                    model: modelPin, provider: providerPin,
                    reasoningEffort: reasoningEffortMutation,
                    continuity: continuity)
                // The save landed; the draft is now the truth, so the reload
                // below is free to reseed from the server's answer.
                baseline = draft
                noteLine = copy.routineSavedNote(theme.id)
                await load(initial: false)
            } catch {
                errorLine = AppModel.reason(error)
            }
        }
    }

    private func pin(_ job: CronJobDetail) {
        busy = true; errorLine = nil; noteLine = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let routine else { return }
                try await model.pinRoutineInference(job, routineID: routine.id)
                noteLine = copy.routineSavedNote(theme.id)
                await load(initial: false)
            } catch {
                errorLine = AppModel.reason(error)
            }
        }
    }

    private func runNow() {
        guard let routine else { return }
        busy = true; errorLine = nil; noteLine = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                // A finished-inline run is the exception; "claimed and running"
                // is the normal answer and is not a failure.
                _ = try await model.runRoutineNow(routine)
                noteLine = copy.routineRunStarted(theme.id)
                await load(initial: false)
            } catch {
                errorLine = AppModel.reason(error)
            }
        }
    }

    private func remove() {
        guard let routine else { return }
        busy = true; errorLine = nil
        Task { @MainActor in
            defer { busy = false }
            // Same wrapper the list uses: the editor pops on success, so the
            // toast (and its ledger row) is what remains to say the routine is
            // gone. The reason still lands inline for a failure that keeps the
            // editor on screen.
            if let reason = await model.deleteRoutineWithFeedback(routine) {
                errorLine = reason
            } else {
                onBack()
            }
        }
    }

    // MARK: - Field chrome

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.mono(theme.id == .soft ? 10 : 9, weight: .heavy))
            .tracking(theme.id == .soft ? 1 : 2)
            .textCase(.uppercase)
            .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>,
                       lines: Int, editable: Bool) -> some View {
        Group {
            if editable {
                TextField(placeholder, text: text, axis: lines > 1 ? .vertical : .horizontal)
                    .textFieldStyle(.plain)
                    .lineLimit(lines > 1 ? lines...(lines + 10) : 1...1)
                    .autocorrectionDisabled(lines == 1)
            } else {
                Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                    .foregroundStyle(text.wrappedValue.isEmpty ? theme.faint : theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(fieldFont)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(theme.id == .ink ? Color.clear : theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous)
            .strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong, lineWidth: 1))
    }

    private var fieldRadius: CGFloat { theme.inputRadius > 100 ? 14 : theme.inputRadius }

    private func optionRow(_ label: String, isOn: Binding<Bool>, editable: Bool) -> some View {
        HStack {
            Text(label)
                .font(theme.id == .control ? theme.mono(11) : theme.body(theme.id == .ink ? 14.5 : 13))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            RoutineSwitch(isOn: isOn.wrappedValue, theme: theme) {
                guard editable else { return }
                isOn.wrappedValue.toggle()
            }
            .opacity(editable ? 1 : 0.5)
        }
        .padding(.vertical, 2)
    }

    private static let presets: [(soft: String, control: String, ink: String, value: String)] = [
        ("every morning at 7", "0 7 * * *", "every morning at seven", "0 7 * * *"),
        ("weekdays at 9", "0 9 * * 1-5", "weekdays at nine", "0 9 * * 1-5"),
        ("every hour", "every 1h", "hourly", "every 1h"),
        ("every 30m", "every 30m", "every half hour", "every 30m"),
    ]

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
                            .font(chipFont)
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
        } else if let normalizedSchedule {
            Text(verbatim: "→ \(normalizedSchedule)")
                .font(theme.mono(theme.id == .ink ? 10 : 10.5))
                .foregroundStyle(theme.ok)
        } else {
            Text(copy.scheduleHelp(theme.id))
                .font(footFont)
                .foregroundStyle(theme.warn)
        }
    }

    // MARK: - Type

    private var iconShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var headerFont: Font {
        switch theme.id {
        case .soft: theme.display(19)
        case .control: theme.display(17)
        case .ink: theme.display(21, weight: .bold)
        }
    }

    private var actionFont: Font {
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

    private var chipFont: Font {
        theme.id == .control ? theme.mono(10) : theme.body(theme.id == .ink ? 13 : 12)
    }
}

// MARK: - Row chrome (file-scoped; each screen keeps its own)

private struct RoutineDetailRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
        case .terminal:
            content
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 11)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

/// A wrapping chip row. `LazyVGrid` cannot do intrinsic-width columns, and a
/// horizontal scroller hides targets a person has to notice before choosing.
private struct FlowChips<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { content($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two per line: delivery targets are short names, and a phone width holds
    /// two comfortably without measuring text.
    private var rows: [[String]] {
        stride(from: 0, to: items.count, by: 2).map {
            Array(items[$0..<min($0 + 2, items.count)])
        }
    }
}

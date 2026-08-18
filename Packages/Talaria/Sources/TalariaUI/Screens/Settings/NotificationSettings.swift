import SwiftUI
import TalariaKit
import TalariaTheme

// Settings → Notifications.
//
// This section exists to end a documented lie. PARITY.md:551 lists it second
// among the whole audit's biggest holes: *"the 'Notify me when' rows are DEMO
// DATA (DemoData.notificationPrefs) that toggle local state and are never
// persisted or sent to the relay — this is a live parity lie, not a gap."*
// Everything below is therefore built the other way round: a control ships only
// if something downstream actually honors it, and anything the relay decides
// for itself is shown as *state*, never as a switch.
//
// So: what does the relay honor per device?
//
//   PER BOT — yes. `profile_filter` on the device registration is an allow-list
//   of hermes profiles; the fan-out consults it in `DeviceStore.for_bot`
//   (app/relay/talaria-push/talaria_push_relay/devices.py:160), and an empty
//   list means every bot. Registration is an idempotent upsert, so re-POSTing
//   is how the filter is changed. That is a real, device-scoped preference and
//   it gets real switches.
//
//   PER KIND — no. `enabled_events` comes from `TALARIA_PUSH_EVENTS` in the
//   gateway process's environment (config.py:134-154) and applies to every
//   device at once; nothing in the payload or the registry carries a per-device
//   kind filter. Sending one would be silently dropped by the Pydantic model.
//   The five kinds are therefore rendered as read-only state with the reason
//   each one is on or off — plus the honest caveat from the relay's own gap
//   table (app/relay/README.md) about what actually fires today:
//
//     approval   hook mode fires at the instant the agent blocks, but carries
//                no request_id, so the app resolves it via `approval.pending`.
//     long_task  exact in hook mode; approximated from poll transitions in
//                sidecar mode.
//     mention    hook mode only — messaging-gateway traffic never crosses
//                /api/ws, so a sidecar cannot see it.
//     routine    fires in both, but only the sidecar knows the job's NAME.
//     gateway    sidecar only, and structurally so: a dead process cannot
//                report its own death.
//
// The iOS half of the chain (permission → APNs token → relay registration) is
// already owned by `NotificationsCard`, so it is embedded rather than
// reimplemented.

public struct NotificationSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var client: GatewayClient? { model.client }

    @State private var relay: PushRelayStatus?
    @State private var device: PushDeviceRecord?
    @State private var probed = false
    @State private var isLoading = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsWarning = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(theme: theme, title: copy.notifySec) {
                NotificationsCard(model: model)
            }

            if let relay { kindsSection(relay) }
            if relay != nil, device != nil { botFilterSection }

            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            if probed, relay == nil, model.mode == .live {
                GatewayFootnote(theme: theme, text: copy.settingsNoRelayNote(theme.id))
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    // MARK: - What pushes (read-only)

    /// One row per wire kind, in the order they matter to someone away from
    /// their desk. The value is the gateway's answer, not a preference.
    private func kindsSection(_ relay: PushRelayStatus) -> some View {
        SettingsSection(theme: theme, title: copy.settingsKindsSection(theme.id),
                        footnote: copy.settingsKindsNote(theme.id)) {
            SettingsGroup(theme: theme) {
                ForEach(Array(Self.kinds.enumerated()), id: \.element) { index, wire in
                    SettingsRow(theme: theme,
                                title: kindTitle(wire),
                                subtitle: kindCaveat(wire),
                                value: relay.sends(wire) ? copy.settingsKindOn(theme.id)
                                                         : copy.settingsKindOff(theme.id),
                                valueTone: relay.sends(wire) ? theme.ok : theme.faint,
                                isLast: index == Self.kinds.count - 1)
                }
            }

            if !relay.apnsConfigured {
                Text(copy.settingsApnsMissing(theme.id,
                                              vars: relay.missingEnv.joined(separator: ", ")))
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            } else if relay.disabled {
                Text(copy.settingsRelayDisabled(theme.id))
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    /// The relay's wire kinds (`ALL_EVENT_KINDS`,
    /// talaria_push_relay/config.py:19), ordered by phone-side urgency rather
    /// than declaration order. These are the strings `enabled_events` speaks —
    /// note `long_task`, which the app models as `PushKind.task`.
    private static let kinds = ["approval", "mention", "routine", "long_task", "gateway"]

    private func kindTitle(_ wire: String) -> String {
        switch wire {
        case "approval": copy.settingsKindApproval(theme.id)
        case "mention": copy.settingsKindMention(theme.id)
        case "routine": copy.settingsKindRoutine(theme.id)
        case "long_task": copy.settingsKindLongTask(theme.id)
        default: copy.settingsKindGateway(theme.id)
        }
    }

    /// What actually fires today, per the relay's own gap table. A row that
    /// only works in one of the two relay modes says so — that is the
    /// difference between "notifications are on" and "this notification will
    /// reach me".
    private func kindCaveat(_ wire: String) -> String {
        switch wire {
        case "approval": return copy.settingsKindApprovalSub(theme.id)
        case "mention": return copy.settingsKindMentionSub(theme.id)
        case "routine": return copy.settingsKindRoutineSub(theme.id)
        case "long_task":
            let minutes = max(1, (relay?.longTaskMinSeconds ?? 600) / 60)
            return copy.settingsKindLongTaskSub(theme.id, minutes: minutes)
        default: return copy.settingsKindGatewaySub(theme.id)
        }
    }

    // MARK: - Which bots may push here

    /// The one genuinely device-scoped preference the relay honors. "All bots"
    /// is the empty filter, which is also the relay's default — so the switch
    /// that turns everything back on is the one that CLEARS the list.
    private var botFilterSection: some View {
        SettingsSection(theme: theme, title: copy.settingsBotFilterSection(theme.id),
                        footnote: copy.settingsBotFilterNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsToggleRow(theme: theme,
                                  title: copy.settingsAllBots(theme.id),
                                  subtitle: copy.settingsAllBotsSub(theme.id),
                                  isOn: allowsEveryBot,
                                  isLast: allowsEveryBot || model.bots.isEmpty) {
                    // Turning the master switch OFF has to name somebody: an
                    // empty list is how the relay spells "everyone", so
                    // restricting starts from the full roster and the user
                    // unchecks from there. With no roster to name, the switch
                    // has no off state at all and stays disabled.
                    Task { await applyFilter(allowsEveryBot ? model.bots.map(\.id) : []) }
                }
                .disabled(busy || (allowsEveryBot && model.bots.isEmpty))

                if !allowsEveryBot {
                    ForEach(Array(model.bots.enumerated()), id: \.element.id) { index, bot in
                        SettingsToggleRow(theme: theme,
                                          title: bot.displayTitle,
                                          subtitle: "@\(bot.handle)",
                                          isOn: allows(bot.id),
                                          isLast: index == model.bots.count - 1) {
                            Task { await toggle(bot.id) }
                        }
                    }
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)

            // A filter naming a profile that no longer exists silently swallows
            // every push from it, so it is surfaced rather than hidden.
            if !strandedProfiles.isEmpty {
                Text(copy.settingsFilterStranded(theme.id,
                                                 names: strandedProfiles.joined(separator: ", ")))
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var filter: [String] { device?.profileFilter ?? [] }

    private var allowsEveryBot: Bool { filter.isEmpty }

    private func allows(_ botID: String) -> Bool {
        filter.isEmpty || filter.contains(botID)
    }

    private var strandedProfiles: [String] {
        let known = Set(model.bots.map(\.id))
        return filter.filter { !known.contains($0) }
    }

    // MARK: - Actions

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            probed = true
        }
        guard model.mode == .live, let client else {
            relay = nil
            device = nil
            return
        }
        relay = await client.pushRelay()
        guard relay != nil else {
            device = nil
            return
        }
        #if os(iOS)
        // Without an APNs token there is no registration to read or edit; the
        // NotificationsCard above is the surface that fixes that, so this half
        // simply stays hidden rather than showing an inert list.
        if let token = PushCoordinator.shared.deviceTokenHex {
            device = await client.pushDevice(tokenHex: token)
        } else {
            device = nil
        }
        #else
        device = nil
        #endif
    }

    private func toggle(_ botID: String) async {
        var next = filter
        if let index = next.firstIndex(of: botID) {
            next.remove(at: index)
            // Emptying the list by hand would read as "every bot" — the exact
            // opposite of what the user just asked for. Fall back to the one
            // bot they left rather than silently re-opening the floodgates.
            if next.isEmpty {
                note(copy.settingsFilterNeedsOne(theme.id), warning: true)
                return
            }
        } else {
            next.append(botID)
        }
        await applyFilter(next)
    }

    private func applyFilter(_ next: [String]) async {
        guard let client, let current = device else { return }
        busy = true
        notice = nil
        defer { busy = false }
        let previous = current.profileFilter
        device?.profileFilter = next
        do {
            try await client.registerPushDevice(tokenHex: current.tokenHex,
                                                environment: current.environment,
                                                profileFilter: next)
            note(next.isEmpty ? copy.settingsFilterCleared(theme.id)
                              : copy.settingsFilterSaved(theme.id, count: next.count),
                 warning: false)
        } catch let error as GatewayError {
            device?.profileFilter = previous
            note(error.message, warning: true)
        } catch {
            device?.profileFilter = previous
            note(error.localizedDescription, warning: true)
        }
    }

    private func note(_ text: String, warning: Bool) {
        notice = text.isEmpty ? nil : text
        noticeIsWarning = warning
    }
}

// MARK: - Themed copy

/// Voice for the notifications section. Every sentence here is a claim about
/// what will actually reach the phone, so none of them are decorative.
public extension CopyPack {

    func settingsKindsSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What pushes"
        case .control: "EVENT KINDS"
        case .ink: "what will reach you"
        }
    }

    func settingsKindsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "These are set on the gateway (TALARIA_PUSH_EVENTS), not per device — every phone registered to this gateway gets the same kinds."
        case .control: "SOURCE: TALARIA_PUSH_EVENTS ON THE GATEWAY. GLOBAL, NOT PER-DEVICE."
        case .ink: "The gateway decides which tidings it sends at all. The choice is not this device’s to make."
        }
    }

    func settingsKindApproval(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A bot needs approval"
        case .control: "APPROVAL REQUIRED"
        case .ink: "a bot awaits your leave"
        }
    }

    func settingsKindApprovalSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Fires the moment the bot blocks. Talaria looks up which request it was on arrival."
        case .control: "pre_approval_request HOOK — NO request_id IN KWARGS; RESOLVED VIA approval.pending."
        case .ink: "Sent the instant the work stops. Which request it was is asked for on arrival."
        }
    }

    func settingsKindMention(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A bot mentions you"
        case .control: "@MENTION"
        case .ink: "your name is spoken"
        }
    }

    func settingsKindMentionSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Needs the relay plugin loaded in each bot’s own gateway process."
        case .control: "pre_gateway_dispatch HOOK — PER PROFILE PROCESS. SIDECAR CANNOT SEE IT."
        case .ink: "Only heard where that bot’s own gateway is listening."
        }
    }

    func settingsKindRoutine(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A routine finishes"
        case .control: "ROUTINE COMPLETE"
        case .ink: "an office is discharged"
        }
    }

    func settingsKindRoutineSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The routine’s name only comes through in sidecar mode; otherwise it just says one finished."
        case .control: "HOOK MODE HAS NO JOB NAME — SIDECAR DIFFS /api/cron/jobs FOR IT."
        case .ink: "Which office, only the watcher knows. The hook says only that one is done."
        }
    }

    func settingsKindLongTask(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A long task finishes"
        case .control: "LONG TASK DONE"
        case .ink: "long labour ends"
        }
    }

    func settingsKindLongTaskSub(_ t: ThemeID, minutes: Int) -> String {
        switch t {
        case .soft: return "Turns running longer than \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .control: return "TURN DURATION > \(minutes)m (TALARIA_PUSH_LONG_TASK_MIN_S)."
        case .ink: return "Work that has run past \(minutes) minute\(minutes == 1 ? "" : "s")."
        }
    }

    func settingsKindGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Your gateway goes down"
        case .control: "GATEWAY OFFLINE"
        case .ink: "the gateway falls silent"
        }
    }

    func settingsKindGatewaySub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Only the standalone sidecar can send this — a gateway that has died cannot report its own death."
        case .control: "SIDECAR ONLY (/api/health HEARTBEAT). NO HOOK CAN COVER THIS."
        case .ink: "Only a watcher outside can say so. A dead thing cannot announce itself."
        }
    }

    func settingsKindOn(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On"
        case .control: "ENABLED"
        case .ink: "sent"
        }
    }

    func settingsKindOff(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Off"
        case .control: "DISABLED"
        case .ink: "withheld"
        }
    }

    func settingsApnsMissing(_ t: ThemeID, vars: String) -> String {
        let list = vars.isEmpty ? "its APNs credentials" : vars
        switch t {
        case .soft: return "The relay has no APNs credentials yet (\(list)), so nothing can be delivered."
        case .control: return "APNs NOT CONFIGURED — MISSING: \(list). NO DELIVERY POSSIBLE."
        case .ink: return "The relay carries no seal (\(list)). Nothing it sends can arrive."
        }
    }

    func settingsRelayDisabled(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Push is switched off on the gateway, so none of these will arrive."
        case .control: "TALARIA_PUSH_DISABLED IS SET — FAN-OUT SUPPRESSED."
        case .ink: "The gateway has been told to hold its tongue."
        }
    }

    func settingsNoRelayNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway has no talaria-push relay installed, so per-kind and per-bot settings have nothing to talk to."
        case .control: "NO talaria-push PLUGIN ON THIS GATEWAY — NO RELAY SURFACE."
        case .ink: "No herald is kept at this gateway. There is nothing here to instruct."
        }
    }

    func settingsBotFilterSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Bots that may reach this phone"
        case .control: "PROFILE FILTER"
        case .ink: "who may call on you"
        }
    }

    func settingsBotFilterNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved with this device’s registration on the gateway. Other devices keep their own list."
        case .control: "profile_filter ON THE DEVICE RECORD. PER DEVICE, NOT PER ACCOUNT."
        case .ink: "Kept beside this device’s name in the gateway’s register. Other devices keep their own."
        }
    }

    func settingsAllBots(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Every bot"
        case .control: "ALL PROFILES"
        case .ink: "all of them"
        }
    }

    func settingsAllBotsSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Turn this off to pick which bots may push here."
        case .control: "EMPTY FILTER = NO RESTRICTION."
        case .ink: "Refuse this to name them one by one."
        }
    }

    func settingsFilterSaved(_ t: ThemeID, count: Int) -> String {
        switch t {
        case .soft: return "Saved — \(count) bot\(count == 1 ? "" : "s") may push here."
        case .control: return "profile_filter UPDATED — \(count) PROFILE\(count == 1 ? "" : "S")."
        case .ink: return "Set down: \(count) may call on you."
        }
    }

    func settingsFilterCleared(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved — every bot may push here."
        case .control: "profile_filter CLEARED — ALL PROFILES."
        case .ink: "The gate stands open to all."
        }
    }

    func settingsFilterNeedsOne(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Leave at least one bot on, or switch “Every bot” back on."
        case .control: "AN EMPTY LIST MEANS ALL — KEEP ONE, OR RE-ENABLE ALL PROFILES."
        case .ink: "Name one at least, or open the gate again."
        }
    }

    func settingsFilterStranded(_ t: ThemeID, names: String) -> String {
        switch t {
        case .soft: "Your list names \(names), which this gateway no longer has."
        case .control: "FILTER REFERENCES UNKNOWN PROFILE(S): \(names)."
        case .ink: "Your list still calls for \(names), who are no longer here."
        }
    }
}

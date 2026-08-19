import SwiftUI
import TalariaKit
import TalariaTheme

enum ProfileLifecycleCompletionFence {
    static func accepts(generation: Int, currentGeneration: Int,
                        gatewayID: String?, currentGatewayID: String?) -> Bool {
        generation == currentGeneration && gatewayID == currentGatewayID
    }
}

enum ProfileLifecycleCompletionSelection {
    /// SwiftUI does not publish `onChange` for an idempotent assignment. Only
    /// arm the one-shot suppression flag when a completion actually changes
    /// the picker value, otherwise the next manual selection would consume it.
    static func requiresSuppression(current: String?, next: String?) -> Bool {
        current != next
    }
}

/// Mobile profile-directory lifecycle. Creation/editing already live in the
/// roster; Settings owns rename/delete because they change identity across
/// every session and cannot be mistaken for cosmetic title editing.
public struct ProfileLifecycleSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    @State private var selectedGatewayID: String?
    @State private var selectedRosterID: String?
    @State private var renameText = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var pendingDelete: ProfileLifecycleTarget?
    @State private var pendingDeleteGeneration = 0
    @State private var pendingDeleteGatewayID: String?
    @State private var generation = 0
    @State private var applyingCompletionSelection = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPicker }
            SettingsSection(theme: theme, title: "PROFILE LIFECYCLE",
                            footnote: lifecycleFootnote) {
                SettingsGroup(theme: theme) {
                    profilePicker
                    renameField
                    SettingsActionRow(theme: theme, title: renameActionTitle,
                                      subtitle: renameActionSubtitle, isBusy: busy) {
                        beginRename()
                    }
                    .disabled(!canRename)
                    SettingsActionRow(theme: theme, title: "Delete profile",
                                      subtitle: deleteSubtitle, isDestructive: true,
                                      isBusy: busy, isLast: true) {
                        if let selectedTarget {
                            pendingDelete = selectedTarget
                            pendingDeleteGeneration = generation
                            pendingDeleteGatewayID = targetGatewayID
                        }
                    }
                    .disabled(selectedTarget == nil || selectedTarget?.route.profile == "default" || busy)
                }
            }
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: targetGatewayID) { prepareGateway() }
        .onChange(of: selectedRosterID) { _, _ in
            generation &+= 1
            if applyingCompletionSelection {
                applyingCompletionSelection = false
            } else {
                prepareProfile()
            }
        }
        .alert("Delete this profile?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete permanently", role: .destructive) {
                guard let target = pendingDelete else { return }
                let operationGeneration = pendingDeleteGeneration
                let operationGatewayID = pendingDeleteGatewayID
                pendingDelete = nil
                Task { await performDelete(target, generation: operationGeneration,
                                           gatewayID: operationGatewayID) }
            }
        } message: {
            if let target = pendingDelete {
                Text("This permanently deletes \(target.route.profile) and its profile data on \(gatewayName(target.route.gatewayID)). This cannot be undone.")
            }
        }
    }

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                           available: Set(gatewayChoices.map(\.id)),
                                           active: model.activeGatewayID,
                                           runtime: LiveRuntime.shared.gatewayID)
    }

    private var profileChoices: [Bot] {
        guard let targetGatewayID else { return [] }
        return model.unionRosterBots.filter { bot in
            model.profileRoute(for: bot.id)?.gatewayID == targetGatewayID
        }
    }

    private var selectedTarget: ProfileLifecycleTarget? {
        guard let selectedRosterID,
              profileChoices.contains(where: { $0.id == selectedRosterID }) else { return nil }
        return model.profileLifecycleTarget(rosterID: selectedRosterID)
    }

    private var cleanRename: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gatewayPicker: some View {
        SettingsSection(theme: theme, title: "PROFILE GATEWAY",
                        footnote: "Profile names are local to one gateway. Choose the machine before changing identity.") {
            SettingsGroup(theme: theme) {
                Picker("Gateway", selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedRosterID = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID ? " · active" : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .disabled(busy)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $selectedRosterID) {
            Text("Choose a profile").tag(String?.none)
            ForEach(profileChoices) { bot in
                Text(bot.displayTitle).tag(Optional(bot.id))
            }
        }
        .pickerStyle(.menu)
        .tint(theme.accent)
        .disabled(busy)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .modifier(SettingsRowChrome(theme: theme, isLast: false))
    }

    @ViewBuilder private var renameField: some View {
        #if os(iOS)
        profileNameField
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        profileNameField
        #endif
    }

    private var profileNameField: some View {
        TextField("New profile name", text: $renameText)
            .font(theme.mono(13))
            .foregroundStyle(theme.ink)
            .disabled(selectedTarget == nil || busy)
            .modifier(SettingsRowChrome(theme: theme, isLast: false))
    }

    private var renameActionTitle: String {
        selectedTarget?.route.profile == "default" ? "Rename display name" : "Rename profile"
    }

    private var renameActionSubtitle: String {
        if !renameNameIsValid {
            return "Use a non-reserved name with lowercase letters, digits, hyphens, or underscores; start with a letter or digit."
        }
        return selectedTarget?.route.profile == "default"
            ? "Hermes keeps the canonical default id and changes only its presented name."
            : "Moves the profile directory and preserves its stored conversations."
    }

    private var renameNameIsValid: Bool {
        guard !cleanRename.isEmpty else { return false }
        if selectedTarget?.route.profile == "default" { return true }
        return ProfileNamePolicy.validatesNamedProfile(cleanRename)
    }

    private var canRename: Bool {
        guard let selectedTarget, renameNameIsValid, !busy else { return false }
        return selectedTarget.route.profile == "default"
            || cleanRename != selectedTarget.route.profile
    }

    private var deleteSubtitle: String {
        selectedTarget?.route.profile == "default"
            ? "Hermes does not allow deleting the default profile."
            : "Permanently removes this profile after confirmation."
    }

    private var lifecycleFootnote: String {
        "Changes are sent only to the selected gateway. A profile with the same name on another gateway is never touched."
    }

    private func prepareGateway() {
        generation &+= 1
        let available = Set(profileChoices.map(\.id))
        if let selectedRosterID, !available.contains(selectedRosterID) {
            self.selectedRosterID = nil
        }
        if selectedRosterID == nil { selectedRosterID = profileChoices.first?.id }
        prepareProfile()
    }

    private func prepareProfile() {
        renameText = selectedTarget?.route.profile == "default" ? "" : selectedTarget?.route.profile ?? ""
        notice = nil
        noticeIsWarning = false
    }

    private func beginRename() {
        guard let target = selectedTarget, !cleanRename.isEmpty else { return }
        let requested = cleanRename
        let operationGeneration = generation
        let operationGatewayID = targetGatewayID
        selectedGatewayID = operationGatewayID
        busy = true
        notice = nil
        Task {
            let outcome = await model.renameProfile(target, to: requested)
            await MainActor.run {
                finish(outcome, original: target, generation: operationGeneration,
                       gatewayID: operationGatewayID)
            }
        }
    }

    @MainActor private func performDelete(_ target: ProfileLifecycleTarget,
                                          generation operationGeneration: Int,
                                          gatewayID operationGatewayID: String?) async {
        guard ProfileLifecycleCompletionFence.accepts(
            generation: operationGeneration, currentGeneration: generation,
            gatewayID: operationGatewayID, currentGatewayID: targetGatewayID) else { return }
        selectedGatewayID = operationGatewayID
        busy = true
        notice = nil
        let outcome = await model.deleteProfile(target, confirmed: true)
        finish(outcome, original: target, generation: operationGeneration,
               gatewayID: operationGatewayID)
    }

    private func finish(_ outcome: ProfileLifecycleOutcome,
                        original: ProfileLifecycleTarget,
                        generation operationGeneration: Int,
                        gatewayID operationGatewayID: String?) {
        busy = false
        guard ProfileLifecycleCompletionFence.accepts(
            generation: operationGeneration, currentGeneration: generation,
            gatewayID: operationGatewayID, currentGatewayID: targetGatewayID) else { return }
        switch outcome {
        case .renamed(let canonical, let displayName):
            noticeIsWarning = false
            notice = displayName.map { "Display name changed to \($0)." }
                ?? "Profile renamed to \(canonical)."
            let route = GatewayBotRoute(gatewayID: original.route.gatewayID, profile: canonical)
            let nextSelection = original.route.gatewayID == LiveRuntime.shared.gatewayID
                ? canonical : route.qualifiedID
            applyingCompletionSelection = ProfileLifecycleCompletionSelection.requiresSuppression(
                current: selectedRosterID, next: nextSelection)
            selectedRosterID = nextSelection
            renameText = canonical == "default" ? "" : canonical
        case .deleted:
            noticeIsWarning = false
            notice = "Profile deleted from \(gatewayName(original.route.gatewayID))."
            applyingCompletionSelection = true
            selectedRosterID = nil
            renameText = ""
        case .refused(let message):
            noticeIsWarning = true
            notice = message
        }
    }

    private func gatewayName(_ gatewayID: String) -> String {
        gatewayChoices.first(where: { $0.id == gatewayID })?.name ?? "the selected gateway"
    }
}

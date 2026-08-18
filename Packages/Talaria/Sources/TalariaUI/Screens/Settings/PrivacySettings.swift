import SwiftUI
import TalariaKit
import TalariaTheme

// Settings → Privacy & data: what Talaria has actually written to this device,
// and the three verbs that undo it.
//
// The list is measured, never asserted. `AppModel.localStorageInventory()`
// probes the Keychain once per saved gateway, walks `UserDefaults` for the
// `talaria` namespace, and sizes the caches on disk and in memory — so a
// preference added by a file this screen has never heard of still appears
// here, and "delete local data" still removes it.
//
// The honesty this section owes the reader is that none of these buttons touch
// the bots: profiles, memory and history live on the gateway. Deleting
// everything here logs the phone out; it does not unmake a single agent.

struct PrivacySettingsSection: View {
    let model: AppModel

    @State private var inventory = StorageInventory()
    @State private var isMeasuring = false
    @State private var busy: Verb?
    /// Only the two irreversible verbs ask first — clearing caches costs a
    /// re-fetch, not a sign-in.
    @State private var confirming: Verb?
    /// Bytes released by the last cache clear, shown until the next one.
    @State private var freed: Int64?

    private enum Verb: String, Identifiable {
        case clearCaches, signOutEverywhere, deleteEverything
        var id: String { rawValue }
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            storedSection
            actionsSection
        }
        .task { await measure() }
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let verb = confirming { confirmActions(verb) }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Stored on this device

    private var storedSection: some View {
        SettingsSection(theme: theme,
                        title: copy.settingsStoredSec(theme.id),
                        footnote: copy.settingsStoredNote(theme.id)) {
            if inventory.groups.isEmpty {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme,
                                title: isMeasuring ? copy.settingsMeasuring(theme.id)
                                                   : copy.settingsNothingStored(theme.id),
                                isLast: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(inventory.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(groupTitle(group.kind))
                                    .font(SettingsType.rowSubtitle(theme))
                                    .foregroundStyle(theme.sub)
                                Spacer(minLength: 8)
                                if group.bytes > 0 {
                                    Text(AppModel.formattedBytes(group.bytes))
                                        .font(SettingsType.rowValue(theme))
                                        .foregroundStyle(theme.faint)
                                }
                            }
                            .padding(.horizontal, 2)

                            SettingsGroup(theme: theme) {
                                ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                                    SettingsRow(theme: theme,
                                                title: item.title,
                                                subtitle: item.detail,
                                                value: item.bytes.map(AppModel.formattedBytes),
                                                isLast: index == group.items.count - 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupTitle(_ kind: StorageGroup.Kind) -> String {
        switch kind {
        case .keychain: copy.settingsKeychainSec(theme.id)
        case .preferences: copy.settingsPrefsSec(theme.id)
        case .caches: copy.settingsCachesSec(theme.id)
        }
    }

    // MARK: Verbs

    private var actionsSection: some View {
        SettingsSection(theme: theme,
                        title: copy.settingsDataSec(theme.id),
                        footnote: copy.settingsDataNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme,
                                  title: copy.settingsClearCaches(theme.id),
                                  subtitle: freed.map { copy.settingsCachesCleared(theme.id,
                                                                                   freed: AppModel.formattedBytes($0)) }
                                      ?? copy.settingsClearCachesNote(theme.id),
                                  isBusy: busy == .clearCaches) {
                    Task { await clearCaches() }
                }
                SettingsActionRow(theme: theme,
                                  title: copy.settingsSignOutAll(theme.id),
                                  subtitle: copy.settingsSignOutAllNote(theme.id),
                                  isBusy: busy == .signOutEverywhere) {
                    confirming = .signOutEverywhere
                }
                SettingsActionRow(theme: theme,
                                  title: copy.settingsDeleteAll(theme.id),
                                  subtitle: copy.settingsDeleteAllNote(theme.id),
                                  isDestructive: true,
                                  isBusy: busy == .deleteEverything,
                                  isLast: true) {
                    confirming = .deleteEverything
                }
            }
        }
    }

    @ViewBuilder
    private func confirmActions(_ verb: Verb) -> some View {
        Button(confirmTitle, role: .destructive) {
            Task {
                switch verb {
                case .signOutEverywhere: await signOutEverywhere()
                case .deleteEverything: await deleteEverything()
                case .clearCaches: await clearCaches()
                }
            }
        }
        Button(copy.cancel, role: .cancel) {}
    }

    private var confirmTitle: String {
        confirming == .deleteEverything ? copy.settingsDeleteAll(theme.id)
                                        : copy.settingsSignOutAll(theme.id)
    }

    private var confirmMessage: String {
        confirming == .deleteEverything ? copy.settingsDeleteAllConfirm(theme.id)
                                        : copy.settingsSignOutAllConfirm(theme.id)
    }

    // MARK: Work

    private func measure() async {
        isMeasuring = true
        inventory = await model.localStorageInventory()
        isMeasuring = false
    }

    private func clearCaches() async {
        busy = .clearCaches
        let released = await model.clearLocalCaches()
        // "Freed Zero KB" is noise; leave the explanatory subtitle in place.
        if released > 0 { freed = released }
        await measure()
        busy = nil
    }

    private func signOutEverywhere() async {
        busy = .signOutEverywhere
        await model.signOutOfEverything()
        await measure()
        busy = nil
    }

    private func deleteEverything() async {
        busy = .deleteEverything
        await model.deleteAllLocalData()
        await measure()
        busy = nil
    }
}

// MARK: - Copy

extension CopyPack {

    func settingsStoredSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On this device"
        case .control: "LOCAL FOOTPRINT"
        case .ink: "WHAT THIS DEVICE KEEPS"
        }
    }

    func settingsStoredNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Measured, not guessed. Credentials live in the Keychain and never in preferences, files or logs."
        case .control: "MEASURED AT OPEN. CREDENTIALS ARE KEYCHAIN-ONLY — NEVER DEFAULTS, FILES OR LOGS."
        case .ink: "Counted, not supposed. Seals are kept in the Keychain alone — never in the plain."
        }
    }

    func settingsKeychainSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Keychain"
        case .control: "KEYCHAIN"
        case .ink: "the sealed box"
        }
    }

    func settingsPrefsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Preferences"
        case .control: "DEFAULTS"
        case .ink: "the settled habits"
        }
    }

    func settingsCachesSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Caches"
        case .control: "CACHES"
        case .ink: "what is merely borrowed"
        }
    }

    func settingsMeasuring(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Measuring…"
        case .control: "MEASURING…"
        case .ink: "counting…"
        }
    }

    func settingsNothingStored(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing stored on this device yet"
        case .control: "NO LOCAL FOOTPRINT"
        case .ink: "this device keeps nothing yet"
        }
    }

    func settingsDataSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Privacy & data"
        case .control: "DATA CONTROL"
        case .ink: "UNMAKING"
        }
    }

    func settingsDataNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "None of this touches your bots. Profiles, memory and history live on the gateway and keep running."
        case .control: "SCOPE IS THIS DEVICE ONLY. PROFILES / MEMORY / HISTORY REMAIN SERVER-SIDE AND KEEP RUNNING."
        case .ink: "None of this reaches the familiars. Their natures, memories and histories are kept at the gateway, and they work on."
        }
    }

    func settingsClearCaches(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Clear caches"
        case .control: "PURGE CACHES"
        case .ink: "let go what is borrowed"
        }
    }

    func settingsClearCachesNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sprites, portraits, voice clips and downloaded responses — all re-fetched when next needed."
        case .control: "SPRITE ATLASES, PORTRAITS, VOICE CLIPS, HTTP CACHE. ALL RE-FETCHABLE."
        case .ink: "Sprites, faces, voices and fetched pages — each returns when it is wanted again."
        }
    }

    func settingsCachesCleared(_ t: ThemeID, freed: String) -> String {
        switch t {
        case .soft: "Freed \(freed)"
        case .control: "RELEASED \(freed.uppercased())"
        case .ink: "\(freed) given back"
        }
    }

    func settingsSignOutAll(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign out everywhere"
        case .control: "DROP ALL CREDENTIALS"
        case .ink: "surrender every seal"
        }
    }

    func settingsSignOutAllNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Forgets every gateway credential and the Nous Portal token. Your gateways stay listed."
        case .control: "PURGES EVERY GATEWAY CREDENTIAL + THE PORTAL TOKEN. UPLINK ROWS SURVIVE."
        case .ink: "Unmakes every gateway's token and the Portal's besides. The ways remain named."
        }
    }

    func settingsSignOutAllConfirm(_ t: ThemeID) -> String {
        switch t {
        case .soft: "You will need to sign in again on each gateway. Your bots keep running."
        case .control: "RE-AUTH REQUIRED PER UPLINK. AGENTS CONTINUE SERVER-SIDE."
        case .ink: "You must set your seal anew upon each way. The familiars work on regardless."
        }
    }

    func settingsDeleteAll(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete local data"
        case .control: "WIPE LOCAL STATE"
        case .ink: "unmake all that is kept here"
        }
    }

    func settingsDeleteAllNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Credentials, saved gateways, preferences and caches — then onboarding starts over."
        case .control: "CREDENTIALS + UPLINK REGISTRY + DEFAULTS + CACHES. ONBOARDING RESTARTS."
        case .ink: "Seals, ways, habits and borrowings alike — then the first page again."
        }
    }

    func settingsDeleteAllConfirm(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This cannot be undone on this device. Nothing on your gateway is deleted — bots, memory and history are untouched."
        case .control: "IRREVERSIBLE LOCALLY. NO SERVER-SIDE DELETION — PROFILES, MEMORY AND HISTORY ARE UNTOUCHED."
        case .ink: "There is no undoing it here. Nothing at the gateway is unmade — the familiars, their memories and their histories stand."
        }
    }
}

import SwiftUI
import TalariaKit
import TalariaTheme
#if os(iOS)
import UIKit
#endif

// Settings → Voice.
//
// Voice on a phone is two machines pretending to be one, and almost every
// mistake in this area comes from blurring them:
//
//   THIS DEVICE owns the microphone and the speaker. Recording, playback and
//   the auto-speak preference are local (AudioRecorder, VoiceRuntime).
//   THE GATEWAY owns the providers. Transcription and synthesis happen there,
//   over POST /api/audio/transcribe and /api/audio/speak, using the addressed
//   profile's keys — which is why a bot with its own ElevenLabs key sounds
//   like itself (GatewayClient+Voice.swift).
//   THE GATEWAY HOST also has its own microphone and speakers, driven by
//   `voice.toggle`. Those are a different pair of ears entirely, and the
//   section only shows them when the gateway says it has a sound device
//   (`audio_available`) — offering "speak aloud" on a headless server would be
//   a switch that does nothing.
//
// So the rows are grouped by *whose hardware they touch*, and each group says
// so. The capability probe underneath is `voice.toggle {action:"status"}`
// (tui_gateway/server.py:14862), already typed in GatewayClient+Voice.swift and
// reused here rather than re-parsed.
//
// What is deliberately not offered:
//   · Wake word — `wake.start {client_capture:true}` wants a continuous PCM
//     feed over `wake.feed`, which iOS cannot sustain outside the foreground
//     (AppModelLive+Voice.swift documents the same call).
// Provider choices come from profile-scoped GET /api/config/schema rather than
// a frozen app list. ElevenLabs gets its live catalog; providers without a
// catalog expose their configured voice as an editable value.

public struct VoiceSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var voice: VoiceRuntime { model.voice }

    /// Owns nothing but the permission state here — `start()` is never called,
    /// so no audio session is activated by opening Settings.
    @State private var recorder = AudioRecorder()
    @State private var capabilities: VoiceCapabilities = .unknown
    @State private var host: HostVoiceState?
    @State private var voices: TTSVoiceCatalog = .unknown
    @State private var providerOptions: VoiceProviderOptions = .empty
    @State private var draftTTSProvider = ""
    @State private var draftSTTProvider = ""
    @State private var draftVoice = ""
    @State private var isProbing = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var isPickingVoice = false
    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateScopeKey: String?
    @State private var generation = 0

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            deviceSection
            if gatewayChoices.count > 1 { gatewayPickerSection }
            if !profileChoices.isEmpty { profilePickerSection }
            gatewaySection
            if showsHostSection { hostSection }
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) {
            let key = scopeKey
            prepareForScope(key)
            await probe(scopeKey: key)
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
        let gatewayID = targetGatewayID
        return model.unionRosterBots.filter { bot in
            guard let route = model.profileRoute(for: bot.id) else {
                return gatewayID == model.activeGatewayID
            }
            return route.gatewayID == gatewayID
        }
    }

    private var targetProfile: String? {
        let profiles = Set(profileChoices.map { model.profileRoute(for: $0.id)?.profile ?? $0.id })
        return selectedProfile.flatMap { profiles.contains($0) ? $0 : nil }
    }

    private var scopeKey: String {
        "\(targetGatewayID ?? "demo")\u{1f}\(targetProfile ?? "__gateway__")"
    }

    private var gatewayPickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsVoiceTargetGateway(theme.id),
                        footnote: copy.settingsVoiceTargetGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsVoiceTargetGateway(theme.id), selection: Binding(
                    get: { targetGatewayID }, set: {
                        selectedGatewayID = $0
                        selectedProfile = nil
                    })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var profilePickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsVoiceTargetProfile(theme.id),
                        footnote: copy.settingsVoiceTargetProfileNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsVoiceTargetProfile(theme.id), selection: $selectedProfile) {
                    Text(copy.settingsOperatorGatewayDefault(theme.id)).tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle)
                            .tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    // MARK: - This device

    private var deviceSection: some View {
        SettingsSection(theme: theme, title: copy.settingsVoiceDeviceSection(theme.id),
                        footnote: copy.settingsVoiceDeviceNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsToggleRow(theme: theme,
                                  title: copy.settingsAutoSpeak(theme.id),
                                  subtitle: copy.settingsAutoSpeakSub(theme.id),
                                  isOn: voice.autoSpeak) {
                    voice.autoSpeak.toggle()
                }
                micRow
            }
        }
    }

    /// The mic is a dead end once denied — iOS will not re-prompt — so the row
    /// turns into a link to Settings rather than a button that does nothing.
    @ViewBuilder private var micRow: some View {
        switch recorder.permission {
        case .granted:
            SettingsRow(theme: theme, title: copy.settingsMic(theme.id),
                        subtitle: copy.settingsMicGrantedSub(theme.id),
                        value: copy.settingsMicGranted(theme.id), valueTone: theme.ok,
                        isLast: true)
        case .undetermined:
            SettingsActionRow(theme: theme, title: copy.settingsMicAsk(theme.id),
                              subtitle: copy.settingsMicUndeterminedSub(theme.id),
                              isLast: true) {
                Task { await recorder.ensurePermission() }
            }
        case .denied:
            SettingsActionRow(theme: theme, title: copy.settingsOpenSystemSettings(theme.id),
                              subtitle: copy.settingsMicDeniedSub(theme.id),
                              isDestructive: true, isLast: true) {
                openSystemSettings()
            }
        case .unsupported:
            SettingsRow(theme: theme, title: copy.settingsMic(theme.id),
                        subtitle: copy.settingsMicUnsupportedSub(theme.id),
                        value: copy.settingsUnavailable(theme.id), isLast: true)
        }
    }

    // MARK: - This gateway

    private var gatewaySection: some View {
        SettingsSection(theme: theme, title: copy.settingsVoiceGatewaySection(theme.id),
                        footnote: capabilities.details.isEmpty ? nil : capabilities.details) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme,
                            title: copy.settingsSTT(theme.id),
                            subtitle: sttSubtitle,
                            value: sttValue, valueTone: sttTone)
                providerPickerRow(title: copy.settingsSTTProvider(theme.id),
                                  value: draftSTTProvider,
                                  options: providerOptions.stt,
                                  kind: .stt)
                providerPickerRow(title: copy.settingsTTSProvider(theme.id),
                                  value: draftTTSProvider,
                                  options: providerOptions.tts,
                                  kind: .tts)

                if !offersVoicePicker, voices.voiceKeyPath != nil {
                    TextField(copy.settingsVoiceName(theme.id), text: $draftVoice)
                        .textFieldStyle(.plain)
                        .font(theme.mono(11))
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .modifier(SettingsRowChrome(theme: theme, isLast: false))
                    SettingsActionRow(theme: theme,
                                      title: copy.settingsSaveVoice(theme.id),
                                      isBusy: busy,
                                      isLast: true) {
                        Task { await saveTypedVoice() }
                    }
                    .disabled(draftVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draftVoice == voices.currentVoice)
                }

                if offersVoicePicker {
                    SettingsRow(theme: theme, title: copy.settingsVoiceName(theme.id),
                                value: selectedVoiceLabel,
                                showsChevron: true,
                                isLast: !isPickingVoice) {
                        withAnimation(.easeInOut(duration: 0.18)) { isPickingVoice.toggle() }
                    }
                    if isPickingVoice {
                        ForEach(Array(voices.voices.enumerated()), id: \.element.id) { index, option in
                            voiceRow(option, isLast: index == voices.voices.count - 1)
                        }
                    }
                }
            }

            if voices.unauthorized {
                Text(copy.settingsVoiceKeyRejected(theme.id))
                    .font(theme.mono(10.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }

            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme, title: copy.settingsRecheck(theme.id),
                                  subtitle: copy.settingsRecheckSub(theme.id),
                                  isBusy: isProbing, isLast: true) {
                    Task { await probe(force: true) }
                }
            }
        }
    }

    /// The gateway can transcribe when it has an STT provider — the phone
    /// supplies the microphone, so the host's own sound device is irrelevant
    /// here. `canTranscribe` also covers the older gateways that answer status
    /// without the requirements probe.
    private var sttValue: String {
        guard model.mode == .live else { return copy.settingsDemoValue(theme.id) }
        guard capabilities.probed else { return copy.settingsUnknown(theme.id) }
        return capabilities.canTranscribe ? copy.settingsAvailable(theme.id)
                                          : copy.settingsUnavailable(theme.id)
    }

    private var sttTone: Color {
        guard model.mode == .live, capabilities.probed else { return theme.faint }
        return capabilities.canTranscribe ? theme.ok : theme.warn
    }

    private var sttSubtitle: String {
        voices.sttProvider.isEmpty ? copy.settingsSTTSub(theme.id)
                                   : copy.settingsSTTSubNamed(theme.id, provider: voices.sttProvider)
    }

    private var ttsProviderValue: String {
        if model.mode != .live { return copy.settingsDemoValue(theme.id) }
        return voices.provider.isEmpty ? copy.settingsUnknown(theme.id) : voices.provider
    }

    private var offersVoicePicker: Bool { !voices.voices.isEmpty }

    private var hasReadableVoice: Bool { !voices.currentVoice.isEmpty }

    private var selectedVoiceLabel: String {
        voices.voices.first { $0.id == voices.currentVoice }?.label
            ?? (voices.currentVoice.isEmpty ? copy.settingsVoiceUnset(theme.id)
                                            : voices.currentVoice)
    }

    private enum ProviderKind: Equatable { case tts, stt }

    private func providerPickerRow(title: String, value: String, options: [String],
                                   kind: ProviderKind) -> some View {
        HStack(spacing: 10) {
            Text(title).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            if options.isEmpty {
                Text(value.isEmpty ? copy.settingsUnknown(theme.id) : value)
                    .font(SettingsType.rowValue(theme)).foregroundStyle(theme.sub)
            } else {
                Picker(title, selection: Binding(
                    get: { value },
                    set: { next in Task { await setProvider(kind, to: next) } })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).tint(theme.accent)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: false))
        .disabled(busy)
    }

    private func voiceRow(_ option: TTSVoiceOption, isLast: Bool) -> some View {
        let isCurrent = option.id == voices.currentVoice
        return Button {
            Task { await selectVoice(option) }
        } label: {
            HStack(spacing: 8) {
                Text(option.label)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    // MARK: - The gateway host's own speakers

    /// Only meaningful when the gateway machine actually has a sound device.
    /// `audio_available` is upstream's own probe of that (server.py:14887), and
    /// it is false on every headless box — where these two switches would be
    /// controls over nothing.
    private var showsHostSection: Bool {
        model.mode == .live && capabilities.probed && capabilities.hostAudio
    }

    private var hostSection: some View {
        SettingsSection(theme: theme, title: copy.settingsVoiceHostSection(theme.id),
                        footnote: copy.settingsVoiceHostNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsToggleRow(theme: theme,
                                  title: copy.settingsHostVoiceMode(theme.id),
                                  subtitle: copy.settingsHostVoiceModeSub(theme.id),
                                  isOn: hostEnabled) {
                    Task { await setHostVoice(!hostEnabled) }
                }
                .disabled(busy)
                SettingsToggleRow(theme: theme,
                                  title: copy.settingsHostTTS(theme.id),
                                  subtitle: copy.settingsHostTTSSub(theme.id),
                                  isOn: hostTTS,
                                  isLast: true) {
                    Task { await setHostTTS(!hostTTS) }
                }
                .opacity(hostEnabled ? 1 : 0.45)
                .disabled(!hostEnabled || busy)
            }
        }
    }

    private var hostEnabled: Bool { host?.enabled ?? capabilities.hostVoiceEnabled }
    private var hostTTS: Bool { host?.tts ?? capabilities.hostTTSEnabled }

    // MARK: - Actions

    private func prepareForScope(_ key: String) {
        guard stateScopeKey != key else { return }
        generation &+= 1
        stateScopeKey = key
        capabilities = .unknown
        host = nil
        voices = .unknown
        providerOptions = .empty
        draftTTSProvider = ""
        draftSTTProvider = ""
        draftVoice = ""
        isProbing = false
        busy = false
        notice = nil
        isPickingVoice = false
    }

    private func gatewayClient(for gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func isCurrent(_ key: String, generation captured: Int) -> Bool {
        stateScopeKey == key && scopeKey == key && generation == captured
    }

    private func probe(force: Bool = false, scopeKey requestedKey: String? = nil) async {
        let key = requestedKey ?? scopeKey
        guard stateScopeKey == key, !isProbing else { return }
        generation &+= 1
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        isProbing = true
        defer { if isCurrent(key, generation: captured) { isProbing = false } }

        // AudioRecorder samples the permission in its initializer and exposes
        // no re-read; `ensurePermission()` would PROMPT, which a settings
        // screen must not do on appear. Rebuilding it is the cheap, honest
        // refresh — nothing is allocated until `start()`, which never runs
        // here — and it is what makes a trip to iOS Settings and back show the
        // new state instead of the stale one.
        recorder = AudioRecorder()

        guard model.mode == .live else {
            capabilities = .unknown
            voices = .unknown
            return
        }
        guard let client = try? await gatewayClient(for: gatewayID) else {
            guard isCurrent(key, generation: captured) else { return }
            capabilities = .unknown
            voices = .unknown
            return
        }
        var nextCapabilities = await client.voiceCapabilities()
        guard isCurrent(key, generation: captured) else { return }
        if force { host = nil }
        // The config read is a separate hop and a gateway may have no voice
        // configuration at all; `.unknown` renders as "unknown", never as an
        // error the user cannot act on.
        let nextVoices = await client.voiceCatalog(profile: profile)
        guard isCurrent(key, generation: captured) else { return }
        let sttReadiness = await client.profileSTTReadiness(profile: profile)
        guard isCurrent(key, generation: captured) else { return }
        if sttReadiness.probed {
            nextCapabilities.speechToText = sttReadiness.canTranscribe
            nextCapabilities.probed = true
        } else {
            nextCapabilities.probed = false
        }
        let nextOptions = await client.voiceProviderOptions(profile: profile)
        guard isCurrent(key, generation: captured) else { return }
        capabilities = nextCapabilities
        voices = nextVoices
        providerOptions = nextOptions
        draftTTSProvider = nextVoices.provider
        draftSTTProvider = nextVoices.sttProvider
        draftVoice = nextVoices.currentVoice
    }

    private func selectVoice(_ option: TTSVoiceOption) async {
        guard stateScopeKey == scopeKey, let path = voices.voiceKeyPath else { return }
        let key = scopeKey
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let captured = generation
        guard let client = try? await gatewayClient(for: gatewayID) else { return }
        guard isCurrent(key, generation: captured) else { return }
        busy = true
        defer { if isCurrent(key, generation: captured) { busy = false } }
        let previous = voices.currentVoice
        voices.currentVoice = option.id
        do {
            try await client.setGatewayConfigValue(path: path, value: .string(option.id),
                                                   profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            draftVoice = option.id
            isPickingVoice = false
            note(copy.settingsVoiceSaved(theme.id, voice: option.name), warning: false)
        } catch let error as GatewayError {
            guard isCurrent(key, generation: captured) else { return }
            voices.currentVoice = previous
            note(error.message, warning: true)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            voices.currentVoice = previous
            note(error.localizedDescription, warning: true)
        }
    }

    private func saveTypedVoice() async {
        guard stateScopeKey == scopeKey, let path = voices.voiceKeyPath else { return }
        let value = draftVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let key = scopeKey
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let captured = generation
        guard let client = try? await gatewayClient(for: gatewayID),
              isCurrent(key, generation: captured) else { return }
        busy = true
        defer { if isCurrent(key, generation: captured) { busy = false } }
        do {
            try await client.setGatewayConfigValue(path: path, value: .string(value),
                                                   profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            voices.currentVoice = value
            note(copy.settingsVoiceSaved(theme.id, voice: value), warning: false)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            draftVoice = voices.currentVoice
            note((error as? GatewayError)?.message ?? error.localizedDescription, warning: true)
        }
    }

    private func setProvider(_ kind: ProviderKind, to value: String) async {
        guard stateScopeKey == scopeKey, !value.isEmpty else { return }
        let key = scopeKey
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let captured = generation
        let path = [kind == .tts ? "tts" : "stt", "provider"]
        guard let client = try? await gatewayClient(for: gatewayID),
              isCurrent(key, generation: captured) else { return }
        busy = true
        do {
            try await client.setGatewayConfigValue(path: path, value: .string(value),
                                                   profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            if kind == .tts { draftTTSProvider = value } else { draftSTTProvider = value }
            busy = false
            await probe(force: true, scopeKey: key)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            busy = false
            note((error as? GatewayError)?.message ?? error.localizedDescription, warning: true)
        }
    }

    private func setHostVoice(_ enabled: Bool) async {
        guard stateScopeKey == scopeKey else { return }
        let key = scopeKey
        let gatewayID = targetGatewayID
        let captured = generation
        guard let client = try? await gatewayClient(for: gatewayID) else { return }
        guard isCurrent(key, generation: captured) else { return }
        busy = true
        defer { if isCurrent(key, generation: captured) { busy = false } }
        do {
            let next = try await client.setHostVoiceMode(enabled: enabled)
            guard isCurrent(key, generation: captured) else { return }
            host = next
        } catch let error as GatewayError {
            guard isCurrent(key, generation: captured) else { return }
            note(error.message, warning: true)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            note(error.localizedDescription, warning: true)
        }
    }

    /// `voice.toggle tts` has no explicit set form upstream — it flips whatever
    /// the host currently has — so this only fires when the reported state
    /// actually differs from what was asked for.
    private func setHostTTS(_ wanted: Bool) async {
        guard stateScopeKey == scopeKey, hostTTS != wanted else { return }
        let key = scopeKey
        let gatewayID = targetGatewayID
        let captured = generation
        guard let client = try? await gatewayClient(for: gatewayID) else { return }
        guard isCurrent(key, generation: captured) else { return }
        busy = true
        defer { if isCurrent(key, generation: captured) { busy = false } }
        do {
            let next = try await client.toggleHostTTS()
            guard isCurrent(key, generation: captured) else { return }
            host = next
        } catch let error as GatewayError {
            guard isCurrent(key, generation: captured) else { return }
            note(error.message, warning: true)
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            note(error.localizedDescription, warning: true)
        }
    }

    private func note(_ text: String, warning: Bool) {
        notice = text.isEmpty ? nil : text
        noticeIsWarning = warning
    }

    private func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Themed copy

/// Voice for the voice section. Gateway text — the `details` provider matrix,
/// an RPC error — passes through verbatim.
public extension CopyPack {

    func settingsVoiceTargetGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice gateway"
        case .control: "VOICE SOURCE"
        case .ink: "the house whose voice this is"
        }
    }

    func settingsVoiceTargetGatewayNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice providers, selectable voices and host speakers belong to one gateway. This does not switch your open chat."
        case .control: "PROVIDER + HOST AUDIO STATE IS GATEWAY-LOCAL. CHAT ROUTE IS UNCHANGED."
        case .ink: "Choose the house whose ears and speakers you mean; the room already open does not move."
        }
    }

    func settingsVoiceTargetProfile(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice profile"
        case .control: "VOICE PROFILE"
        case .ink: "whose voice is being shaped"
        }
    }

    func settingsVoiceTargetProfileNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Provider and voice settings can override the gateway default for one agent."
        case .control: "PROFILE-SCOPED STT/TTS CONFIG. HOST AUDIO REMAINS GATEWAY-WIDE."
        case .ink: "Choose the house rule, or give one resident a voice of their own."
        }
    }

    func settingsVoiceDeviceSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On this phone"
        case .control: "LOCAL AUDIO"
        case .ink: "what this device hears"
        }
    }

    func settingsVoiceGatewaySection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "On your gateway"
        case .control: "GATEWAY AUDIO PROVIDERS"
        case .ink: "what the gateway can do"
        }
    }

    func settingsVoiceHostSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway’s own speakers"
        case .control: "HOST AUDIO DEVICE"
        case .ink: "the machine’s own voice"
        }
    }

    func settingsVoiceDeviceNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Recording and playback happen here; the words are transcribed and spoken by your gateway."
        case .control: "CAPTURE + PLAYBACK LOCAL. STT/TTS EXECUTED GATEWAY-SIDE PER PROFILE."
        case .ink: "This device listens and speaks. The gateway does the understanding."
        }
    }

    func settingsVoiceHostNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "These control the machine your gateway runs on, not this phone. They reset when the gateway restarts."
        case .control: "AFFECTS HERMES_VOICE ON THE HOST PROCESS. RUNTIME ONLY — NOT PERSISTED."
        case .ink: "You are reaching across to the machine itself. It forgets when it wakes again."
        }
    }

    func settingsAutoSpeak(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Speak replies aloud"
        case .control: "AUTO-TTS"
        case .ink: "let them speak"
        }
    }

    func settingsAutoSpeakSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Plays each answer through this phone as it finishes."
        case .control: "PLAYS COMPLETED TURNS VIA /api/audio/speak."
        case .ink: "Each answer is read to you when it is done."
        }
    }

    func settingsMic(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Microphone"
        case .control: "MICROPHONE"
        case .ink: "the ear"
        }
    }

    func settingsMicAsk(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Allow the microphone"
        case .control: "REQUEST MIC PERMISSION"
        case .ink: "grant the ear"
        }
    }

    func settingsMicGranted(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Allowed"
        case .control: "GRANTED"
        case .ink: "open"
        }
    }

    func settingsMicGrantedSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice turns can record."
        case .control: "CAPTURE AVAILABLE."
        case .ink: "It may listen when asked."
        }
    }

    func settingsMicUndeterminedSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice needs the microphone before it can hear you."
        case .control: "NO CAPTURE UNTIL AUTHORIZED."
        case .ink: "Nothing is heard until you allow it."
        }
    }

    func settingsMicDeniedSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "iOS is blocking the microphone. Turn it back on in Settings → Talaria."
        case .control: "MIC DENIED AT OS LEVEL — RE-ENABLE IN iOS SETTINGS."
        case .ink: "The ear is stopped. Only the system may open it again."
        }
    }

    func settingsMicUnsupportedSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No microphone on this platform."
        case .control: "NO CAPTURE PATH ON THIS PLATFORM."
        case .ink: "This shape of the app has no ear."
        }
    }

    func settingsOpenSystemSettings(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open iOS Settings"
        case .control: "OPEN iOS SETTINGS"
        case .ink: "go to the system"
        }
    }

    func settingsSTT(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Transcription"
        case .control: "SPEECH → TEXT"
        case .ink: "the scribe"
        }
    }

    func settingsSTTSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Turns what you say into a prompt."
        case .control: "POST /api/audio/transcribe."
        case .ink: "It sets down what you said."
        }
    }

    func settingsSTTSubNamed(_ t: ThemeID, provider: String) -> String {
        switch t {
        case .soft: "Provided by \(provider)."
        case .control: "PROVIDER: \(provider.uppercased())."
        case .ink: "Written down by \(provider)."
        }
    }

    func settingsTTSProvider(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Speech provider"
        case .control: "TEXT → SPEECH"
        case .ink: "the voice"
        }
    }

    func settingsSTTProvider(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Transcription provider"
        case .control: "STT PROVIDER"
        case .ink: "the scribe used"
        }
    }

    func settingsTTSProviderSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Provider choices are discovered from this gateway and profile."
        case .control: "DYNAMIC tts.provider OPTIONS FROM /api/config/schema."
        case .ink: "The gateway names every voice-maker it can use here."
        }
    }

    func settingsVoiceName(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice"
        case .control: "VOICE ID"
        case .ink: "which voice"
        }
    }

    func settingsVoiceDesktopOnly(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This provider does not publish a catalog; enter its documented voice identifier."
        case .control: "NO CATALOG — EDIT THE PROVIDER VOICE ID DIRECTLY."
        case .ink: "It offers no list, but you may write the voice it knows."
        }
    }

    func settingsVoiceUnset(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Provider default"
        case .control: "PROVIDER DEFAULT"
        case .ink: "whatever it favours"
        }
    }

    func settingsVoiceSaved(_ t: ThemeID, voice: String) -> String {
        switch t {
        case .soft: "Now speaking as \(voice)."
        case .control: "VOICE → \(voice.uppercased())."
        case .ink: "It will speak as \(voice)."
        }
    }

    func settingsSaveVoice(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save voice"
        case .control: "SAVE VOICE ID"
        case .ink: "keep this voice"
        }
    }

    func settingsVoiceKeyRejected(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway’s ElevenLabs key was rejected, so no voices could be listed."
        case .control: "ELEVENLABS 401/403 — VOICE CATALOG UNAVAILABLE."
        case .ink: "The gateway’s word was refused; no voices would answer."
        }
    }

    func settingsHostVoiceMode(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Voice mode on the host"
        case .control: "HERMES_VOICE"
        case .ink: "wake the machine’s ear"
        }
    }

    func settingsHostVoiceModeSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Lets someone sitting at the gateway talk to it directly."
        case .control: "ENABLES HOST-SIDE CAPTURE + STOP PHRASES."
        case .ink: "Whoever sits by the machine may speak to it."
        }
    }

    func settingsHostTTS(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Speak out loud there"
        case .control: "HOST TTS"
        case .ink: "let it speak where it stands"
        }
    }

    func settingsHostTTSSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Replies play from the gateway’s speakers too."
        case .control: "REPLIES SPOKEN ON THE HOST AUDIO DEVICE."
        case .ink: "The answer sounds in that room as well as this one."
        }
    }

    func settingsRecheck(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Check again"
        case .control: "RE-PROBE"
        case .ink: "ask again"
        }
    }

    func settingsRecheckSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Re-reads what this gateway can hear and say."
        case .control: "voice.toggle status + GET /api/config."
        case .ink: "Put the question to the gateway once more."
        }
    }

    func settingsAvailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Ready"
        case .control: "AVAILABLE"
        case .ink: "willing"
        }
    }

    func settingsUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Not set up"
        case .control: "UNAVAILABLE"
        case .ink: "wanting"
        }
    }

    func settingsUnknown(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unknown"
        case .control: "UNPROBED"
        case .ink: "unasked"
        }
    }

    func settingsDemoValue(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Demo"
        case .control: "DEMO"
        case .ink: "rehearsal"
        }
    }
}

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
// (tui_gateway/server.py:14740), already typed in GatewayClient+Voice.swift and
// reused here rather than re-parsed.
//
// What is deliberately not offered:
//   · Wake word — `wake.start {client_capture:true}` wants a continuous PCM
//     feed over `wake.feed`, which iOS cannot sustain outside the foreground
//     (AppModelLive+Voice.swift documents the same call).
//   · TTS provider switching — `tts.provider` is a 10-way choice where each
//     option drags its own field set (PARITY.md:626, ~28 keys). The provider is
//     shown; changing it stays on desktop.
//   · A voice list for providers whose catalog is a desktop-side table (edge,
//     openai, gemini). Only ElevenLabs publishes one over the gateway
//     (GET /api/audio/elevenlabs/voices, hermes_cli/web_server.py:5014), so
//     only ElevenLabs gets a picker; the rest show their configured voice and
//     point at desktop.

public struct VoiceSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var client: GatewayClient? { model.client }
    private var voice: VoiceRuntime { model.voice }

    /// Owns nothing but the permission state here — `start()` is never called,
    /// so no audio session is activated by opening Settings.
    @State private var recorder = AudioRecorder()
    @State private var capabilities: VoiceCapabilities = .unknown
    @State private var host: HostVoiceState?
    @State private var voices: TTSVoiceCatalog = .unknown
    @State private var isProbing = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var isPickingVoice = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            deviceSection
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
        .task { await probe() }
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

                SettingsRow(theme: theme,
                            title: copy.settingsTTSProvider(theme.id),
                            subtitle: copy.settingsTTSProviderSub(theme.id),
                            value: ttsProviderValue,
                            isLast: !offersVoicePicker && !hasReadableVoice)

                if hasReadableVoice && !offersVoicePicker {
                    SettingsRow(theme: theme, title: copy.settingsVoiceName(theme.id),
                                subtitle: copy.settingsVoiceDesktopOnly(theme.id),
                                value: voices.currentVoice, isLast: true)
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
    /// `audio_available` is upstream's own probe of that (server.py:14766), and
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

    private func probe(force: Bool = false) async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        // AudioRecorder samples the permission in its initializer and exposes
        // no re-read; `ensurePermission()` would PROMPT, which a settings
        // screen must not do on appear. Rebuilding it is the cheap, honest
        // refresh — nothing is allocated until `start()`, which never runs
        // here — and it is what makes a trip to iOS Settings and back show the
        // new state instead of the stale one.
        recorder = AudioRecorder()

        guard model.mode == .live, client != nil else {
            capabilities = .unknown
            voices = .unknown
            return
        }
        capabilities = await model.refreshVoiceCapabilities()
        if force { host = nil }
        // The config read is a separate hop and a gateway may have no voice
        // configuration at all; `.unknown` renders as "unknown", never as an
        // error the user cannot act on.
        voices = await client?.voiceCatalog() ?? .unknown
    }

    private func selectVoice(_ option: TTSVoiceOption) async {
        guard let client, let path = voices.voiceKeyPath else { return }
        busy = true
        defer { busy = false }
        let previous = voices.currentVoice
        voices.currentVoice = option.id
        do {
            try await client.setGatewayConfigValue(path: path, value: .string(option.id))
            isPickingVoice = false
            note(copy.settingsVoiceSaved(theme.id, voice: option.name), warning: false)
        } catch let error as GatewayError {
            voices.currentVoice = previous
            note(error.message, warning: true)
        } catch {
            voices.currentVoice = previous
            note(error.localizedDescription, warning: true)
        }
    }

    private func setHostVoice(_ enabled: Bool) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            host = try await client.setHostVoiceMode(enabled: enabled)
        } catch let error as GatewayError {
            note(error.message, warning: true)
        } catch {
            note(error.localizedDescription, warning: true)
        }
    }

    /// `voice.toggle tts` has no explicit set form upstream — it flips whatever
    /// the host currently has — so this only fires when the reported state
    /// actually differs from what was asked for.
    private func setHostTTS(_ wanted: Bool) async {
        guard let client, hostTTS != wanted else { return }
        busy = true
        defer { busy = false }
        do {
            host = try await client.toggleHostTTS()
        } catch let error as GatewayError {
            note(error.message, warning: true)
        } catch {
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

    func settingsTTSProviderSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Change the provider on desktop — each one brings its own settings."
        case .control: "tts.provider — 10 OPTIONS, EACH WITH ITS OWN FIELD SET. DESKTOP."
        case .ink: "Which throat is used is decided at the desk."
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
        case .soft: "This provider’s voice list isn’t published by the gateway — pick one on desktop."
        case .control: "NO VOICE CATALOG OVER THE API FOR THIS PROVIDER."
        case .ink: "This provider names no voices aloud. Choose at the desk."
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

import SwiftUI
import TalariaKit
import TalariaTheme

// Voice — the full-screen overlay reached from the chat composer's mic.
// Two counter-rotating rings (solid + dashed; ink adds astrolabe crosshairs)
// around a breathing bot-avatar orb, a 12-bar waveform, the spoken line, and
// hush / write side buttons around the red end button.
// Ported from Talaria.dc.html `data-screen-label="Voice"`.
//
// Live mode runs a real conversation on this device: AVAudioRecorder captures
// until voice activity stops, the clip goes to POST /api/audio/transcribe, the
// transcript is submitted as an ordinary prompt, and the reply comes back from
// POST /api/audio/speak and plays through AVAudioPlayer — then it listens
// again. The waveform is the microphone (and, while the bot talks, the player's
// own meter), not a timer. Demo mode keeps the canned copy and the scripted
// animation and never touches the microphone.
//
// The gateway's own `voice.*` events still route through `attachVoiceRouter()`:
// they belong to a host-side listener, but a stop phrase or a barge-in spoken
// there must end this turn too.

public struct VoiceView: View {
    private let model: AppModel
    private let botID: String
    @Binding private var isPresented: Bool

    @State private var session = VoiceSession()

    public init(model: AppModel, botID: String, isPresented: Binding<Bool>) {
        self.model = model
        self.botID = botID
        self._isPresented = isPresented
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var bot: Bot? { model.bot(botID) }

    /// The 12 bars' full-cycle durations + stagger, lifted from the prototype.
    private static let waveDurations: [Double] = [0.9, 1.4, 0.7, 1.1, 1.6, 0.8,
                                                  1.2, 0.6, 1.5, 1.0, 1.3, 0.75]

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 40)
                ringStage
                    .padding(.top, 42)
                waveform
                    .padding(.top, 36)
                quote
                    .padding(.top, 28)
                    .padding(.horizontal, 44)
                Spacer(minLength: 12)
                if session.showsSpeakToggle { speakToggle.padding(.bottom, 18) }
                controls
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { session.begin(model: model, botID: botID) }
        .onDisappear { session.end() }
        // A stop phrase heard by a host-side listener ends the turn here too.
        .onChange(of: model.voice.stopPhrases) { _, _ in dismissToChat() }
        // Barge-in: the host says the user spoke over the reply — cut playback.
        .onChange(of: model.voice.interruptions) { _, _ in session.interrupt() }
    }

    // MARK: Background (the voiceBgCss token, derived from pack colors)

    @ViewBuilder
    private var background: some View {
        switch theme.id {
        case .soft:
            // linear 180deg: warm paper fading into lavender.
            theme.bg.overlay(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0),
                            .init(color: theme.accent.opacity(0.10), location: 0.55),
                            .init(color: theme.accent.opacity(0.20), location: 1)],
                    startPoint: .top, endPoint: .bottom))
        case .control:
            // radial phosphor bloom behind the orb (circle at 50% 38%).
            theme.bg.overlay(
                RadialGradient(colors: [theme.accent.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.5, y: 0.38),
                               startRadius: 0, endRadius: 320))
        case .ink:
            theme.bg
        }
    }

    // MARK: Header

    private var header: some View {
        Text(verbatim: "\(copy.voiceHead) \(plainUpper(botID))")
            .font(headFont)
            .tracking(theme.id == .soft ? 0 : 2.5)
            .foregroundStyle(headColor)
            .lineLimit(1)
    }

    private var headFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var headColor: Color {
        switch theme.id {
        case .soft: theme.ink.opacity(0.5)
        case .control: theme.accent
        case .ink: theme.ink.opacity(0.55)
        }
    }

    // MARK: Ring stage — 234pt: rings, orb, crosshairs, avatar

    private var ringStage: some View {
        ZStack {
            // Outer solid ring, 9s clockwise; control tips it with a bright arc.
            ZStack {
                Circle().strokeBorder(theme.voiceRing1, lineWidth: 1)
                Circle()
                    .trim(from: 0.62, to: 0.88)
                    .stroke(theme.voiceRing1Top, lineWidth: 1)
                    .padding(0.5)
            }
            .frame(width: 234, height: 234)
            .modifier(Spinning(duration: 9))

            // Inner dashed ring, 13s counter-clockwise.
            Circle()
                .strokeBorder(theme.voiceRing2, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .frame(width: 194, height: 194)
                .modifier(Spinning(duration: 13, reverse: true))

            // Breathing orb glow (soft/control; ink keeps the plate bare). Live
            // audio swells it past the idle breath so the orb reads as level.
            if let orbStops = theme.voiceOrb {
                Circle()
                    .fill(RadialGradient(colors: [orbStops.center, orbStops.edge],
                                         center: UnitPoint(x: 0.37, y: 0.31),
                                         startRadius: 0, endRadius: 105))
                    .frame(width: 150, height: 150)
                    .modifier(Breathing())
                    .scaleEffect(1 + session.level * 0.16)
                    .animation(.easeOut(duration: 0.12), value: session.level)
            }

            // Ink's astrolabe crosshairs, over the rings, under the face.
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(width: 250, height: 1)
                Rectangle().fill(theme.line).frame(width: 1, height: 250)
            }

            AvatarView(shape: bot?.shape ?? .circle, hue: bot?.hue ?? .teal,
                       size: 90, isWorking: true, theme: theme)
                .modifier(Breathing())
        }
        .frame(width: 234, height: 234)
        .contentShape(Circle())
        // Tapping the orb while the bot talks is the local barge-in.
        .onTapGesture { session.interrupt() }
        .accessibilityLabel(Text(session.stateLabel(copy, theme.id)))
    }

    // MARK: Waveform

    @ViewBuilder
    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            if session.showsMeteredWave {
                // Live mode: the rolling level history, oldest → newest.
                ForEach(Array(session.levels.enumerated()), id: \.offset) { index, level in
                    MeteredBar(color: theme.voiceWave,
                               glow: theme.voiceWaveGlow,
                               cornerRadius: theme.voiceBarRadius,
                               level: level * Self.barWeight(index))
                }
            } else {
                // Demo copy, and the "busy" phases where no audio is flowing.
                ForEach(Array(Self.waveDurations.enumerated()), id: \.offset) { index, duration in
                    WaveBar(color: theme.voiceWave,
                            glow: theme.voiceWaveGlow,
                            cornerRadius: theme.voiceBarRadius,
                            duration: duration,
                            delay: Double(index) * 0.09,
                            idle: !session.showsAnimatedWave || session.isMuted)
                }
            }
        }
        .frame(height: 33)
        .accessibilityHidden(true)
    }

    /// Taper the ends so a flat level still reads as a waveform, not a fence.
    private static func barWeight(_ index: Int) -> Double {
        let center = Double(AudioRecorder.barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 1 - distance * 0.35
    }

    // MARK: Quote

    private var quote: some View {
        Text(quoteText)
            .font(quoteFont)
            .italic(theme.id == .ink)
            .lineSpacing(theme.id == .control ? 4.5 : 4)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.id == .control ? theme.ink.opacity(0.9) : theme.ink)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: quoteText)
    }

    /// Demo: the canned themed quote. Live: what was just said or answered,
    /// falling back to the state line (and to a host-side voice.status when the
    /// gateway is driving its own listener).
    private var quoteText: String {
        if model.mode == .demo { return copy.voiceQuote }
        if let line = session.line, !line.isEmpty { return line }
        if let hostState = model.voice.hostState, !hostState.isEmpty { return hostState }
        return session.stateLabel(copy, theme.id)
    }

    private var quoteFont: Font {
        switch theme.id {
        case .soft: theme.body(16, weight: .medium)
        case .control: theme.body(15)
        case .ink: theme.body(18)
        }
    }

    // MARK: Auto-TTS toggle (desktop's voice.auto_tts)

    private var speakToggle: some View {
        Button {
            model.voice.autoSpeak.toggle()
            if !model.voice.autoSpeak { session.interrupt() }
        } label: {
            Text(model.voice.autoSpeak ? copy.voiceSpeakOn(theme.id) : copy.voiceSpeakOff(theme.id))
                .font(theme.id == .control ? theme.mono(9, weight: .bold) : theme.body(11, weight: .semibold))
                .tracking(theme.id == .soft ? 0 : 1)
                .foregroundStyle(model.voice.autoSpeak ? theme.accent : theme.ink.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 20 : 6, style: .continuous)
                        .strokeBorder(model.voice.autoSpeak
                                      ? theme.accent.opacity(0.5) : theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.voice.autoSpeak ? [.isSelected] : [])
    }

    // MARK: Controls — mute · end · text

    private var controls: some View {
        HStack(spacing: 15) {
            if session.showsMute {
                sideButton(copy.mute, active: session.isMuted) {
                    session.toggleMute()
                }
            }
            endButton
            sideButton(copy.textBtn) {
                dismissToChat()
            }
        }
    }

    private var endButton: some View {
        Button(action: dismissToChat) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.voiceEndGlyph)
                .frame(width: 19, height: 19)
                .frame(width: 63, height: 63)
                .background(theme.danger)
                .clipShape(RoundedRectangle(cornerRadius: theme.id == .control ? 12 : 31.5,
                                            style: .continuous))
                .shadow(color: theme.danger.opacity(theme.id == .control ? 0.45 : 0.38),
                        radius: theme.id == .control ? 13 : 11,
                        y: theme.id == .control ? 0 : 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copy.cancel))
    }

    private func sideButton(_ label: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(sideLabel(label))
                .font(sideFont)
                .tracking(theme.id == .control ? 1 : 0)
                .foregroundStyle(active ? theme.accent : sideColor)
                .frame(width: 52, height: 52)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(sideShape)
                .overlay(sideShape.strokeBorder(
                    active ? theme.accent.opacity(0.6) : sideBorder, lineWidth: 1))
                .contentShape(sideShape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// Ink renders its lowercase verbs in small caps via the font; soft and
    /// control ship their labels pre-cased in the copy pack.
    private func sideLabel(_ label: String) -> String { label }

    private var sideShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 10 : 26, style: .continuous)
    }

    private var sideFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .heavy)
        case .control: theme.mono(9, weight: .bold)
        case .ink: theme.body(12, weight: .bold).smallCaps()
        }
    }

    private var sideColor: Color {
        theme.ink.opacity(theme.id == .ink ? 0.6 : 0.55)
    }

    private var sideBorder: Color {
        switch theme.id {
        case .soft: theme.line
        case .control: theme.lineStrong.opacity(0.8)
        case .ink: theme.lineStrong
        }
    }

    // MARK: Routing

    private func dismissToChat() {
        session.end()
        isPresented = false
    }

    private func plainUpper(_ id: String) -> String {
        (id.prefix(1).uppercased() + id.dropFirst()).uppercased()
    }
}

// MARK: - The voice conversation

/// Drives one voice conversation: capability probe → mic permission → listen →
/// transcribe → prompt → speak → listen again, until the user ends it.
///
/// Every await is inside one cancellable task, so dismissing the overlay (or
/// muting) unwinds the loop at whatever step it reached; the recorder and the
/// player are torn down in `end()` rather than by each step.
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case starting
        /// Demo mode: canned copy, scripted animation, no microphone.
        case demo
        case listening, transcribing, thinking, speaking, muted
        /// The user refused the microphone.
        case denied
        /// The gateway has no transcription provider.
        case unavailable
        /// No microphone on this platform (the macOS build).
        case unsupported
        /// The microphone would not start.
        case captureFailed(RecorderFailure?)
        /// The gateway refused a step of the loop; carries its own message.
        case gatewayFailed(String)
    }

    private(set) var phase: Phase = .starting
    /// The rolling line under the orb: what you said, then what came back.
    private(set) var line: String?
    private(set) var isMuted = false

    let recorder = AudioRecorder()
    let player = VoicePlayer()

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var segment: CheckedContinuation<SegmentEnd?, Never>?
    @ObservationIgnored private var started = false

    // MARK: Lifecycle

    func begin(model: AppModel, botID: String) {
        guard !started else { return }
        started = true
        line = nil
        isMuted = false

        guard model.mode == .live else {
            phase = .demo
            return
        }
        model.attachVoiceRouter()
        model.voice.resetConversation()
        loop = Task { [weak self] in
            await self?.run(model: model, botID: botID)
        }
    }

    func end() {
        loop?.cancel()
        loop = nil
        finishSegment(nil)
        recorder.cancel()
        player.stop()
        VoiceAudioSession.deactivate()
        started = false
        phase = .starting
        line = nil
    }

    /// Barge-in / skip: stop the reply mid-sentence and go back to listening.
    func interrupt() {
        guard phase == .speaking else { return }
        player.stop()
    }

    func toggleMute() {
        isMuted.toggle()
        // Demo has no microphone to mute — it only pins the waveform, as the
        // prototype did.
        guard phase != .demo else { return }
        if isMuted {
            // Mute stops *this device's* capture. It deliberately does not
            // touch `voice.toggle`, which would mute the gateway host instead.
            recorder.cancel()
            player.stop()
            finishSegment(nil)
            phase = .muted
        }
        // Unmuting is picked up by the loop, which returns to .listening.
    }

    // MARK: State for the view

    /// Current 0…1 level, from whichever side of the conversation is audible.
    var level: Double {
        switch phase {
        case .listening: recorder.level
        case .speaking: player.level
        default: 0
        }
    }

    var levels: [Double] {
        switch phase {
        case .listening: recorder.levels
        case .speaking: player.levels
        default: Array(repeating: 0, count: AudioRecorder.barCount)
        }
    }

    /// Metered bars while audio flows either way.
    var showsMeteredWave: Bool {
        phase == .listening || phase == .speaking
    }

    /// The scripted animation stands in for "busy but silent".
    var showsAnimatedWave: Bool {
        phase == .demo || phase == .starting || phase == .transcribing || phase == .thinking
    }

    /// Nothing to mute once the conversation cannot run.
    var showsMute: Bool {
        switch phase {
        case .denied, .unavailable, .unsupported, .captureFailed, .gatewayFailed: false
        default: true
        }
    }

    var showsSpeakToggle: Bool {
        switch phase {
        case .demo, .denied, .unavailable, .unsupported, .captureFailed, .gatewayFailed: false
        default: true
        }
    }

    func stateLabel(_ copy: CopyPack, _ theme: ThemeID) -> String {
        switch phase {
        case .starting: copy.voiceConnecting(theme)
        case .demo: copy.voiceQuote
        case .listening: copy.voiceListening(theme)
        case .transcribing: copy.voiceTranscribing(theme)
        case .thinking: copy.voiceThinking(theme)
        case .speaking: copy.voiceSpeaking(theme)
        case .muted: copy.voiceMuted(theme)
        case .denied: copy.voiceMicDenied(theme)
        case .unavailable: copy.voiceNoTranscription(theme)
        case .unsupported: copy.voiceNeedsPhone(theme)
        case .captureFailed(let failure):
            if case .engine(let detail)? = failure { detail } else { copy.voiceMicBusy(theme) }
        case .gatewayFailed(let message): message
        }
    }

    // MARK: The loop

    private func run(model: AppModel, botID: String) async {
        phase = .starting
        // Probe first: a gateway with no STT provider can never hear us, and
        // asking for the microphone before saying so would be rude.
        let capabilities = await model.refreshVoiceCapabilities()
        guard !Task.isCancelled else { return }
        guard capabilities.canTranscribe else {
            phase = .unavailable
            return
        }
        guard recorder.isSupported else {
            phase = .unsupported
            return
        }
        guard await recorder.ensurePermission() == .granted else {
            phase = .denied
            return
        }

        while !Task.isCancelled {
            while isMuted, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            guard await listenAndAnswer(model: model, botID: botID) else { return }
        }
    }

    /// One turn. Returns false when the conversation should stop entirely.
    private func listenAndAnswer(model: AppModel, botID: String) async -> Bool {
        phase = .listening
        recorder.start()
        guard recorder.isRecording else {
            phase = .captureFailed(recorder.failure)
            return false
        }

        let ending = await awaitSegment()
        guard !Task.isCancelled else { return false }
        guard let ending else {
            recorder.cancel()
            return true                       // muted or dismissed mid-listen
        }
        guard ending != .silence, let clip = recorder.stop() else {
            // Room tone only — drop it and listen again rather than burning a
            // provider call on silence.
            recorder.cancel()
            return true
        }

        phase = .transcribing
        let heard: String
        do {
            heard = try await model.transcribe(clip, for: botID)
        } catch let error as GatewayError {
            phase = .gatewayFailed(error.message)
            return false
        } catch {
            phase = .gatewayFailed(error.localizedDescription)
            return false
        }
        guard !Task.isCancelled else { return false }
        // Upstream returns an empty transcript for "no speech detected".
        guard !heard.isEmpty else { return true }

        line = heard
        phase = .thinking
        let reply = await model.submitVoicePrompt(heard, to: botID)
        guard !Task.isCancelled else { return false }
        guard let reply, !reply.isEmpty else { return true }
        line = reply

        if model.voice.autoSpeak, !isMuted {
            if let audio = await model.synthesizeReply(reply, for: botID) {
                guard !Task.isCancelled else { return false }
                phase = .speaking
                await player.play(audio)
            } else if let failure = model.voice.speechFailure {
                // No TTS provider: say so once, keep the conversation going in
                // text — the transcript line still updates.
                model.voice.autoSpeak = false
                line = failure
            }
        }
        return !Task.isCancelled
    }

    /// Await the recorder's voice-activity verdict; nil when the wait was cut
    /// short (mute, dismissal).
    private func awaitSegment() async -> SegmentEnd? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SegmentEnd?, Never>) in
            segment = continuation
            recorder.onSegmentEnd = { [weak self] ending in
                self?.finishSegment(ending)
            }
        }
    }

    private func finishSegment(_ ending: SegmentEnd?) {
        guard let continuation = segment else { return }
        segment = nil
        recorder.onSegmentEnd = nil
        continuation.resume(returning: ending)
    }
}

// MARK: - Voice copy (three voices, same states)

/// The prototype's copy pack predates on-device voice, so the conversation
/// states carry their own strings — same three voices as everything else.
public extension CopyPack {
    func voiceConnecting(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Opening the mic…"
        case .control: "OPENING VOICE LINK…"
        case .ink: "the audience is being prepared…"
        }
    }

    func voiceListening(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Listening…"
        case .control: "LISTENING — SPEAK"
        case .ink: "it attends. speak."
        }
    }

    func voiceTranscribing(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Getting that down…"
        case .control: "TRANSCRIBING"
        case .ink: "your words are being set down…"
        }
    }

    func voiceThinking(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Thinking…"
        case .control: "WORKING"
        case .ink: "it considers…"
        }
    }

    func voiceSpeaking(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Speaking — tap the orb to cut in"
        case .control: "PLAYBACK — TAP ORB TO CUT"
        case .ink: "it answers — touch the orb to stay it"
        }
    }

    func voiceMuted(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Muted — tap MUTE to speak again"
        case .control: "MIC MUTED"
        case .ink: "hushed — touch hush again to speak"
        }
    }

    func voiceMicDenied(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Microphone access is off. Turn it on in Settings › Talaria › Microphone."
        case .control: "MIC DENIED — ENABLE IN SETTINGS › TALARIA › MICROPHONE"
        case .ink: "the ear is stopped. grant it in Settings › Talaria › Microphone."
        }
    }

    func voiceNoTranscription(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "This gateway has no transcription provider, so it cannot hear you. Set one up in Hermes settings → Voice."
        case .control: "NO STT PROVIDER ON THIS GATEWAY — CONFIGURE HERMES VOICE"
        case .ink: "no scribe attends this gateway. appoint one in its voice settings."
        }
    }

    func voiceMicBusy(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Something else is using the microphone. Close it and try again."
        case .control: "MIC HELD BY ANOTHER APP"
        case .ink: "another hand holds the ear. release it and return."
        }
    }

    func voiceNeedsPhone(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Voice needs a device with a microphone."
        case .control: "NO CAPTURE DEVICE"
        case .ink: "this vessel has no ear"
        }
    }

    func voiceSpeakOn(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Replies spoken"
        case .control: "REPLIES SPOKEN"
        case .ink: "it speaks aloud"
        }
    }

    func voiceSpeakOff(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Replies silent"
        case .control: "REPLIES SILENT"
        case .ink: "it answers in silence"
        }
    }
}

// MARK: - Motion (ringU / breatheU / waveU keyframes)

/// Continuous rotation; `reverse` spins counter-clockwise.
private struct Spinning: ViewModifier {
    let duration: Double
    var reverse: Bool = false
    @State private var spinning = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spinning ? (reverse ? -360 : 360) : 0))
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// The 3.2s scale(1 → 1.07) breathing cycle shared by orb and face.
private struct Breathing: ViewModifier {
    @State private var swollen = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(swollen ? 1.07 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    swollen = true
                }
            }
    }
}

/// One 4×29 waveform bar: scaleY .22 ↔ 1 on its own staggered clock; muting
/// pins every bar low. Used for demo copy and the silent "busy" phases.
private struct WaveBar: View {
    let color: Color
    let glow: Color?
    let cornerRadius: CGFloat
    let duration: Double
    let delay: Double
    let idle: Bool

    @State private var tall = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: 4, height: 29)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 4)
            .scaleEffect(y: (tall && !idle) ? 1 : 0.22, anchor: .center)
            .animation(.easeOut(duration: 0.2), value: idle)
            .onAppear {
                withAnimation(.easeInOut(duration: duration / 2)
                    .repeatForever(autoreverses: true)
                    .delay(delay)) {
                    tall = true
                }
            }
    }
}

/// The same bar, driven by a measured 0…1 level instead of a clock.
private struct MeteredBar: View {
    let color: Color
    let glow: Color?
    let cornerRadius: CGFloat
    let level: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: 4, height: 29)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 4)
            .scaleEffect(y: max(0.22, min(1, 0.22 + level * 0.78)), anchor: .center)
            .animation(.easeOut(duration: 0.09), value: level)
    }
}

// MARK: - Voice tokens (ring1/ring1Top/ring2/orbFill/waveC/… derived per pack)

private extension ThemePack {
    /// Outer solid ring stroke.
    var voiceRing1: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent.opacity(0.30)
        case .ink: ink.opacity(0.40)
        }
    }

    /// The brighter top arc of the outer ring (soft blends it away).
    var voiceRing1Top: Color {
        switch id {
        case .soft: accent.opacity(0.35)
        case .control: accent
        case .ink: ink
        }
    }

    /// Inner dashed ring stroke.
    var voiceRing2: Color {
        switch id {
        case .soft: accent.opacity(0.30)
        case .control: accent.opacity(0.25)
        case .ink: ink.opacity(0.35)
        }
    }

    /// Radial orb fill stops; nil = no orb (ink's bare astrolabe).
    var voiceOrb: (center: Color, edge: Color)? {
        switch id {
        case .soft: (color(for: .violet).opacity(0.50), accent.opacity(0.15))
        case .control: (accent.opacity(0.32), accent.opacity(0.04))
        case .ink: nil
        }
    }

    /// Waveform bar color (waveC).
    var voiceWave: Color {
        id == .ink ? ink : accent
    }

    /// Phosphor bloom behind the bars — control only (waveGlow).
    var voiceWaveGlow: Color? {
        id == .control ? accent.opacity(0.5) : nil
    }

    /// Bar end radius follows the theme's dot language (dotR).
    var voiceBarRadius: CGFloat {
        id == .control ? 1 : 2
    }

    /// The 19pt square inside the red end button (voiceEndGlyph).
    var voiceEndGlyph: Color {
        id == .soft ? panel : bg
    }
}

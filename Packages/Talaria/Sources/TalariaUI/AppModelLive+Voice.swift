import Foundation
import Observation
import TalariaKit

// Live-mode voice: the model-side half of the phone's voice loop.
//
// The loop itself is client-side (record here → /api/audio/transcribe →
// prompt.submit → /api/audio/speak → play here), so this file's job is the glue
// the view cannot own: the capability probe, the two REST hops scoped to the
// bot's profile, waiting out a turn, and a router for the gateway's own voice
// events. Those events (`voice.transcript`, `voice.status`, `voice.interrupted`)
// only fire when the *gateway host* is running voice mode; Talaria still honors
// them — a stop phrase spoken into a desk machine should end the phone's turn
// too, and `voice.interrupted` is a real barge-in signal.
//
// Wake word is deliberately absent: `wake.start {client_capture:true}` expects a
// continuous PCM feed over `wake.feed`, which iOS cannot sustain outside the
// foreground. `wake.detected` from a host-side listener is routed anyway (it is
// free), so a shell can present voice on it.
//
// Verified wire shapes (hermes-agent-upstream, re-checked this pass):
//   voice.toggle {action:"status"} → {enabled, record_key, tts, available,
//     audio_available, stt_available, details}   tui_gateway/server.py:14757-14782
//   voice.tts {text} → {status:"speaking"}; 4020 without text
//                                              tui_gateway/server.py:15008-15021
//   voice.record {action, session_id} — NOT used here: it drives the gateway
//     HOST's microphone and errors 4015 ("voice mode is off") unless
//     voice.toggle on flipped HERMES_VOICE on that machine
//                                              tui_gateway/server.py:14854-14882
//   POST /api/audio/transcribe {data_url, mime_type} [?profile=]
//     → {ok, transcript, provider}              hermes_cli/web_server.py:4891-4979
//   POST /api/audio/speak {text} [?profile=]
//     → {ok, data_url, mime_type, provider}     hermes_cli/web_server.py:5098-5171
//   voice.transcript payload keys are {text} | {stop_phrase, text} |
//     {no_speech_limit} — the last one reports that the HOST's own 3-strikes
//     silence detector gave up (server.py:14933-14947). It is deliberately not
//     routed: Talaria's loop runs on this device and its own VAD already
//     decides when to re-listen, so honoring a host timeout would end a phone
//     conversation for something that happened on a desk machine.

/// Shared voice state. `AppModel`'s stored properties live in a file another
/// owner holds, and extensions cannot add storage — same pattern as
/// `LiveRuntime`. One voice conversation runs at a time.
@MainActor
@Observable
public final class VoiceRuntime {
    public static let shared = VoiceRuntime()

    /// UserDefaults key for the auto-speak preference (desktop: voice.auto_tts).
    public static let autoSpeakKey = "talaria-voice-autospeak"

    /// Latest `voice.transcript` text from a host-side listener.
    public private(set) var hostTranscript: String?
    /// Latest `voice.status` state ("listening", "thinking", …).
    public private(set) var hostState: String?
    /// Bumped by `voice.interrupted` — barge-in; playback should stop.
    public private(set) var interruptions = 0
    /// Bumped by `voice.transcript {stop_phrase:true}` — end voice mode.
    public private(set) var stopPhrases = 0
    /// Bumped by `wake.detected`; a shell may present voice on it.
    public private(set) var wakeDetections = 0

    /// Last probe of `voice.toggle {action:"status"}`.
    public internal(set) var capabilities: VoiceCapabilities = .unknown
    /// Set when synthesis failed, so the UI can say so once and stop trying.
    public internal(set) var speechFailure: String?

    /// Speak replies aloud (desktop's auto-TTS toggle).
    public var autoSpeak: Bool {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: Self.autoSpeakKey) }
    }

    @ObservationIgnored var handlerID: UUID?
    /// The link the handler is registered on. A reconnect builds a new client,
    /// and a handler registered on the dead one would silently stop delivering.
    @ObservationIgnored weak var handlerClient: GatewayClient?
    @ObservationIgnored var attaching = false

    private init() {
        autoSpeak = UserDefaults.standard.object(forKey: Self.autoSpeakKey) as? Bool ?? true
    }

    /// Clear per-conversation state (not the capability cache, which is a
    /// property of the gateway rather than of one turn).
    public func resetConversation() {
        hostTranscript = nil
        hostState = nil
        speechFailure = nil
    }

    func handle(_ event: GatewayEvent) {
        switch TypedGatewayEvent(event) {
        case .voiceTranscript(let text, let stopPhrase):
            if let text, !text.isEmpty { hostTranscript = text }
            if stopPhrase { stopPhrases += 1 }
        case .voiceStatus(let state):
            hostState = state.isEmpty ? nil : state
        case .other(let raw) where raw.type == "voice.interrupted":
            interruptions += 1
        case .other(let raw) where raw.type == "wake.detected":
            wakeDetections += 1
        default:
            break
        }
    }
}

/// Whether the phone can reach its gateway right now, from voice's point of
/// view.
///
/// Voice is the surface where being wrong about this is loudest: every other
/// screen degrades to stale-but-readable, while voice keeps the microphone hot
/// and the orb breathing over a socket that is gone. The distinction that
/// matters to the conversation is not "connected / not connected" but "will it
/// come back on its own?" — one state parks and resumes, the other has to say
/// so and stop.
public enum VoiceLinkState: Sendable, Equatable {
    /// Socket up — or demo mode, which has no socket to lose.
    case up
    /// Dropped. AppModelLive's backoff loop, or ConnectionSupervisor, is
    /// dialing; the conversation parks and picks up where it left off.
    case reconnecting
    /// Not coming back without the user: the refresh token was rejected (the
    /// reconnect loop stops dead on `AuthError.sessionExpired`) or the gateway
    /// was disconnected on purpose.
    case needsSignIn
}

extension AppModel {

    /// Shared voice state, for views.
    public var voice: VoiceRuntime { VoiceRuntime.shared }

    // MARK: - Liveness

    /// Live-link state as the voice loop needs to see it. Observable: reading
    /// it from a view body (or an `onChange`) subscribes to `isOffline`,
    /// `client` and the supervisor's re-auth flag.
    public var voiceLink: VoiceLinkState {
        guard mode == .live else { return .up }
        // A torn-down link (Settings → Disconnect) leaves mode == .live with no
        // client; nothing is dialing for it.
        guard client != nil else { return .needsSignIn }
        guard isOffline else { return .up }
        // `needsReauth` can name a *different* saved gateway — one tapped in
        // Connections while signed out. Only the live one means nobody is
        // dialing on our behalf.
        if let stalled = needsReauth, let live = LiveRuntime.shared.baseURL,
           stalled.absoluteString == live.absoluteString {
            return .needsSignIn
        }
        return .reconnecting
    }

    // MARK: - Event router

    /// Subscribe to the gateway's voice events. Idempotent; safe in demo mode
    /// (no gateway, nothing to route). The main event pump in AppModelLive
    /// ignores `voice.*`, so voice keeps its own handler and its own lifetime.
    public func attachVoiceRouter() {
        let runtime = VoiceRuntime.shared
        guard mode == .live, let client, !runtime.attaching else { return }
        // Already listening on *this* client. A socket-level reconnect re-dials
        // the same GatewayClient and its handler table survives the new
        // transport (GatewayClient.connect rebuilds only `eventsTask`, which
        // reads the live table), so nothing needs re-registering there. A new
        // gateway builds a new client, and that stale record is dropped here.
        if runtime.handlerID != nil, runtime.handlerClient === client { return }
        runtime.handlerID = nil
        runtime.handlerClient = nil
        runtime.attaching = true
        Task { @MainActor in
            let id = await client.addEventHandler { event in
                Task { @MainActor in VoiceRuntime.shared.handle(event) }
            }
            runtime.attaching = false
            // The link was replaced while the registration was in flight.
            guard self.client === client else {
                await client.removeEventHandler(id)
                return
            }
            runtime.handlerID = id
            runtime.handlerClient = client
            // Probe once per link while we are here: the composer's mic has to
            // know whether this gateway can hear at all *before* it is tapped.
            await self.refreshVoiceCapabilities()
        }
    }

    public func detachVoiceRouter() {
        let runtime = VoiceRuntime.shared
        let client = runtime.handlerClient
        // A capability set belongs to one gateway; carrying it across a
        // disconnect would gate the mic on a machine we are no longer talking to.
        runtime.capabilities = .unknown
        guard let id = runtime.handlerID, let client else {
            runtime.handlerID = nil
            runtime.handlerClient = nil
            return
        }
        runtime.handlerID = nil
        runtime.handlerClient = nil
        Task { await client.removeEventHandler(id) }
    }

    // MARK: - Capabilities

    /// Probe what this gateway can actually do. Demo mode reports a fully
    /// capable pretend gateway so the overlay demonstrates itself.
    @discardableResult
    public func refreshVoiceCapabilities() async -> VoiceCapabilities {
        guard mode == .live, let client else {
            VoiceRuntime.shared.capabilities = .unknown
            return .unknown
        }
        let caps = await client.voiceCapabilities()
        VoiceRuntime.shared.capabilities = caps
        return caps
    }

    /// Whether the mic affordance should be offered at all. Demo mode always
    /// shows it; live mode hides it only when a gateway told us it has no
    /// transcription provider.
    public var voiceIsAvailable: Bool {
        guard mode == .live else { return true }
        return VoiceRuntime.shared.capabilities.canTranscribe
    }

    // MARK: - Speech ⇄ text (profile-scoped, like desktop)

    /// POST the clip for transcription. An empty return means "no speech" —
    /// upstream reports that as success and expects a re-listen
    /// (web_server.py:4966-4975).
    public func transcribe(_ clip: RecordedClip, for botID: String) async throws -> String {
        guard mode == .live else { return "" }
        // Never answer "no speech" for "no gateway": the caller re-listens on
        // an empty transcript, so returning "" here spins the microphone
        // forever against a link that is gone.
        guard let client else {
            throw GatewayError(code: -3, message: "not connected")
        }
        return try await client.transcribeAudio(dataURL: clip.dataURL,
                                                mimeType: clip.mimeType,
                                                profile: botID)
    }

    /// Synthesize a reply. Returns nil (and latches a reason) when the gateway
    /// has no TTS provider configured — the conversation continues silently
    /// rather than dying on a missing optional dependency.
    public func synthesizeReply(_ text: String, for botID: String) async -> Data? {
        guard mode == .live, let client, !text.isEmpty else { return nil }
        do {
            return try await client.synthesizeSpeech(text: text, profile: botID).data
        } catch let error as GatewayError {
            VoiceRuntime.shared.speechFailure = error.message
            return nil
        } catch {
            VoiceRuntime.shared.speechFailure = error.localizedDescription
            return nil
        }
    }

    // MARK: - One voice turn

    /// Submit a spoken prompt and wait out the reply. Returns the reply text,
    /// or nil if the turn produced nothing (interrupted, error, link lost).
    ///
    /// This deliberately takes the composer's own path rather than `send`.
    /// `sendOrSteer` is what raises `chat.isRunning` — which is what puts the
    /// stop control under the turn and lets the composer steer into it instead
    /// of interrupting it — what raises the tool-chip turn floor so tool chips
    /// land on this turn's bubble, what lets staged attachments ride the
    /// prompt, and what arms the submit watchdog. Calling `send` directly (as
    /// this did) produced a turn the rest of the app could not see: no stop
    /// button, no steering, tool chips attaching to the previous bubble.
    ///
    /// Demo mode passes through the same door. `sendOrSteer`'s demo branch runs
    /// its own cancellable turn (`ChatRuntime.demoTurns`) on the same
    /// 0.9–1.8 s clock as `AppModel.demoReply`, and it clears `isTyping`,
    /// `isRunning` and appends the reply in one synchronous MainActor block —
    /// so the sampler below can never observe "idle with no reply yet" and cut
    /// the pretend turn short.
    public func submitVoicePrompt(_ text: String, to botID: String) async -> String? {
        let chat = chat(for: botID)
        sendOrSteer(text: text, to: botID)
        // Floor read AFTER the send: both of sendOrSteer's live branches append
        // the user bubble, so the reply is the first row past this index.
        return await awaitReply(botID: botID, after: chat.messages.count)
    }

    /// Wait until the bot's turn settles and hand back its final text.
    ///
    /// There is no turn-completion callback in the model — `message.complete`
    /// lands in the shared event pump, which owns no voice state — so this
    /// samples the same observable state the transcript renders from. 5 Hz is
    /// far below the streaming rate and costs nothing next to a model turn.
    public func awaitReply(botID: String, after index: Int,
                           timeout: TimeInterval = 300) async -> String? {
        let chat = chat(for: botID)
        let start = Date()
        var sawTurn = false
        while Date().timeIntervalSince(start) < timeout {
            // A turn whose ending we cannot hear is not worth waiting on: with
            // the socket down there is no message.complete coming, and the
            // synthesis hop that would speak the answer cannot run either. The
            // caller parks on the link instead and resumes when it returns —
            // the reply itself is not lost, it arrives in the transcript when
            // session.resume replays the turn.
            guard voiceLink == .up else { return nil }

            let streaming = chat.messages.last?.isStreaming ?? false
            let busy = chat.isTyping || chat.isRunning || streaming
                || LiveRuntime.shared.workingBotIDs.contains(botID)
            if busy { sawTurn = true }

            if !busy, chat.messages.count > index, let last = chat.messages.last {
                // A system row (error, denial, the stop note) ends the turn
                // with no speech.
                return last.author == .bot ? last.text : nil
            }
            // The turn never started: the send failed, or the submit was
            // steered into a turn that had already finished.
            if !busy, !sawTurn, Date().timeIntervalSince(start) > 20 { return nil }

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return nil                    // cancelled — the overlay closed
            }
        }
        return nil
    }
}

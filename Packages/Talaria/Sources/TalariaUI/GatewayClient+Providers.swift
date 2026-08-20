import Foundation
import TalariaKit

// The wire behind Settings → Models & providers / Voice / Notifications.
//
// What separates this file from GatewayClient+Models.swift is SCOPE. That file
// speaks for one chat: every call carries a `session_id`, and the gateway
// records the answer as a per-session override. Settings speaks for the
// gateway's own defaults — `config.yaml` — so every call here deliberately
// omits `session_id` (or says `--global` / `scope: "global"`), and a control
// that cannot express that distinction is not offered at all.
//
// Verified upstream shapes (hermes-agent-upstream, re-read this pass — no
// shape here is guessed):
//
//   config.set key:"model"           tui_gateway/server.py:11829
//     With no matching session the handler runs `_apply_model_switch("",
//     {"agent": None}, value, …)` (server.py:11885). Whether that PERSISTS is
//     decided by `resolve_persist_behavior` (hermes_cli/model_switch.py:732),
//     which defaults to session-only — `model.persist_switch_by_default` is
//     False on a fresh install. So a "default model" control has to send the
//     `--global` flag inside `value`; the parser accepts flags in the raw
//     string (model_switch.py:849 parse_model_switch_args) and the answer's
//     `scope` then reads "global" (server.py:5041). Sending the bare id would
//     write nothing and silently lie.
//
//   config.set key:"reasoning"       tui_gateway/server.py:12199
//     Takes an explicit `scope` param: `if global_scope or session is None:
//     _write_config_key("agent.reasoning_effort", arg)` (server.py:12286).
//
//   config.get key:"reasoning"       tui_gateway/methods_config.py:220
//     → {value, display}. With no session_id it reports the config default.
//
//   GET  /api/config                 hermes_cli/web_server.py:6794
//   PUT  /api/config {config,profile} hermes_cli/web_server.py:7595
//     The PUT DEEP-MERGES over what is on disk (`_deep_merge`,
//     hermes_cli/config.py:2584) — whose docstring names
//     `tts.elevenlabs.voice_id` as exactly this case — so a patch may carry
//     one leaf without erasing its siblings.
//
//   GET /api/audio/elevenlabs/voices hermes_cli/web_server.py:5097
//     → {available, voices:[{voice_id, name, label}]}. A rejected key answers
//     HTTP 200 with {available:false, error:"unauthorized"} on purpose, so a
//     missing/expired key is a state to render, not an error to raise.
//
//   voice.toggle {action}            tui_gateway/server.py:14832
//     "status" | "on" | "off" | "tts". `tts` is a TOGGLE (no explicit value)
//     and errors 4014 unless voice mode is already on. All of it drives the
//     gateway HOST's own microphone/speakers — never this phone's.
//
//   POST /api/plugins/talaria-push/devices
//     app/relay/talaria-push/dashboard/plugin_api.py:125 — idempotent upsert
//     of {device_token, platform, environment, profile_filter}.
//     `profile_filter` is a per-BOT allow-list ([] = every bot); the relay
//     honors it in `DeviceStore.for_bot` (talaria_push_relay/devices.py:160).
//     There is no per-KIND device filter: kinds are gateway-wide
//     (`TALARIA_PUSH_EVENTS` → `/status.enabled_events`, plugin_api.py:181).

// MARK: - Typed payloads

/// One voice offered by the gateway's TTS provider.
public struct TTSVoiceOption: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// The provider's own richer label ("Adam — american, deep"), when given.
    public var label: String

    public init(id: String, name: String, label: String = "") {
        self.id = id; self.name = name; self.label = label.isEmpty ? name : label
    }

    init?(_ v: JSONValue) {
        guard let id = v["voice_id"]?.stringValue, !id.isEmpty else { return nil }
        let name = v["name"]?.stringValue ?? id
        self.init(id: id, name: name, label: v["label"]?.stringValue ?? name)
    }
}

/// What the gateway can offer a voice picker right now.
public struct TTSVoiceCatalog: Sendable, Equatable {
    /// The provider `tts.provider` resolves to ("edge", "elevenlabs", …).
    public var provider: String
    /// The voice id currently configured for that provider, if any.
    public var currentVoice: String
    /// Selectable voices. Empty when the provider keeps its list client-side
    /// (edge/openai/…) — the gateway exposes a live list for ElevenLabs only.
    public var voices: [TTSVoiceOption]
    /// The provider has a list but the credential was rejected.
    public var unauthorized: Bool
    /// The transcription provider, for display (`stt.provider`).
    public var sttProvider: String
    /// False until a gateway answered.
    public var probed: Bool

    public static let unknown = TTSVoiceCatalog(provider: "", currentVoice: "", voices: [],
                                                unauthorized: false, sttProvider: "",
                                                probed: false)

    public init(provider: String, currentVoice: String, voices: [TTSVoiceOption],
                unauthorized: Bool, sttProvider: String, probed: Bool) {
        self.provider = provider; self.currentVoice = currentVoice; self.voices = voices
        self.unauthorized = unauthorized; self.sttProvider = sttProvider; self.probed = probed
    }

    /// The config key holding this provider's voice, e.g.
    /// `tts.elevenlabs.voice_id`. Nil when we don't know the provider's shape,
    /// which is the signal to render the voice read-only rather than guess a
    /// key and write garbage into someone's config.yaml.
    public var voiceKeyPath: [String]? {
        switch provider {
        case "elevenlabs": ["tts", "elevenlabs", "voice_id"]
        case "edge": ["tts", "edge", "voice"]
        case "openai": ["tts", "openai", "voice"]
        case "gemini": ["tts", "gemini", "voice"]
        default: nil
        }
    }
}

/// Dynamic provider choices from GET /api/config/schema. Hermes merges built-
/// ins, command providers, plugin registrations, and the current profile value
/// on every request; keeping this server-driven prevents Talaria from freezing
/// a vendor list that immediately drifts.
public struct VoiceProviderOptions: Sendable, Equatable {
    public var tts: [String]
    public var stt: [String]

    public init(_ value: JSONValue) {
        let fields = value["fields"]
        tts = fields?["tts.provider"]?["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        stt = fields?["stt.provider"]?["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public static let empty = VoiceProviderOptions(.null)
}

/// The host-side voice mode reported by `voice.toggle`.
public struct HostVoiceState: Sendable, Equatable {
    /// HERMES_VOICE — the umbrella bit on the gateway machine.
    public var enabled: Bool
    /// HERMES_VOICE_TTS — the host speaks replies through its own speakers.
    public var tts: Bool

    public init(enabled: Bool, tts: Bool) {
        self.enabled = enabled; self.tts = tts
    }

    init(_ v: JSONValue) {
        enabled = v["enabled"]?.boolValue ?? false
        tts = v["tts"]?.boolValue ?? false
    }
}

/// The push relay's own report — what it can send, and what it is allowed to.
public struct PushRelayStatus: Sendable, Equatable {
    public var apnsConfigured: Bool
    /// APNs env vars the relay is still missing.
    public var missingEnv: [String]
    /// Master kill switch (`TALARIA_PUSH_DISABLED`).
    public var disabled: Bool
    /// Wire kinds this gateway will send: approval | long_task | mention |
    /// routine | gateway. Gateway-wide config, not a per-device choice.
    public var enabledEvents: [String]
    /// Minimum turn length before a "long task" push (seconds).
    public var longTaskMinSeconds: Int
    /// Handles the mention scanner watches for.
    public var mentionHandles: [String]
    public var deviceCount: Int

    init(_ v: JSONValue) {
        apnsConfigured = v["apns_configured"]?.boolValue ?? false
        missingEnv = v["apns_missing_env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        disabled = v["relay_disabled"]?.boolValue ?? false
        enabledEvents = v["enabled_events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        longTaskMinSeconds = v["long_task_min_s"]?.intValue ?? 0
        mentionHandles = v["mention_handles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        deviceCount = v["device_count"]?.intValue ?? v["devices"]?.intValue ?? 0
    }

    public func sends(_ kind: String) -> Bool {
        !disabled && enabledEvents.contains(kind)
    }
}

/// This device's row in the relay registry.
public struct PushDeviceRecord: Sendable, Equatable {
    public var tokenHex: String
    /// "dev" (APNs sandbox) | "prod".
    public var environment: String
    /// Stable Talaria saved-connection id echoed into this gateway's pushes.
    public var gatewayID: String?
    /// Bots allowed to push here. Empty = every bot.
    public var profileFilter: [String]

    public init(tokenHex: String, environment: String = "dev", gatewayID: String? = nil,
                profileFilter: [String] = []) {
        self.tokenHex = tokenHex; self.environment = environment
        self.gatewayID = gatewayID; self.profileFilter = profileFilter
    }

    init?(_ v: JSONValue) {
        guard let token = v["device_token"]?.stringValue, !token.isEmpty else { return nil }
        self.init(tokenHex: token,
                  environment: v["environment"]?.stringValue ?? "dev",
                  gatewayID: v["gateway_id"]?.stringValue,
                  profileFilter: v["profile_filter"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

// MARK: - RPCs

extension GatewayClient {

    // MARK: Gateway defaults (models)

    /// The catalog as the gateway's *defaults* see it: no `session_id`, so
    /// `model.options` answers from disk config rather than from a live agent's
    /// in-memory pin (methods_complete.py:469 → `_model_picker_context(None)`).
    ///
    /// The two flags are where a settings catalog has to differ from the chat
    /// picker's, and both are documented in `build_models_payload`
    /// (hermes_cli/inventory.py:114):
    ///   `explicit_only: false` — the chat picker hides ambient/auto-seeded
    ///     credentials; Settings is where you go to SEE what is configured, so
    ///     hiding one would be hiding the thing you came to fix.
    ///   `include_unconfigured: true` — appends the CANONICAL_PROVIDERS rows
    ///     nobody has authenticated yet. Without it a provider you have never
    ///     set up simply does not exist on this screen, and there is no way to
    ///     add its first key. Those rows carry no models, so they never widen
    ///     the model list — they only widen the provider list.
    ///
    /// The payload itself is decoded by `ModelCatalog` in
    /// GatewayClient+Models.swift; only the request differs.
    func defaultModelCatalog(refresh: Bool = false) async throws -> ModelCatalog {
        var params: [String: JSONValue] = ["explicit_only": .bool(false),
                                           "include_unconfigured": .bool(true)]
        if refresh { params["refresh"] = .bool(true) }
        // A refresh re-probes every saved custom endpoint; an offline local
        // server can sit on the socket well past the default ceiling.
        return ModelCatalog(try await rpc("model.options", .object(params),
                                          timeout: refresh ? 180 : 60))
    }

    /// Set the gateway's default model — `config.set key:"model"` with no
    /// session and an explicit `--global`, which is the only spelling that
    /// reaches `config.yaml` (see the file header). Same three answers as a
    /// session switch: `confirm_required` means NOTHING was applied.
    ///
    /// The provider is NOT optional in practice. `parse_model_switch_args`
    /// resolves a bare name *within the current aggregator first*
    /// (model_switch.py:713-716), so setting a self-hosted model while a
    /// subscription provider is active sends the gateway looking for it at the
    /// wrong endpoint — the symptom is a "could not reach this custom
    /// endpoint's model listing" warning naming the OTHER provider's URL.
    /// `--provider <slug>` is the documented spelling (model_switch.py:515).
    func applyDefaultModel(_ model: String, provider: String? = nil,
                           confirmExpensive: Bool = false) async throws -> ModelSwitchOutcome {
        let slug = (provider ?? "").trimmingCharacters(in: .whitespaces)
        let value = slug.isEmpty ? "\(model) --global"
                                 : "\(model) --provider \(slug) --global"
        var params: [String: JSONValue] = ["key": "model", "value": .string(value)]
        if confirmExpensive { params["confirm_expensive_model"] = .bool(true) }
        return ModelSwitchOutcome(try await rpc("config.set", .object(params), timeout: 180))
    }

    /// The gateway's default reasoning effort. "" is never returned — upstream
    /// resolves an unset key to "medium" and a YAML `false` to "none".
    func defaultReasoningEffort() async throws -> String {
        let result = try await rpc("config.get", ["key": "reasoning"], timeout: 20)
        return result["value"]?.stringValue ?? ModelLabels.defaultEffort
    }

    /// Persist the default reasoning effort to `agent.reasoning_effort`.
    @discardableResult
    func applyDefaultReasoningEffort(_ value: String) async throws -> String {
        let result = try await rpc("config.set", ["key": "reasoning",
                                                  "value": .string(value),
                                                  "scope": "global"], timeout: 30)
        return result["value"]?.stringValue ?? value
    }

    // MARK: Voice configuration

    /// Read the gateway's TTS/STT configuration and, when the provider offers
    /// a live list, its selectable voices. Never throws: every branch of a
    /// gateway that simply has no voice configured is a state to render.
    func voiceCatalog(profile: String? = nil) async -> TTSVoiceCatalog {
        guard let config = try? await restJSON(path: "api/config", query: profileQuery(profile),
                                               timeout: 20) else {
            return .unknown
        }
        let tts = config["tts"]
        let provider = tts?["provider"]?.stringValue ?? ""
        let stt = config["stt"]?["provider"]?.stringValue ?? ""

        var current = ""
        var voices: [TTSVoiceOption] = []
        var unauthorized = false

        switch provider {
        case "elevenlabs":
            current = tts?["elevenlabs"]?["voice_id"]?.stringValue ?? ""
            if let payload = try? await restJSON(path: "api/audio/elevenlabs/voices",
                                                 query: profileQuery(profile), timeout: 20) {
                voices = payload["voices"]?.arrayValue?.compactMap(TTSVoiceOption.init) ?? []
                // available:false with an `error` is a rejected key; without
                // one it just means no key is configured.
                unauthorized = (payload["available"]?.boolValue == false)
                    && (payload["error"]?.stringValue?.isEmpty == false)
            }
        case "edge":
            current = tts?["edge"]?["voice"]?.stringValue ?? ""
        case "openai":
            current = tts?["openai"]?["voice"]?.stringValue ?? ""
        case "gemini":
            current = tts?["gemini"]?["voice"]?.stringValue ?? ""
        default:
            break
        }

        return TTSVoiceCatalog(provider: provider, currentVoice: current, voices: voices,
                               unauthorized: unauthorized, sttProvider: stt, probed: true)
    }

    func voiceProviderOptions(profile: String? = nil) async -> VoiceProviderOptions {
        guard let schema = try? await restJSON(path: "api/config/schema",
                                               query: profileQuery(profile), timeout: 20) else {
            return .empty
        }
        return VoiceProviderOptions(schema)
    }

    /// Write one nested config leaf through `PUT /api/config`. The server
    /// deep-merges, so `["tts","elevenlabs","voice_id"]` rewrites that key and
    /// leaves `model_id` — and every other section — untouched.
    func setGatewayConfigValue(path: [String], value: JSONValue,
                               profile: String? = nil) async throws {
        guard let leaf = path.last else { return }
        var patch: JSONValue = .object([leaf: value])
        for key in path.dropLast().reversed() { patch = .object([key: patch]) }
        var body: [String: JSONValue] = ["config": patch]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        let receipt = try await restJSON(path: "api/config", method: "PUT",
                                         body: .object(body), timeout: 30)
        try GatewayOperationsPolicy.requireOKReceipt(
            receipt, operation: "Update gateway configuration")
    }

    /// `voice.toggle on|off` — the gateway HOST's voice mode. Runtime-only
    /// upstream (it writes `HERMES_VOICE` in the process env, not config), so
    /// it resets when the gateway restarts.
    @discardableResult
    func setHostVoiceMode(enabled: Bool) async throws -> HostVoiceState {
        HostVoiceState(try await rpc("voice.toggle",
                                     ["action": .string(enabled ? "on" : "off")], timeout: 20))
    }

    /// `voice.toggle tts` — flips host speech output. There is no explicit
    /// set form upstream, so the caller must only send this when the reported
    /// state differs from what the user asked for. Errors 4014 when host voice
    /// mode is off.
    @discardableResult
    func toggleHostTTS() async throws -> HostVoiceState {
        HostVoiceState(try await rpc("voice.toggle", ["action": "tts"], timeout: 20))
    }

    // MARK: Push relay

    /// Typed `/status`. nil when the relay plugin isn't installed — the
    /// surface hides rather than showing an error nobody can act on.
    func pushRelay() async -> PushRelayStatus? {
        await pushRelayStatus().map(PushRelayStatus.init)
    }

    /// This device's registration, or nil when it isn't registered.
    func pushDevice(tokenHex: String) async -> PushDeviceRecord? {
        let wanted = tokenHex.lowercased()
        return await pushRelayDevices()
            .compactMap(PushDeviceRecord.init)
            .first { $0.tokenHex.lowercased() == wanted }
    }

    /// Re-POST this device with a per-bot allow-list. Registration is an
    /// idempotent upsert, so this is also how the filter is CHANGED; an empty
    /// list means "every bot", which is the relay's own default.
    func registerPushDevice(tokenHex: String, environment: String, gatewayID: String,
                            profileFilter: [String]) async throws {
        let body: JSONValue = .object([
            "device_token": .string(tokenHex),
            "platform": "ios",
            "environment": .string(environment),
            "gateway_id": .string(gatewayID),
            "profile_filter": .array(profileFilter.map(JSONValue.string)),
        ])
        try await restJSON(path: "api/plugins/talaria-push/devices", method: "POST",
                           body: body, timeout: 20)
    }

    // MARK: Internals

    /// Both the config and audio routes take the same optional `?profile=`.
    private func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }
}

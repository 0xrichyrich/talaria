# Changelog

All notable changes to Talaria. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org). Talaria is MIT licensed.

## [Unreleased] — 2026-08-18

The overnight run: roadmap phases 0–5, landed unattended in one session and
reviewed the next morning. Six commits, ~27,000 lines, 73 files.

**Read this first: nothing in this entry has been run against a live gateway.**
No gateway was reachable during the run, so every behaviour below is a shape
read from the upstream Python and compiled, not a shape seen on the wire. The
parity docs record that distinction rather than smoothing it over — 26 of the 30
rows moved in [PARITY.md](PARITY.md) are 🔶 "built but never run against a live
gateway", not ✅. [docs/OVERNIGHT-REPORT.md](docs/OVERNIGHT-REPORT.md) lists the
live checks to run first, in the order most likely to find a real bug.

### Fixed

- **Tapping a bot opened a chat with no history, and the first message forked a
  new session away from it.** Every entry point — roster row, deep link, push
  tap, search result, activity row, artifact and inbox jumps — now routes
  through `openChat(botID:)`. This was the run's blocking bug: each phone
  conversation was silently orphaning itself from the bot's real history.
- **The canonical forever-chat is honored.** One resolver
  (`AppModelLive+CanonicalChat.swift`) is the single door every open and send
  funnels through, in the plugin's order — explicit binding, then the pin from
  `ui_meta["hermes-bots"].chat`, then the canonical "Bot Chat" title, then the
  previewed session, and only then birth. The pin is written back, so phone and
  desktop open the same conversation.
- **One identity path.** `BotSheetView`'s local `displayName` — which hardcoded
  `"@" + botID` — is gone, and `CopyPack.composer` takes the resolved handle.
  A sheet reading "@default" behind a header reading "Skynet" is no longer
  possible.
- **The connect-time push handshake no longer erases your per-bot filter.** The
  relay's upsert replaces the whole record, and registration re-sent an empty
  `profile_filter` on every connect.
- **A voice-started turn has a stop button** — voice submits through
  `sendOrSteer` rather than `send`.

### Added

- **Liveness** (`AppModelLive+Liveness.swift`, `Components/NetworkMonitor.swift`)
  — a phone suspends and desktop does not, which produced *wrong state* rather
  than missing features. Foreground re-seed and a reaper over
  `session.active_list`, coalesced so concurrent triggers ask once and
  generation-guarded so a re-dial mid-pass cannot apply a stale snapshot; an
  NWPathMonitor nudge with a settle delay and a nudge floor so a flapping
  interface cannot dial in a loop. A gateway that lacks the method is remembered
  and never asked again.
- **Settings** (`Screens/SettingsView.swift`, `Screens/Settings/*`) — the app's
  first settings screen: Gateways, Appearance (themes, text size, motion),
  Notifications, Models & providers, Voice, Solo, Privacy & data, About &
  diagnostics. Deliberately not desktop's 202 controls; raw config and env
  editing stay off the phone, with an honest pointer to desktop.
- **Fleet management** — cron create/edit/delete with run history and
  `last_error` (`RoutineEditorView.swift`, `AppModelLive+Cron2.swift`); session
  pin, rename, export, archive, delete, branch and compress behind long-press,
  never as primary navigation; an artifacts index that fetches and previews real
  bytes with share-sheet export; approval policy — mode, bypass, wait, and a
  revocable allowlist; and messaging-platform pairing approvals.
- **Bot Mode depth** — A2A with sender attribution and @mention routing
  (`AppModelLive+A2A.swift`, `Components/MentionField.swift`); a union roster
  across every saved Connection; the cosmetics bridge made two-way, so a bot
  renamed or recolored on the phone reads the same on the laptop; avatar
  generation via `image.generate` → `profiles.set_asset`; and roster craft —
  recency ranking, the 90-second liveness window, pinning, and an unread
  watermark that catches CLI, cron and other-machine deliveries.
- **Solo mode** (`SoloEngine.swift`, `FoundationModelsProvider.swift`,
  `SoloTools.swift`, `Screens/SoloExplainerView.swift`) — a native agent loop
  over Apple Foundation Models, with the tool set iOS permits and the *same*
  approval vocabulary as a gateway bot. Two gates: a permission that is off
  keeps its tools out of the registry entirely rather than making them refuse,
  and every call still raises an ordinary approval. `web_fetch` enforces
  http/https only, a byte ceiling applied while streaming, and no cross-host
  redirects. The explainer asserts nothing — engine rows are live probes and the
  tool list is generated from the registry, so it cannot drift.

### Changed

- `GatewayClient.listSessions` takes `includeHidden`, and `createSession` takes
  `hidden` — Bot Mode's sessions are born hidden, and the surfaces that own them
  are the only ones that pass the flag.
- `deleteAllLocalData` now takes Solo's transcripts, memory and images with it.
  They are the one part of Talaria with no server copy, so leaving them behind
  would be the worst possible reading of "delete everything".

### Known gaps

Group rooms (Region 5 of the Bot Mode contract) are still unbuilt; `/new` inside
a canonical chat is not rerouted to `/compact`; there is no `set_hidden`
reconciliation sweep for sessions created before the fix. Full list in
[docs/ROADMAP.md](docs/ROADMAP.md#what-is-actually-left).

## [0.1.0] — 2026-08-17

Initial scaffold. This is a foundation release: the protocol, auth, theme,
state, and pipeline layers are real and compile-checked, all twelve screens
plus the app shell (`@main` entry, deep links, tab chrome, push banner,
onboarding) are ported from the design prototype, and the package
cross-compiles clean for iOS. Demo mode is fully interactive; live-gateway
mode is wired end-to-end but has not yet been soak-tested against a long-lived
production gateway. See [PARITY.md](PARITY.md) for the honest per-feature
status.

### Added

- **TalariaKit** — gateway protocol client for `hermes serve`:
  - JSON-RPC 2.0 WebSocket transport for `/api/ws` (id-correlated,
    out-of-order-safe, event stream, `gateway.ready` handshake).
  - Typed RPC wrappers for the surfaces Talaria uses: `profiles.*` (roster,
    create/configure/describe, avatar assets), `session.*`
    (create/resume/close/interrupt/usage/context breakdown), `prompt.submit`
    (incl. queued), `session.steer`, `approval.respond`/`approval.pending`,
    `clarify.respond`, per-session YOLO and model pin via `config.set`,
    `cron.manage`, `image.generate`, `voice.toggle`, plus REST transcript
    hydration (`GET /api/sessions/{id}/messages`).
  - Typed server→client events (message/thinking/reasoning deltas, tool
    lifecycle, approvals, clarify, notifications, usage, global `*.changed`
    broadcasts) with a lossless `.other` escape hatch.
  - Auth stack at desktop parity: session token, native PKCE (RFC 8252)
    with loopback redirect listener and token refresh, single-use WS tickets;
    Keychain-only credential storage.
  - `NousPortalClient` — the CLI's Nous Portal device-code OAuth (rotating
    single-use refresh token, hard host allowlists) plus the
    OpenAI-compatible streaming inference API, behind the new
    `InferenceProvider` seam (gatewayless chat tier).
  - `BotWorkAttributes` — the ActivityKit contract shared between the app
    process and the widget extension.
  - Domain models mirroring the design prototype's data contract, and the
    full demo roster (`DemoData`) ported from it.
- **TalariaTheme** — the three theme packs (Soft / Control / Ink) with exact
  design token values, per-theme copy packs (Approvals/Holds/Seals voice),
  runtime switching with persistence, and the avatar language (6 shapes × hue
  palettes, scanning eyes).
- **TalariaUI** —
  - `AppModel` observable state tree with demo/live mode dispatch, per-bot
    chat state, and the offline compose queue; `AppModel+Live` wires the
    gateway in: roster mapping from `profiles.list` (with `ui_meta["talaria"]`
    cosmetics + stable-hash fallback), event routing (streaming deltas →
    `ChatState`, approvals → roster badges, `sessions.changed`/`cron.changed`
    refreshes), lazy per-bot session create/resume, approval resolution,
    routine toggles with the `[bot:<name>]` namespace parse, and
    flush-on-connect for the offline queue.
  - `AuthController` — phased sign-in orchestration (probe `/api/status` →
    paste-token or native-PKCE browser flow → Keychain), with password
    providers riding the same browser broker.
  - `ConnectionRegistry` — saved gateways (metadata in UserDefaults,
    credentials Keychain-only) with parallel health probes, measured ping,
    and asleep-vs-offline detection.
  - `LiveActivityController` (observation-driven, one activity, most-recent
    working bot) and `PushCoordinator` (notification authorization, the
    `TALARIA_APPROVAL` actionable category in the current theme's voice,
    APNs registration, deep-link routing, demo payload previews).
  - First five screens, demo-fed and themed: Bot profile sheet (stats,
    sessions, context meter, YOLO, model pin, memory star map,
    duplicate/edit), Create bot, Routines, Artifacts, and the Search palette,
    plus the shared `ScreenHeader` chrome.
- **TalariaLocal** (separate optional package) — curated on-device model
  catalog (Qwen3 1.7B/4B, Llama 3.2 3B; 4-bit MLX conversions with RAM
  guidance). Quarantined so the main app links no third-party code unless
  the user opts in. See docs/LOCAL-INFERENCE.md.
- **talaria-verify** — XCTest-free protocol conformance checks
  (`swift run talaria-verify`), also wrapped as an XCTest target: event
  envelope decoding, usage parsing, URL normalization, WS URL building, PKCE
  challenge shape, token refresh window, demo-data integrity, live-session
  payload parsing.
- **ios/** — XcodeGen shell: `project.yml` defining the app target plus the
  `TalariaWidgets` (Live Activity) and `TalariaNotificationService`
  extensions; app icon; bundled IBM Plex Mono and Cormorant Garamond fonts
  with their OFL licenses. The generated `Talaria.xcodeproj` is never
  committed.
- **relay/talaria-push** — first modules of the gateway-side APNs push relay:
  env-driven config, the 0600 device registry with locked atomic writes, and
  a dependency-light APNs HTTP/2 client (httpx + ES256 JWT).
- Project documentation: README, PARITY.md (the desktop-parity contract and
  roadmap), docs/ARCHITECTURE.md, docs/LOCAL-INFERENCE.md, CONTRIBUTING.md,
  SECURITY.md, LICENSE.md (MIT), DCO, Makefile, and GitHub Actions CI
  (SwiftPM build + verify required; xcodegen simulator build advisory until
  the app entry point lands).

### Known gaps

- **Not yet runnable as an app**: `ios/Talaria/App/` has no `@main` entry
  point, and the Roster, Chat, Approvals, Activity, Agent Inbox,
  Connections, Onboarding, and Voice screens are still being ported from the
  design prototype. The CI simulator-build job is advisory until then.
- The `BotWorkLiveActivity` widget render view is not written, and the
  notification-service extension is an empty scaffold.
- No reconnect backoff loop or scene-phase observer yet (resume + queue
  flush exist; nothing triggers them automatically).
- Relay push fan-out, hermes hook handlers, and the sidecar are not yet
  landed (`push.py`, `events.py`, `sidecar.py`); no APNs credentials are
  provisioned.
- `LocalModelProvider` and the model download manager (TalariaLocal) are
  pending; only the catalog exists.
- Voice audio transport and Hermes Cloud agent discovery are unresolved
  designs.
- Protocol code is verified against recorded frame shapes, not yet against a
  live gateway matrix.

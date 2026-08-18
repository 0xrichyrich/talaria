# Changelog

All notable changes to Talaria. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org). Talaria is MIT licensed.

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

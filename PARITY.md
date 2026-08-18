# PARITY.md — the Hermes Desktop ↔ Talaria contract

This is the 1:1 parity map against **Hermes Desktop 0.17.0** (feature inventory
sourced from the upstream desktop checkout) and the contribution roadmap for
this repo: pick a 🚧 or ⭕ row, check the gateway surface named in the row, and
send a PR. Protocol shapes are documented in the desktop repo and mirrored in
`Packages/Talaria/Sources/TalariaKit` (see file pointers per section).

**Legend**

| Mark | Meaning |
|---|---|
| ✅ built | Working end-to-end in this repo today |
| 🚧 scaffolded | The protocol client / models / state / screen exist in `Sources`, but the end-to-end wiring is not finished |
| ⭕ planned | On the roadmap; nothing usable in the repo yet |
| ➖ n/a mobile | Deliberately not ported — reason given |

Honest snapshot: the transport, auth, event, theme, and state layers are built
and exercised by `swift run talaria-verify`; live-mode wiring
(`AppModel+Live`), the auth controller, the connections registry, the Live
Activity and push pipelines, the app shell (`@main`, deep links, tab chrome,
push banner), and all twelve prototype screens have landed and build clean
for iOS. Demo mode is fully interactive. **Nothing below is marked ✅ until
it has been verified against a live `hermes serve` gateway** — that
end-to-end soak is the next milestone, so live-path rows sit at 🚧 on
implementation-complete honesty.

---

## 1. Connection & auth (desktop: connection-config / gateway settings)

Code: `TalariaKit/GatewayAuth.swift`, `GatewayTransport.swift`,
`GatewayClient.swift`, `KeychainStore.swift`, `LoopbackListener.swift`;
`TalariaUI/AuthController.swift`, `ConnectionRegistry.swift`.

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| JSON-RPC over WebSocket | One JSON object per text frame; out-of-order pooled responses; ~30 fps delta coalescing | `/api/ws` | ✅ built (`GatewayTransport` actor; id-correlated, event stream) |
| `gateway.ready` handshake | First frame after accept; carries skin + `change_events` | `gateway.ready` event | ✅ built (connect blocks on it; skin captured) |
| Remote gateway, token auth | Paste URL + dashboard session token; both HTTP and WS legs must pass | WS `?token=`, REST `X-Hermes-Session-Token` | 🚧 client + `AuthController` paste-token path (probe → validate → Keychain) built; onboarding screen pending |
| Remote gateway, native OAuth (PKCE) | RFC 8252: system browser → loopback redirect → code redeem; encrypted token store; refresh at exp−60 s | `auth/native/authorize`, `POST auth/native/token`, `auth/native/refresh` | 🚧 flow, loopback listener, refresh, Keychain, and the `AuthController` browser hand-off (state check, phased UI states) built; onboarding screen pending |
| WS tickets (gated mode) | Single-use 30 s ticket minted before every dial | `POST /api/auth/ws-ticket` → WS `?ticket=` | ✅ built (re-minted on every `GatewayClient.connect()`) |
| Username & password (basic provider) | Desktop remote sign-in ladder | `GET /api/auth/providers` + native broker | 🚧 provider probe + ordering built (`AuthController`; password providers ride the same browser broker via the gateway's `/login`); screen pending |
| Legacy OAuth cookie flow | Embedded BrowserWindow session cookies | `hermes_session_at`/`_rt` cookies | ➖ n/a mobile — native PKCE is the mobile-correct flow; cookies are the desktop fallback |
| Hermes Cloud discovery | Nous Portal login, `/api/agents` roster, per-agent silent sign-in | Portal REST | ⭕ planned (`NousPortalClient` covers Portal OAuth for *direct inference* — see §14 — not agent discovery yet) |
| SSH mode | Spawns/boots `hermes serve` over OpenSSH + port tunnel | ssh + remote lifecycle | ➖ n/a mobile — no OpenSSH/child processes on iOS; use Tailscale to reach the same box |
| Multi-connection registry | Named agent sources, union roster, per-connection sockets | desktop-local registry | 🚧 `ConnectionRegistry` built (saved gateways in UserDefaults, credentials Keychain-only, parallel `/api/status` health probes with measured ping, asleep-vs-offline detection); Connections screen + multi-socket roster pending — single live gateway first |
| Extra gateway headers (access proxies) | Per-connection header map for Cloudflare Access etc. | applied to gateway-origin requests | ⭕ planned |
| Local backend spawn / first-run bootstrap | Installs runtime, spawns `hermes serve` locally | child process mgmt | ➖ n/a mobile — iOS cannot host the backend; Talaria is remote-only by design |
| Reconnect + session parking | Full-jitter backoff; resume stored key within ~20 s grace reattaches in-flight turn | `session.resume` fast path | 🚧 resume, ticket re-mint, and offline-queue flush-on-connect built; automatic backoff loop and scene-phase observer pending |
| Version-skew hygiene | `-32601` fallbacks, `desktop_contract` gate (v6) | `session.info.desktop_contract` | 🚧 contract surfaced in `SessionInfo`; gating logic pending |

## 2. Chat & sessions (desktop: chat surface, transcript, composer)

Code: `TalariaKit/GatewayClient.swift` (RPC wrappers),
`GatewayEvents.swift` (typed events), `TalariaUI/AppModel.swift` +
`AppModelLive.swift` (state + live event routing).

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Create / resume / activate sessions | Lazy create, resume by durable key, defer-history hydration | `session.create/resume/close`, `GET /api/sessions/{id}/messages` | 🚧 wrappers + REST hydration + per-bot lazy create/resume on first send (`AppModel+Live`) built; Chat screen pending |
| Streaming transcript | Token deltas, interim segments, thinking/reasoning blocks | `message.start/delta/interim/complete`, `thinking.delta`, `reasoning.delta` | 🚧 typed events + live delta→`ChatState` routing (typing indicator, streaming row, completion reconcile) built; Chat screen pending |
| Tool lifecycle rows | Start/complete cards with arg preview, duration, summaries, inline diffs | `tool.generating/start/complete` | 🚧 typed payloads built; `tool.start` drives the bot's working-task line; transcript cards pending (no inline-diff viewer) |
| Rich rendering (markdown/mermaid/katex/embeds) | Full streamdown pipeline | client-side | ⭕ planned — plain-text-first, markdown next |
| Prompt submit (incl. queue-behind-turn) | Busy sessions queue; `queued:true` avoids interrupt | `prompt.submit` | 🚧 wrapper + live send path built incl. `queued`; composer pending |
| Stop / interrupt | Stop button; denies pending approvals too | `session.interrupt` | 🚧 wrapper built |
| Steer / redirect mid-turn | Inject into next tool result / redirect active turn | `session.steer`, `session.redirect` | 🚧 steer wrapped; redirect not yet |
| Rewind / truncation / retry / undo / compress / branch | Fail-closed truncation consent dance, history reconciliation | `prompt.submit` truncate params, `session.undo/compress/branch` | ⭕ planned |
| Attachments (image/file/pdf/clipboard) | Drag-drop, paste, picker → `@file:` refs | `image.attach*`, `file.attach`, `pdf.attach` | ⭕ planned (photo picker + share sheet) |
| Message queue panel / drafts | Queued prompts UI, per-thread drafts | client-side | ⭕ planned |
| Session usage ticker + context meter | 1 Hz usage events; breakdown popover | `session.usage`, `session.context_breakdown` | 🚧 `Usage`/`ContextSegment` models, RPCs, and live usage routing built; context meter renders in the Bot sheet |
| Per-session model pin | Model pill, deferred switch when busy | `config.set {key:"model"}`, `model.options` | 🚧 wrappers + Bot-sheet pin chips built; deferred-switch handling pending |
| YOLO toggle (per-session approval bypass) | Statusbar zap; session or global scope | `config.set {key:"yolo"}` | 🚧 wrapper (session scope) + Bot-sheet toggle built |
| Message reactions | Emoji on rows | `message.react` + `message.reaction` event | ⭕ planned |
| Session list / search / archive / pin / unread | Batched cross-profile sidebar | `session.list`, REST sessions API | 🚧 `listSessions` built; recent sessions render in the Bot sheet |
| Session tiles / split view / tabs / multi-window | Side-by-side panes, tab strip | client-side | ➖ n/a mobile — one screen at a time on a phone |
| Transcript find-in-page | Electron `findInPage` | client-side | 🚧 search palette built (§10); transcript-scoped search pending |
| Todos / goals / background delegation stack | Composer status stack | `todo` tool events, `subagent.*` | ⭕ planned (activity feed shows task-level state first) |
| Subagent monitor (`/agents`) | Delegation tree with live tails | `subagent.*`, watch-window resume | ⭕ planned |

## 3. Approvals & interactive prompts

Code: `GatewayEvents.swift` (`ApprovalRequest`, `ClarifyRequest`),
`GatewayClient.swift` (respond wrappers), `Models.swift` (`Approval`),
`AppModelLive.swift` (event → roster/approvals routing).

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Approval request cards | Blocking card: command, why, choices incl. permanent-allow | `approval.request` event → `approval.respond` | 🚧 events, respond, and live routing (approval → roster badge, resolve → run resumes) built; swipeable card UI pending — this is Talaria's marquee feature |
| Pending-approval replay on resume | Restored after reconnect | `approval.pending`, `pending_approval` in resume payload | 🚧 parsed in `LiveSession` and re-emitted into the approval flow on resume |
| Clarify questions (multi-select) | Question card mid-turn | `clarify.request` → `clarify.respond` | 🚧 typed + respond built; UI pending |
| Sudo / secret prompts | Password/secret dialogs; empty = refusal | `sudo.respond`, `secret.respond` | ⭕ planned (passthrough only; never stored) |
| MCP setup prompts | Consent card for MCP server setup | `mcp.setup.request/respond` | ⭕ planned |
| Approval-mode menu (manual/smart/off) | Global approvals policy | `config.get/set approvals.mode` | ⭕ planned |
| Client-capability reads (terminal/preview/window) | Agent reads the desktop's panes | `terminal.read.request` etc. | ➖ n/a mobile — Talaria sends `source:"talaria"` and does not advertise these capabilities (nothing to read on a phone) |

## 4. Roster & profiles (desktop: Bot Mode plugin, `/profiles` overlay)

Code: `GatewayClient.swift` (profiles RPCs), `Models.swift` (`Bot`),
`TalariaTheme/AvatarView.swift`, `AppModelLive.swift` (roster mapping),
`TalariaUI/Screens/BotSheetView.swift`, `CreateBotView.swift`.

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Bot roster (one row per profile) | Avatars, unread, live working state | `profiles.list` (+ session events) | 🚧 `profiles.list` → `Bot` mapping built (`ui_meta["talaria"]` cosmetics with stable-hash fallback; working/approval status from live events); Roster screen pending |
| Avatar language (shape × hue, scanning eyes) | Bot Mode's avatar system | client-side (`ui_meta`) | ✅ built (`AvatarSilhouette` + eye animation ports the prototype's `SHAPE_CSS`) |
| Bot profile sheet (describe) | Description, skills/toolsets/MCP summary | `profiles.describe` | 🚧 `BotSheetView` built (stats, recent sessions, context meter, YOLO, model pin, memory star map, duplicate/edit, CLI-delete footnote); live soak pending |
| Create bot (name, job, look, SOUL.md) | New Agent flow | `profiles.create` | 🚧 `CreateBotView` built (profile-id rules `[a-z0-9-]`, shape/hue pickers, personality → SOUL.md, advanced disclosure); live soak pending |
| Edit / configure bot | Soul editor, model, skills exclusion, `ui_meta` | `profiles.configure` | 🚧 wrapper incl. `disabled_skills` + `ui_meta`; Edit-look-&-soul path reuses the create sheet |
| Duplicate bot | Clone profile w/ history options | `profiles.create {clone_from}` | 🚧 wrapper (`cloneFrom` → `clone_all`) + Bot-sheet action built |
| Custom avatar portrait | Image asset on profile | `profiles.set_asset/get_asset` | 🚧 wrappers built |
| AI-generated portraits | Bot Mode avatar generation | `image.generate` | 🚧 wrapper built (data-URL result); flow pending |
| Profile delete | CLI-only upstream; desktop mirrors that | — | ➖ n/a by design — `hermes profile delete` only (matches desktop + design) |
| Profile export/import | tar.gz with appearance overlay | `POST /api/profiles/{name}/export` | ⭕ planned |
| Per-profile themes | Desktop profile theming | client-side | ➖ n/a mobile — Talaria themes the whole app (Soft/Control/Ink); bot identity is the avatar |
| Memory star map (per bot) | `/starmap` graph + memory cards | `GET /api/learning/graph` | 🚧 mini star-map card in the Bot sheet built (demo memory); live learning-graph feed pending — the full d3 overlay stays desktop |

## 5. Routines (desktop: `/cron` overlay, Bot Mode Routines tile)

Code: `GatewayClient.swift` (`cronManage`/`cronList`),
`AppModelLive.swift` (`[bot:<name>]` namespace parse),
`TalariaUI/Screens/RoutinesView.swift`.

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Routine list per bot | Cron jobs scoped to profile; `[bot:<name>]` namespace | `cron.manage` (WS) / REST cron API | 🚧 screen (`RoutinesView`: this bot + other bots + cron footnote), namespace parse, and live refresh built; live soak pending |
| Toggle / pause / resume / trigger-now | Job controls | `cron.manage`, `POST /api/cron/jobs/{id}/pause…` | 🚧 enable/disable dispatch wired to the screen's toggles; pause/resume/trigger-now pending |
| Create/edit routine (schedule builder) | Schedule, prompt, model override, delivery targets | `cron.manage` / `POST /api/cron/jobs` | ⭕ planned (natural-language "+ New routine" row per design) |
| Run history → sessions | Runs land as sessions | cron runs API | ⭕ planned (runs land in the bot's chat) |
| Automation blueprints gallery | Instantiate templates | `/api/cron/blueprints` | ➖ n/a mobile — admin surface; use desktop/web |
| Live refresh | `cron.changed` broadcast | `cron.changed` | 🚧 typed + wired (`cron.changed` → `refreshRoutines()`) |

## 6. Activity & notifications

Code: `TalariaUI/PushCoordinator.swift`, `relay/talaria-push/`,
`ios/TalariaNotificationService/` (target scaffold).

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Activity feed (day-grouped ledger) | Toast center + sidebar signals | client aggregation of events | 🚧 `ActivityDay`/`ActivityItem` + demo feed built; live aggregation + screen pending |
| Agent notices | Sticky/TTL notices | `notification.show/clear` | 🚧 typed events built |
| Native notifications w/ actions | OS notifications, approve from banner | desktop `hermes:notify` → Talaria: APNs via `relay/` | 🚧 app side built (`PushCoordinator`: authorization, `TALARIA_APPROVAL` actionable category in the current theme's voice, APNs registration, deep-link routing, demo-mode payload previews) + NSE target scaffolded; relay core landed (`config`/`devices`/`apns`), fan-out + hooks + sidecar pending |
| Unread tracking | Server watermark | `PATCH /api/sessions/{id} {unread}` | 🚧 unread in `Bot` model; server sync pending |
| Background-task completion | `background.complete` toast | `background.complete` | 🚧 typed event built |

## 7. Agent Inbox (desktop: Bot Mode bot-to-bot)

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Cross-bot traffic feed | @-mention delivery between profiles | `session.create`+`prompt.submit` per bot; `cli.exec hermes -p <bot> chat` | 🚧 `A2AMessage` model + demo feed built; live delivery pending |
| @mention a bot from chat | Mention → handoff + report back | same as above | ⭕ planned |
| Messaging-platform handoff | Hand session to Telegram/Discord… | `handoff.request/state/fail` | ⭕ planned |

## 8. Artifacts (desktop: `/artifacts` gallery)

Code: `TalariaUI/Screens/ArtifactsView.swift`.

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Artifacts vault (files/images/links) | Client-side extraction from transcripts | `GET /api/sessions/{id}/messages` + media API | 🚧 screen built (`ArtifactsView` grid: image/file/link cards in the owner's color); live extraction pending |
| Open-session jump | Tap artifact → owning session | client-side | 🚧 built (tap → owner bot's chat) |
| Media download | Via gateway media endpoint | `GET /api/media` | ⭕ planned |

## 9. Voice & wake

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Voice conversation mode | Record → transcribe → spoken replies, barge-in | `voice.toggle/record/tts`, `voice.transcript` events, `/api/audio/*` | 🚧 status/toggle wrappers + typed transcript events built; Voice overlay pending (transport for audio frames still an open question — see design HANDOFF) |
| Push-to-talk from composer | Mic button | `POST /api/audio/transcribe` | ⭕ planned |
| Wake word ("Hey Hermes") | Backend listener + client mic feed | `wake.*` | ➖ n/a mobile — iOS forbids always-on background mic for third-party apps |

## 10. Search & command palette

Code: `TalariaUI/Screens/SearchPalette.swift`.

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Search palette | ⌘K: sessions, routes, commands, actions | `GET /api/sessions/search` + client registry | 🚧 screen built (`SearchPalette`: "Live now" empty state; filters bots, sessions, artifacts, actions; routes on tap); server-side session search pending |
| Slash commands / completions | `commands.catalog`, `complete.slash/path` | WS RPCs | ⭕ planned |

## 11. Theming & appearance

Code: `TalariaTheme/` (ThemePack, CopyPack, ThemeManager, Packs),
`TalariaUI/Components/ScreenHeader.swift` (shared themed chrome).

| Feature | Desktop behavior | Gateway surface | Talaria status |
|---|---|---|---|
| Theme system | Presets, VS Code import, per-profile, translucency | client-side | ✅ built as Talaria's own triple: Soft / Control / Ink token packs with exact design values |
| Copy packs (voice per theme) | — (desktop has no copy-pack equivalent) | client-side | ✅ built (Approvals/Holds/Seals; RELEASE/grant-the-seal; even the push-action titles follow the pack) |
| Runtime switch + persistence | Light/dark/system etc. | client-side | ✅ built (`ThemeManager`, cycle order soft→control→ink, persisted) |
| Backend-synced skins | `/skin` command, `skin.changed` | `gateway.ready.skin`, `skin.changed` | 🚧 skin captured on ready; not yet applied to UI |
| VS Code marketplace themes | Electron fetch | — | ➖ n/a mobile |
| i18n (en/ar/ja/zh) | 4 locales incl. RTL | client-side | ⭕ planned — en only today |

## 12. Admin surfaces intentionally left to desktop / web dashboard

Talaria is a window onto the roster, not an admin console. These desktop
surfaces stay ➖ n/a mobile — point your browser at the gateway's dashboard
instead:

| Desktop surface | Reason |
|---|---|
| Settings → Model/Chat/Workspace/Safety/Memory/Advanced config editor | Schema-driven config editing is a desktop/web job; a mistake here can strand the gateway |
| Providers / API keys / env vault | Credential entry belongs on the machine that owns them |
| Skills & toolsets & MCP management pages | Heavy admin flows (hub installs, mcp.json editing, OAuth connects); per-bot skill exclusion IS in scope (§4) |
| Messaging platforms / pairing / webhooks | Server-side platform config |
| Command Center (logs, doctor, backup, restart, update) | Ops surface; a Connections health probe (`/api/status`) is in scope (§1) and 🚧 built |
| Billing / subscription | Nous portal + Apple IAP rules make this web-only |
| Projects / worktrees / git review / files pane / PTY terminals | Filesystem + PTY + git are machine-local capabilities the phone doesn't have |
| Plugin system (runtime-loaded JS plugins) | No runtime code loading on iOS (App Store rules); Talaria features are first-party Swift |

## 13. Desktop features that don't map to mobile

| Desktop feature | Why n/a |
|---|---|
| Embedded PTY terminals (node-pty/xterm) | No PTYs, no child processes on iOS |
| HUD window / Quick Entry / wake-indicator / pet overlay windows | No floating always-on-top windows on iOS; Live Activity is the HUD analogue |
| System tray / multi-window / session windows | iOS single-window model |
| Local backend spawning & bootstrap installer | Cannot run Python/`hermes serve` on-device |
| Find-in-page (Electron), zoom persistence, native theme titlebars | Electron-specific chrome |
| Auto-update of local checkout | App Store / TestFlight handles app updates; gateway updates stay a desktop/web op |
| Desktop pet sprite windows | The roster avatars carry the personality; a cosmetic in-chat pet sprite may come later (`petMode` in the design) |

## 14. Mobile-native extras (not in desktop)

The other half of the contract: things Talaria adds because it lives on a
phone.

| Feature | Notes | Status |
|---|---|---|
| Demo mode | Full six-bot roster, scripted replies, approvals, routines — no gateway needed; App Review path. Mirrors the design prototype's data | ✅ built (`DemoData`, `AppModel.enterDemoMode`; the landed screens all run demo-fed) |
| Swipe approvals | Right = approve, left = deny, ≥90 pt commit; explicit buttons remain | ⭕ planned (design final; Approvals screen not yet ported) |
| Offline compose queue | Messages typed while unreachable queue locally, flush on reconnect | 🚧 queue + flush-on-connect built (`AppModel`, `flushComposeQueue()`); reachability/offline detection wiring pending |
| Live Activity / Dynamic Island | Working bot's avatar + elapsed timer; tap → chat (`talaria://bot/<id>`) | 🚧 `BotWorkAttributes` contract (TalariaKit, shared with the widget target), `LiveActivityController` (observation-driven, one activity, most-recent-working-bot policy), and the `TalariaWidgets` target built; the `BotWorkLiveActivity` render view is not yet written |
| Actionable push banners (APNs) | Approve directly from the notification; approvals as critical alerts | 🚧 `PushCoordinator` + NSE target + relay core built; relay fan-out/hooks/sidecar and APNs credentials pending (see §6) |
| Onboarding with gateway wizard | Mode chips (Tailscale/LAN vs Cloud), auth, theme pick, notifications | 🚧 `AuthController` (probe → token/PKCE → Keychain) + flow state in `AppModel` built; screens pending |
| Gatewayless chat — Nous Portal direct | BYO inference: the CLI's device-code OAuth (`hermes-cli` client id, rotating single-use refresh token) + OpenAI-compatible streaming chat, no gateway required | 🚧 `NousPortalClient` + the `InferenceProvider` seam built (host allowlists enforced); not yet bound to a chat surface |
| On-device local models | Fully offline chat via MLX (Qwen3 1.7B/4B, Llama 3.2 3B, 4-bit) in the optional `Packages/TalariaLocal` package — never linked unless the user opts in | 🚧 package + curated `ModelCatalog` (RAM guidance) built; `LocalModelProvider` + download manager pending |
| Haptics & theme-tuned motion | Per-theme motion language | ⭕ planned |

---

*Update this file in the same PR as the feature. A row moves ⭕ → 🚧 when the
protocol/model layer lands with checks in `talaria-verify`, and 🚧 → ✅ only
when the screen works against a live `hermes serve` gateway.*

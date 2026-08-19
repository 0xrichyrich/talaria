# talaria-push-relay

Gateway-side APNs push relay for **Talaria**, the iOS client for
[hermes-agent]. Ships as a standard hermes plugin (`talaria-push/`) plus an
optional standalone sidecar watcher, and is written to be upstreamable into
hermes-agent — MIT licensed, no Talaria-app dependencies, pure Python.

```
app/relay/
├── pyproject.toml            pip package "talaria-push-relay" (sidecar installs)
├── .env.example              every knob, systemd EnvironmentFile-friendly
├── LICENSE                   MIT
└── talaria-push/             ← the hermes plugin dir (copy to ~/.hermes/plugins/)
    ├── plugin.yaml           manifest (kind: standalone, hooks: [...])
    ├── __init__.py           register(ctx) → observer hooks
    ├── LICENSE
    ├── dashboard/
    │   ├── manifest.json     hidden tab + api: plugin_api.py
    │   ├── plugin_api.py     REST routes → /api/plugins/talaria-push/*
    │   └── dist/index.js     no-op (REST-only plugin)
    └── talaria_push_relay/   importable package (shared by all three load paths)
        ├── config.py         TALARIA_* env parsing
        ├── devices.py        devices.json registry (0600, flock, atomic writes)
        ├── apns.py           HTTP/2 APNs client, ES256 JWT (~50 min cache), 410-prune
        ├── push.py           payload contract + fan-out worker + dedupe
        ├── events.py         hermes plugin hook handlers (in-process mode)
        └── sidecar.py        standalone WS/REST watcher (sidecar mode)
```

## Two modes, one payload contract

| | **Hook mode** (plugin) | **Sidecar mode** (`talaria-push-sidecar`) |
|---|---|---|
| Runs | inside every hermes process that loads plugins (`hermes serve`, `hermes gateway`, CLI, cron) | separate process; connects to `ws://host:9119/api/ws` + REST like the served SPA (auth-flows.md §2) |
| Sees | plugin lifecycle hooks (`VALID_HOOKS`) | `session.active_list` / `approval.pending` RPC polling, global WS broadcasts, `/api/cron/jobs`, `/api/health` |
| Best at | approvals at the instant they block, @mentions, per-turn timing | approval **request ids**, routine **names**, gateway offline/recovered |

Run either alone, or both together with `TALARIA_PUSH_EVENTS` split so no
event kind is enabled in both processes (otherwise the phone buzzes twice).
`.env.example` shows the recommended split.

## What fires today vs. needs upstream hooks (honest table)

Sources verified against the upstream checkout (paths relative to
`hermes-agent`):

| Event (HANDOFF spec) | Hook mode today | Sidecar mode today | Gap / upstream ask |
|---|---|---|---|
| **Approval request** | ✅ `pre_approval_request` hook (`tools/approval.py`) fires in the process running the blocked agent, before the notify callback. **But the hook kwargs carry no `request_id`** — pushes send `approval_request_id: ""`; the iOS client fetches the concrete id via the `approval.pending` RPC, or answers FIFO (`approval.respond` without `request_id` resolves the oldest, ws-protocol.md §8). | ✅ Polls `approval.pending` per active session (~2 s) — full fidelity incl. `request_id`, at polling latency. | Upstream ask: add `request_id` to the `pre_approval_request` kwargs (one-line change at the fire sites; `approval_data` already holds it). Then hook mode is exact and the sidecar's approval poller can be retired. |
| **Long task done (>10 min)** | ✅ `pre_llm_call` (turn start) + `on_session_end` (turn end, `completed/failed/interrupted`) — exact per-turn duration. | ⚠️ Approximated from idle↔streaming transitions in `session.active_list` (resolution = 2 s poll; can't tell success from in-turn error). | None needed for hook mode. There is no per-turn `message.complete` hook; the `pre_llm_call`→`on_session_end` bracket is equivalent for wall-clock duration. |
| **Routine (cron) finished** | ✅ `on_session_end` with `platform == "cron"` (cron jobs run their agent with `platform="cron"`, `cron/scheduler.py`). **The hook cannot see the job name** — push says "routine finished" generically. | ✅ Diffs `GET /api/cron/jobs?profile=all` on `cron.changed` broadcasts (+5 min backstop) — has the job name, parses the Talaria `[bot:<name>] <routine>` namespace. | Upstream ask: a `cron_job_completed` hook (mirroring the existing `kanban_task_*` observer family) carrying `job_id`, `job_name`, `status`. |
| **@mention in A2A / gateway messages** | ✅ `pre_gateway_dispatch` observer sees every user-originated inbound `MessageEvent` in the messaging gateway — all platforms including `a2a` — and scans for `@<handle>` (`TALARIA_PUSH_MENTION_HANDLES`, default = profile name). Always returns `None` (never alters dispatch). | ❌ Messaging-gateway inbound traffic never crosses the `/api/ws` surface. | None — hook mode covers it. Caveat: fires per *gateway process*, so mentions of bot B are seen by B's gateway; install/enable the plugin for each bot profile that should push. |
| **Gateway offline / recovered** | ❌ Structurally impossible — a dead process can't self-report, and there is no shipped shutdown hook that survives SIGKILL/power loss. | ✅ `/api/health` heartbeat; N consecutive failures ⇒ "offline", first success after ⇒ "recovered". **Only meaningful if the sidecar outlives the gateway** — run it under systemd/launchd, ideally on a different machine over Tailscale. A sidecar on the same host that dies with the host detects nothing; that residual gap needs an off-host watchdog and is out of scope here. | Inherent; no hook can fix this. |

Also honestly: hook mode requires the plugin to be **enabled** and the env
vars present in each hermes process. `hermes serve` (WS/iOS sessions),
`hermes gateway` (messaging), and cron all call `discover_plugins()`, so one
enable covers them — but a bare `hermes chat` in an env without
`TALARIA_APNS_*` simply won't push (it logs one warning and stays silent).

## Install (plugin / hook mode)

1. Copy the plugin dir into the hermes root (not a profile dir — user
   plugins load from `~/.hermes/plugins/` for every profile):

   ```sh
   cp -R app/relay/talaria-push ~/.hermes/plugins/talaria-push
   ```

   (Real copy, not a symlink — the web server resolves plugin paths and
   refuses files outside the plugin directory.)

2. Install the one wheel hermes doesn't ship, into hermes' Python env:

   ```sh
   python -m pip install 'h2>=4.1'    # httpx's HTTP/2 transport for APNs
   ```

3. Enable it (user plugins are disabled until allow-listed):

   ```sh
   hermes plugins enable talaria-push
   ```

   or add `talaria-push` to `plugins.enabled` in `~/.hermes/config.yaml`.

4. Configure APNs env vars (see `.env.example`) in the environment of the
   hermes processes — for a systemd-managed `hermes serve`:
   `EnvironmentFile=~/.hermes/talaria-push/relay.env`.

5. Restart `hermes serve` / `hermes gateway`. Verify:

   ```sh
   curl -H "X-Hermes-Session-Token: $TOKEN" \
        http://127.0.0.1:9119/api/plugins/talaria-push/status
   ```

**Per-bot profiles:** profiles started as `hermes -p <bot>` share the root
`~/.hermes/plugins/`, and the device registry deliberately lives under the
*root* home (`~/.hermes/talaria-push/devices.json`) so one registration
covers every bot. Mention handles default to each process's own profile
name.

## Install (sidecar mode)

```sh
pip install ./app/relay          # installs talaria-push-relay + talaria-push-sidecar
cp app/relay/.env.example ~/.hermes/talaria-push/relay.env  # then edit
set -a; . ~/.hermes/talaria-push/relay.env; set +a
talaria-push-sidecar --base-url http://127.0.0.1:9119
```

The sidecar refuses to start without APNs config. Loopback/static-token
gateways only: it authenticates like the served SPA (`?token=` on the WS,
`X-Hermes-Session-Token` on REST), auto-scraping the token from `GET /`
when `TALARIA_GATEWAY_TOKEN` is unset. Gated (OAuth, non-loopback)
deployments need the sidecar co-located on the gateway host pointing at
`http://127.0.0.1:9119`.

## Device registration API

Mounted like every dashboard plugin router at
`/api/plugins/talaria-push/` and **session-authenticated by the same
middleware as all `/api/*` routes** — `X-Hermes-Session-Token` header on
loopback, cookie/OAuth session on gated binds. The plugin adds no separate
secret on purpose: dashboard auth is the trust boundary.

```
POST   /api/plugins/talaria-push/devices
       {"device_token": "<hex>", "platform": "ios",
        "environment": "dev"|"prod", "gateway_id": "<saved-connection-id>",
        "profile_filter": ["ops-bot"]?}
GET    /api/plugins/talaria-push/devices
DELETE /api/plugins/talaria-push/devices            {"device_token": "<hex>"}
DELETE /api/plugins/talaria-push/devices/{token}
GET    /api/plugins/talaria-push/status
POST   /api/plugins/talaria-push/test               {"device_token"?: "...", "kind"?: "mention"}
```

`environment` selects APNs sandbox (`dev`, Xcode builds) vs production
(`prod`, TestFlight/App Store) per device. `gateway_id` is the phone's stable
source identity for this gateway; the relay echoes it into every payload so
colliding profile/session/approval ids cannot route to another saved machine.
`profile_filter` limits which bots may push to that device (empty = all).
Registrations are idempotent upserts — the iOS app re-POSTs its token on every
launch.

The test route defaults to the non-actionable `mention` shape because its
synthetic bot/session are not authoritative Hermes identities. Passing
`{"kind":"approval"}` remains useful for inspecting category presentation,
but its Approve action deliberately fails closed rather than answering work.

Store: `~/.hermes/talaria-push/devices.json`, `0600`, atomic tmp+rename
writes under an advisory `flock`, corrupt files quarantined as
`devices.corrupt`. `410 Unregistered` / `400 BadDeviceToken` from APNs
auto-prunes the record.

## Push payload contract (iOS side)

```jsonc
{
  "aps": {
    "alert": {"title": "ops-bot needs approval", "body": "rm -rf build …"},
    "sound": "default",
    "thread-id": "ops-bot",
    "category": "TALARIA_APPROVAL",        // TALARIA_TASK | TALARIA_MENTION |
                                           // TALARIA_ROUTINE | TALARIA_GATEWAY
    "interruption-level": "time-sensitive" // approval + gateway; others "active"
  },
  "kind": "approval",                      // approval|long_task|mention|routine|gateway
  "gateway_id": "2F80…",                  // source-qualified app connection id
  "bot": "ops-bot",
  "session_id": "ab12cd34",
  "approval_request_id": "9f3c…",          // "" in hook mode (see gap table)
  "title": "…", "body": "…",
  "deeplink": "talaria://approvals"        // gateway→talaria://connections,
                                           // else talaria://bot/<bot>?session_id=…
}
```

`TALARIA_APPROVAL` is the category the iOS client registers its actionable
Approve/Later notification buttons against (per the HANDOFF spec).
`interruption-level: time-sensitive` requires the Time Sensitive
Notifications capability on the app id; the relay deliberately does not
use `critical` (needs a special Apple entitlement).

## APNs client notes

Pure Python, no pyapns2/aioapns: one authenticated HTTP/2 POST per
notification via `httpx` (+`h2`). Provider JWTs are ES256-signed with the
`.p8` key (`cryptography`) and cached ~50 minutes (Apple wants 20–60);
`403 ExpiredProviderToken` drops the cache and re-mints on the next send.
Sandbox and production hosts get separate pooled connections. Transient
`429/5xx` get one bounded retry; everything else is logged and dropped —
pushes are best-effort by design, approvals remain safe because the
upstream approval flow times out and denies on its own (ws-protocol.md §8).

## Security notes

- **Registration is dashboard-authenticated** — anyone with dashboard
  access can register a device and will then receive approval prompts and
  message previews. That matches the dashboard trust model (dashboard
  access already grants full approval control), but treat dashboard
  tokens accordingly.
- **Push bodies leak context** by nature: approval pushes carry the
  (upstream-redacted) command text; mention pushes carry message text.
  APNs is end-to-end TLS to Apple, but notification previews sit on the
  lock screen — the iOS client should honor "hide previews".
  Everything is truncated (≤120/≤900 chars) well below the 4 KB cap.
- **Secrets**: the `.p8` key never leaves disk; keep it `0600`. The relay
  never logs tokens or JWTs, and logs device tokens only as `…last8`.
- `devices.json` and its directory are created `0600`/`0700`.
- The sidecar's scraped session token grants full dashboard control —
  it lives only in process memory, is never written to disk, and the
  sidecar only calls read-only RPCs (`session.active_list`,
  `approval.pending`) and `GET` REST routes.
- The plugin registers **observer** hooks only; `pre_gateway_dispatch`
  always returns `None`, so it can never skip/rewrite messages, and a
  crashing handler is isolated by both the upstream dispatcher and the
  relay's own never-raise wrappers.

## Upstreaming

`talaria-push/` is self-contained, MIT (this whole component, unlike the
Talaria app itself, is plain MIT so it can land in hermes-agent),
manifest v2, no imports from the Talaria app, and follows the same
layout as bundled plugins (`plugin.yaml` + `register(ctx)` +
`dashboard/plugin_api.py`). The two upstream asks in the gap table
(`request_id` on `pre_approval_request`, a `cron_job_completed` hook)
would let hook mode cover everything except offline detection.

[hermes-agent]: https://github.com/NousResearch/hermes-agent

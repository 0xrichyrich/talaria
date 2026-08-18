# Local & direct inference

Talaria's real product is a hermes gateway connection: full bots with
profiles, tools, approvals, memory, and routines, delivered over
`/api/ws`. This document covers the two *extra* backends that exist behind
the `InferenceProvider` seam — talking to Nous Portal's inference API
directly, and running a small model on the phone itself — and is honest
about what they are not.

| Tier | What you get | What you don't |
|---|---|---|
| **Hermes gateway** (primary) | Full bots: tools, approvals, memory, sessions, routines | Needs a reachable gateway |
| **Nous Portal direct** | Streaming chat with any hosted model, no gateway required | No tools, no memory, no sessions, no approvals |
| **On-device model** | Offline/private "pocket bot" chat | Everything above, plus it's a ≤4B model |

## The seam

`TalariaKit.InferenceProvider` is deliberately tiny: `models()` and one
streaming `chat(messages:model:stream:)` call. No sessions, no tools, no
persistence — callers own conversation state and pass the full message
array every turn. Both extra backends implement exactly this and nothing
more, which keeps them interchangeable and keeps the UI honest about their
limits.

## What works today

### Nous Portal direct chat (`NousPortalClient`, TalariaKit)

The same OAuth device-code flow the CLI runs for `hermes auth add nous`:

- `POST {portal}/api/oauth/device/code` with `client_id=hermes-cli`,
  `scope=inference:invoke`; the user approves in the browser at
  `verification_uri_complete` while the app polls the token endpoint
  (`authorization_pending` → poll capped at 1 s; `slow_down` → back off,
  cap 30 s). Polling survives transient network loss — it only gives up
  when the device code itself expires.
- Refresh uses the header grant (`x-nous-refresh-token`) at 120 s before
  expiry. The refresh token **rotates and is single-use** — the rotated RT
  is written through to the Keychain immediately, and concurrent refreshes
  are deduped so Portal's reuse detection never fires. `invalid_grant` /
  `invalid_token` / `refresh_token_reused` are terminal: tokens drop, the
  user signs in again.
- Inference is the OpenAI-compatible API at
  `https://inference-api.nousresearch.com/v1`: `GET /models` and
  `POST /chat/completions` with `stream: true`, SSE parsed off
  `URLSession.bytes`. A server-provided `inference_base_url` is accepted
  only when `https://` with a host on the hard allowlist — never trust a
  URL off the wire.
- Tokens live in the Keychain (service `bot.talaria.nous-portal`), keyed by
  portal base URL, independent of any gateway credential. Sign-out is
  client-side; Portal has no public revocation grant.

What you get is plain streaming chat (including the `reasoning_content`
channel) with any hosted model. It is useful on its own and it is the
fallback when your gateway is down — but it is chat, not a bot.

### On-device models (`TalariaLocal`)

`TalariaLocal` is a **separate Swift package** so the main Talaria package
and the default app target stay free of third-party dependencies. Linking
it pulls in MLX (Metal kernels) and the Hugging Face hub/tokenizer stack;
the app only adds it when the user opts into local models.

- `LocalModelProvider` — `InferenceProvider` backed by an MLX language
  model via `MLXLMCommon`/`MLXLLM`. One resident model at a time; stateless
  per call (full re-prefill each turn — honest about the context window);
  `<think>…</think>` spans stream to the reasoning channel and never enter
  the returned message.
- `ModelCatalog` — the curated roster, all 4-bit `mlx-community`
  conversions:

  | Model | Hub id | Download | Peak memory | Needs |
  |---|---|---|---|---|
  | Qwen3 1.7B (default) | `mlx-community/Qwen3-1.7B-4bit` | ≈1.0 GB | ≈1.6 GB | Any 4 GB iPhone (12+) |
  | Llama 3.2 3B | `mlx-community/Llama-3.2-3B-Instruct-4bit` | ≈1.8 GB | ≈2.6 GB | 6 GB (13 Pro / 15+) |
  | Qwen3 4B | `mlx-community/Qwen3-4B-4bit` | ≈2.3 GB | ≈3.4 GB | 8 GB (15 Pro / 16+) + Increased Memory Limit entitlement |

- `ModelDownloadManager` / `LocalModelStore` — streaming Hub snapshot
  downloads with progress, cancel/resume, per-model deletion, and disk
  accounting. Models live under Application Support (excluded from backup —
  multi-GB and always re-downloadable).

Build notes: MLX needs a Metal device. TalariaLocal builds with Xcode /
`xcodebuild` for a device or Apple-silicon destination; it does **not**
build under the plain `swift build` CI that covers the main package, and it
does not run in the iOS simulator. The app target that links it must carry
`com.apple.developer.kernel.increased-memory-limit` for the 4B tier.

## What deliberately does not work: the full hermes runtime on-device

The hermes agent runtime is a Python system (3.11–3.13, exact-pinned
dependencies including Rust/C wheels). Running it on the phone was
investigated seriously; the findings, condensed:

**Structural blockers on iOS**

- **No subprocess.** `fork`/`exec` are forbidden in the app sandbox, and
  hermes leans on subprocess everywhere: the terminal tool, skills'
  `scripts/`, cron `script` jobs, ffmpeg/ripgrep shell-outs — and
  agent-to-agent handoff itself is a subprocess of the sending agent.
- **No persistent background execution.** The cron ticker and the
  messaging gateway assume a long-lived process; iOS grants only
  BGTask windows.
- **No runtime pip.** The lazy-install system pip-installs tools' extras at
  runtime; everything would have to be vendored at build time.
- **Native wheels.** `uvicorn[standard]`'s uvloop/httptools don't build for
  iOS (pins would need relaxing to the pure-Python paths), and the
  `nemo-relay` native module's platform markers exclude iOS entirely.

**Even if you embedded CPython** (PEP 730 makes CPython ≥3.13 officially
support iOS, and the BeeWare toolchain can cross-compile the problem
wheels): it is App Store-fragile, a large ongoing engineering cost, and —
decisive — the tool surface that makes hermes *hermes* (a shell, a
browser, a real filesystem, system binaries) simply does not exist on iOS.
You would ship the agent loop without the hands.

**And even with hands, the model economics fail.** Hermes system prompts
are large (SOUL + memory snapshot + Bot-Mode protocol + tool schemas +
skills index — tens of thousands of prefill tokens). At phone-class prefill
rates that is many seconds to minutes before the first token, every
session. iPhone app memory ceilings (~3.5–4 GB usable even with the
entitlement) cap you at ≤4B 4-bit models, whose tool-calling reliability is
the weakest link for an agent loop; sustained decode also throttles and
drains the battery.

**So the local model is a pocket bot, not a local hermes profile.** No
SOUL.md, no memory, no tools, no cron, no sessions. It answers questions
offline and privately; it does not act.

## Roadmap

1. **Today** — gateway for full bots; Portal direct chat; local MLX pocket
   chat (this document).
2. **Next** — surface the pocket bot properly in the UI: offline banner
   hand-off ("your gateway is unreachable — pocket bot is available"),
   model management in Settings.
3. **Explicitly not committed** — an offline "lite agent" tier (embedded
   runtime for chat + memory + search over synced session state). The
   investigation above says it is *feasible* with real engineering effort;
   it is not planned until the gateway experience is finished. If it ever
   lands, tools stay server-side.

## Practical guidance

- Gate downloads and model pickers on `LocalModelSpec.fitsThisDevice`, and
  show `ramGuidance` next to every download button — an OOM kill looks like
  an app crash to the user.
- Download over Wi-Fi; sizes are honest in `downloadSizeLabel`.
- Free the resident model (`LocalModelProvider.unload()`) on memory
  warnings and when the local chat leaves the screen; it reloads on the
  next turn.
- All user-visible copy for these surfaces goes through `CopyPack` like
  everything else — the strings in `ModelCatalog` are data for the
  management screen, not themed UI copy.

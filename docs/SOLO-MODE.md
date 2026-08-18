# Solo mode — Talaria without a gateway

**Status: designed, not built. Sequenced after the desktop-parity pass.**

Talaria's default shape is a window onto a Hermes gateway you run somewhere
else. Solo mode is the other half of the promise: **a private agent that runs
entirely on the phone**, for people who want an agent without standing up a
server — and for everyone else on the days their gateway is asleep.

This document is the honest version of "run Hermes on the phone", including
what we deliberately are *not* building and why.

---

## The three tiers

| Tier | What runs | Where inference happens | Tools available |
|---|---|---|---|
| **Gateway** (today) | full hermes-agent | your gateway's provider | everything hermes has: shell, browser, files, MCP, skills |
| **Solo** (this doc) | a native Swift agent loop | on-device model, or Nous Portal | the iOS-permitted set (below) |
| **Chat** (fallback) | nothing | on-device model, or Portal | none — plain conversation |

Solo is not a hermes profile and never claims to be. It has its own storage,
its own memory file, and its own (much smaller) tool surface. When a gateway
is configured, the gateway roster stays the product's center of gravity.

---

## Inference on device

### Default: Apple Foundation Models (iOS 26+)

The system on-device model (~3B) reached through Apple's Foundation Models
framework is the right default for "later model iPhones":

- **Zero download, zero storage cost.** The weights are already on the device;
  we ship no gigabytes and manage no cache.
- **Tool calling and guided generation are first-class**, which is exactly
  what an agent loop needs — no fragile JSON coaxing out of a small model.
- **Apple owns the thermal and memory envelope**, the two things that make a
  hand-rolled 4B model miserable in a foreground app.
- Availability is a runtime check (device class, language, Apple Intelligence
  enabled), so the UI must degrade gracefully — gate on `@available(iOS 26, *)`
  plus the framework's own availability probe.

### Power path: MLX (`Packages/TalariaLocal`)

For people who want a specific model — a bigger Qwen, an abliterated build, a
fine-tune — keep the MLX path already scaffolded: a curated catalog (Qwen3
1.7B/4B, Llama 3.2 3B, 4-bit) with honest RAM guidance and a **user-initiated**
download. Never auto-download; the first run must be a deliberate choice with
the size printed on the button.

Constraints worth stating plainly in the UI (measured, from
`.research/profiles-runtime.md` §8.4): a 7–8B Q4 model wants ~5 GB and will not
fit the app's memory ceiling, so 3–4B is the practical top end; long prompts
are dominated by prefill, so Solo keeps its system prompt short; sustained
decode drains and throttles, so Solo is for short exchanges, not multi-minute
agent loops.

### Remote-but-serverless: Nous Portal

`NousPortalClient` (TalariaKit) already does the device-code flow and
OpenAI-compatible streaming. That is the "no gateway, no local model, still
good" option, and it is the fastest tier by far.

---

## The Solo tool surface

iOS deletes most of what makes hermes powerful, so Solo gets a small set of
tools the platform actually permits — chosen because each is useful *from a
phone*, not because it mimics desktop:

- **Files** — read/write inside the app sandbox and the Files-app scope the
  user grants; import from the document picker.
- **Web** — fetch a URL and extract readable text; a search tool if a key is
  configured.
- **Calendar & reminders** — EventKit, read and create with permission.
- **Photos** — read selected images (vision-capable models only).
- **Shortcuts** — run a named shortcut, which is the honest iOS analogue of
  "shell": it is how the platform lets an app trigger user-defined automation.
- **Memory & search** — a local notes/memory file and full-text search over
  Solo's own session history.

Every tool is permission-gated and appears in the same approval flow as
gateway bots, so the safety story is identical whichever tier you are in.

---

## What we are NOT building: embedded hermes

Running the real hermes-agent runtime in-process on iOS was researched
(`.research/profiles-runtime.md` §8.3) and rejected. CPython on iOS is
genuinely supported (PEP 730) and the *agent core* would run, but:

- **No `fork`/`exec`.** The terminal/shell tool — hermes's most-used tool —
  cannot exist. Neither can ripgrep or ffmpeg subprocesses.
- **Native deps don't ship for iOS**: `nemo-relay` has no iOS wheel; FTS5
  session search needs a custom SQLite build; the voice/wake extras pull
  Android/Linux-only wheels.
- **App Review risk**: hermes downloads and executes new code at runtime
  (skills, plugins, MCP servers). That is the exact pattern review scrutinizes.
- **It buys the name, not the product.** You would ship a hermes that cannot
  touch anything, in a process that also has to host a model.

A native Swift loop with a real (if small) tool set is more useful, more
honest, and an order of magnitude less fragile. People who want the full
runtime should run `hermes serve` on a box and point Talaria at it — which is
the product's main path and works today.

---

## The explainer GUI

Solo mode is only trustworthy if people can see exactly what they get. Before
the first Solo run, a comparison screen — same three-theme treatment as the
rest of the app — lays out, side by side:

- **What works on device**: chat, memory, the tool list above, everything
  private, no network required (Portal tier excepted).
- **What needs a gateway**: shell and real machine access, browser automation,
  MCP servers, skills, cron routines, bot-to-bot handoffs, subagents.
- **What it costs**: model download size and disk, expected speed on this
  device class, battery/thermal note.

The same screen is reachable later from Connections, so the trade-off stays
visible rather than being a one-time modal nobody reads.

---

## Sequencing

1. Desktop-parity pass (in flight) — Solo must not slow it down.
2. `SoloEngine` behind the existing `InferenceProvider` seam: Foundation
   Models first, MLX and Portal as alternates.
3. Tool registry + the approval bridge reused from gateway mode.
4. The explainer GUI, then onboarding gets a third door beside "Connect a
   gateway" and "Explore with demo data".
5. PARITY.md gets a Solo section so nobody reads Solo's capabilities as
   gateway parity.

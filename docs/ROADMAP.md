# Talaria roadmap — phased plan to Bot Mode parity

**Status: proposed, awaiting review. Nothing in here is implemented yet.**

Written 2026-08-18 from three sources: the 1,190-row desktop audit
([PARITY.md](../PARITY.md)), the 443-row Bot Mode plugin audit
([BOT-MODE-PARITY.md](BOT-MODE-PARITY.md)), and three bugs found by driving the
app against a live gateway.

The ordering principle: **correctness before capability, liveness before
surface area, and Bot Mode before everything else.** A phone that shows the
wrong state is worse than a phone missing a screen, and a beautiful settings
screen on top of a chat that loses your history is a bad trade.

---

## Phase 0 — Correctness (blocking; ~1 day)

Three live bugs, all found in one session of real use. Everything else waits.

### 0.1 Chat opens without its history · **critical**

`RosterView.swift:260` sets `model.openBotID = bot.id` directly and never
calls `AppModel.openChat(botID:)` — the function that resumes the stored
session and hydrates the transcript. Nothing else calls it either, so on a
real gateway:

- the chat opens with no history, showing only the roster preview line that
  `ChatView.seedChatIfNeeded()` injects as a fake message;
- the first message you send calls `ensureSession`, which **creates a new
  session** instead of continuing the bot's conversation.

That second effect is the serious one: every phone conversation silently
forks a fresh session, orphaned from the bot's real history — precisely the
"list of sessions" drift that BOT-MODE-PARITY warns is the end of the product.

*Fix:* route every entry point (roster row, deep link, push tap, search
result, activity row) through `openChat(botID:)`, and delete the preview-seed
fallback once hydration is real. Add a regression check that opening a bot
with a known session yields a non-empty transcript.

### 0.2 Bot identity is inconsistent across screens · **high**

`BotSheetView.swift:58` defines its own local `displayName` that hardcodes
`"@" + botID`, bypassing `Bot.displayTitle`. Same class of bug in the
composer placeholder (`CopyPack.composer(botID)` → "Transmit to @default"
instead of the handle @hermes). The chat header is correct, which is why it
reads "Skynet" while the sheet behind it reads "@default".

*Fix:* one identity path. Delete the local helper, make `CopyPack.composer`
take the resolved handle, and audit every remaining `botID`-as-display-string
call site.

### 0.3 The canonical forever-chat is not honored · **critical**

Desktop pins one canonical chat per bot in `ui_meta["hermes-bots"].chat` and
opens *always* there — never "most recent session"
(plugin.js:2726-2800). Talaria resumes `last_session` instead, so a cron
delivery or a subagent run can hijack what you see when you tap a bot.

*Fix:* read the pin, resume it, fall back to resume-by-title then create.
Write the pin back when a chat is created so desktop and phone agree. This is
the single most load-bearing behavior in Bot Mode.

---

## Phase 1 — Liveness (~2–3 days)

A phone suspends; desktop does not. This is the systemic theme behind the
largest cluster of ⭕ rows, and it produces *wrong state*, not missing
features — a bot can appear to spin forever because the turn finished while
the app was backgrounded.

1. **Foreground re-seed** — on `scenePhase == .active`, call
   `session.active_list` and reconcile: clear working state for turns that
   ended, re-attach ones still running, refresh the roster.
2. **Reconnect nudge on network restore** — `NWPathMonitor` triggers an
   immediate reconnect instead of waiting out the backoff.
3. **Runtime reaper** — a bot marked working with no live session and no
   events for N seconds gets cleared rather than spinning forever.
4. **Reconnect grace, verified live** — kill the socket mid-turn and confirm
   the ~20 s park/reattach path and `inflight` replay actually work. Built,
   never exercised.
5. **Stop button on voice turns** — voice submits via `send` rather than
   `sendOrSteer`, so a voice-started turn has no stop control (known,
   deliberately deferred).

---

## Phase 2 — Settings (~3–4 days)

Desktop has **202 discrete settings controls**; Talaria has no settings screen
at all. That single absence is ~17% of the entire audit gap, and it is one
decision rather than 130 features.

The goal is **not** 202 controls on a phone. It is one Settings screen with
the controls a phone-first operator actually reaches for, and honest pointers
to desktop for the rest:

- **Gateways** — the connection registry (exists in Connections; move/merge).
- **Appearance** — themes (exists), plus text size and reduce-motion.
- **Notifications** — the card that exists, plus per-kind prefs wired to the
  relay's `profile_filter`.
- **Models & providers** — default model, reasoning effort, API keys
  (`model.save_key`), provider connect/disconnect.
- **Voice** — input/output device behavior, TTS on/off, wake settings.
- **Privacy & data** — what's stored on device, Keychain contents, sign out,
  clear cache, delete local data.
- **About & diagnostics** — versions, gateway contract, logs, "report an
  issue" bundle.

Explicitly *not* on mobile: env-var editing, config.yaml raw editing, storage
paths, update channels — those get a "manage on desktop" pointer.

---

## Phase 3 — Managing the fleet (~4–5 days)

The audit's other big theme: Talaria reads and answers well, but cannot
administer. Ordered by how often a phone-first operator needs it.

1. **Cron editing + run history** — create/edit/delete schedules and see what
   a routine actually did. Currently list + toggle only.
2. **Session management** — pin, archive, rename, delete, and a real
   sessions-per-bot browser (the sheet exists; the verbs mostly don't).
3. **Approvals depth** — pattern allowlists, approval modes
   (manual/smart/off), and the pairing-approval queue.
4. **Artifacts** — a genuine outputs index with preview and share-sheet
   export, rather than the derived list.
5. **Credentials & pairing** — messaging-platform pairing approvals, which
   today can only be done from desktop or CLI.

---

## Phase 4 — Bot Mode depth (~4–5 days)

The parts of the plugin that make it feel like a fleet rather than a list.

1. **A2A / Agent Inbox for real** — cross-profile handoffs with attribution,
   @mention routing between bots, and the compose path.
2. **Multi-gateway roster** — one roster spanning Connections, with
   `name-device` handle disambiguation and per-row connection labels.
3. **Bot cosmetics round-trip** — write `ui_meta["hermes-bots"]` back (title,
   shape, color) so phone edits show up on desktop; today we only read.
4. **Avatar generation** — `image.generate` → `profiles.set_asset` portraits.
5. **Roster craft** — the plugin's ordering/ranking rules, "active in the last
   90s", unread semantics, and the entrance/idle motion detailed in the
   BOT-MODE-PARITY design notes.

---

## Phase 5 — Solo mode (~1 week)

Per [SOLO-MODE.md](SOLO-MODE.md), already agreed: Apple Foundation Models as
the default on-device tier, MLX as the power path, Portal as serverless, a
small iOS-permitted tool set, and the explainer GUI that shows exactly what
you get locally versus with a gateway. Sequenced last because it is additive —
it makes Talaria useful *without* a gateway, but it does not make Talaria
correct *with* one.

---

## Never (the mobile ceiling)

From the audit's 189 n/a-mobile rows — recorded so nobody re-opens them:
embedded shell/PTY terminals, HUD/quick-entry/pet-overlay windows, global
shortcuts, git operations, external-terminal launch, find-in-page,
auto-update, local backend spawning, VS Code theme import. iOS has no
`fork`/`exec` and no multi-window desktop; where an analogue exists (Shortcuts
for automation, share sheet for export) it is named in
[PARITY.md](../PARITY.md#mobile-ceiling).

---

## Sequencing rationale

- **0 before everything** — the history bug silently forks sessions. Every
  day it ships, real conversations get orphaned.
- **1 before 2** — a settings screen that toggles things while the roster
  shows stale state is polish on a broken foundation.
- **2 before 3** — settings is one bounded screen that closes the single
  largest counted gap and gives 3's features somewhere to live.
- **3 before 4** — administering the fleet you have beats enriching how the
  fleet talks to itself.
- **5 last** — additive, and it deserves the explainer GUI done properly
  rather than rushed.

## Decisions (settled 2026-08-18)

1. **Settings scope — as proposed.** No raw config/env editing on device: you
   can just *ask a bot* to make config changes, which is a better mobile
   affordance than a text editor for YAML. Mobile settings stay the controls a
   phone-first operator reaches for; everything else points at desktop.
2. **Phase 3 before Phase 4 — unchanged.**
3. **Cosmetics round-trip — yes, write back.** Phone edits write
   `ui_meta["hermes-bots"]` so desktop sees them, matching desktop's own
   merge semantics (server block authoritative, local-only fields preserved).
   This moves into Phase 0 alongside reading the canonical-chat pin, since
   both touch the same block.
4. **Session verbs — mostly a desktop concern.** The canonical forever-chat is
   the mobile model. Pin/archive/delete land as a tucked-away *power-user*
   surface (long-press in the sessions sheet), never as primary navigation.

# Plan — 1:1 with the Bot Mode plugin

**Status: proposed, awaiting review. Nothing here is implemented.**

Target: [`apps/desktop/src/plugins/hermes-bots/plugin.js`](../../hermes-agent-upstream/apps/desktop/src/plugins/hermes-bots/plugin.js),
8,323 lines, audited row-by-row in [BOT-MODE-PARITY.md](BOT-MODE-PARITY.md).
Written 2026-08-18, after the overnight run and a live verification session
against a real gateway.

## Where we actually are

| Region | Rows | ⭕ | 🔶 | ✅ | ➖ |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1. Roster rows | 73 | 26 | 34 | 8 | 5 |
| 2. Bot CRUD, cosmetics, meta | 73 | 24 | 28 | 13 | 8 |
| 3. Canonical chat | 58 | 17 | 29 | 7 | 5 |
| 4. Handles, search, mentions | 54 | 23 | 17 | 3 | 11 |
| 5. A2A + group rooms | 63 | 30 | 15 | 11 | 7 |
| 6. Notifications & activity | 63 | 30 | 15 | 13 | 5 |
| 7. Plugin/shell integration | 59 | 19 | 24 | 5 | 11 |
| **Total** | **443** | **169** | **162** | **60** | **52** |

**~36% of the portable surface** (391 rows once the 52 ➖ are excluded,
counting a 🔶 as half). The shape of that number matters more than the number:

- **162 🔶 are written but unproven.** The overnight run believed no gateway
  was reachable — it was probing loopback while the gateway binds the tailnet
  IP — so everything gateway-dependent was marked partial regardless of
  quality. This is the cheapest parity in the document.
- **169 ⭕ are concentrated**, not spread thin: Region 4 (handles/search/
  mentions) has 3 ✅ of 54, and Region 5 carries **group rooms**, an entire
  unbuilt feature rather than a gap.
- **Region 1 at 8 ✅ of 73** is not a broken roster — the roster works. It is
  that the plugin puts enormous craft into that one screen, and each piece of
  craft is its own row.

**Already landed (do not rebuild):** the canonical forever-chat resolver and
pin write-back, the single `openChat()` door, one identity path
(title + @handle), `include_hidden`, the symmetric `ui_meta["hermes-bots"]`
write with live-block merge, pinning, roster context menu, `MentionField`,
title editing, pets, and the model picker.

---

## Phase A — Prove what exists (1 session, no new features)

The highest parity-per-hour work in this plan, and it needs a phone in hand
rather than an agent.

Drive the app against the live gateway while I promote rows with citations:
open bots and confirm canonical-chat resolution, send and confirm no session
fork, exercise cron CRUD (now that jobs are addressed by `job_id`), approve
something real, rename/recolor a bot and confirm the laptop agrees, fire a
test push, and watch a working bot's pet.

**Expected: 40–60 rows move 🔶 → ✅ without writing a line of code**, and any
that fail become precise bug reports instead of suspicions. Two bugs already
came out of one such pass this morning (cron `job_id`, model provider
routing) — both invisible to review, both instant against real data.

---

## Phase B — Roster craft (~2–3 days)

Region 1's 26 ⭕ / 34 🔶. The roster is the screen you live on, and desktop's
version is doing far more than it appears to.

1. **`preferred_session_ids` round-trip** — the enabling call for the region;
   `profiles.list` can return a `preferred_session` per bot instead of us
   guessing from `last_session`.
2. **Active-now strip** — the 90-second liveness window, as a zero-height-when-
   empty row of faces that never reorders the roster beneath it.
3. **Preview polish** — markdown flattening, A2A prefix stripping, and the
   `🤖 @sender` chip. The audit calls this the highest craft-per-hour item in
   the document.
4. **Avatar motion parity** — the work-pose rule, faster blink while working,
   chin dots, and the ±1.5° idle sway phase-offset per bot.
5. **One shared face clock** — replace per-avatar loops with a single
   `TimelineView` driver, dormant on scene phase and tab. Prerequisite for 4
   being free rather than expensive.
6. **Haptics** on the open paths, in each pack's voice.

---

## Phase C — Handles, search, mentions (~2 days)

Region 4 is the thinnest in the document (3 ✅ of 54) and the most
phone-shaped: typing is expensive on a phone, so search and autocomplete
carry more weight here than they do on a laptop.

1. **Roster search semantics** — desktop's `filterBots`: match on display
   name, profile id, handle, and connection label, narrowing without ever
   re-ranking.
2. **Mention middleware** — typing `@ops fix this` currently sends those
   literal characters to the model. Rewrite in `composedPrompt()` as an
   RPC-shaped handoff, with the fence/inline-code strip and the ambiguity
   refusal.
3. **Mention autocomplete polish** — prefix match on handle, cap 8, the
   `Bot · <displayName>` meta line.
4. **Duplicate-name disambiguation** — the `@name-device` handle form, which
   only becomes real with Phase E but should be correct before it.

---

## Phase D — Notifications & activity (~2 days)

Region 6's 30 ⭕. Mostly about a phone that was asleep catching up correctly.

1. **Roster unread watermarks** — the only model that catches cron, CLI,
   another machine, or anything that happened while the phone slept.
2. **A live toast bus** — today a failed pin, duplicate, or cosmetic save
   produces *no* user-visible feedback in live mode. Optimistic-then-confirm
   pairs across every mutation.
3. **Activity ledger completeness** — every toast mirrored into the feed, so
   the Activity tab is a real log rather than a demo artifact.
4. **Notification copy + routing parity** with the plugin's own strings.

---

## Phase E — Group rooms (~4–5 days)

Region 5's headline: **the single biggest unbuilt feature in Bot Mode.** A
room with several bots, a shared log, deterministic `@mention` turn selection,
≤3 rotated round-robin rounds, `(pass)` as silence, per-member watermarks, a
`needs you` badge, composite avatars, and hidden member sessions.

Worth its own phase because it is the one place where "Bot Mode on a phone"
could beat the desktop: a group of agents in your pocket is a better fit for a
phone than for a tiling window manager. Prerequisites: the canonical-chat
resolver (done), mention middleware (Phase C).

---

## Phase F — Federation (~3–4 days)

The multi-gateway union roster: connection chips, `@name-device` handles,
second-class foreign rows, cross-connection delivery and reply relay. Today
Talaria switches gateways on tap rather than holding several live links.

Deliberately last: it multiplies the state space of everything before it, and
it is only valuable once the single-gateway experience is genuinely good.

---

## Ceiling — what 1:1 cannot mean

52 ➖ rows, recorded so nobody chases them: desktop's row-level hover
affordances (no hover on a phone), the pet *desktop overlay* window, global
shortcuts, multi-window session views, and everything routed through Electron
IPC. Where an analogue exists it is named in the audit — hover menus become
long-press, the overlay becomes the roster companion sprite.

---

## Sequencing rationale

- **A before everything.** Promoting 🔶 rows costs nothing and turns
  suspicion into either evidence or a bug report. It also re-baselines the
  percentage honestly before we spend days moving it.
- **B before C.** The roster is where the felt gap is largest; search matters
  most once there are enough bots that scrolling is the wrong answer.
- **D before E.** Group rooms generate exactly the cross-source traffic that
  the watermark and toast work exists to handle.
- **E before F.** Rooms are product; federation is plumbing that makes rooms
  bigger. Rooms are worth more on a phone.
- **F last**, and possibly never at full fidelity — see the note in Phase F.

## Questions for review

1. **Phase A** — worth a real session with the phone, or would you rather I
   keep building and let evidence accumulate incidentally?
2. **Group rooms (E)** — do you actually use them on desktop? If not, E drops
   below F and the plan gets a week shorter.
3. **Federation (F)** — do you run more than one gateway today, or is the
   mini the only one? If it is the only one, F becomes speculative work.
4. **Motion/craft (B4–B6)** — how much do you care about the avatar language
   matching exactly? It is the most visible work and the least functional.

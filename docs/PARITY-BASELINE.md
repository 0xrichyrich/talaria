# Current Hermes parity baseline

This is the authority for new Talaria parity work. The older row-by-row audits
remain useful historical evidence, but their percentages and source citations
are not current until they are regenerated against this baseline.

## Exact authority

- Hermes repository: <https://github.com/nousresearch/hermes-agent>
- Hermes commit: `395c70d616f6426e990632ff8b57cf1e9499702f`
- Talaria baseline: `e5fe2e7633cd4b0cc25034733c405e82efaf3d54`
- Audited: 2026-08-18
- Machine-readable pin and authority-file hashes:
  [`parity/hermes-upstream.json`](../parity/hermes-upstream.json)

Run the local check against an exact Hermes checkout:

```sh
python3 scripts/check_hermes_upstream.py --checkout /path/to/hermes-agent
```

Check whether upstream has moved:

```sh
python3 scripts/check_hermes_upstream.py --remote
```

The scheduled upstream-drift workflow runs the latter check. A failure is a
request to review upstream, not permission to move the pin without an audit.

## What “parity” means

Talaria is Bot Mode first. Its navigation and interaction design remain native
to a phone, while it provides the portable functionality of Hermes Desktop
behind that interface.

A capability is **present** only when all applicable parts are proven:

1. The user can reach and complete it in Talaria.
2. Request and event shapes match the pinned Hermes gateway.
3. Durable state survives relaunch and gateway reconnect where Desktop state
   is durable.
4. Errors and partial delivery are visible; failures never masquerade as
   successful delivery, a room pass, or a completed mutation.
5. Focused automated behavior tests pass.
6. Gateway-dependent behavior has been exercised against a real compatible
   gateway. Source review or the existence of an RPC wrapper alone is partial.
7. Background-sensitive behavior has real-device evidence before it is called
   complete.

Platform-specific presentation may differ. Device-local Desktop mechanisms
such as Electron window placement are not copied literally, but a portable
user capability is not “n/a” merely because the Desktop interaction cannot be
copied. For example, local terminal and filesystem UI become secure remote
gateway controls on iOS.

## Current honest status

The 2026-08-17 Desktop audit measured 30% covered portable behavior. Subsequent
Talaria work improved several Bot Mode areas, but it was developed against an
older Hermes snapshot and current upstream expanded materially. There is no
defensible newer percentage until the granular ledgers are regenerated.

The current implementation is best described as a mobile Hermes client with
substantial Bot Mode support, not a 1:1 client. The largest correctness gaps
are the remaining multi-connection management surfaces and group rooms:

- Talaria retains authenticated clients for multiple gateways and routes chat,
  events, sessions, full approval recovery/prompts, and unread state by source.
  Routine listing, detail/history, create/edit/run/delete, and toggles are also
  routed. Capabilities and several other management mutations remain primary-only.
- Talaria's in-flight room work models one group per bot; current Hermes uses
  multiple memberships and standalone rooms.
- Foreign room members are not yet delivered through their owning connection.

## Delivery ledger

Every item below ships as one or more independently reviewable PRs. A checked
item means the behavior contract above is satisfied, not merely that code was
written.

- [x] Pin the exact current Hermes authority and automate upstream drift detection.
- [ ] Regenerate both granular ledgers from the pinned source and stabilize the
      crash-recovery work as reviewable, tested slices.
- [ ] Replace global gateway switching with a managed multi-connection pool and
      source-qualified state, events, sessions, and mutations.
- [ ] Migrate group metadata to multiple memberships and standalone room identities.
- [ ] Implement cross-machine room delivery, explicit failure semantics,
      attachments, threads, and stranded-reply recovery.
- [ ] Close current Bot Mode gaps: roster hiding, avatars, remote creation,
      target capabilities, mentions, routines, canonical chats, and profile lifecycle.
- [ ] Add rich transcripts and full session interaction controls.
- [ ] Add mobile management for providers, models, profiles, tools, skills, MCP,
      plugins, routines, messaging, memory, and agents.
- [ ] Add gateway-backed files, artifacts, projects, git, terminal, and command-center UI.
- [ ] Finish push, background, offline, reconciliation, and capability/version reliability.
- [ ] Certify the complete matrix against the pinned gateway and document only
      the remaining true platform exceptions.

Multi-connection implementation checkpoints:

- [x] Canonical source-qualified bot identity with fail-closed bare-name resolution.
- [x] Coalescing, retryable authenticated client pool shared by primary and
      secondary roster connections.
- [x] Source-qualified canonical chat state, streaming/tool events, and runtime
      session routing, including colliding short session ids.
- [x] Open, send, steer, stop, react, and change session controls for foreign
      bots without changing the primary connection.
- [x] Source-qualified stored-session list/open/rename/delete/branch/compress/
      export/search and title events, with collision-safe caches.
- [x] Source-qualified unread events, durable roster watermarks, badge clearing,
      and gateway-role transitions, including colliding profile names.
- [x] Source-qualified approval request identity, pending replay,
      acknowledgements, full-choice responses, and clarify/sudo/secret prompts.
- [x] Source-qualified routine roster, cron.changed refresh, safe legacy-job
      quarantine, and pause/resume routing.
- [x] Source-qualified routine detail/history/create/edit/run/delete with
      gateway-scoped REST credentials, caches, delivery targets, and transcripts.
- [ ] Source-qualified capabilities and remaining management mutations.

## Crash-recovery snapshot disposition

Commit `3139626a73b2e41bce0c3ef6e5dfa15b0817f5c6` is recovery material, not an
integration branch. It diverged from the Phase B baseline while independently
carrying versions of work that later landed through the reviewed Phase C and D
PRs. It must never be merged or cherry-picked wholesale.

- Phase C handles, search, and mentions already landed on `main`; their reviewed
  versions are authoritative.
- Phase D notifications, activity, unread state, and forever-chat protection
  already landed on `main`; their reviewed versions are authoritative.
- The snapshot's singular `group` room model is rejected because current Hermes
  uses multiple memberships and standalone rooms. Room work starts from the
  pinned upstream contract, not from that data model.
- Avatar/cosmetic pieces that are not already on `main` may be extracted later
  only after comparison with current Hermes blob-avatar behavior.
- No parity row moves merely because the snapshot contains an implementation.

CI now runs both the portable `talaria-verify` executable and individually
named XCTest cases. New pure behavior belongs in `TalariaKit` with focused
XCTest coverage; gateway and lifecycle slices add integration fixtures before
their status can move to present.

## Merge rule

Runtime PRs merge in dependency order. Each PR must identify the ledger rows it
moves, include focused tests, pass repository CI, and state any gateway/device
evidence still needed. Upstream drift is resolved before claiming new parity.

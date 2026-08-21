# Hermes `c1e25cad` parity delta

This is the requirement ledger for the audited move from Hermes
`b5455fdd16fe608214f91149233660e1836b067c` through
`9ef9b2d2d01eb4bcf9420973c5ef6c98f2176455` and then
`c1e25cadffe539b058816be5fdfc9127d7199fa4`. It supplements the older
row-by-row ledgers; when they disagree, this exact-source delta is newer.

The authority hashes live in [`parity/hermes-upstream.json`](../parity/hermes-upstream.json).
An implementation row is not certified merely because it is checked below:
the evidence column names the remaining gateway or device proof explicitly.

## Current-source corrections

| Contract | Talaria disposition | Automated evidence | Remaining certification |
|---|---|---|---|
| Canonical Bot Chat adopt-before-mint, preferred-session tri-state, exact root title, one hydration-timeout retry | Implemented on the `codex/hermes-9ef9-parity` branch. Ordinary newest sessions are never grandfathered; stale preferred replies cannot replace a newer server pin. | `BotModeRuntimePolicyTests`, preferred-session protocol checks, source-qualified routing tests | Real primary and foreign profiles: existing exact chat, renamed history pin, empty stray pin, omitted/malformed/null preferred result, one timeout then success |
| Friendly renamed mentions | Implemented. Bot Mode title and raw core `display_name` both remain accepted; legacy handles, including the default agent, remain routable; reserved friendly aliases cannot claim broadcast/user words; exact forms win before collapsed ambiguity. Room members retain both identities. | Mention/handle protocol checks, `RoomEngineTests`, `BotModeRuntimePolicyTests` | Two gateways with colliding friendly, collapsed, and legacy forms; roster disappearance and relaunch |
| Preferred/last conversation activity plus worker-session liveness | Implemented. Conversation activity alone controls unread/ranking; a valid worker stamp contributes live presentation for 150 seconds and display age without reordering. | Preferred-session checks and `BotModeRuntimePolicyTests` | Real worker child session, clock-skew/future stamp, remote gateway row |
| Roster Hide/Unhide | Implemented as display-only `ui_meta["hermes-bots"].hidden`. Unhide writes literal `false`; hidden rows retain mentions, rooms, polling, and unread but do not emit activity toasts. Show Hidden is session-local and dims inspection rows. | Cosmetics protocol checks and `BotModeRuntimePolicyTests` | Desktop/mobile round trip, hidden unread arrival, failed write rollback |
| Hidden room-member clarification and approval | Implemented as runtime-only prompt state rebuilt from `session.resume`. Clarify wins when both fields exist; cards use the exact room/member/runtime/request identity and owning gateway. Approval requires a positive resolved count. Batch answers are sequential, resume accepted locks from `pending_clarify.answers`, and never resend locked questions. | `RoomPendingPromptTests`, `RoomRoutingTests` | Cross-gateway approval and single/multi-select/batch clarify; partial batch relaunch; desktop resolves first; 20-minute hard cap |
| Room pending deadline/recovery | Implemented. A blocked non-running session cannot become a pass. Busy or awaiting-user state extends the sliding 180-second deadline up to the 20-minute hard cap; the cap clears transient prompt UI while leaving durable timed-out work for later harvest/re-mirroring. | `RoomRoutingTests` | Background/relaunch near both deadlines; rename, member removal, and disband while a prompt is open |
| Immutable room member-session identity | Implemented with the durable Talaria `RoomID`, independent of the editable room name. Rename preserves identity; delete and same-name recreation mint a different identity and cannot resume the deleted room's title-based sessions. Existing durable session IDs remain first authority and legacy name-titled rooms retain an explicit migration fallback. | `RoomRoutingTests` | Rename and same-name recreation against real primary and foreign profiles |
| Source-qualified slash commands | Implemented. Catalog/completion/resolve caches are per physical gateway; `slash.exec` captures the client and session that own the selected bot and connection generation. Typed output/send/skill/prefill/alias results are decoded without an unsafe unconditional `command.dispatch` fallback. Follow-up send failure retains a recoverable draft without replaying the first RPC. | `SourceQualifiedRoutingTests` | Two live gateways with the same runtime session id; supported structured results; plugin/quick-command collision remains rejected |
| Source-qualified MCP setup prompts | Implemented with `(gateway, request_id)` identity, secondary event routing, exact-source expiration and response. | `SourceQualifiedRoutingTests` | Same request id on two live gateways and one expired response |
| Profile-scoped Projects | Implemented against current `projects.discover_repos`, `projects.tree`, and `projects.project_sessions`. Every read/write carries the verified raw profile; discovery uses `scan:true` and completes before tree hydration. Same-gateway client replacement and profile lifecycle invalidate authority. Partial or saturated trees fail closed. | `WorkspaceProjectsProfileScopeTests`, `WorkspaceCommandCenterTests` | Two profiles with colliding project ids; zero-session remote repo scan; profile rename/delete during mutation |

## Portable current-Hermes work still open

| Surface | Status / next proof |
|---|---|
| Gateway PTY | Missing. Hermes now provides authenticated `/api/pty` with profile/session binding, opaque reattach tokens, bounded replay, resize, native approvals, and disconnect survival. A mobile Advanced Terminal is portable on supported gateway hosts and is not a desktop-only exception. |
| Projects filesystem | Blocked upstream for safe mobile use: `/api/fs` does not return authoritative resolved-target/root containment proof and writes have no atomic expected-hash/`If-Match`. Talaria must remain fail-closed rather than provide best-effort editing. |
| Unknown explicit Project profile | Hermes currently falls back to the launch profile. Talaria revalidates the selected route immediately before writes and fails closed, but Hermes should reject an explicit unknown profile. |
| Rich transcript parity | Partial: markdown, tables, code, quiet/advanced tools, working avatar, transcript actions, and jump-to-bottom exist. Persistent multimodal parts, inline generated images/lightbox, grouped live tool runs, diff/ANSI/search/math/diagram, per-message TTS, whole-turn timing, branches, tour/activity, and durable prompt queue remain. |
| Management parity | Partial: provider/model/profile/capability/routine/memory/voice/operator surfaces exist. Messaging platform/webhook lifecycle, subagent tree/live tail/files/cost, learned-memory curation, profile import/export, MCP per-server logs, auxiliary/vision slots, and MoA administration remain. |
| Git/System depth | Partial: core review and guarded mutations exist. Base/commit/ship context, dirty-worktree recovery, worktree-session integration, usage periods/daily/model/skill detail, and multi-gateway backend update orchestration remain. |
| Artifact completeness | Recent derived gallery only. Exact provenance/fetching is source-qualified, but discovery is bounded and needs retained-gateway fan-out plus explicit incomplete/cursor state. |

## True platform exceptions

These are genuinely local Desktop behaviors and are not copied literally:

- Finder/Explorer reveal and native path pickers for the gateway host.
- Electron titlebar, placement, HUD, always-on-top, translucency, and local
  multi-window management.
- Launching a separate desktop terminal emulator or locally spawning backends.
- Replacing Talaria's signed binary; App Store/TestFlight owns iOS app updates.
- Native Windows PTY when the gateway itself has no supported PTY backend.

Remote Git, Projects, gateway maintenance, and the authenticated gateway PTY
are portable mobile equivalents, not exceptions.

## Certification still required

- Exact `c1e25cad` gateway or a documented compatible release, plus a second
  gateway for collision and detach tests.
- Real-device long-thread, background/foreground, Wi-Fi/cellular handoff,
  queued-send, room prompt, attachment, and reduced-motion checks.
- Debug APNs real events (approval, response, mention, routine, interrupted
  negative and profile filter), then the same production matrix from a
  TestFlight build after the Skynet Ventures account is provisioned.
- A supervisor that outlives the gateway for honest offline/recovered push;
  a sidecar on the same failed host is not sufficient evidence.

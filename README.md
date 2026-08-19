# Talaria — Hermes, on foot.

Talaria (the winged sandals of Hermes) is a native iOS client for
[Hermes Agent](https://github.com/NousResearch/hermes-agent). It is not a
second brain and it holds no state of its own — it is a **window onto the bot
roster already running on your `hermes serve` gateway**. Every bot is a Hermes
profile (`~/.hermes/profiles/<name>/`); Talaria shows you the same roster as
Hermes Desktop's Bot Mode, streams the same sessions over the same
`/api/ws` JSON-RPC surface, and puts approvals, routines, and voice in your
pocket.

Parity claims are pinned to an exact Hermes revision and use behavior-based
completion rules. See the [current parity baseline](docs/PARITY-BASELINE.md);
older percentages in the granular audits are historical until regenerated.

> **Status:** early but runnable. The protocol client, auth stack, connections
> registry, theme engine, live-mode state wiring, the Live Activity / push
> pipelines, and all twelve screens from the design prototype (Roster, Chat,
> Approvals, Activity, Agent Inbox, Artifacts, Bot sheet, Create bot,
> Routines, Connections, Onboarding, Voice) are ported and build clean for
> iOS. Demo mode is fully interactive; live-gateway mode is wired end-to-end
> but not yet soak-tested against a production gateway. The honest,
> per-feature map is [PARITY.md](PARITY.md).

## Features

The six things Talaria is for (matching the landing page):

1. **Approvals with teeth** — bots block before anything risky leaves: an
   outbound email, a shell command, a public post. Approve or deny from your
   phone; the blocked run resumes instantly. Swipe right to approve, left to
   deny.
2. **Routines on cron** — per-bot schedules backed by Hermes cron
   (jobs namespaced `[bot:<name>]`). Runs land in that bot's own chat.
3. **The Agent Inbox** — bot-to-bot traffic in one attributed feed. See your
   researcher hand findings to your comms bot, and @mention any bot yourself.
4. **Live Activity** — while any bot works, its avatar and a live elapsed
   timer sit in the Dynamic Island. Tap to jump into the chat.
5. **Voice, hands free** — talk to a bot straight from the composer, using the
   gateway's own voice mode.
6. **Any gateway, anywhere** — Tailscale, LAN, or Hermes Cloud. Named
   connections with live health, just like desktop's Connections registry.

And the roster ships with personality: geometric shape × hue avatars with
blinking eyes that scan while the bot works.

## Screenshots

*(Coming with the first TestFlight build — Roster, Chat, swipe Approvals, and
the three themes.)*

## Install

### App Store

TBD — Talaria will ship on the App Store once the screens stabilize. Until
then, build from source.

### Build from source

Requirements: **Xcode 16+** on macOS, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the Xcode project is generated, not checked in).

```sh
brew install xcodegen
git clone https://github.com/0xrichyrich/talaria.git && cd talaria
make ios
```

**Testing it on your own iPhone, or against your own gateway?**
[TESTING.md](TESTING.md) is the guide — device signing with your own team and
bundle id, the three ways to authenticate, wireless installs, push setup, and
what to include in a bug report.

`make ios` runs `xcodegen generate` in `ios/` and builds the `Talaria` scheme
for the iOS Simulator. To work on the non-UI core without Xcode project
generation:

```sh
cd Packages/Talaria
swift build            # compiles TalariaKit / TalariaTheme / TalariaUI for macOS too
swift run talaria-verify   # protocol conformance checks, no XCTest needed
```

## Connect your gateway

Talaria talks to any `hermes serve` gateway it can reach. The typical setup is
a box on your tailnet:

```sh
# on the machine that runs your bots
hermes serve --host 0.0.0.0        # binds the /api/ws JSON-RPC + REST surface
```

Then in Talaria's onboarding (or Connections → Add gateway), paste the URL —
e.g. `http://100.84.12.9:9119`. Three ways to authenticate, mirroring Hermes
Desktop:

| Option | When | How it works |
|---|---|---|
| **Session token** | Loopback / fully trusted networks | Paste the dashboard session token. REST uses the `X-Hermes-Session-Token` header; the WebSocket dials `?token=`. |
| **Sign in with Nous Research** | Gated gateways (any non-loopback bind) | Native OAuth (RFC 8252 PKCE): system browser → `auth/native/authorize` → loopback redirect on the phone → token redeem. WebSockets then use single-use 30 s tickets from `POST /api/auth/ws-ticket`. Also works with a self-hosted OIDC IdP. |
| **Username & password** | Trusted LAN / tailnet | The gateway's built-in basic-auth provider, brokered through the same native flow. |

Tokens live only in the iOS Keychain. Your data stays on your gateway — no
Talaria account, no telemetry, no middleman.

## Themes

One app, three souls — full token *and copy* packs, switchable at runtime:

- **Soft** — warm, rounded, friendly. The messenger you already know.
- **Control** — OLED phosphor telemetry. Approvals become *Holds*; approve
  becomes *RELEASE*.
- **Ink** — parchment, seals, familiars. Approvals become *The Seals*; approve
  becomes *grant the seal*.

## Demo mode

Onboarding offers **“Explore with demo data”**: a canned six-bot roster with
scripted replies, pending approvals, routines, and simulated pushes — the full
app experience with no gateway required (and what App Review sees). Demo
content mirrors the design prototype's data shapes one-for-one.

Also in progress, for when you have no gateway at all: **gatewayless chat**
via Nous Portal direct inference (the CLI's device-code sign-in, streaming
completions) and fully offline **on-device models** (MLX, in the optional
`Packages/TalariaLocal` package). No bots, tools, or approvals on these paths
— just chat.

## Repository layout

| Path | What lives there |
|---|---|
| `Packages/Talaria/` | The Swift package: `TalariaKit` (gateway protocol client, auth, models, demo data), `TalariaTheme` (the three theme packs + avatar language), `TalariaUI` (screens + `AppModel` state tree + live wiring), `talaria-verify` (protocol checks). No third-party dependencies. |
| `Packages/TalariaLocal/` | Optional on-device inference (MLX + Hugging Face hub), deliberately quarantined in its own package so the main app stays dependency-free unless the user opts in. |
| `ios/` | XcodeGen app shell: `project.yml` (app + `TalariaWidgets` Live-Activity extension + `TalariaNotificationService` extension), resources (app icon, bundled fonts). `Talaria.xcodeproj` is generated, never committed. |
| `relay/` | Gateway-side APNs push-relay plugin (`talaria-push`): approvals as actionable critical alerts, routine/mention/long-task pushes. *In progress — config, device registry, and the APNs HTTP/2 client have landed; event fan-out and the sidecar are next.* |
| `docs/` | Engineering docs, starting with [ARCHITECTURE.md](docs/ARCHITECTURE.md). |

Contributions map to rows in [PARITY.md](PARITY.md) — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

Talaria is released under the **[MIT License](LICENSE.md)**: free to read,
compile, run, modify, fork, and redistribute. The Talaria name, wing mark,
and app icon are excluded from the license — rename your forks. All
contributions require a [DCO](DCO) sign-off (`git commit -s`).

The agent runtime underneath, [hermes-agent](https://github.com/NousResearch/hermes-agent),
is MIT from day one. Talaria speaks its `/api/ws` surface as-is; protocol
changes belong upstream.

## Source

Public home: <https://github.com/0xrichyrich/talaria> (source of truth), synced
into Cursor Origin at <https://cursor.com/codebase/richyrich/talaria>

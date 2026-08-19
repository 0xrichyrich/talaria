# Testing Talaria

Thanks for trying this. Talaria is young and moving fast — this guide gets you
from clone to a working app against your own gateway, and tells you honestly
what to expect when you get there.

**You need:** macOS with **Xcode 16+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a reachable **`hermes serve`** gateway. Push
notifications additionally need a paid Apple Developer account; everything
else works with a free one.

---

## 1. Simulator (fastest — no Apple account needed)

```sh
git clone https://github.com/Skynet-Ventures/talaria.git && cd talaria
make ios
```

That runs `xcodegen generate` in `ios/` and builds the `Talaria` scheme. Open
`ios/Talaria.xcodeproj` and run, or build straight from the command line:

```sh
cd ios
xcodebuild -project Talaria.xcodeproj -scheme Talaria \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build -quiet build CODE_SIGNING_ALLOWED=NO
```

The Simulator can reach a gateway on your LAN or over Tailscale, so this is a
real test, not a toy one. Onboarding also offers **“Explore with demo data”**
if you just want to look around without a gateway.

## 2. Your own iPhone

The project's default bundle id belongs to this repo's author, so **use your
own** — pass `TALARIA_BUNDLE_ID` and your Apple team id:

```sh
cd ios && xcodegen generate
xcodebuild -project Talaria.xcodeproj -scheme Talaria \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -allowProvisioningUpdates build \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=YOURTEAMID \
  TALARIA_BUNDLE_ID=com.yourname.talaria \
  CODE_SIGN_ENTITLEMENTS=Talaria/Support/Talaria-dev.entitlements
```

Your team id is in [developer.apple.com/account](https://developer.apple.com/account)
under Membership.

**Why `Talaria-dev.entitlements`:** the full entitlements file declares an App
Group, which CLI automatic signing cannot provision. The dev variant drops it
and keeps push. The only casualty is a theme lookup the widget makes through
the shared container, which falls back gracefully.

Install and launch:

```sh
xcrun devicectl list devices        # find your device id
xcrun devicectl device install app --device <DEVICE_ID> \
  build-device/Build/Products/Debug-iphoneos/Talaria.app
xcrun devicectl device process launch --device <DEVICE_ID> com.yourname.talaria
```

First run needs the phone plugged in and unlocked, and you must tap **Trust**.
After that pairing sticks and **you can install over Wi-Fi** — same commands,
no cable, as long as both machines are on the same network.

Also: on the phone, enable **Settings → Privacy & Security → Developer Mode**.

## 3. Connecting to your gateway

Run the gateway where your bots live. Bind it somewhere the phone can reach —
loopback will not do:

```sh
hermes serve --host 0.0.0.0 --port 9119       # or your Tailscale IP
```

In onboarding (or Connections → add gateway) enter the URL, e.g.
`http://100.x.y.z:9119`. Three ways in, matching Hermes Desktop:

| Mode | When | How |
| --- | --- | --- |
| **Session token** | loopback / fully trusted | paste the dashboard session token |
| **Sign in with Nous Research** | any non-loopback bind (gated) | in-app OAuth (RFC 8252 PKCE) |
| **Username & password** | trusted LAN / tailnet | the gateway's basic-auth provider, same in-app flow |

Sign-in runs in an **in-app web sheet**, not Safari. That is deliberate:
Lockdown Mode blocks `http://` on non-standard ports, which breaks the
loopback redirect the standard flow depends on. The sheet intercepts the
callback before any socket is dialed, so sign-in works with Lockdown Mode on.

Tokens live only in the iOS Keychain. There is no Talaria account and no
server of ours in the path — your phone talks to your gateway.

## 4. Push notifications (optional)

Push needs a gateway-side relay, since hermes-agent has no APNs support
upstream. It ships here: [`relay/`](relay/). You will need an APNs `.p8` key,
its Key ID, and your Team ID. Follow [`relay/README.md`](relay/README.md),
then in the app: **Connections → Notifications → Enable → Send test push**.
That card shows every link in the chain (iOS permission → APNs token → relay
registration), so you can see exactly where it breaks.

---

## What to expect

Talaria is **Bot Mode on a phone** — a roster of your Hermes profiles, each
with one forever-chat — not a session manager. If it starts feeling like a
list of sessions, that is a bug.

Roughly a third of Hermes Desktop's Bot Mode surface is implemented, tracked
row by row in [docs/BOT-MODE-PARITY.md](docs/BOT-MODE-PARITY.md) with the plan
in [docs/BOT-PARITY-PLAN.md](docs/BOT-PARITY-PLAN.md). Broad desktop parity
lives in [PARITY.md](PARITY.md).

**Works today:** the roster, chat with streaming, reasoning ("Thought") blocks,
tool chips, block markdown, approvals with the full choice set, model picker
grouped by provider, sessions, cron, capabilities (skills/MCP/toolsets), voice,
attachments, slash commands, pets, three themes, Live Activity.

**Known rough edges:** group rooms are unbuilt; a phone that sleeps mid-turn
can briefly show a bot as still working; several surfaces are implemented but
have never met a live gateway, so please report anything that looks
confidently wrong.

## Reporting a bug

A screenshot plus these four things makes almost any report actionable:

1. **What you did** and what you expected.
2. **Device + iOS version**, and whether **Lockdown Mode** is on.
3. **Gateway**: `hermes --version`, how it is bound (loopback / LAN /
   Tailscale / cloud), and which auth mode you used.
4. **Anything in the gateway log** (`~/.hermes/logs/serve.log`) around the
   time it happened.

Please redact tokens, `.p8` contents, and gateway URLs you would rather not
share publicly. If it is a **security** issue — auth, Keychain, the approval
path, or the relay — do not open a public issue; see
[SECURITY.md](SECURITY.md).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the details. The short version: commits
need a DCO sign-off (`git commit -s`), the Xcode project is generated so never
commit `Talaria.xcodeproj`, and features should map to a row in the parity
docs. Protocol changes belong upstream in
[hermes-agent](https://github.com/NousResearch/hermes-agent) — Talaria speaks
its `/api/ws` surface as-is.

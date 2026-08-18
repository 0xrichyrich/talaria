# Contributing to Talaria

Thanks for helping build the native iOS window onto Hermes. Talaria is a
companion client for [Hermes Agent](https://github.com/NousResearch/hermes-agent):
the agent runtime stays upstream; this repo is the Swift app plus the small
gateway-side push relay plugin.

## Ground rules

- **License**: Talaria is released under the [MIT License](LICENSE.md). By
  contributing, you agree your contribution is licensed under the same terms.
- **DCO sign-off required**: every commit must carry a `Signed-off-by:` line
  matching the commit author (`git commit -s`). This certifies the
  [Developer Certificate of Origin](DCO). PRs with unsigned commits will be
  asked to rebase. The DCO is what keeps the project's chain of title clean,
  so it is not optional.
- **Parity first**: feature work should map to a row in [PARITY.md](PARITY.md)
  (Hermes Desktop parity) or to one of the mobile-native extras listed there.
  If you want to add something outside that map, open an issue first.
- **Protocol changes belong upstream**: Talaria speaks the `hermes serve`
  `/api/ws` surface as-is. If a feature needs a new gateway RPC or event,
  propose it in hermes-agent — don't fork the protocol here.

## Development setup

1. Xcode 16+ with the iOS 18 SDK (Live Activities require an iOS 16.1+
   deployment target; Talaria targets iOS 17).
2. `brew install xcodegen` and run `xcodegen generate` in `ios/` to produce
   `Talaria.xcodeproj` (the project file is generated, not checked in).
3. A running gateway to test against: `hermes serve` from the upstream repo,
   on the same LAN or over Tailscale.
4. Push notifications and Live Activities require a paid Apple Developer
   membership and real devices; everything else works in the Simulator.

## Style

- Swift 6 language mode, strict concurrency. SwiftUI for all UI.
- No third-party dependencies without discussion — the client is deliberately
  thin (URLSession WebSockets, Keychain, ActivityKit, WidgetKit).
- Theme work goes through the token packs in `Sources/TalariaTheme` — never
  hard-code a color or font in a screen.

## Reporting security issues

Do not open public issues for vulnerabilities in auth, token storage, or the
push relay. See [SECURITY.md](SECURITY.md).

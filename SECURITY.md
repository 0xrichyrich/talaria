# Security Policy

Talaria handles gateway credentials (Nous Portal OAuth tokens, gateway
usernames/passwords) and can approve agent actions remotely. Treat every bug
in auth, Keychain storage, the approval path, or the push relay as
security-sensitive.

## Reporting

Email **security@talaria.bot** with details and
reproduction steps. Please do not open public issues or PRs for
vulnerabilities. We aim to acknowledge within 72 hours.

## Scope notes

- Tokens and passwords are stored only in the iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlock`), never in UserDefaults, files, or
  logs.
- The app talks only to gateways the user registers and to Nous Portal for
  OAuth/inference. There is no Talaria-operated backend; push relays are
  self-hosted alongside `hermes serve` by whoever runs the gateway.
- Approval pushes are actionable; anything that could let a third party forge
  an approval-request notification or an approve/deny RPC is critical.

Vulnerabilities in the agent runtime itself belong upstream:
https://github.com/NousResearch/hermes-agent/blob/main/SECURITY.md

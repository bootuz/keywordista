# Security Policy

## Threat model in one paragraph

Keywordista is a single-user macOS tool whose Vapor server binds to `127.0.0.1` only. The threat model is "anything else running on this machine has equivalent access" — the SQLite database, the keychain, the user's home directory, and the dashboard endpoints are all reachable by any process running as the user. There is no bearer-token authentication on the API, deliberately, because it would not raise the bar against the realistic attacker.

What we *do* care about:
- A malicious **website** could try to fetch `http://127.0.0.1:8080/api/v1/...` from a user's browser tab and trigger state-changing requests. Same-origin policy blocks reading responses; CSRF risk is low because Keywordista has no auth cookie to forge against, but we'd still want to know about exploitable cross-origin write paths.
- A malicious **App Store Connect / Apple Search Ads credential leak** through the `/api/v1/settings/...` endpoints would be a real concern — those endpoints return credential status (no secrets) but accept secrets on `PUT`.
- A **dependency vulnerability** that leaks data outside the loopback or executes arbitrary code is in scope.

## Reporting a vulnerability

Please **don't open a public issue** for vulnerabilities. Use GitHub's private security advisory flow:

➡️ **[Report a vulnerability](https://github.com/bootuz/keywordista/security/advisories/new)**

You can also email `bootuz07@gmail.com` if the advisory flow isn't an option.

When reporting, please include:

- A description of the vulnerability and the version / commit affected.
- Reproduction steps or a proof-of-concept.
- Your assessment of the impact (data exfil, RCE, DoS, etc.).
- Whether you'd like to be credited in the fix.

## What to expect

- **Acknowledgement**: within 7 days.
- **Triage**: a fix plan or "not exploitable in our threat model, here's why" reply within 14 days for issues we accept.
- **Fix**: shipped in the next service release, with a public advisory once the fix is available.

## Out of scope

- Issues that require local code-execution access to the machine already.
- Issues in dependencies that don't have a documented impact path through Keywordista.
- DoS via running the user's own machine out of memory / disk.

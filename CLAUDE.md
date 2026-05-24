# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Keywordista is a single-user, single-machine App Store keyword tracker. It ships as either a macOS menubar app (canonical install) or a self-hosted Docker image. Everything lives in one tree split into three layers, each with its own build system:

| Layer | Path | Build | Output |
| --- | --- | --- | --- |
| Vapor server (Swift) | `Sources/App/` | root `Package.swift` (`swift build`) | server binary |
| Svelte 5 SPA | `web/` | `npm` + Vite | static assets in `Public/` |
| SwiftUI menubar shell | `mac/` | separate `mac/Package.swift` | `Keywordista.app` (wraps the other two) |

The `mac/` SPM package is intentionally separate so the macOS-only SwiftUI deps don't bleed into the cross-platform server build.

## Common commands

```bash
# Day-to-day server + web dev (two terminals)
make dev-backend           # Vapor on :8080 (alias for `swift run`)
make dev-web               # Vite on :5173, proxies /api → :8080

# Single-command launch (builds SPA into Public/, then execs Vapor)
make run                   # alias for ./keywordista

# Build and open the full menubar app (server + SPA + shell)
make open-mac-app

# Tests — CI requires all three green
swift test                              # Swift Testing suite (Tests/AppTests/)
cd web && npm run check                 # svelte-check + tsc strict mode
cd mac && swift build                   # menubar app compiles

# Run a single Swift test (Swift Testing uses --filter on test name)
swift test --filter RefreshServiceTests

# Web + Swift type checks separately
make check-web
make build

# Docker image (server only; menubar app is macOS-only)
make docker-build          # tags keywordista:dev
make docker-smoke          # builds, runs, hits /health, tears down

# Release artifacts
make dmg                   # signed + notarized DMG (releases/)
make dmg-unsigned          # skip signing — fast local validation
```

Release flows for the three artifacts live in `.github/workflows/` (`release-app.yml`, `release-service.yml`, `release-image.yml`) and are triggered by tag pushes (`app-v*`, `service-v*`).

## Architecture: server (`Sources/App/`)

The server follows a strict layered pattern. **Controllers stay slim and call into protocol-fronted services that hold protocol-fronted repositories.** Don't shortcut this by calling Fluent directly from a controller — tests rely on the protocols.

```
Controllers/   ←  thin HTTP shells, call services
  └── Services/      ←  business logic, take repository protocols
        └── Repositories/  ←  Fluent implementations of *RepositoryProtocol
              └── Models/        ←  Fluent models + migrations
```

### Composition root

`Sources/App/Composition/Container.swift` is the single place where concrete dependencies get wired. It hangs factories off `Request` (request-scoped, for controllers) and off `Application` (job-scoped, for `Queues` jobs which only have a `QueueContext`).

When adding a new service:
1. Define a `…ServiceProtocol` next to the concrete type in `Services/`.
2. Add a factory in `Container.swift` — `extension Request { func myService() -> any MyServiceProtocol }`.
3. Controllers/jobs depend on the protocol only.
4. Tests use `Tests/AppTests/Support/InMemoryRepositories.swift` (in-memory `actor` fakes) — follow the existing pattern.

### Database driver routing (load-bearing)

`Sources/App/Composition/DatabaseProvider.swift` chooses SQLite vs Postgres **at runtime** based on `DATABASE_URL`. Both drivers are linked into every build — the choice is purely env-var driven. SQLite-specific tuning (PRAGMAs) is in the provider and a no-op for Postgres. Don't add driver-specific code outside this file.

### Env-var contract (load-bearing)

**All env vars go through `Sources/App/Config/EnvVarManifest.swift`.** Don't read `Environment.get(…)` directly in production code. `Manifest.bootstrap()` runs first in `configure.swift` so missing required vars fail loudly at boot. The contract is mirrored in `docs/env-vars.md` and enforced by `Tests/AppTests/EnvVarManifestTests.swift` + `scripts/check-env-manifest.sh`.

Two runtime modes via `KEYWORDISTA_MODE`:
- `local` — menubar-spawned, 127.0.0.1, no auth. SQLite always.
- `server` — Docker deploy, 0.0.0.0, **requires** `KEYWORDISTA_ENCRYPTION_KEY` + `KEYWORDISTA_PUBLIC_BASE_URL`.

### Queues — `workerCount = 1` is intentional

`configure.swift` pins `app.queues.configuration.workerCount = 1`. Don't bump this. Comment in the file explains: parallel workers cause both iTunes 504s (rate-limit) *and* SQLite "database is locked" errors. Polite ~1 req/sec to iTunes is the contract with Apple.

Two scheduled jobs (UTC):
- `DailyRefreshScheduler` @ 03:00 — refresh every tracked keyword.
- `RefreshChartsScheduler` @ 04:00 — chart-position watchdog (1h offset avoids stacking; 4h after Apple's midnight-PT chart refresh).

The orphan-job sweeper at boot (`UPDATE _jobs SET state='completed' WHERE state='processing'`) is required — without it a single stranded job permanently wedges the SPA's refresh chip.

### JSON dates: fractional seconds (load-bearing)

`configure.swift` swaps Vapor's default ISO8601 encoder/decoder for one with `.withFractionalSeconds`. The SPA's `reconcile()` loop in `web/src/lib/stores.ts` compares a ms-precision client `startedAt` against the row's `checkedAt`; whole-second precision causes the refresh spinner to spin forever. Don't change the JSON date strategy without updating the SPA contract.

### No auth

Server binds `127.0.0.1` in local mode — anything that could reach it can already read `db.sqlite` directly. The `/api/v1` collection in `routes.swift` is unauthenticated by design. (Server mode is also currently unauthenticated; auth middleware is mentioned as a future hook in env-vars docs but not wired.)

## Architecture: web (`web/`)

Svelte 5 + Tailwind + Vite. `svelte-check` is strict — fix warnings before pushing or CI fails.

- `web/src/lib/stores.ts` — central state + the `reconcile()` polling loop that coordinates with the server queue. Read its comments before touching refresh-status logic.
- `web/src/lib/countries.ts` — Apple's 175-territory list, source of truth for storefronts on both sides of the wire.
- `web/src/lib/chartEvents.ts` — polling loop that fires `new Notification(...)` for chart watchdog events.
- `web/src/components/` — flat directory; no nested component folders by convention.

Dev server proxies `/api` to `:8080` (see `vite.config.ts`). Production build emits to `../Public/` so Vapor's `FileMiddleware` + `SPAFallbackMiddleware` serve it.

## Architecture: menubar (`mac/`)

`MenuBarExtra`-based SwiftUI app (`LSUIElement`). Key files in `mac/Sources/Keywordista/`:
- `ServiceSupervisor.swift` — picks a free port in 8080–8090, spawns the server binary with `--hostname 127.0.0.1 --port <chosen>`, supervises restart.
- `HealthMonitor.swift` — pings `/health` to detect crashes.
- `UpdateChecker.swift` — pulls service tarballs from GitHub Releases (server auto-updates; the `.app` itself needs a DMG re-download).
- `LoginItemManager.swift` — login-item registration.

The menubar app sets `KEYWORDISTA_PUBLIC_DIR` to point Vapor at its bundled SPA assets and `KEYWORDISTA_DATA_DIR` to `~/Library/Application Support/Keywordista/`.

## Conventions worth knowing

- **Comments explain *why*, not *what*.** The bar is "search the codebase for the word *Why* — match that density where the reasoning isn't obvious from the code."
- **Strict Concurrency (minimal)** is enabled on the App target (`Package.swift`). Watch for `Sendable` warnings.
- **Append-only rank history.** `RankCheck` deduplicates consecutive identical observations into a single row with `firstSeenAt`/`checkedAt`. Don't add update-in-place logic without thinking about the timeline contract.
- **Storefront-aware everywhere.** Anything that talks to iTunes should respect `AppStorefrontAvailability` so the watchdog only polls storefronts where each app actually ships.
- **Tests:** Swift Testing (not XCTest). Use `@Test`, `#expect`, and the in-memory repo actors. Network-touching tests stub the HTTP client.

## Commit messages

Imperative subject, ≤72 chars. **Do not mention Claude, AI, or any assistant in commit messages or PR descriptions** (project-wide rule, also in CONTRIBUTING.md).

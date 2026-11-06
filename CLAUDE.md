# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Keywordista is a local-first App Store keyword tracker for indie iOS developers. It ships as either a macOS menubar app (canonical install, single user, no auth) or a self-hosted Docker image for a small team (2–10 people, with user accounts). Product direction lives in `docs/roadmap.md` (OODA framing: Observe is done, Orient is the current frontier, Decide/Act come later); design spikes live in `docs/specs/`.

The tree is split into four layers, each with its own build system:

| Layer | Path | Build | Output |
| --- | --- | --- | --- |
| Vapor server (Swift) | `Sources/App/` | root `Package.swift` (`swift build`) | server binary |
| Svelte 5 SPA | `web/` | `npm` + Vite | static assets in `Public/` |
| SwiftUI menubar shell | `mac/` | separate `mac/Package.swift` | `Keywordista.app` (wraps server + SPA) |
| MCP server (TypeScript) | `mcp/` | `npm` + `tsc` | `mcp/dist/index.js` (stdio) |

Toolchain floor: Swift 6.2 (Xcode 26) with Swift 5 language mode, macOS 15 for both the server and the menubar app. The floor comes from Apple's `apple-ads-platform-api-swift` package, which declares it statically.

The `mac/` SPM package is intentionally separate so the macOS-only SwiftUI deps don't bleed into the cross-platform server build. Reference deploy manifests (docker-compose + Caddy + Litestream, Render, Fly, Kubernetes, Nomad) live in `deploy/`; ops docs in `docs/deploy/` and `docs/architecture/`.

## Common commands

```bash
# Day-to-day server + web dev (two terminals)
make dev-backend           # Vapor on :8080 (`KEYWORDISTA_MODE=local swift run`)
make dev-web               # Vite on :5173, proxies /api → :8080
# Bare `swift run` fails at boot: KEYWORDISTA_MODE must be set explicitly.

# Single-command launch (builds SPA into Public/, then execs Vapor)
make run                   # alias for ./keywordista

# Build and open the full menubar app (server + SPA + shell)
make open-mac-app

# Tests — CI (ci.yml) requires all of these green
swift test                              # Swift Testing suite (Tests/AppTests/)
cd web && npm run check && npm run build  # svelte-check + tsc strict, then Vite build
cd mac && swift build && swift test     # menubar app compiles + pure-function tests
./scripts/check-env-manifest.sh         # env-var manifest ↔ docs/env-vars.md drift check
# CI also builds the Docker image and enforces an image-size ceiling.

# MCP server (not in CI — run locally when touching mcp/)
make mcp-build             # npm install + tsc
make mcp-check             # vitest
make mcp-inspector         # MCP Inspector against dist/index.js

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

Other directories:
- `Domain/` — pure functions with no I/O: `KeywordScorer` (difficulty + entry barrier), `OpportunityScore`, `CompetitorGapClassifier`, `MetadataLinter`. Keep scoring formulas here so the dashboard and MCP never duplicate them.
- `Clients/` — external APIs: App Store Connect, Apple Search Ads, iTunes charts RSS. (The iTunes search/lookup clients and the App Store HTML scraper live in `Services/`.)
- `Auth/` — users, sessions, invites, middleware (server mode only; see below).
- `Crypto/` — `SecretBox` encrypts stored ASC/ASA credentials at rest.
- `Jobs/` — queue jobs and schedulers. `Commands/` — CLI subcommands (`createsuperuser`).

### Core data flow

`RefreshService` runs one iTunes search per keyword (top 200), then writes a `RankCheck` for **every** watched app, own *and* competitor, because competitor ranks come from the same results array at no extra iTunes cost and the gap view depends on them. It also saves the top 5 results as `TopResultSnapshot` rows, which feed the scorer. `WatchedApp.kind` (`own` / `competitor`) controls where an app appears: `DashboardService` shows only `.own`, and `ChartTrackerService` skips competitors (charts would cost an extra iTunes request per app).

Difficulty and entry barrier are frozen into each `RankCheck` when it's written, so changing the scorer never rewrites history. The opportunity score is `ASA impressions ÷ difficulty` and exists only for keywords that appear in the user's Apple Search Ads reports; there's no estimated popularity on purpose (see `docs/specs/popularity-spike-decision.md`).

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

Two runtime modes via `KEYWORDISTA_MODE`, which **must be set explicitly** (boot throws `modeNotSet` otherwise; the Dockerfile, `ServiceSupervisor`, and `make dev-backend` each set it):
- `local` — menubar-spawned, 127.0.0.1, no auth. SQLite.
- `server` — Docker deploy, 0.0.0.0, auth on, **requires** `KEYWORDISTA_ENCRYPTION_KEY` + `KEYWORDISTA_PUBLIC_BASE_URL`. SQLite or Postgres.

Adding an env var means updating the manifest, `docs/env-vars.md`, and keeping `scripts/check-env-manifest.sh` green.

### Queues — `workerCount = 1` is intentional

`configure.swift` pins `app.queues.configuration.workerCount = 1`. Don't bump this. Comment in the file explains: parallel workers cause both iTunes 504s (rate-limit) *and* SQLite "database is locked" errors. Polite ~1 req/sec to iTunes is the contract with Apple.

Three scheduled jobs (UTC), spaced so they don't stack:
- `DailyRefreshScheduler` @ 03:00 — refresh every tracked keyword.
- `DailyMetadataSnapshotJob` @ 03:30 — snapshot App Store metadata for own + competitor apps (feeds compare/optimizer). Skipped entirely when `KEYWORDISTA_METADATA_SNAPSHOT_ENABLED=false`.
- `RefreshChartsScheduler` @ 04:00 — chart-position watchdog (4h after Apple's midnight-PT chart refresh).

The orphan-job sweeper at boot (`UPDATE _jobs SET state='completed' WHERE state='processing'`) is required — without it a single stranded job permanently wedges the SPA's refresh chip.

### JSON dates: fractional seconds (load-bearing)

`configure.swift` swaps Vapor's default ISO8601 encoder/decoder for one with `.withFractionalSeconds`. The SPA's `reconcile()` loop in `web/src/lib/stores.ts` compares a ms-precision client `startedAt` against the row's `checkedAt`; whole-second precision causes the refresh spinner to spin forever. Don't change the JSON date strategy without updating the SPA contract.

### Auth is mode-conditional

`routes.swift` registers the product controllers differently per mode:
- **Local mode: no auth.** The server binds `127.0.0.1`, so anything that could reach it can already read `db.sqlite` directly. Every `/api/v1` controller is mounted bare.
- **Server mode:** product routes (`/apps`, `/competitors`, `/keywords`, `/dashboard`, `/charts`, metadata) sit behind `AuthMiddleware` (a `keywordista_session` cookie with a rolling TTL). `/settings/*`, `/users/*`, and `/admin` (backup) are also behind `RoleMiddleware.requireAdmin()`.
- **Always public:** `/health`, `/api/v1/version`, `/api/v1/auth/*` (`/auth/state` tells the SPA which mode it's in so it can hide auth UI locally).

The first admin is created with the `keywordista createsuperuser` CLI command, or seeded from `KEYWORDISTA_ADMIN_EMAIL` + `KEYWORDISTA_ADMIN_PASSWORD_HASH` when the users table is empty. There's no web setup endpoint (it was removed on purpose). Teammates join via invite links. When adding a new controller, register it in **both** branches of the `switch manifest.mode` and pick the right group. Record `creatorUserID` from `req.auth.get(User.self)?.id`, which is nil in local mode.

Stored ASC/ASA credentials are encrypted with `SecretBox`. In local mode the key comes from `EncryptionKeyResolver`; server mode requires `KEYWORDISTA_ENCRYPTION_KEY`.

## Architecture: web (`web/`)

Svelte 5 + Tailwind + Vite. `svelte-check` is strict — fix warnings before pushing or CI fails.

- `web/src/lib/stores.ts` — central state + the `reconcile()` polling loop that coordinates with the server queue. Read its comments before touching refresh-status logic.
- `web/src/lib/countries.ts` — Apple's 175-territory list, source of truth for storefronts on both sides of the wire.
- `web/src/lib/chartEvents.ts` — polling loop that fires `new Notification(...)` for chart watchdog events.
- `web/src/lib/router.ts` — hash-based `svelte-spa-router` map. Pages: Dashboard (`/`), Compare, Gaps, Charts, Optimizer, plus server-mode auth pages (login, bootstrap, invite, users admin). Use the `ROUTES` constants rather than path strings.
- `web/src/lib/authStore.ts` / `auth.ts` — holds the `/auth/state` result (mode, signed-in user).
- `web/src/lib/api.ts` + `types.ts` — the typed API client; keep in sync with server DTOs. `apiFetch`'s 401 hook sends the user to `/login` (except for `/auth/*` calls, so the login form can show "invalid credentials").
- `web/src/components/` — flat directory; no nested component folders by convention.

Dev server proxies `/api` to `:8080` (see `vite.config.ts`). Production build emits to `../Public/` so Vapor's `FileMiddleware` + `SPAFallbackMiddleware` serve it.

## Architecture: menubar (`mac/`)

`MenuBarExtra`-based SwiftUI app (`LSUIElement`) that manages **multiple instances**: the local backend plus any number of remote deployments. `AppCoordinator` in `KeywordistaApp.swift` owns the long-lived services. Key files in `mac/Sources/Keywordista/`:
- `ServiceSupervisor.swift` — picks a free port in 8080–8090, spawns the server binary (local mode, `--hostname 127.0.0.1 --port <chosen>`), and writes `<dataDir>/runtime.json` with the base URL so the MCP server can find it. It runs whichever is newer of a downloaded `service/` in the data dir and the copy bundled in the `.app`. After a crash it auto-restarts the child with backoff and an attempt cap (`RestartBackoff.swift`); only `stop()` exits are treated as intentional. Quit, SIGTERM and SIGINT stop the child via `AppShutdownDelegate`.
- `Model/` — `Instance` (a `local` / `remote` sum type; the local instance has a fixed UUID), `InstanceStore` (persists `instances.json`), `InstanceLifecycle`.
- `Health/` — `HealthCoordinator` keeps one `InstanceHealthMonitor` per instance, each polling `/health`.
- `Provider/` — the PaaS abstraction used by the deploy wizard. Only `Render/` exists so far.
- `Deploy/` — the "Deploy to a server…" and "Add existing" wizards, secret generation, GHCR probing, `ReadinessProbe`.
- `Security/KeychainStore.swift` — provider API tokens and per-instance session cookies.
- `UpdateChecker.swift` — pulls service tarballs from GitHub Releases (server auto-updates; the `.app` itself needs a DMG re-download).
- `LoginItemManager.swift` — login-item registration.

The menubar app sets `KEYWORDISTA_PUBLIC_DIR` to point Vapor at its bundled SPA assets and `KEYWORDISTA_DATA_DIR` to `~/Library/Application Support/Keywordista/`. `mac/Tests/` holds pure-function regression tests (e.g. the spawn-env contract), and CI runs them.

## Architecture: MCP server (`mcp/`)

A stdio MCP server exposing ten workflow-shaped tools (reads, add/remove with `confirm: true`, and `refresh`, which waits for completion) over the HTTP API. It finds the server via `KEYWORDISTA_BASE_URL`, then the `runtime.json` written by `ServiceSupervisor`, then a `/health` probe of ports 8080–8090. It only works against local mode (no auth). If you change an API response shape it uses, update `mcp/src/schemas.ts` too. See `mcp/README.md`.

## Conventions worth knowing

- **Comments explain *why*, not *what*.** The bar is "search the codebase for the word *Why* — match that density where the reasoning isn't obvious from the code."
- **Strict Concurrency (minimal)** is enabled on the App target (`Package.swift`). Watch for `Sendable` warnings.
- **Append-only rank history.** `RankCheck` deduplicates consecutive identical observations into a single row with `firstSeenAt`/`checkedAt`. Don't add update-in-place logic without thinking about the timeline contract.
- **Storefront-aware everywhere.** Anything that talks to iTunes should respect `AppStorefrontAvailability` so the watchdog only polls storefronts where each app actually ships.
- **Tests:** Swift Testing (not XCTest). Use `@Test`, `#expect`, and the in-memory repo actors. Network-touching tests stub the HTTP client.

## Commit messages

Imperative subject, ≤72 chars. **Do not mention Claude, AI, or any assistant in commit messages or PR descriptions** (project-wide rule, also in CONTRIBUTING.md).

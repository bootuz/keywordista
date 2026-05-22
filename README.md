# Keywordista

Self-hosted App Store keyword tracker for indie iOS developers.

[![CI](https://github.com/bootuz/keywordista/actions/workflows/ci.yml/badge.svg)](https://github.com/bootuz/keywordista/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)](#install)

Tracks where your apps rank for a set of keywords across multiple App Store regions, snapshots the top results, and remembers everything — so you can see real ASO trends instead of guessing from this-week-only screenshots. Runs entirely on your Mac: a Vapor service stores history in SQLite, a Svelte dashboard renders it, and a menubar app supervises the whole thing.

---

## Why

The keyword-tracking tools indie devs reach for are either expensive subscriptions, abandoned web apps, or a spreadsheet that goes stale within a week. Keywordista gives you the same dashboard you'd pay $50/mo for, but you own the data and the schedule.

Built for tracking dozens of keywords across half a dozen regions for a handful of apps — single-user scale. Not multi-tenant, not cloud-deployed, doesn't try to be.

---

## Install

> **A signed/notarized DMG is on the way.** For now, build from source — it's two commands.

### Prerequisites

- **macOS 13** Ventura or later
- **Swift 5.10+** (bundled with Xcode 15.3 / standalone toolchain)
- **Node 18+** for the Svelte SPA build

### From source

```bash
git clone https://github.com/bootuz/keywordista.git
cd keywordista
make open-mac-app
```

The `make open-mac-app` target builds the Vapor server, builds the SPA, assembles `Keywordista.app`, and opens it. A magnifying-glass icon appears in your menu bar. Click **Open Dashboard** → the browser opens `http://127.0.0.1:8080/` (or `:8081…:8090` if `:8080` is already taken).

#### Headless / dev mode

Prefer no menubar app? Use the launcher script:

```bash
./keywordista
```

This builds the SPA and `exec`s the Vapor server in the foreground. Ctrl+C stops it. Same dashboard at `http://127.0.0.1:8080/`. Data lives in `./db.sqlite` instead of `~/Library/Application Support/Keywordista/`.

---

## How it works

```
                           ┌──────────────────────────────────┐
                           │ Keywordista.app  (menubar shell) │
                           │ ─ Spawns + supervises the server │
                           │ ─ Picks a free port (8080–8090)  │
                           │ ─ "Open Dashboard" in browser    │
                           │ ─ Quit kills the child cleanly   │
                           └────────────┬─────────────────────┘
                                        │ spawns
                                        ▼
              ┌──────────────────────────────────────────────────┐
              │ Vapor server (Swift, 127.0.0.1 only)             │
              │ ├ REST API under /api/v1                         │
              │ ├ Static Svelte SPA on /                         │
              │ ├ Daily refresh job (03:00 UTC) + on-demand      │
              │ └ Polite serial worker (~1 req/sec to iTunes)    │
              └────────────┬───────────────────────┬─────────────┘
                           ▼                       ▼
                ┌──────────────────┐    ┌──────────────────────┐
                │ SQLite (Fluent)  │    │ iTunes Search API    │
                │ + append-only    │    │ (no key required)    │
                │   rank history   │    └──────────────────────┘
                └──────────────────┘
```

- **Append-only history.** Each refresh writes a `RankCheck` row keyed by `(keyword, watched_app, observed_at)`. We dedupe consecutive identical observations into a single row with `firstSeenAt`/`checkedAt`, so a stable rank doesn't bloat the DB but the timeline still tells you exactly when something changed.
- **No auth.** The server binds to `127.0.0.1` only. Anything that could send an HTTP request to it can already read the SQLite file directly — so the bearer-token gate would only add UX friction, not security.
- **Polite worker.** One job at a time, ~1 req/sec to iTunes. Stays well below Apple's edge-throttling threshold.

---

## Dev workflow

```bash
# All targets are in the Makefile — run `make help` for the catalog.
make build-web         # build the SPA into Public/
make build             # swift build the server
make dev-backend       # run the server in the foreground
make dev-web           # Vite dev server on :5173 (proxies /api → :8080)
make mac-app           # build Keywordista.app from sources
make open-mac-app      # build + open the .app
swift test             # run server tests
```

### Building a release DMG

The `mac/build-dmg.sh` script produces a signed + notarized DMG suitable for sharing on GitHub Releases. It does the full release flow: universal binaries (arm64 + x86_64) for both the menubar app and the server, Developer ID Application signing with hardened runtime + timestamp, DMG packaging, Apple notarization, and ticket stapling. Output lands in `releases/Keywordista-$VERSION.dmg`.

**One-time setup** (only needed for full signing + notarization):

```bash
# Store notarytool credentials in your keychain. You'll need an
# app-specific password from https://appleid.apple.com/account/manage
xcrun notarytool store-credentials keywordista \
  --apple-id    <your-apple-id> \
  --team-id     KHNA6PF8QV \
  --password    <app-specific-password>
```

**Build commands:**

```bash
make dmg              # full release: sign + notarize + staple
make dmg-unsigned     # skip signing entirely (faster, for testing)

# Or per-stage opt-out via env vars:
KEYWORDISTA_SKIP_NOTARIZE=1 make dmg    # sign but don't notarize
```

Contributors without a Developer ID cert can use `make dmg-unsigned` to verify the build flow. The resulting DMG installs but Gatekeeper will show "unidentified developer" on first launch.

#### Automated releases via GitHub Actions

Tagging `app-v0.1.0` and pushing the tag triggers `.github/workflows/release-app.yml`, which runs the same `build-dmg.sh` on a `macos-15` runner with all signing + notarization secrets injected. See [`.github/RELEASING.md`](.github/RELEASING.md) for the one-time secret-configuration ritual.

### Project layout

| Path | What lives there |
|---|---|
| `Sources/App/` | The Vapor server — models, controllers, services, jobs |
| `Tests/AppTests/` | Swift Testing suite (20 tests) for scoring + repositories + services |
| `web/` | The Svelte 5 + TypeScript + Tailwind SPA |
| `mac/` | The SwiftUI `MenuBarExtra` app + the `Keywordista.app` build script |
| `Public/` | Built SPA assets (regenerated by `npm run build`) |
| `keywordista` | Single-command launcher script for headless / dev mode |

---

## API surface

Everything under `/api/v1`. No auth — `127.0.0.1`-only.

| Method | Path | What |
|---|---|---|
| `GET` | `/health` | Liveness probe (no auth needed; the menubar app pings this) |
| `POST` | `/apps` | Add a watched app — body `{ appStoreId, lookupCountry }` |
| `GET` | `/apps` | List watched apps |
| `DELETE` | `/apps/:id` | Remove a watched app (cascades to its rank history) |
| `POST` | `/keywords` | Add a tracked keyword — body `{ term, countryCode }` |
| `GET` | `/keywords` | List keywords |
| `DELETE` | `/keywords/:id` | Remove a keyword (cascade) |
| `POST` | `/keywords/:id/refresh` | Enqueue one immediate refresh |
| `POST` | `/refresh-all` | Enqueue refresh for every keyword |
| `GET` | `/refresh-status` | `{ pending }` — how many jobs are queued |
| `GET` | `/dashboard` | The dashboard table — one row per `(keyword, watched_app)` |
| `GET` | `/keywords/:id/history?watchedAppId=…` | Full rank history for one (keyword, app) pair |
| `GET` | `/settings/{asc,asa}` | Read App Store Connect / Apple Search Ads credential status |
| `PUT`/`DELETE` | `/settings/{asc,asa}` | Update / clear those credentials |
| `GET` | `/api/v1/version` | `{ current, latest, updateAvailable, downloadUrl }` — used by the menubar app's update check |

See `requests.http` for ready-to-run `curl`/JetBrains-HTTP examples.

---

## What's not here (yet)

- **Apple Search Ads popularity scores.** v1 derives `difficulty` and `entryBarrier` from search results alone. ASA integration is a hookable seam — the credentials slot in `/api/v1/settings/asa` is already wired, just no fetcher consuming it yet.
- **Push / email rank-change alerts.** The data's all in the history table; a small job consumer would do it.
- **Auto-updates of the menubar app itself.** The server can update independently (the menubar app pulls service tarballs from GitHub Releases — see `mac/Sources/Keywordista/`), but bumping the .app version still means downloading a new DMG.
- **Linux / Windows.** Vapor runs everywhere; `Keywordista.app` is macOS-only. Linux users can clone + `./keywordista` from source.

---

## Contributing

Bug reports and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The ASO scoring heuristic in particular (`Sources/App/Services/KeywordScorer.swift`) is a documented best-effort approximation; sharper formulas with citations are explicitly invited.

Found a vulnerability? See [SECURITY.md](SECURITY.md).

---

## License

[Apache License 2.0](LICENSE). © 2026 Astemir Boziev.

# Keywordista env-var contract (v1.0)

Every operator-controllable knob is an env var. Reading them anywhere
in production code is funneled through one file
([Sources/App/Config/EnvVarManifest.swift](../Sources/App/Config/EnvVarManifest.swift)) —
this doc is the human-readable rendering of that contract.

The image bakes most of these as ENV defaults via the Dockerfile, so
the *minimum* you need to set as the operator is two:
`KEYWORDISTA_ENCRYPTION_KEY` + `KEYWORDISTA_PUBLIC_BASE_URL`.

## Backward-compatibility commitments

See [docs/architecture/image-contract.md](architecture/image-contract.md)
for the SemVer policy. TL;DR — a name present in v1.0 cannot be removed
in any v1.x; renames need a major-version bump with one full cycle of
dual support.

---

## Runtime mode

### `KEYWORDISTA_MODE`

- **Type:** `local` \| `server`
- **Required:** **yes — must be set explicitly**
- **Default:** none (boot throws `EnvVarError.modeNotSet` if unset)
- **Since:** 1.0

Runtime mode. `local` skips auth, binds to 127.0.0.1, single-user — used
by the macOS menubar app's spawned backend. `server` registers the auth
middleware, binds to 0.0.0.0, and **requires** both
`KEYWORDISTA_ENCRYPTION_KEY` and `KEYWORDISTA_PUBLIC_BASE_URL`.

**Why fail-fast instead of a default?** Either default leaves a footgun:
defaulting to `server` crashes any macOS-spawn / dev-loop path that
forgets to set it (the v0.3.5 regression); defaulting to `local` would
silently boot a misconfigured Docker image as a single-user backend
bound to 127.0.0.1 inside a remote container nobody can reach.
Requiring explicit intent eliminates both symmetric bugs.

The three real deployment paths set it for you:

- **Docker image** — `Dockerfile` sets `ENV KEYWORDISTA_MODE=server`.
- **macOS menubar app** — `ServiceSupervisor.makeChildEnvironment` sets `KEYWORDISTA_MODE=local`.
- **`swift run` dev loops** — prefix the command:
  ```bash
  KEYWORDISTA_MODE=local swift run App serve --hostname 127.0.0.1 --port 9999
  ```

---

## Listening

### `PORT`

- **Type:** positive integer
- **Default:** `8080`
- **Since:** 1.0

HTTP listen port. Most PaaS providers override this — Render injects
`PORT=10000`, Fly injects `8080`, Heroku-style providers vary. The
image reads whatever's set.

### `HOSTNAME`

- **Type:** string
- **Default:** `0.0.0.0` (server) / `127.0.0.1` (local)
- **Since:** 1.0

Bind address. Rarely overridden. The mode-conditional default does the
right thing for both deployment paths.

---

## Storage

### `KEYWORDISTA_DATA_DIR`

- **Type:** absolute path
- **Default:** `/data`
- **Since:** 1.0

Root directory for derived paths (SQLite file, future user-uploaded
files). Must be writable. In Docker deploys this is the volume mount
point; in the macOS app it's the menubar app's data dir under
`~/Library/Application Support/Keywordista/`.

### `DATABASE_URL`

- **Type:** `postgres://…` or `postgresql://…`
- **Required:** no
- **Default:** unset (falls back to SQLite at `DATABASE_PATH`)
- **Since:** 1.0
- **Secret:** ✅ contains a password

If set with a `postgres://` scheme, Keywordista uses Postgres via Fluent.
Takes precedence over `DATABASE_PATH`. Anything else (`mysql://`,
`sqlite:///`, garbage) silently falls back to SQLite — defensive
against accidental pastes.

### `DATABASE_PATH`

- **Type:** absolute path
- **Default:** `db.sqlite` (local, cwd-relative) / `/data/db.sqlite` (server)
- **Since:** 1.0

SQLite file path. Ignored if `DATABASE_URL` is set. The local-mode
default keeps `swift run` dev-friendly; the server-mode default matches
the Docker image's `VOLUME /data`.

---

## Secrets

### `KEYWORDISTA_ENCRYPTION_KEY`

- **Type:** 64 hex chars (32 bytes)
- **Required in:** `server`
- **Default in local:** derived from the Mac's `IOPlatformUUID`
- **Since:** 1.0
- **Secret:** ✅

The symmetric key for encryption-at-rest of operator credentials (ASC
`.p8`, ASA client secret, future Web Push private key). Generate ONCE
per deployment with `openssl rand -hex 32` — losing it means losing
access to stored secrets (the DB stays intact but the encrypted columns
become unreadable).

Boot fails fast with a clear `"KEYWORDISTA_ENCRYPTION_KEY is required in
server mode"` message if missing.

In local mode (the macOS app's spawned backend), if unset we derive
deterministically from the Mac's hardware UUID — same Mac → same key →
existing SQLite stays decryptable. Different Mac → different key, which
is the correct behavior for "don't carry your secrets to someone else's
Mac."

---

## Public surface

### `KEYWORDISTA_PUBLIC_BASE_URL`

- **Type:** `http(s)://` URL, no trailing slash
- **Required in:** `server`
- **Since:** 1.0

Public URL of this instance, e.g. `https://kw.studio.com`. Used to
render invite links sent to teammates. Boot fails fast with a clear
`"KEYWORDISTA_PUBLIC_BASE_URL is required in server mode"` message if
missing.

### `KEYWORDISTA_PUBLIC_DIR`

- **Type:** absolute path
- **Default:** Vapor's `app.directory.publicDirectory` (i.e. `Public/`
  next to the binary)
- **Since:** 1.0

Path to the built Svelte SPA assets. The Docker image sets this to
`/app/Public` (where the spa-builder stage copied the build output);
the macOS app sets it to the bundled assets dir.

---

## Admin bootstrap

### `KEYWORDISTA_ADMIN_EMAIL`

- **Type:** email address (lowercased + trimmed)
- **Required:** no
- **Since:** 1.0

If set together with `KEYWORDISTA_ADMIN_PASSWORD_HASH` and the `users`
table is empty at boot, seeds an admin user. The cockpit (M3+) uses
this for pre-baked-credentials deploys; raw `docker run` operators can
skip both and use the in-browser setup wizard.

### `KEYWORDISTA_ADMIN_PASSWORD_HASH`

- **Type:** bcrypt MCF string (`$2a$…` / `$2b$…` / `$2y$…`)
- **Required:** no
- **Since:** 1.0
- **Secret:** ✅

Pre-bcrypted admin password. **Plaintext passwords are NEVER accepted
as env vars** — the cockpit hashes locally on the Mac before sending
the hash to the provider. Generate with `htpasswd -nB -C 12 yourname |
cut -d: -f2`.

---

## Sign-up and auth policy

### `KEYWORDISTA_OPEN_SIGNUP`

- **Type:** boolean (`true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off`)
- **Default:** `false`
- **Since:** 1.0

If true, exposes `POST /api/v1/auth/signup` for public registration.
Off by default — invites are the canonical path. Flipping this on
turns the deployment from "team mode" into "open SaaS" mode.

### `KEYWORDISTA_SESSION_TTL_DAYS`

- **Type:** positive integer
- **Default:** `30`
- **Since:** 1.0

Rolling session expiry in days. Each request slides the expiry forward.

### `KEYWORDISTA_INVITE_TTL_DAYS`

- **Type:** positive integer
- **Default:** `7`
- **Since:** 1.0

Default expiry (in days) for invites generated via the admin UI.

### `KEYWORDISTA_BCRYPT_COST`

- **Type:** positive integer (typically 10–14)
- **Default:** `12`
- **Since:** 1.0

Cost factor for password hashing. Revisit annually as hardware
improves. Higher = slower logins but more brute-force resistance.

### `KEYWORDISTA_TRUST_PROXY`

- **Type:** boolean
- **Default:** `true` (server) / `false` (local)
- **Since:** 1.0

If true, honor `X-Forwarded-*` headers. Defaults true in server mode
because providers (Render, Fly, Railway, K8s ingress, Caddy) terminate
TLS upstream and pass `X-Forwarded-Proto: https`.

### `KEYWORDISTA_RATE_LIMIT_AUTH_PER_15MIN`

- **Type:** positive integer
- **Default:** `5`
- **Since:** 1.0

Per-IP failed-login attempts before the endpoint returns 429 for the
rest of the 15-minute window.

---

## Logging

### `KEYWORDISTA_LOG_LEVEL`

- **Type:** `trace` \| `debug` \| `info` \| `notice` \| `warning` \| `error` \| `critical`
- **Default:** `info`
- **Since:** 1.0

Standard log-level dial. Replaces the legacy `LOG_LEVEL` env var
(kept as an alias for one major version cycle).

### `KEYWORDISTA_LOG_FORMAT`

- **Type:** `json` \| `text`
- **Default:** `json` (server) / `text` (local)
- **Since:** 1.0

Server mode defaults to JSON so log aggregators (Datadog, Loki,
Cloudwatch, Render's log tail) ingest cleanly. Local mode defaults to
text so humans can read the menubar app's spawned backend logs.

---

## Scheduler tuning

### `KEYWORDISTA_REFRESH_HOUR`

- **Type:** integer 0–23 (hour UTC)
- **Default:** `3`
- **Since:** 1.0

Hour for the daily keyword refresh scheduler. Tunable for low-traffic
windows.

### `KEYWORDISTA_CHARTS_HOUR`

- **Type:** integer 0–23 (hour UTC)
- **Default:** `4`
- **Since:** 1.0

Hour for the chart-position scheduler. One hour after the keyword
refresh by default — don't pile both on iTunes at once.

### `KEYWORDISTA_WORKER_COUNT`

- **Type:** positive integer
- **Default:** `1`
- **Since:** 1.0

In-process queue workers. Capped at 1 by design (iTunes API throttling
+ SQLite write-lock contention). Future-proofed as a knob in case
Apple ever lifts the throttling.

### `KEYWORDISTA_HEALTHCHECK_PATH`

- **Type:** path starting with `/`
- **Default:** `/health`
- **Since:** 1.0

For providers that need the health check at a non-default path.

---

## Build-time identity (NOT in this contract)

These three vars are set by the Dockerfile via `ENV` directives at
build time and read by `ImageMetadata` at boot. They're deliberately
*not* part of `EnvVarManifest` — they identify the binary, not
configure its runtime:

- `KEYWORDISTA_BUILD_VERSION` — SemVer of this build, e.g. `1.2.3`
- `KEYWORDISTA_BUILD_COMMIT_SHA` — short git SHA
- `KEYWORDISTA_BUILD_DATE` — ISO-8601 UTC timestamp

Surfaced at `/health`, `/api/v1/version`, and the `--version` flag.

---

## See also

- [docs/architecture/image-contract.md](architecture/image-contract.md) — SemVer & backcompat policy
- [docs/architecture/exit-codes.md](architecture/exit-codes.md) — what a non-zero exit means
- [docs/deploy/raw-docker.md](deploy/raw-docker.md) — minimum-viable `docker run`
- [deploy/](../deploy/) — reference manifests for compose / Render / Fly / K8s / Nomad
- [Sources/App/Config/EnvVarManifest.swift](../Sources/App/Config/EnvVarManifest.swift) — canonical source of truth

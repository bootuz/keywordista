# The Keywordista image is the product surface

A Keywordista server deployment is, by definition:

> *that image + these env vars + this volume mount.*

That's it. There's no other surface. The macOS cockpit is one way to
produce that triple; raw `docker run`, `docker compose`, Kubernetes,
Nomad, Coolify, Dokku, raw VPS, "I rsync'd a binary to my Raspberry
Pi" — all valid, all equivalent. They consume the same contract.

This document describes the contract's shape and its
backward-compatibility commitments.

---

## What's in the image vs. what's external

| Concern                                | Where                                                       |
| -------------------------------------- | ----------------------------------------------------------- |
| Swift binary                           | inside the image (`/app/keywordista`)                       |
| Built Svelte SPA                       | inside the image (`/app/Public/`)                           |
| Bundled static assets                  | inside the image                                            |
| Default migrations                     | inside the image (run on boot)                              |
| Compiled-in build metadata             | inside the image (read by `ImageMetadata`)                  |
| **`KEYWORDISTA_*` configuration**      | env vars (operator-supplied)                                |
| **`DATABASE_URL` or `DATABASE_PATH`**  | env vars                                                    |
| **Database itself**                    | external volume mount or external Postgres                  |
| **ASC `.p8` + ASA client secret**      | encrypted at rest in DB (via the operator's encryption key) |
| **User accounts, sessions, invites**   | DB                                                          |
| **`KEYWORDISTA_ENCRYPTION_KEY`**       | env var                                                     |
| **TLS certificates**                   | upstream proxy / provider's responsibility                  |

The image is **stateless**. Killing the container and starting a new
one with the same env vars + the same volume yields the same running
deployment. This is what makes it work uniformly across PaaS, K8s,
Nomad, raw Docker.

---

## Distribution

- **Published to** `ghcr.io/bootuz/keywordista`
- **Public** — no auth required to pull
- **Multi-arch** — `linux/amd64` + `linux/arm64`
- **Signed** with cosign + GitHub OIDC (keyless)
- **SLSA-3 provenance** attached as a registry attestation
- **SBOM** attached as a registry attestation
- **Tags** per release:
  - `:1.2.3` — exact SemVer
  - `:1.2` — major.minor (auto-bumped on patches)
  - `:1` — major (auto-bumped on minors)
  - `:latest` — newest stable
  - `@sha256:<digest>` — immutable, **always prefer this in production**

See [`docs/deploy/raw-docker.md`](../deploy/raw-docker.md#verify-the-supply-chain)
for cosign / SLSA verification commands.

---

## Versioning (SemVer)

Standard SemVer for the image as a whole:

- **MAJOR** — backward-incompatible env-var renames or removals,
  DB-schema break that prevents downgrade, breaking API changes that
  affect existing clients (the macOS cockpit, the dashboard SPA),
  required-env-var additions.
- **MINOR** — additive env vars, new opt-in features, new optional API
  endpoints, performance improvements.
- **PATCH** — bug fixes, dep bumps, docs.

The Mac DMG (`app-v*`), the menubar service .zip (`service-v*`), and
this image (`image-v*`) are **three independent SemVer streams**. They
don't lock-step. Each has its own changelog and release cadence.

---

## Backward-compatibility commitments

### Env-var names

- **A var present in v1.0 cannot be removed in any v1.x.**
- Deprecated vars get one full major-version cycle of dual support.
- Renames are major-version events with a deprecated alias for one
  major cycle (e.g. `LOG_LEVEL` → `KEYWORDISTA_LOG_LEVEL` in v1.0; the
  old `LOG_LEVEL` is read as a fallback through v1.x).
- The `EnvVarManifest` (Sources/App/Config/EnvVarManifest.swift) is
  the canonical source. CI fails if any new `Environment.get(...)`
  appears outside that file.

### `/health` response shape

`/health` returns at least:

```json
{
  "status": "ok",
  "version": "1.2.3",
  "commitSHA": "abc1234",
  "buildDate": "2026-05-24T19:23:00Z",
  "mode": "server",
  "db": "sqlite"
}
```

- **Additive fields are fine** in MINOR releases.
- **Renames or removals are MAJOR-version events.**
- A response of HTTP 503 during boot is valid; HTTP 200 means the
  binary has finished migrations and is ready to serve requests.

### `/api/v1/version` response shape

Same SemVer rules as `/health`. The cockpit's `RemoteUpdateChecker`
(M5) parses this response across instances to detect drift; field
renames break that contract.

### Database schema migrations

- **Forward-only.** Downgrading an image after migrations run is not
  supported.
- Schema-version mismatches surface as exit code 4 ("DB connection
  failed") with a clear log message naming the conflict.

### Image entrypoint

`ENTRYPOINT ["/app/keywordista"]` + `CMD ["serve"]`. Both are stable;
operators who override CMD to pass different Vapor flags (`--hostname
0.0.0.0 --port 9000`) can rely on it working across versions.

---

## What the macOS app shares with the image

The macOS app's spawned local-mode backend is built from the **same
Swift source** as the Docker image — different distribution, identical
env-var contract. The platform difference manifests in exactly two
places in the codebase:

1. `KEYWORDISTA_MODE=local` (set explicitly by the menubar app)
   versus `=server` (the image's default).
2. `EncryptionKeyResolver` derives the encryption key from
   `IOPlatformUUID` in local mode on macOS — guarded by
   `#if os(macOS)`, never reached on Linux.

That's it. Everything else — routes, controllers, services, DB code —
is platform-agnostic.

---

## Adding a new env var

1. Declare it in `Sources/App/Config/EnvVarManifest.swift` (one new
   `EnvVar<T>` static + append to `EnvVars.all`).
2. Add a section to [`docs/env-vars.md`](../env-vars.md).
3. Read it at the consuming site via `manifest.require(...)` or
   `manifest.optional(...)`.
4. CI's `env-manifest` job fails if you tried to read it via raw
   `Environment.get(...)`.

The `EnvVarManifestTests.testAllListIsComplete` test fails if you
declared the static but forgot to append to `.all` (so it won't show
up in `--help` or `/api/v1/version/env`).

---

## See also

- [`docs/env-vars.md`](../env-vars.md) — the full contract
- [`docs/architecture/exit-codes.md`](exit-codes.md) — exit-code reference
- [`Sources/App/Config/EnvVarManifest.swift`](../../Sources/App/Config/EnvVarManifest.swift) — canonical source
- Plan §4.6 — the architectural keystone document this page summarizes

# Deploy Keywordista with raw Docker

The minimum-viable deploy. Works on any host with Docker installed —
a $4/mo VPS, a homelab Proxmox VM, a spare M-series Mac, or just a
developer laptop for testing.

This page assumes you're comfortable with `docker run` and want the
shortest possible path from zero to "my team has a Keywordista". For
something more idiomatic to your platform, see also:

- [`deploy/docker-compose.yml`](../../deploy/docker-compose.yml) — managed services + optional Postgres/Caddy/Litestream
- [`deploy/render.yaml`](../../deploy/render.yaml) — Render Blueprint
- [`deploy/fly.toml`](../../deploy/fly.toml) — Fly.io app config
- [`deploy/kubernetes/`](../../deploy/kubernetes/) — Deployment + Service + Ingress
- [`deploy/nomad/`](../../deploy/nomad/) — Nomad job spec

The image is **the same** for every path. What changes is the wrapping.

---

## TL;DR

```bash
# 1. Start the container
docker run -d \
  --name keywordista \
  -p 8080:8080 \
  -v keywordista-data:/data \
  -e KEYWORDISTA_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  -e KEYWORDISTA_PUBLIC_BASE_URL=https://keywordista.example.com \
  ghcr.io/bootuz/keywordista:latest

# 2. Create the admin user
docker exec -it keywordista keywordista createsuperuser
# (prompts for email + password)

# 3. Visit your URL → log in → done
```

The `createsuperuser` step is the Django-style admin-bootstrap
command. It runs out-of-band so admin creation never touches the
public HTTP surface — no scanner-race window, no setup endpoint to
gate. Same command also works for adding additional admins later
(e.g. after a lost-password recovery).

---

## What's required

Just two env vars. Both fail boot fast with a clear message if missing:

- `KEYWORDISTA_ENCRYPTION_KEY` — 64 hex chars (32 bytes). **Generate
  once and never lose** — this is the key that encrypts your App Store
  Connect `.p8` and all other secrets at rest in the DB. Losing it
  means losing access to those secrets forever; the DB stays intact
  but the encrypted columns become unreadable.

  ```bash
  openssl rand -hex 32
  ```

- `KEYWORDISTA_PUBLIC_BASE_URL` — Public URL the team will access
  this deployment at. Used to render invite links sent to teammates.
  No trailing slash.

Everything else has sensible defaults — see
[`docs/env-vars.md`](../env-vars.md) for the full contract.

## What's optional but recommended

### Pre-bake the admin user (skip the manual createsuperuser step)

If you'd rather not run a separate `docker exec` step, you can
bake the admin into the deploy spec via two env vars. The server's
boot-time `AdminBootstrap` (M3.17) consumes them on first boot:

```bash
# Hash a password locally — never put plaintext in env vars.
HASH=$(htpasswd -nB -C 12 you | cut -d: -f2)
docker run -d \
  --name keywordista \
  -p 8080:8080 \
  -v keywordista-data:/data \
  -e KEYWORDISTA_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  -e KEYWORDISTA_PUBLIC_BASE_URL=https://kw.example.com \
  -e KEYWORDISTA_ADMIN_EMAIL=you@example.com \
  -e KEYWORDISTA_ADMIN_PASSWORD_HASH="$HASH" \
  ghcr.io/bootuz/keywordista:latest
```

The container boots, sees both env vars, seeds the admin into the
empty `users` table, and the very first request to `/` lands on
the login page. This is exactly the mechanism the Keywordista
macOS cockpit uses behind the scenes — your raw-docker setup
matches the cockpit's deploy spec byte-for-byte.

### Adding more admins later

Same `createsuperuser` command works for additional admins after
the first one exists — useful for lost-password recovery or
provisioning a backup admin:

```bash
docker exec -it keywordista keywordista createsuperuser
```

For team-member additions (non-admin), use the **Settings → Users**
invite flow inside the dashboard instead — recipients get a
single-use link and don't need shell access to your container.

---

## Pin by digest for production

`:latest` is convenient but mutable — a `docker pull` six months from
now might land on a different version. For production, pin the
immutable digest:

```bash
# Get the current digest of :latest
DIGEST=$(docker pull ghcr.io/bootuz/keywordista:latest 2>&1 | grep -i Digest | awk '{print $2}')
echo "Pinning to $DIGEST"

docker run -d \
  --name keywordista \
  -p 8080:8080 \
  -v keywordista-data:/data \
  -e KEYWORDISTA_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  -e KEYWORDISTA_PUBLIC_BASE_URL=https://kw.example.com \
  ghcr.io/bootuz/keywordista@$DIGEST
```

The cockpit (when it ships in M3+) always pins by digest.

---

## Verify the supply chain

Every published image is signed with cosign (keyless, GitHub OIDC) and
carries SLSA-3 provenance. Before pulling into production:

```bash
# 1. Install cosign:
brew install cosign   # or: go install github.com/sigstore/cosign/v2/cmd/cosign@latest

# 2. Verify the signature was issued by THIS repo's workflow:
cosign verify ghcr.io/bootuz/keywordista@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/bootuz/keywordista' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# 3. (Optional) Verify the SLSA-3 provenance attestation:
cosign verify-attestation ghcr.io/bootuz/keywordista@sha256:<digest> \
  --type slsaprovenance \
  --certificate-identity-regexp 'https://github.com/bootuz/keywordista' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

A passing verify proves "this image was built by THIS workflow run
from THIS commit in our repo" — not "someone with our credentials
pushed an image to ghcr."

---

## Upgrading

Pull the new tag and recreate the container. The persistent volume
carries the SQLite file forward; migrations run on boot.

```bash
docker pull ghcr.io/bootuz/keywordista:1.2.3
docker stop keywordista && docker rm keywordista
docker run -d \
  --name keywordista \
  -p 8080:8080 \
  -v keywordista-data:/data \
  -e KEYWORDISTA_ENCRYPTION_KEY=... \
  -e KEYWORDISTA_PUBLIC_BASE_URL=... \
  ghcr.io/bootuz/keywordista:1.2.3
```

**Migrations are forward-only.** Downgrading is not supported — once
you've upgraded a DB, going back to an older image will fail with
schema-version errors.

---

## Backups

For raw-Docker deploys without a real backup service:

```bash
# Hot SQLite snapshot (safe with WAL journal mode)
docker exec keywordista \
  sqlite3 /data/db.sqlite ".backup '/data/snapshot.sqlite'"
docker cp keywordista:/data/snapshot.sqlite ./keywordista-$(date +%Y%m%d).sqlite
```

For a real backup story (continuous replication to S3/R2/B2), see
[`deploy/litestream.yml`](../../deploy/litestream.yml) — the
docker-compose path bundles Litestream as an optional sidecar.

---

## What if it won't boot?

The image's exit code tells you what went wrong — see
[docs/architecture/exit-codes.md](../architecture/exit-codes.md).
Common cases:

| Exit | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 2    | Missing required env var. Logs name the var.                     |
| 3    | `KEYWORDISTA_ENCRYPTION_KEY` is malformed (must be 64 hex chars). |
| 4    | DB connection failed. For Postgres, check `DATABASE_URL`.        |
| 22   | Healthcheck failed inside the container (curl exit code).        |

For everything else: `docker logs keywordista`.

---

## See also

- [`docs/env-vars.md`](../env-vars.md) — full env-var reference
- [`docs/architecture/image-contract.md`](../architecture/image-contract.md) — what the image promises
- [`docs/architecture/exit-codes.md`](../architecture/exit-codes.md) — non-zero exit reference

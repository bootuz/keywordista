#!/usr/bin/env bash
#
# deploy/init.sh — one-shot bootstrap for a "custom Docker host" deploy.
#
# The cockpit's Custom-Docker-Host provider (M5) generates this script,
# the matching docker-compose.yml, and a filled-in .env, drops the trio
# into a tarball, and walks the user through:
#
#   scp -r keywordista-deploy/ user@your-server.com:~/
#   ssh user@your-server.com 'cd keywordista-deploy && bash init.sh'
#
# What this script does:
#   1. Confirms Docker + docker compose are installed (installs Docker
#      on Ubuntu/Debian if missing; falls back to a clear error on other
#      distros).
#   2. Validates that .env has the two required values set (encryption
#      key + public base URL).
#   3. `docker compose pull` so the first `up` is fast.
#   4. `docker compose up -d` and waits for /health.
#   5. Prints the URL + the next-step ("open it, finish setup wizard").
#
# Idempotent: re-running this script on an existing deploy is safe —
# `docker compose up -d` rolls forward to whatever the current
# docker-compose.yml + .env describe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. Prerequisites ────────────────────────────────────────────────

require_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "→ Docker + docker compose not found. Attempting to install (Ubuntu/Debian)…"
  if [[ -f /etc/debian_version ]] && command -v apt-get >/dev/null 2>&1; then
    # Convenience script from Docker — fine for fresh boxes; for
    # production-grade installs follow https://docs.docker.com/engine/install/.
    curl -fsSL https://get.docker.com | sh
    if [[ -n "${SUDO_USER:-}" ]]; then
      usermod -aG docker "$SUDO_USER" || true
      echo "→ Added $SUDO_USER to the docker group. You may need to log out + back in for it to take effect."
    fi
    return 0
  fi

  cat >&2 <<EOF
✘ Docker isn't installed and this script can't install it automatically
  on your distro. Install it manually, then re-run:
    https://docs.docker.com/engine/install/

  After installing, verify with:
    docker --version
    docker compose version
EOF
  exit 1
}

# ── 2. .env validation ──────────────────────────────────────────────

validate_env() {
  if [[ ! -f .env ]]; then
    cat >&2 <<EOF
✘ No .env file next to docker-compose.yml.

  Copy the template and fill in at least the two required values:
    cp .env.example .env
    \$EDITOR .env

EOF
    exit 1
  fi

  # Look for the two required keys, non-empty.
  local missing=()
  for key in KEYWORDISTA_ENCRYPTION_KEY KEYWORDISTA_PUBLIC_BASE_URL; do
    if ! grep -qE "^${key}=.+$" .env; then
      missing+=("$key")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "✘ .env is missing required values:" >&2
    for k in "${missing[@]}"; do
      echo "  • $k" >&2
    done
    echo "" >&2
    echo "Run \`openssl rand -hex 32\` for KEYWORDISTA_ENCRYPTION_KEY." >&2
    exit 1
  fi
}

# ── 3. Pull + up ────────────────────────────────────────────────────

deploy() {
  echo "→ Pulling latest image…"
  docker compose pull keywordista

  echo "→ Starting services…"
  docker compose up -d

  echo "→ Waiting for /health (up to 60s)…"
  for i in {1..30}; do
    if docker compose exec -T keywordista curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
      echo "✓ keywordista is healthy"
      break
    fi
    sleep 2
    if [[ $i -eq 30 ]]; then
      echo "✘ /health didn't respond within 60s — recent logs:" >&2
      docker compose logs --tail 40 keywordista >&2
      exit 1
    fi
  done
}

# ── 4. Done ─────────────────────────────────────────────────────────

print_next_steps() {
  local url
  url=$(grep -E '^KEYWORDISTA_PUBLIC_BASE_URL=' .env | cut -d= -f2-)
  cat <<EOF

────────────────────────────────────────────────────────
✓ Keywordista is running.

   $url

Next:
  • Visit the URL above to finish the in-browser setup wizard
    (or skip it if you set KEYWORDISTA_ADMIN_EMAIL +
    KEYWORDISTA_ADMIN_PASSWORD_HASH in .env).
  • In the dashboard: Settings → ASC → paste your .p8 to start
    tracking keywords.
  • Re-running this script later is safe — it picks up any changes
    to docker-compose.yml or .env.

Logs:
  docker compose logs -f keywordista

Stop:
  docker compose down

────────────────────────────────────────────────────────
EOF
}

# ── main ────────────────────────────────────────────────────────────

require_docker
validate_env
deploy
print_next_steps

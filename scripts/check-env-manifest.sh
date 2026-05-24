#!/usr/bin/env bash
#
# scripts/check-env-manifest.sh
#
# CI guard for the §4.6.3 env-var contract: fails if anything in
# Sources/App/ calls `Environment.get(...)` outside the canonical manifest
# file. Forces every operator-controllable env-var read to flow through
# EnvVarManifest's typed accessors:
#
#   let port = try manifest.require(EnvVars.port)        // Int
#   let key  = try manifest.optional(EnvVars.encryptionKey)  // Data?
#
# Why some paths are excluded:
#   - Tests/AppTests/  : tests can read CI/TMPDIR/etc. — not shipped
#   - scripts/         : build-side tooling
#   - mac/             : SwiftUI menubar app, separate target & concerns
#   - Generated/       : codegen output (currently unused; future-proofed)
#
# The TEMPORARY_EXCEPTIONS list below is for files that pre-date the
# manifest and haven't been migrated yet. Each line carries the
# milestone that will remove it; CI yells about any NEW file appearing
# in this list. By M0.4 the list should be empty.
#
# Exit code: 0 on clean, 1 on any offending line found.

set -euo pipefail

# Run from repo root (script is in scripts/, root is one level up).
cd "$(dirname "$0")/.."

PATTERN='Environment\.get\s*\('
SEARCH_ROOT='Sources/App'
ALLOWED_MANIFEST='Sources/App/Config/EnvVarManifest.swift'

# Files that still call Environment.get directly because their migration
# hasn't landed yet. Removing entries is part of the milestone listed in
# the trailing comment.
TEMPORARY_EXCEPTIONS=(
  'Sources/App/configure.swift'  # removed by M0.4 (RuntimeMode plumbing)
)

# Build the exclusion grep arg: skip the manifest itself + each temp file.
EXCLUDE_ARGS=("--exclude=${ALLOWED_MANIFEST##*/}")
for f in "${TEMPORARY_EXCEPTIONS[@]}"; do
  EXCLUDE_ARGS+=("--exclude=${f##*/}")
done

# `|| true` because grep returns 1 when it finds nothing — that's our
# happy path. We check the captured output explicitly below.
OFFENDERS=$(
  grep -rn --include='*.swift' "${EXCLUDE_ARGS[@]}" \
    -E "$PATTERN" "$SEARCH_ROOT" \
    || true
)

if [[ -n "$OFFENDERS" ]]; then
  echo "✘ Raw Environment.get(...) calls found outside the manifest:"
  echo ""
  echo "$OFFENDERS"
  echo ""
  echo "Read env vars through EnvVarManifest instead:"
  echo ""
  echo "    let port = try manifest.require(EnvVars.port)        // Int"
  echo "    let key  = try manifest.optional(EnvVars.encryptionKey) // Data?"
  echo ""
  echo "To add a new var: declare it in"
  echo "  $ALLOWED_MANIFEST"
  echo "and reference it via EnvVars.<name>."
  echo ""
  echo "Allowed today (no further additions):"
  echo "  • $ALLOWED_MANIFEST  (the manifest itself)"
  for f in "${TEMPORARY_EXCEPTIONS[@]}"; do
    echo "  • $f  (temporary; see script header)"
  done
  exit 1
fi

# Informational: the count of allowed reads inside the manifest. Worth
# eyeballing — a sudden jump means someone added a lot of new vars (which
# is fine, just worth a moment of attention).
MANIFEST_READS=$(grep -c -E "$PATTERN" "$ALLOWED_MANIFEST" || echo 0)
TEMP_TOTAL=0
for f in "${TEMPORARY_EXCEPTIONS[@]}"; do
  if [[ -f "$f" ]]; then
    n=$(grep -c -E "$PATTERN" "$f" || echo 0)
    TEMP_TOTAL=$((TEMP_TOTAL + n))
  fi
done

echo "✓ env-var contract guard clean"
echo "  manifest ($ALLOWED_MANIFEST): $MANIFEST_READS Environment.get call(s)"
echo "  temporary exceptions:         $TEMP_TOTAL call(s) across ${#TEMPORARY_EXCEPTIONS[@]} file(s)"

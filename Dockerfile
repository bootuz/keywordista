# syntax=docker/dockerfile:1.7
#
# Keywordista server image. Single configurable artifact (plan §4.6) —
# everything that varies between deployments is an env var, the image
# itself is bit-identical for every host.
#
# Three stages:
#   1. spa-builder    — Node 20, builds the Svelte SPA → /spa/Public
#   2. swift-builder  — Swift 6.1, builds the Vapor binary dynamically
#                       linked against the Swift runtime libs that the
#                       slim runtime base already ships
#   3. runtime        — swift:6.1-jammy-slim, non-root user, /data
#                       volume, runs as the entrypoint
#
# Why NOT `--static-swift-stdlib`: that flag bundles libswift* into
# the binary itself (Swift Foundation / NIO / Crypto, ~200-300 MB on
# amd64). Static stdlib makes sense when the runtime base is
# `distroless/cc` or `scratch` (no Swift stdlib at all). With the
# `*-slim` runtime base, those same libs are already present and
# dynamically linkable — bundling them statically is worst-of-both.
# Empirical impact: dropped image size from ~462 MB → ~165 MB on amd64.
#
# Multi-arch (linux/amd64 + linux/arm64) is built via `docker buildx`
# in the M0.8 GHCR workflow; this Dockerfile is platform-neutral.
#
# Build args:
#   KEYWORDISTA_BUILD_VERSION    SemVer of this build (defaults to 'dev')
#   KEYWORDISTA_BUILD_COMMIT_SHA short git SHA       (defaults to 'unknown')
#   KEYWORDISTA_BUILD_DATE       ISO-8601 build date (defaults to 'unknown')
#
# CI sets all three via --build-arg in the release workflow; raw
# `docker build .` gets the fallback values, which ImageMetadata
# surfaces at /health and /api/v1/version.

# ── Stage 1: Svelte SPA ──────────────────────────────────────────────

FROM node:20-alpine AS spa-builder
WORKDIR /spa

# Package files first → npm-cache layer reuses across source changes.
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund

# Source. Vite reads vite.config.ts and emits flat to ../Public (i.e.
# /Public from /spa), which we copy in stage 3 below.
COPY web/ ./
RUN npm run build

# Sanity check — fail the build now (with a clear message) rather than
# later in the runtime stage if the SPA build silently produced nothing.
RUN test -f /Public/index.html || (echo "SPA build did not produce /Public/index.html" && exit 1)

# ── Stage 2: Vapor binary ────────────────────────────────────────────

FROM swift:6.1-jammy AS swift-builder
WORKDIR /build

# Resolve deps first — Package.swift + Package.resolved (if present)
# define the dependency graph. Layering this before source means a
# source-only change reuses the resolved-deps layer.
COPY Package.swift ./
COPY Package.resolved* ./
RUN swift package resolve

# Then the actual sources.
COPY Sources Sources
COPY Tests Tests

# Dynamic linking against libswift* (Foundation / NIO / Crypto) — the
# slim runtime base ships these. See the file header for why static
# stdlib is the wrong call here.
RUN swift build -c release

# Stage the built binary at a stable path so the runtime COPY doesn't
# need to know SPM's internal layout.
RUN mkdir -p /build/staging \
 && cp /build/.build/release/App /build/staging/keywordista

# ── Stage 3: Runtime ─────────────────────────────────────────────────

FROM swift:6.1-jammy-slim AS runtime

# Curl for the HEALTHCHECK probe + ca-certificates for outbound HTTPS
# (iTunes / App Store Connect APIs). Both are tiny.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user. uid 10001 is the convention for "system user above the
# 1000-range humans use." Required by some PaaS (App Runner; certain
# Lightsail container configs) and just-good-practice everywhere else.
RUN groupadd --system --gid 10001 keywordista \
 && useradd --system --uid 10001 --gid keywordista --shell /usr/sbin/nologin \
            --home-dir /app keywordista

WORKDIR /app

# Binary + bundled SPA. The SPA is served by Vapor's FileMiddleware at
# the path KEYWORDISTA_PUBLIC_DIR (set below).
COPY --from=swift-builder --chown=keywordista:keywordista \
     /build/staging/keywordista /app/keywordista
COPY --from=spa-builder --chown=keywordista:keywordista \
     /Public /app/Public

# Data dir. Mount a host volume here in production (Render persistent
# disk, Fly volume, docker -v) so the SQLite file survives container
# restarts.
RUN mkdir -p /data && chown -R keywordista:keywordista /data
VOLUME ["/data"]

# Build-time identity surfaced at /health, /api/v1/version, and the
# --version flag. Read at process start by ImageMetadata.
ARG KEYWORDISTA_BUILD_VERSION=dev
ARG KEYWORDISTA_BUILD_COMMIT_SHA=unknown
ARG KEYWORDISTA_BUILD_DATE=unknown
ENV KEYWORDISTA_BUILD_VERSION=$KEYWORDISTA_BUILD_VERSION \
    KEYWORDISTA_BUILD_COMMIT_SHA=$KEYWORDISTA_BUILD_COMMIT_SHA \
    KEYWORDISTA_BUILD_DATE=$KEYWORDISTA_BUILD_DATE

# Server-mode defaults baked into the image. Operator overrides at
# deploy time via the provider's env-var UI; the full contract is
# documented in EnvVarManifest.swift / docs/env-vars.md.
#
# Notably NOT set here: KEYWORDISTA_ENCRYPTION_KEY and
# KEYWORDISTA_PUBLIC_BASE_URL — both are `requiredIn: .server`. Boot
# fails fast with a clear "X is required in server mode" message if
# they're missing, which is the correct behavior: a Keywordista
# instance with no operator-supplied encryption key would silently
# share the image's "key" with every other deployment.
ENV KEYWORDISTA_MODE=server \
    KEYWORDISTA_PUBLIC_DIR=/app/Public \
    KEYWORDISTA_DATA_DIR=/data \
    PORT=8080

USER keywordista

EXPOSE 8080

# 30s interval is enough for PaaS-style health-checking without
# hammering the binary; start-period of 10s covers cold migrations.
# Curl with -fsS so a non-2xx surfaces as exit 22 (failure) cleanly.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/health || exit 1

# `serve` is Vapor's stock command; the binary inherits Vapor's CLI
# parsing for free, so `--hostname` / `--port` / `--env` are still
# overridable from the command line (matches how the macOS menubar
# supervisor invokes the local-mode binary).
ENTRYPOINT ["/app/keywordista"]
CMD ["serve"]

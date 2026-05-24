.PHONY: dev-backend dev-web build-web build run install-web check-web clean-web mac-app open-mac-app dmg dmg-unsigned docker-build docker-smoke help

.DEFAULT_GOAL := run

help:
	@echo "Keywordista dev targets:"
	@echo "  make               — single-command launch (alias for ./keywordista)"
	@echo "  make dev-backend   — run Vapor on :8080"
	@echo "  make dev-web       — run Vite dev server on :5173 (proxies /api → :8080)"
	@echo "  make build-web     — build SPA to Public/ for production serving"
	@echo "  make install-web   — npm install in web/"
	@echo "  make check-web     — type-check Svelte + TS"
	@echo "  make build         — swift build"
	@echo "  make run           — single-command launch: build web + swift run"
	@echo "  make mac-app       — build Keywordista.app (server + SPA + menubar shell)"
	@echo "  make open-mac-app  — mac-app + open the resulting .app"
	@echo "  make dmg           — build a signed + notarized DMG (releases/)"
	@echo "  make dmg-unsigned  — build an unsigned DMG (skips signing + notarizing)"
	@echo "  make docker-build  — build the server Docker image as keywordista:dev"
	@echo "  make docker-smoke  — docker-build + run, hit /health, tear down"

dev-backend:
	swift run

dev-web:
	cd web && npm run dev

install-web:
	cd web && npm install

check-web:
	cd web && npm run check

build-web:
	cd web && npm run build

build:
	swift build

run:
	@./keywordista

clean-web:
	rm -rf web/node_modules Public/web

# Build the Keywordista.app bundle. Wraps the SwiftUI menubar binary around
# the Vapor server binary + built SPA — see mac/build-app.sh for details.
mac-app:
	cd mac && ./build-app.sh debug

open-mac-app: mac-app
	open mac/Keywordista.app

# Build a release DMG: universal binaries, Developer ID signed, notarized,
# stapled. Requires (a) a Developer ID Application cert in the keychain
# and (b) a one-time notarytool credential profile named "keywordista".
# See mac/build-dmg.sh for the full env-var contract.
dmg:
	cd mac && ./build-dmg.sh

# Same release build, but skips signing + notarization — useful when you
# want to verify the universal-binary assembly without burning a notarize
# round-trip.
dmg-unsigned:
	cd mac && KEYWORDISTA_SKIP_SIGN=1 ./build-dmg.sh

# Builds the server Docker image with KEYWORDISTA_BUILD_* metadata
# derived from the current git state. Tag is keywordista:dev so it
# never collides with a published :semver tag.
docker-build:
	docker build \
	  --build-arg KEYWORDISTA_BUILD_VERSION=dev \
	  --build-arg KEYWORDISTA_BUILD_COMMIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
	  --build-arg KEYWORDISTA_BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	  -t keywordista:dev .

# End-to-end smoke test: build + run + GET /health + tear down. Use this
# locally to validate the image without setting up a real deployment.
# `set -e` so the docker stop runs even when curl fails — gives us logs
# on failure instead of a silent hang.
docker-smoke: docker-build
	@echo "→ Starting keywordista:dev with a throwaway encryption key"
	@docker rm -f keywordista-smoke >/dev/null 2>&1 || true
	docker run -d --name keywordista-smoke \
	  -p 8080:8080 \
	  -e KEYWORDISTA_ENCRYPTION_KEY=$$(openssl rand -hex 32) \
	  -e KEYWORDISTA_PUBLIC_BASE_URL=http://localhost:8080 \
	  keywordista:dev
	@sleep 5
	@set -e; \
	  if curl -fsS http://localhost:8080/health; then \
	    echo ""; \
	    echo "✓ smoke test passed"; \
	    docker stop keywordista-smoke >/dev/null; \
	    docker rm keywordista-smoke >/dev/null; \
	  else \
	    echo "✘ smoke test failed — image logs follow:"; \
	    docker logs keywordista-smoke; \
	    docker stop keywordista-smoke >/dev/null; \
	    docker rm keywordista-smoke >/dev/null; \
	    exit 1; \
	  fi

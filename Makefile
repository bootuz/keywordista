.PHONY: dev-backend dev-web build-web build run install-web check-web clean-web mac-app open-mac-app help

.DEFAULT_GOAL := run

KEYWORDISTA_API_TOKEN ?= devtoken

help:
	@echo "Keywordista dev targets:"
	@echo "  make               — single-command launch (alias for ./keywordista)"
	@echo "  make dev-backend   — run Vapor on :8080 with devtoken"
	@echo "  make dev-web       — run Vite dev server on :5173 (proxies /api → :8080)"
	@echo "  make build-web     — build SPA to Public/ for production serving"
	@echo "  make install-web   — npm install in web/"
	@echo "  make check-web     — type-check Svelte + TS"
	@echo "  make build         — swift build"
	@echo "  make run           — single-command launch: build web + swift run"
	@echo "  make mac-app       — build Keywordista.app (server + SPA + menubar shell)"
	@echo "  make open-mac-app  — mac-app + open the resulting .app"

dev-backend:
	KEYWORDISTA_API_TOKEN=$(KEYWORDISTA_API_TOKEN) swift run

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

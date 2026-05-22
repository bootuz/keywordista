#!/usr/bin/env bash
# Build Keywordista.app from this SPM package + the repo's Vapor server +
# the SPA. Result is a runnable .app bundle in mac/Keywordista.app.
#
# Usage:
#   ./build-app.sh              # debug build, debug server
#   ./build-app.sh release      # release build, release server (slower, smaller)
#
# Open with: `open Keywordista.app` (or drag to /Applications).

set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="Keywordista"
APP_BUNDLE="$APP_NAME.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
REPO_ROOT="$(cd .. && pwd)"

echo "→ building menubar app ($CONFIG)…"
swift build -c "$CONFIG"

echo "→ assembling $APP_BUNDLE structure…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/$CONFIG/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/"
# PkgInfo is the classic 8-byte file telling Finder this is an .app. Modern
# macOS doesn't strictly require it, but it shuts up the occasional
# "damaged" warning on older systems.
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# App icon. Skipped silently if the source PNG isn't checked in yet —
# Finder will just show the generic .app icon in that case. Once
# mac/Resources/AppIcon.png exists, the build always regenerates the
# .icns so an updated source PNG flows through without a manual step.
if [ -f "Resources/AppIcon.png" ]; then
    ./generate-icon.sh
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "→ building service binary ($CONFIG)…"
(cd "$REPO_ROOT" && swift build -c "$CONFIG")
cp "$REPO_ROOT/.build/$CONFIG/App" "$APP_BUNDLE/Contents/Resources/keywordista-server"

echo "→ building SPA…"
(cd "$REPO_ROOT/web" && npm run build --silent)
cp -R "$REPO_ROOT/Public" "$APP_BUNDLE/Contents/Resources/Public"

echo "→ $APP_BUNDLE built. Run with: open $APP_BUNDLE"

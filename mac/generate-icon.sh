#!/usr/bin/env bash
# Compile the Icon Composer document mac/Resources/AppIcon.icon into the
# two files the .app bundle needs:
#
#   Assets.car    — the layered Liquid Glass icon macOS 26+ draws (light,
#                   dark, clear and tinted appearances all come from it).
#   AppIcon.icns  — a flat fallback actool renders from the same document
#                   for macOS 15, which can't read the layered icon.
#
# Why actool instead of rendering PNGs ourselves: only actool knows how to
# bake the .icon's glass groups into Assets.car, and it produces the .icns
# fallback from the same source, so the two can't drift apart.
#
# Edit the icon by opening AppIcon.icon in Icon Composer (ships with
# Xcode 26+). Both outputs are gitignored; only the .icon is committed.
#
# Called automatically by build-app.sh and build-dmg.sh. Safe to run
# standalone too.
#
# Usage:  ./mac/generate-icon.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES="$SCRIPT_DIR/Resources"
SRC="$RES/AppIcon.icon"

if [[ ! -d "$SRC" ]]; then
    echo "✗ icon source not found: $SRC"
    exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# --minimum-deployment-target matches LSMinimumSystemVersion in Info.plist;
# it's what makes actool emit the .icns fallback alongside Assets.car.
xcrun actool "$SRC" \
    --compile "$OUT" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --include-all-app-icons \
    --output-partial-info-plist "$OUT/partial.plist" \
    --output-format human-readable-text >/dev/null

for f in Assets.car AppIcon.icns; do
    if [[ ! -f "$OUT/$f" ]]; then
        echo "✗ actool did not produce $f (needs Xcode 26 or newer)"
        exit 1
    fi
    cp "$OUT/$f" "$RES/$f"
done
echo "✓ wrote $RES/Assets.car and $RES/AppIcon.icns"

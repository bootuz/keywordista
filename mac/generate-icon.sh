#!/usr/bin/env bash
# Generate mac/Resources/AppIcon.icns from the source PNG at
# mac/Resources/AppIcon.png. macOS .icns files are multi-resolution
# containers; this script renders the source at every size the system
# might want to draw (16/32/128/256/512 @1x and @2x) then asks iconutil
# to bundle them.
#
# Called automatically by build-app.sh and build-dmg.sh when the source
# PNG exists. Safe to run standalone too.
#
# Usage:  ./mac/generate-icon.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/Resources/AppIcon.png"
OUT="$SCRIPT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "✗ source icon not found: $SRC"
    echo "  Save your 1024×1024 PNG to that path and try again."
    exit 1
fi

# Sanity check: source must be at least 1024×1024 so the @2x_512 slot
# gets the original (downscaling beats upscaling for icon clarity).
SRC_WIDTH=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/ {print $2}')
if [[ "$SRC_WIDTH" -lt 1024 ]]; then
    echo "⚠ source PNG is ${SRC_WIDTH}px wide; should be 1024×1024 for the @2x_512 slot."
    echo "  Continuing anyway — sips will upscale."
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# (target_pixel_size, filename) pairs that iconutil expects. Both @1x
# and @2x for every logical size, so the system always has a perfect
# pixel match regardless of the Mac's display scaling.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ wrote $OUT"

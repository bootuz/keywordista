#!/usr/bin/env bash
# Build a signed + notarized Keywordista DMG suitable for distribution.
#
# Flow:
#   1. Universal release builds  (arm64 + x86_64) for both the menubar app
#      and the Vapor server, plus a fresh SPA bundle.
#   2. Assemble Keywordista.app from those artifacts.
#   3. Code-sign the inner binaries, then the .app outer wrapper, with the
#      Developer ID Application identity + hardened runtime + timestamp.
#   4. Stage the .app + an /Applications symlink into a temp dir; turn that
#      into Keywordista-$VERSION.dmg via hdiutil (UDZO).
#   5. Sign the DMG too.
#   6. Submit the DMG to Apple notarization via notarytool, wait for the
#      ticket, staple it back onto the DMG, then verify with spctl.
#
# Output: releases/Keywordista-$VERSION.dmg
#
# Per-stage opt-out (for local iteration when you don't want the full round-
# trip cost of every release artifact):
#   KEYWORDISTA_SKIP_SIGN=1       — skip codesign on the .app and the DMG.
#                                   Implies KEYWORDISTA_SKIP_NOTARIZE=1
#                                   because notarization requires signing.
#   KEYWORDISTA_SKIP_NOTARIZE=1   — sign as usual, but don't submit to Apple.
#                                   The DMG will install but Gatekeeper will
#                                   show "Apple could not verify…" on first
#                                   launch.
#
# Override knobs:
#   CODESIGN_IDENTITY    — full identity string, defaults to the first
#                          "Developer ID Application" in the keychain.
#   NOTARYTOOL_PROFILE   — name of the stored notarytool credential profile
#                          (default: keywordista).
#                          Create it once with:
#                            xcrun notarytool store-credentials keywordista \
#                              --apple-id <your-apple-id> \
#                              --team-id KHNA6PF8QV \
#                              --password <app-specific-password>

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────

APP_NAME="Keywordista"
BUNDLE_ID="com.bootuz.keywordista"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-keywordista}"
SKIP_SIGN="${KEYWORDISTA_SKIP_SIGN:-0}"
SKIP_NOTARIZE="${KEYWORDISTA_SKIP_NOTARIZE:-0}"

# Notarization implies signing — you can't notarize an unsigned blob.
if [[ "$SKIP_SIGN" == "1" ]]; then
    SKIP_NOTARIZE="1"
fi

# Resolve paths up front so every subshell knows where it stands.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$MAC_DIR/.." && pwd)"
APP_BUNDLE="$MAC_DIR/$APP_NAME.app"
RELEASES_DIR="$REPO_ROOT/releases"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$MAC_DIR/Resources/Info.plist")
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$RELEASES_DIR/$DMG_NAME"

# Auto-discover the Developer ID Application identity from the keychain
# if the caller didn't pin one explicitly.
if [[ -z "${CODESIGN_IDENTITY:-}" && "$SKIP_SIGN" != "1" ]]; then
    CODESIGN_IDENTITY=$(
        security find-identity -v -p codesigning |
        grep "Developer ID Application:" |
        head -n 1 |
        sed -E 's/.*"(.+)".*/\1/'
    )
    if [[ -z "$CODESIGN_IDENTITY" ]]; then
        cat >&2 <<EOF
✗ No "Developer ID Application" identity found in your keychain.
  Either install your Apple Developer ID cert, or set
  KEYWORDISTA_SKIP_SIGN=1 to build an unsigned DMG.
EOF
        exit 1
    fi
fi

# ── Helpers ───────────────────────────────────────────────────────────────

step() { printf "\n→ %s\n" "$1"; }
warn() { printf "⚠ %s\n" "$1" >&2; }

# ── 1. Universal release builds ───────────────────────────────────────────

# Two design choices baked into the build commands below:
#
#  1. **Per-arch builds + lipo, not `swift build --arch arm64 --arch x86_64`.**
#     SwiftPM's universal-build mode shells out to Xcode's xcbuild engine,
#     which trips on some Vapor transitive deps (swift-collections,
#     swift-service-lifecycle) under Xcode 16.x with cryptic errors like
#     "Some of the Swift language versions used in target settings are
#     supported. (given: [5], supported: [])". Building each arch
#     separately uses SwiftPM's native build system, which doesn't have
#     this issue. `lipo -create` then merges the two single-arch binaries
#     into one universal binary — same end result, more robust path.
#
#  2. **-Osize for the server** works around a Swift 6.2.1 SIL optimizer
#     crash in FluentKit's EnumBuilder.generateDatatype() during the
#     CopyPropagation pass. Runtime cost is unmeasurable for our workload
#     (~1 iTunes call/sec, SQLite writes); the binary is also a few MB
#     smaller. Flip back to -O when Apple ships the SIL fix.
SERVER_SWIFTC_FLAGS=("-Xswiftc" "-Osize")

build_universal_binary() {
    local label="$1"     # human-readable name for logs
    local build_dir="$2" # directory containing Package.swift to build in
    local product="$3"   # SwiftPM product/target name (also the binary file name)
    local output="$4"    # final universal-binary path
    shift 4
    local extra_flags=("$@")

    step "building $label (release, arm64)…"
    # bash 3.2 (macOS's default) errors on "${empty_array[@]}" under set -u.
    # The ${arr[@]+"${arr[@]}"} idiom expands to nothing when unset/empty
    # and to the properly-quoted elements when populated.
    (cd "$build_dir" && swift build -c release --product "$product" --arch arm64 ${extra_flags[@]+"${extra_flags[@]}"})
    local arm64_bin
    arm64_bin="$(cd "$build_dir" && swift build -c release --product "$product" --arch arm64 --show-bin-path)/$product"

    step "building $label (release, x86_64)…"
    (cd "$build_dir" && swift build -c release --product "$product" --arch x86_64 ${extra_flags[@]+"${extra_flags[@]}"})
    local x86_64_bin
    x86_64_bin="$(cd "$build_dir" && swift build -c release --product "$product" --arch x86_64 --show-bin-path)/$product"

    step "lipo-merging $label into universal binary…"
    lipo -create "$arm64_bin" "$x86_64_bin" -output "$output"
    lipo -archs "$output"
}

# Universal Vapor server → temp output path so we don't clobber single-arch
# .build/ outputs that subsequent invocations rely on.
SERVER_BIN="$REPO_ROOT/.build/keywordista-server-universal"
build_universal_binary \
    "Vapor server" \
    "$REPO_ROOT" \
    "App" \
    "$SERVER_BIN" \
    "${SERVER_SWIFTC_FLAGS[@]}"

# Universal menubar app. The menubar target doesn't pull in FluentKit so
# it doesn't strictly need -Osize, but keeping the build pattern uniform
# makes the script easier to reason about and trims a few KB anyway.
APP_BIN="$MAC_DIR/.build/$APP_NAME-universal"
build_universal_binary \
    "menubar app" \
    "$MAC_DIR" \
    "$APP_NAME" \
    "$APP_BIN"

step "building SPA…"
(cd "$REPO_ROOT/web" && npm run build --silent)

# ── 2. Assemble Keywordista.app ───────────────────────────────────────────

step "assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$APP_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SERVER_BIN" "$APP_BUNDLE/Contents/Resources/keywordista-server"
cp -R "$REPO_ROOT/Public" "$APP_BUNDLE/Contents/Resources/Public"
cp "$MAC_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
# Classic 8-byte BNDL hint — modern macOS doesn't strictly need it but
# silences the occasional "damaged" warning on older systems.
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# App icon. Regenerated from mac/Resources/AppIcon.png on every release
# build so a designer can swap the source PNG without touching anything
# else. Skipped if the source isn't there yet (Finder shows the generic
# .app icon as a fallback).
if [ -f "$MAC_DIR/Resources/AppIcon.png" ]; then
    "$MAC_DIR/generate-icon.sh"
    cp "$MAC_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# ── 3. Code-sign the .app (inside-out) ────────────────────────────────────

if [[ "$SKIP_SIGN" == "1" ]]; then
    warn "skipping codesign — Gatekeeper will block first-launch on download"
else
    step "signing with: $CODESIGN_IDENTITY"
    # Inside-out is the documented order: sign the inner binaries first so
    # the outer .app's signature seals over already-signed children. The
    # alternative (--deep on the outer call) is deprecated and produces
    # subtly different signatures.
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Resources/keywordista-server"

    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" \
        "$APP_BUNDLE"

    step "verifying .app signature…"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

# ── 4. Build the DMG ──────────────────────────────────────────────────────

step "staging DMG contents…"
mkdir -p "$RELEASES_DIR"
rm -f "$DMG_PATH"

STAGE_DIR="$(mktemp -d -t keywordista-dmg)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R "$APP_BUNDLE" "$STAGE_DIR/"
# /Applications symlink is the "drag-here-to-install" convention every Mac
# user recognizes. No fancy background image in v0.1 — easy to add later.
ln -s /Applications "$STAGE_DIR/Applications"

step "creating $DMG_NAME (UDZO)…"
# UDZO = UDIF zlib-compressed. Good balance of size and decompression speed.
# UDBZ (bzip2) is smaller but mounts noticeably slower on older Macs.
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# ── 5. Sign the DMG ───────────────────────────────────────────────────────

if [[ "$SKIP_SIGN" != "1" ]]; then
    step "signing DMG…"
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

# ── 6. Notarize + staple ──────────────────────────────────────────────────

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    warn "skipping notarization — Gatekeeper will warn on first launch"
else
    step "submitting to Apple notarization (profile: $NOTARYTOOL_PROFILE)…"
    # --wait blocks until Apple finishes. Usually 1–5 minutes.
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait

    step "stapling ticket onto DMG…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    step "Gatekeeper assessment…"
    # spctl --assess simulates what Gatekeeper does on download.
    # --type install is the right policy for an installer artifact.
    spctl --assess --type install --verbose=2 "$DMG_PATH" || true
fi

# ── 7. Report ─────────────────────────────────────────────────────────────

SIZE=$(du -h "$DMG_PATH" | cut -f1)
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

cat <<EOF

✓ ${DMG_PATH#$REPO_ROOT/}
  version: $VERSION
  size:    $SIZE
  sha256:  $SHA256
EOF

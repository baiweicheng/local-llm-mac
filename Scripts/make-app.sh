#!/usr/bin/env bash
#
# make-app.sh — build Blink.app, a double-clickable app bundle,
# from this Swift Package.
#
# Run it from Terminal, in this folder (or anywhere — it finds the
# package root itself):
#
#     bash Scripts/make-app.sh
#
# (No chmod needed when you run it through `bash` like that.)
#
# What it does:
#   1. Builds the package in release mode (swift build -c release).
#   2. Assembles the .app: the executable, an Info.plist generated
#      from Scripts/Info.plist (including all the permission notes
#      macOS shows), and the app icon — decoded from
#      Resources/AppIcon-1024.png.b64 and turned into a proper
#      .icns with the standard macOS sizes.
#   3. Copies along any resource bundles the build produced (the
#      MLX runtime looks for its Metal library in one), best effort.
#   4. Code-signs the bundle: with your Apple Development /
#      Developer ID identity if you have one, otherwise ad-hoc.
#      Ad-hoc is fine for running on your own Mac — the first time
#      you open the app, Gatekeeper will ask you to right-click it
#      and choose Open (see the README).
#
# The finished app lands in  .build-app/Blink.app  — drag it
# into your Applications folder.

set -euo pipefail

# ----------------------------------------------------------------
# The app's name and identity. The product is called Blink (the
# name was chosen on 2026-10-23); APP_NAME is the display name —
# the bundle comes out as Blink.app and shows "Blink" everywhere
# macOS names the app. The Swift package's executable keeps its
# internal product name (LocalLLM, see BUILT_EXECUTABLE below);
# only this display layer carries the product name. BUNDLE_ID
# stays as it is: changing it would make macOS treat the app as
# a different app (fresh permissions, fresh settings).
APP_NAME="Blink"
BUNDLE_ID="com.baiweicheng.localllm"
APP_VERSION="1.0"
MIN_SYSTEM="27.0"
# The executable `swift build` produces — the package's internal
# product name, unchanged by the product rename. It is copied
# into the bundle under $APP_NAME, which is what the generated
# Info.plist names as CFBundleExecutable.
BUILT_EXECUTABLE="LocalLLM"
# ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

OUT_DIR="$ROOT/.build-app"
APP_DIR="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> Building $APP_NAME in release mode…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$BUILT_EXECUTABLE"
if [ ! -x "$BIN_PATH" ]; then
    echo "!! Build finished but no executable at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH" "$CONTENTS/MacOS/$APP_NAME"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

echo "==> Writing Info.plist (name: $APP_NAME, id: $BUNDLE_ID)"
sed -e "s/__APP_NAME__/$APP_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__APP_VERSION__/$APP_VERSION/g" \
    -e "s/__MIN_SYSTEM__/$MIN_SYSTEM/g" \
    "$SCRIPT_DIR/Info.plist" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

echo "==> Building the app icon"
ICON_WORK="$OUT_DIR/icon-work"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK/AppIcon.iconset"
MASTER="$ICON_WORK/AppIcon-1024.png"
# BSD base64 (macOS) spells decode -D; GNU base64 spells it -d.
# Try the macOS spelling first, fall back to the GNU one.
if ! base64 -D -i "$ROOT/Resources/AppIcon-1024.png.b64" -o "$MASTER" 2>/dev/null; then
    base64 --decode "$ROOT/Resources/AppIcon-1024.png.b64" > "$MASTER"
fi
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" \
        --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" \
        --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" \
    -o "$CONTENTS/Resources/AppIcon.icns"

# Some dependencies (the MLX runtime among them) ship resource
# bundles next to the executable and look for them beside the app.
# Copy whatever the build produced into the bundle's Resources —
# best effort: absence is normal for most packages.
found_bundle=0
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$CONTENTS/Resources/"
    found_bundle=1
done
if [ "$found_bundle" = "1" ]; then
    echo "==> Copied dependency resource bundles into the app"
fi

echo "==> Signing"
# Prefer a Developer ID Application identity when one exists (it's
# the distribution identity), and fall back to Apple Development —
# taking the first match of either kind, as this used to, could
# pick the development identity on a Mac that has both.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -n 1 \
    | sed -E 's/.*\"([^\"]+)\".*/\1/' || true)"
if [ -z "${IDENTITY:-}" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' \
        | head -n 1 \
        | sed -E 's/.*\"([^\"]+)\".*/\1/' || true)"
fi
if [ -n "${IDENTITY:-}" ]; then
    echo "    Using identity: $IDENTITY"
    SIGN_WITH="$IDENTITY"
else
    echo "    No Apple signing identity found — signing ad-hoc."
    echo "    (First launch: right-click the app and choose Open.)"
    SIGN_WITH="-"
fi
# Sign nested code FIRST, inside-out (deepest paths first): the
# dependency bundles copied into Resources (the MLX runtime ships
# native code in them) must carry the same signature and hardened
# runtime as the app itself, or library validation can refuse them
# at launch. Both flavors sign identically — hardened runtime
# either way — so the two builds can't behave differently.
find "$APP_DIR" -depth \( -name "*.bundle" -o -name "*.framework" \) -print0 \
    | while IFS= read -r -d '' nested; do
        echo "    Signing nested: $nested"
        codesign --force --options runtime --sign "$SIGN_WITH" "$nested"
    done
# Review finding 21: the MAIN app signs with Blink.entitlements,
# which carries com.apple.security.automation.apple-events — the
# entitlement the quick panel's Apple events to Finder need under
# hardened runtime. (NSAppleEventsUsageDescription in Info.plist
# only words the prompt; it grants nothing.) Nested bundles sign
# without it: the entitlement belongs to the app, not its
# dependencies. Ad-hoc signing accepts --entitlements the same way;
# the first Finder probe still prompts, as it should.
codesign --force --options runtime \
    --entitlements "$SCRIPT_DIR/Blink.entitlements" \
    --sign "$SIGN_WITH" "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || \
    echo "!! codesign verify reported problems (see above); the app may still run."

echo ""
echo "Done: $APP_DIR"
echo "Drag it into your Applications folder, then double-click it."
echo "First launch of an ad-hoc signed app: right-click → Open → Open."

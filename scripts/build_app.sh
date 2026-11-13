#!/usr/bin/env bash
# Builds SidePanel.app from the Swift package. Needs only Apple's Command Line
# Tools (xcode-select --install) — Xcode is optional.
#
#   scripts/build_app.sh                 # Apple Silicon (arm64), ad-hoc signed
#   ARCHS="arm64 x86_64" scripts/build_app.sh   # universal binary
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build_app.sh
#
# Environment:
#   ARCHS          architectures to build (default: arm64)
#   SIGN_IDENTITY  codesigning identity; "-" (default) means ad-hoc
#   BUNDLE_ID      bundle identifier (default: app.sidepanel.SidePanel)
#   VERSION        marketing version (default: contents of VERSION)
#   BUILD_NUMBER   build number (default: git commit count)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS="${ARCHS:-arm64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-app.sidepanel.SidePanel}"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="$ROOT/dist"
APP="$DIST/SidePanel.app"

echo "==> Building SidePanel $VERSION ($BUILD_NUMBER) for: $ARCHS"
binaries=()
for arch in $ARCHS; do
    swift build -c release --product SidePanel --arch "$arch"
    binaries+=("$(swift build -c release --product SidePanel --arch "$arch" --show-bin-path)/SidePanel")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#binaries[@]}" -gt 1 ]; then
    lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/SidePanel"
else
    cp "${binaries[0]}" "$APP/Contents/MacOS/SidePanel"
fi
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (identity: $SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc: runs on this Mac (and others after right-click → Open). Not notarizable.
    codesign --force --sign - --entitlements Packaging/SidePanel.entitlements "$APP"
else
    codesign --force --options runtime --timestamp \
        --entitlements Packaging/SidePanel.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/SidePanel"
echo "==> Done: $APP"

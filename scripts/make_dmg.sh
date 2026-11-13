#!/usr/bin/env bash
# Packages dist/SidePanel.app into a compressed disk image with an
# Applications shortcut. When signing + notarization credentials are present,
# the app and the DMG are both notarized and stapled, so the download opens
# with a plain double-click on any Mac.
#
#   scripts/make_dmg.sh
#
# Optional environment:
#   SIGN_IDENTITY   "Developer ID Application: …" (the app must already be signed with it)
#   NOTARY_PROFILE  or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD — see scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
APP="dist/SidePanel.app"
DMG="dist/SidePanel-$VERSION.dmg"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/build_app.sh first" >&2; exit 1; }

SIGNED=0
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then SIGNED=1; fi
NOTARIZE=0
if [ "$SIGNED" = 1 ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${APPLE_ID:-}" ]; }; then NOTARIZE=1; fi

if [ "$NOTARIZE" = 1 ]; then
    # Notarize and staple the app itself, so it stays trusted after being copied out of the DMG.
    ditto -c -k --keepParent "$APP" dist/SidePanel-notarize.zip
    scripts/notarize.sh dist/SidePanel-notarize.zip
    xcrun stapler staple "$APP"
    rm -f dist/SidePanel-notarize.zip
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "SidePanel" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

if [ "$SIGNED" = 1 ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
    scripts/notarize.sh "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" || true
fi

hdiutil verify "$DMG" >/dev/null
echo "==> Done: $DMG (signed: $SIGNED, notarized: $NOTARIZE)"

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

rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

BG="$STAGE/background.tiff"
if [ -f Packaging/dmg-background@2x.png ]; then
    # Retina-aware background: both resolutions in one TIFF.
    tiffutil -cathidpicheck Packaging/dmg-background.png Packaging/dmg-background@2x.png -out "$BG" >/dev/null 2>&1 \
        || cp Packaging/dmg-background.png "$BG"
fi

made=0
if command -v create-dmg >/dev/null 2>&1 && [ -f "$BG" ]; then
    # Styled installer window: background with instructions, app on the left,
    # Applications shortcut on the right (positions match generate_dmg_background.py).
    BGFILE="$(mktemp -d)/background.tiff"; mv "$BG" "$BGFILE"
    if create-dmg \
        --volname "SidePanel" \
        --volicon Packaging/AppIcon.icns \
        --background "$BGFILE" \
        --window-pos 200 140 \
        --window-size 660 440 \
        --icon-size 112 \
        --text-size 13 \
        --icon "SidePanel.app" 170 170 \
        --hide-extension "SidePanel.app" \
        --app-drop-link 490 170 \
        --no-internet-enable \
        "$DMG" "$STAGE"; then
        made=1
    else
        echo "warning: create-dmg failed; falling back to a plain DMG" >&2
        rm -f "$DMG"
    fi
fi
if [ "$made" = 0 ]; then
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "SidePanel" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
fi

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

#!/usr/bin/env bash
# Packages dist/SidePanel.app into a compressed disk image with an
# Applications shortcut, optionally signing and notarizing it.
#
#   scripts/make_dmg.sh
#
# Optional environment for distribution outside your own Macs:
#   SIGN_IDENTITY     "Developer ID Application: …" — signs the DMG
#   NOTARY_PROFILE    name of a notarytool keychain profile, created once with:
#                     xcrun notarytool store-credentials sidepanel-notary \
#                         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
APP="dist/SidePanel.app"
DMG="dist/SidePanel-$VERSION.dmg"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/build_app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "SidePanel" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

hdiutil verify "$DMG" >/dev/null
echo "==> Done: $DMG"

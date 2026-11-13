#!/usr/bin/env bash
# Submits a file (.zip of an app, or a .dmg) to Apple's notary service and waits.
#   scripts/notarize.sh path/to/file
# Credentials, either:
#   NOTARY_PROFILE  a keychain profile created with `xcrun notarytool store-credentials`
# or all of:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password from appleid.apple.com)
set -euo pipefail
FILE="$1"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
    echo "error: no notarization credentials (set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD)" >&2
    exit 1
fi
echo "==> Notarizing $(basename "$FILE") (usually a few minutes)"
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 30m

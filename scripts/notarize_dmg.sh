#!/bin/bash
# Has Apple notarize build/GitTree.dmg and staples the ticket to it, so it opens without a warning.
#
# Credentials, either a keychain profile (stored once per Mac with
# `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific password>`):
#   NOTARY_KEYCHAIN_PROFILE=<profile> scripts/notarize_dmg.sh
# or an Apple ID with an app-specific password:
#   NOTARY_APPLE_ID=<id> NOTARY_TEAM_ID=<team> NOTARY_PASSWORD=<password> scripts/notarize_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

dmg="build/GitTree.dmg"

if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    : "${NOTARY_APPLE_ID:?Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD}"
    : "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID}"
    : "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD}"
    auth=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

echo "Sending $dmg to Apple's notary service and waiting for the result (usually a few minutes)…"
result=$(xcrun notarytool submit "$dmg" "${auth[@]}" --wait --output-format json)
status=$(/usr/bin/plutil -extract status raw -o - - <<< "$result" 2>/dev/null || echo "unknown")
if [ "$status" != "Accepted" ]; then
    echo "Notarization: $status" >&2
    id=$(/usr/bin/plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)
    if [ -n "$id" ]; then xcrun notarytool log "$id" "${auth[@]}" >&2; fi
    exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Notarized and stapled: $dmg"

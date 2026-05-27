#!/usr/bin/env bash
#
# sign-and-notarize.sh — Developer ID sign every Mach-O inside an .app bundle
# (deep, hardened-runtime, with entitlements), submit to Apple notary, and
# staple the ticket.
#
# Required env vars:
#   APPLE_SIGNING_IDENTITY    e.g. "Developer ID Application: BSV …"
#   APPLE_ID                  notary Apple ID
#   APPLE_APP_SPECIFIC_PASSWORD
#   APPLE_TEAM_ID
#
# Usage: Scripts/sign-and-notarize.sh /path/to/Yggdrasil.app /path/to/Yggdrasil.entitlements
set -euo pipefail

APP_PATH=${1:?"Usage: $0 <Yggdrasil.app> <entitlements.plist>"}
ENTITLEMENTS_PATH=${2:?"Usage: $0 <Yggdrasil.app> <entitlements.plist>"}

: "${APPLE_SIGNING_IDENTITY:?must be set}"
: "${APPLE_ID:?must be set}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?must be set}"
: "${APPLE_TEAM_ID:?must be set}"

# Sign nested helpers and frameworks first, bundle outermost last.
echo "==> Signing nested binaries"
find "$APP_PATH/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "{}"

echo "==> Signing the main bundle"
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true

echo "==> Notarizing"
ZIP_PATH="${APP_PATH%.app}-notarize.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
rm -f "$ZIP_PATH"

echo "==> Stapling"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

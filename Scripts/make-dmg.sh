#!/usr/bin/env bash
#
# make-dmg.sh — wrap Yggdrasil.app in a .dmg with a drag-to-Applications layout.
#
# Usage: Scripts/make-dmg.sh /path/to/Yggdrasil.app /path/to/Yggdrasil-X.Y.Z.dmg
set -euo pipefail

APP_PATH=${1:?"Usage: $0 <Yggdrasil.app> <out.dmg>"}
DMG_PATH=${2:?"Usage: $0 <Yggdrasil.app> <out.dmg>"}
VOL_NAME="Yggdrasil"

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R "$APP_PATH" "$STAGE_DIR/Yggdrasil.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

echo "Wrote $DMG_PATH"

#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_DIR="$ROOT_DIR/dist/HangulFix.app"
DMG_PATH="$ROOT_DIR/dist/HangulFix-macOS.dmg"
DMG_SHA_PATH="$DMG_PATH.sha256"

if [[ ! -d "$APP_DIR" ]]; then
    "$ROOT_DIR/scripts/create-app-bundle.sh"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE_DIR="$WORK_DIR/HangulFix"
mkdir -p "$STAGE_DIR"

ditto "$APP_DIR" "$STAGE_DIR/HangulFix.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH" "$DMG_SHA_PATH"
hdiutil create \
    -volname "HangulFix" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

shasum -a 256 "$DMG_PATH" > "$DMG_SHA_PATH"
echo "$DMG_PATH"

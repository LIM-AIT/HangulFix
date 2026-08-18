#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity.}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a keychain profile created with xcrun notarytool store-credentials.}"

VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
DMG_PATH="dist/HangulFix-$VERSION-macOS.dmg"
DMG_SHA_PATH="$DMG_PATH.sha256"

export CODESIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"

rm -rf dist/HangulFix.app
rm -f "$DMG_PATH" "$DMG_SHA_PATH"

./scripts/create-app-bundle.sh
codesign --verify --deep --strict --verbose=2 dist/HangulFix.app

./scripts/create-dmg.sh

xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$DMG_SHA_PATH"

echo ""
echo "Notarized release ready:"
echo "$ROOT_DIR/$DMG_PATH"

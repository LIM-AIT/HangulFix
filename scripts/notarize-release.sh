#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity.}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a keychain profile created with xcrun notarytool store-credentials.}"

export CODESIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"

rm -rf dist/HangulFix.app
rm -f dist/HangulFix-macOS.dmg dist/HangulFix-macOS.dmg.sha256

./scripts/create-app-bundle.sh
codesign --verify --deep --strict --verbose=2 dist/HangulFix.app

./scripts/create-dmg.sh

xcrun notarytool submit dist/HangulFix-macOS.dmg \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

xcrun stapler staple dist/HangulFix-macOS.dmg
xcrun stapler validate dist/HangulFix-macOS.dmg

shasum -a 256 dist/HangulFix-macOS.dmg > dist/HangulFix-macOS.dmg.sha256

echo ""
echo "Notarized release ready:"
echo "$ROOT_DIR/dist/HangulFix-macOS.dmg"

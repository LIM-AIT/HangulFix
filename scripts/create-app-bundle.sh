#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="0.8.0"
BUILD_NUMBER="8"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release --product HangulFix
BIN_DIR="$(swift build -c release --show-bin-path)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/HangulFix.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/HangulFix" "$MACOS_DIR/HangulFix"
chmod +x "$MACOS_DIR/HangulFix"

"$ROOT_DIR/scripts/create-app-icon.sh" "$RESOURCES_DIR/HangulFix.icns" >/dev/null

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>HangulFix</string>
    <key>CFBundleExecutable</key>
    <string>HangulFix</string>
    <key>CFBundleIconFile</key>
    <string>HangulFix</string>
    <key>CFBundleIdentifier</key>
    <string>com.limait.HangulFix</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>HangulFix</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 LIM-AIT. All rights reserved.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$APP_DIR"
    else
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$APP_DIR"
    fi
fi

echo ""
echo "HangulFix.app created:"
echo "$APP_DIR"
echo "Version: $APP_VERSION ($BUILD_NUMBER)"
echo "Signing identity: $SIGN_IDENTITY"
echo ""
echo "Run: open '$APP_DIR'"

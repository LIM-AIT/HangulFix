#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH="$ROOT_DIR/dist/HangulFix.app"
ZIP_PATH="$ROOT_DIR/dist/HangulFix-macOS.zip"
ZIP_SHA_PATH="$ZIP_PATH.sha256"
DMG_PATH="$ROOT_DIR/dist/HangulFix-macOS.dmg"
DMG_SHA_PATH="$DMG_PATH.sha256"
EXPECTED_BUNDLE_ID="com.limait.HangulFix"
EXPECTED_VERSION="0.8.0"
EXPECTED_ICON="HangulFix"

fail() {
    echo "Distribution verification failed: $*" >&2
    exit 1
}

for path in "$APP_PATH" "$ZIP_PATH" "$ZIP_SHA_PATH" "$DMG_PATH" "$DMG_SHA_PATH"; do
    [[ -e "$path" ]] || fail "missing artifact: $path"
done

shasum -a 256 -c "$ZIP_SHA_PATH"
shasum -a 256 -c "$DMG_SHA_PATH"

verify_app() {
    local app="$1"
    local plist="$app/Contents/Info.plist"

    [[ -x "$app/Contents/MacOS/HangulFix" ]] || fail "missing executable in $app"
    [[ -f "$app/Contents/Resources/HangulFix.icns" ]] || fail "missing icon in $app"
    [[ -f "$plist" ]] || fail "missing Info.plist in $app"

    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$EXPECTED_BUNDLE_ID" ]] \
        || fail "unexpected bundle identifier in $app"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$EXPECTED_VERSION" ]] \
        || fail "unexpected bundle version in $app"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" == "$EXPECTED_ICON" ]] \
        || fail "unexpected app icon metadata in $app"

    codesign --verify --deep --strict --verbose=2 "$app"
}

verify_app "$APP_PATH"

WORK_DIR="$(mktemp -d)"
MOUNT_DIR="$WORK_DIR/dmg"
ZIP_DIR="$WORK_DIR/zip"
mkdir -p "$MOUNT_DIR" "$ZIP_DIR"
DMG_ATTACHED=0

cleanup() {
    if [[ "$DMG_ATTACHED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ditto -x -k "$ZIP_PATH" "$ZIP_DIR"
[[ -d "$ZIP_DIR/HangulFix.app" ]] || fail "ZIP does not contain HangulFix.app"
verify_app "$ZIP_DIR/HangulFix.app"

hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_DIR" \
    "$DMG_PATH" >/dev/null
DMG_ATTACHED=1

[[ -d "$MOUNT_DIR/HangulFix.app" ]] || fail "DMG does not contain HangulFix.app"
[[ -L "$MOUNT_DIR/Applications" ]] || fail "DMG does not contain Applications symlink"
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] \
    || fail "DMG Applications shortcut does not target /Applications"
verify_app "$MOUNT_DIR/HangulFix.app"

hdiutil detach "$MOUNT_DIR" -quiet
DMG_ATTACHED=0

echo ""
echo "Distribution verification PASSED"
echo "Verified: checksums, ZIP extraction, DMG mount, app metadata, icon, executable, codesign, Applications shortcut"

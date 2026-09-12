#!/bin/bash
# Package the exported app; use its version for the DMG filename.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$REPO_ROOT/GitStride.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Run ./build_release.sh before packaging GitStride." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
DMG_PATH="$REPO_ROOT/GitStride-$VERSION.dmg"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitstride-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_PATH" "$STAGING_DIR/GitStride.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname GitStride -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

printf 'Created %s\n' "$DMG_PATH"
printf 'Next: notarize and staple this DMG, then run ./update_appcast.sh "%s".\n' "$DMG_PATH"
echo "See docs/releasing.md for the notarization and publication steps."

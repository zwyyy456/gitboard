#!/bin/bash
# Archive and export with the team configured in the Xcode project.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$REPO_ROOT/build/release"
ARCHIVE_PATH="$RELEASE_DIR/GitStride.xcarchive"
EXPORT_PATH="$RELEASE_DIR/export"
mkdir -p "$RELEASE_DIR"

# Xcode signs embedded Sparkle helpers as part of archive/export.
xcodebuild -project "$REPO_ROOT/GitStride.xcodeproj" -scheme GitStride \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$RELEASE_DIR/DerivedData" \
    -archivePath "$ARCHIVE_PATH" archive

cat > "$RELEASE_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST

# The export inherits the archive's team. A Developer ID Application
# certificate and its private key must already be installed on this Mac.
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist"
codesign --verify --deep --strict "$EXPORT_PATH/GitStride.app"

SPARKLE_BIN="$RELEASE_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIGNING_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account gitstride -p)
BUNDLED_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$EXPORT_PATH/GitStride.app/Contents/Info.plist")
if [ "$SIGNING_PUBLIC_KEY" != "$BUNDLED_PUBLIC_KEY" ]; then
    echo "The app's SUPublicEDKey must match the gitstride Sparkle key. See docs/releasing.md." >&2
    exit 1
fi

rm -rf "$REPO_ROOT/GitStride.app"
ditto "$EXPORT_PATH/GitStride.app" "$REPO_ROOT/GitStride.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/GitStride.app/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$REPO_ROOT/GitStride.app/Contents/Info.plist")
printf 'Exported GitStride %s (build %s). Next: ./create_dmg.sh\n' "$VERSION" "$BUILD_NUMBER"

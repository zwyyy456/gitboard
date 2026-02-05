#!/bin/bash

# Build and sign GitBoard for release
# Uses existing Developer ID certificate

set -e

APP_NAME="GitBoard"
VERSION="1.0.0"
BUILD_NUMBER="1"
BUNDLE_ID="co.yogesh.GitBoard"
SIGNING_IDENTITY="Developer ID Application: Yogesh Dhakal (7WYP3LRDL8)"

echo "=== Building $APP_NAME v$VERSION (build $BUILD_NUMBER) ==="

# Clean previous build
rm -rf build
rm -rf "$APP_NAME.app"

# Build Release using xcodebuild
echo "Building Release configuration..."
xcodebuild -scheme GitBoard \
    -configuration Release \
    -derivedDataPath ./build \
    DEVELOPMENT_TEAM=7WYP3LRDL8 \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    clean build

# Copy app from build directory
APP_PATH="./build/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    exit 1
fi

cp -R "$APP_PATH" "./${APP_NAME}.app"

# Create entitlements file
ENTITLEMENTS_FILE="/tmp/gitboard-entitlements.plist"
cat > "$ENTITLEMENTS_FILE" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Sign Sparkle framework if present (inside-out, deepest first)
if [ -d "$APP_NAME.app/Contents/Frameworks/Sparkle.framework" ]; then
    echo "Signing Sparkle framework..."
    SPARKLE_FW="$APP_NAME.app/Contents/Frameworks/Sparkle.framework/Versions/B"

    # Sign XPC services
    if [ -d "$SPARKLE_FW/XPCServices/Installer.xpc" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FW/XPCServices/Installer.xpc"
    fi
    if [ -d "$SPARKLE_FW/XPCServices/Downloader.xpc" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FW/XPCServices/Downloader.xpc"
    fi

    # Sign Updater.app
    if [ -d "$SPARKLE_FW/Updater.app" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FW/Updater.app"
    fi

    # Sign Autoupdate helper
    if [ -f "$SPARKLE_FW/Autoupdate" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FW/Autoupdate"
    fi

    # Sign Sparkle dylib
    if [ -f "$SPARKLE_FW/Sparkle" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE_FW/Sparkle"
    fi

    # Sign framework bundle
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_NAME.app/Contents/Frameworks/Sparkle.framework/Versions/B"
fi

# Sign main binary
echo "Signing main binary..."
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGNING_IDENTITY" "$APP_NAME.app/Contents/MacOS/$APP_NAME"

# Sign entire app bundle
echo "Signing app bundle..."
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGNING_IDENTITY" "$APP_NAME.app"

# Cleanup
rm -f "$ENTITLEMENTS_FILE"

# Verify signature
echo "Verifying signature..."
codesign --verify --deep --strict "$APP_NAME.app"

echo ""
echo "✅ Build complete: $APP_NAME.app"
echo ""
echo "Next: Run ./create_dmg.sh to create the DMG"

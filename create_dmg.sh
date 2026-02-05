#!/bin/bash

# Create DMG installer for GitBoard

set -e

APP_NAME="GitBoard"
VERSION="1.0.0"
DMG_FILE="${APP_NAME}-${VERSION}.dmg"
TEMP_DIR="dmg_temp"

echo "Creating DMG for $APP_NAME..."

# Build the app first if it doesn't exist
if [ ! -d "$APP_NAME.app" ]; then
    echo "Building app first..."
    ./build_release.sh
fi

# Clean up any previous temp directory
rm -rf "$TEMP_DIR"
rm -f "$DMG_FILE"

# Create temp directory structure
mkdir -p "$TEMP_DIR"

# Copy app to temp directory (use ditto to preserve symlinks)
ditto "$APP_NAME.app" "$TEMP_DIR/$APP_NAME.app"

# Create symlink to Applications folder
ln -s /Applications "$TEMP_DIR/Applications"

# Create the DMG
echo "Creating DMG..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$TEMP_DIR" \
    -ov -format UDZO \
    "$DMG_FILE"

# Clean up
rm -rf "$TEMP_DIR"

# Get file size for appcast
FILE_SIZE=$(stat -f%z "$DMG_FILE")

echo ""
echo "✅ DMG created: $DMG_FILE"
echo "   Size: $FILE_SIZE bytes"
echo ""
echo "Next steps:"
echo ""
echo "1. Notarize the DMG:"
echo "   xcrun notarytool submit $DMG_FILE --keychain-profile \"notarytool-profile\" --wait"
echo ""
echo "2. Staple the ticket:"
echo "   xcrun stapler staple $DMG_FILE"
echo ""
echo "3. Update appcast:"
echo "   ./update_appcast.sh $VERSION \"Release notes\""
echo ""
echo "4. Upload to server:"
echo "   - $DMG_FILE → https://yogesh.co/gitboard/"
echo "   - appcast.xml → https://yogesh.co/gitboard/"

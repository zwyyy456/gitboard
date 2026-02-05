#!/bin/bash

# Update appcast.xml for Sparkle updates
# Usage: ./update_appcast.sh VERSION "Release notes"
# Example: ./update_appcast.sh 1.1.0 "Added dark mode support"

set -e

VERSION=$1
NOTES=$2
DMG_FILE="GitBoard-${VERSION}.dmg"
APPCAST_FILE="appcast.xml"
PRIVATE_KEY="$HOME/.sparkle_private_key"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 VERSION \"Release notes\""
    echo "Example: $0 1.1.0 \"Added dark mode support\""
    exit 1
fi

if [ ! -f "$DMG_FILE" ]; then
    echo "Error: $DMG_FILE not found"
    echo "Build the DMG first using create_dmg.sh"
    exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
    echo "Error: Sparkle private key not found at $PRIVATE_KEY"
    echo "Generate one with: ./generate_keys"
    exit 1
fi

# Get DMG file size
FILE_SIZE=$(stat -f%z "$DMG_FILE")

# Sign the DMG and get signature
echo "Signing $DMG_FILE..."
# You need Sparkle's sign_update tool - path may vary
SIGN_TOOL="$HOME/.build/checkouts/Sparkle/bin/sign_update"
if [ ! -f "$SIGN_TOOL" ]; then
    # Try alternative location from Xcode derived data
    SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)
fi

if [ -z "$SIGN_TOOL" ] || [ ! -f "$SIGN_TOOL" ]; then
    echo "Error: sign_update tool not found"
    echo "Build Sparkle first or locate the sign_update binary"
    exit 1
fi

SIGNATURE=$("$SIGN_TOOL" "$DMG_FILE" 2>&1 | grep "sparkle:edSignature" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature"
    exit 1
fi

echo "Signature: $SIGNATURE"

# Get current build number and increment
CURRENT_BUILD=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$APPCAST_FILE" | head -1 | grep -o '[0-9]*')
NEW_BUILD=$((CURRENT_BUILD + 1))

# Generate pubDate
PUB_DATE=$(date -R)

# Create new item entry
NEW_ITEM="        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <h2>What's New</h2>
                <p>$NOTES</p>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$NEW_BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"https://yogesh.co/gitboard/$DMG_FILE\"
                sparkle:edSignature=\"$SIGNATURE\"
                length=\"$FILE_SIZE\"
                type=\"application/octet-stream\"/>
        </item>"

# Backup current appcast
cp "$APPCAST_FILE" "${APPCAST_FILE}.bak"

# Insert new item after <language>en</language>
sed -i '' "/<language>en<\/language>/a\\
\\
$NEW_ITEM
" "$APPCAST_FILE"

echo ""
echo "Updated $APPCAST_FILE with version $VERSION (build $NEW_BUILD)"
echo ""
echo "Next steps:"
echo "1. Upload $DMG_FILE to https://yogesh.co/gitboard/"
echo "2. Upload $APPCAST_FILE to https://yogesh.co/gitboard/"
echo "3. Test the update by running an older version of the app"

#!/bin/bash
# Generate a signed update entry from a notarized DMG using Sparkle.
# Usage: ./update_appcast.sh path/to/GitStride-VERSION.dmg [release-notes.html]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DMG_PATH="${1:-}"
NOTES_PATH="${2:-}"
if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    echo "Usage: $0 path/to/GitStride-VERSION.dmg [release-notes.html]" >&2
    exit 1
fi

# The release build resolves Sparkle at this deterministic artifact location.
SPARKLE_BIN="$REPO_ROOT/build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "Sparkle tools are missing. Run ./build_release.sh first." >&2
    exit 1
fi
xcrun stapler validate "$DMG_PATH"

DMG_NAME=$(basename "$DMG_PATH")
case "$DMG_NAME" in
    GitStride-*.dmg) VERSION="${DMG_NAME#GitStride-}"; VERSION="${VERSION%.dmg}" ;;
    *) echo "Expected a DMG created by ./create_dmg.sh." >&2; exit 1 ;;
esac

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitstride-appcast.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
cp "$DMG_PATH" "$STAGING_DIR/$DMG_NAME"
cp "$REPO_ROOT/appcast.xml" "$STAGING_DIR/appcast.xml"
if [ -n "$NOTES_PATH" ]; then
    cp "$NOTES_PATH" "$STAGING_DIR/${DMG_NAME%.dmg}.html"
fi

"$SPARKLE_BIN/generate_appcast" \
    --account gitstride \
    --download-url-prefix "https://github.com/zwyyy456/GitStride/releases/download/v$VERSION/" \
    --link "https://gitstride.zwyyy456.tech" \
    --embed-release-notes --maximum-deltas 0 --maximum-versions 0 \
    "$STAGING_DIR"

# Check the filename against the version extracted by Sparkle from the DMG.
# Never invent or increment a build number separately from the packaged app.
SIGNATURE=$(python3 - "$STAGING_DIR/appcast.xml" "$DMG_NAME" "$VERSION" <<'PY'
import sys
import urllib.parse
import xml.etree.ElementTree as ET
feed, name, version = sys.argv[1:]
namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(feed).findall("./channel/item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    filename = urllib.parse.unquote(urllib.parse.urlparse(enclosure.get("url", "")).path.rsplit("/", 1)[-1])
    if filename == name:
        if item.findtext("sparkle:shortVersionString", namespaces=namespace) != version:
            raise SystemExit("DMG filename does not match the packaged app version.")
        signature = enclosure.get("{" + namespace["sparkle"] + "}edSignature")
        if not signature:
            raise SystemExit("Sparkle did not sign the update. Check the gitstride Keychain account and the app's SUPublicEDKey.")
        print(signature)
        break
else:
    raise SystemExit("Sparkle did not generate an update entry for this DMG.")
PY
)
"$SPARKLE_BIN/sign_update" --account gitstride --verify "$DMG_PATH" "$SIGNATURE"
cp "$STAGING_DIR/appcast.xml" "$REPO_ROOT/appcast.xml"
printf 'Updated appcast.xml for %s. Upload the DMG to GitHub release v%s before publishing the feed.\n' "$DMG_NAME" "$VERSION"

#!/bin/bash
# Build a drag-and-drop macOS DMG installer for Simple Video.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Simple Video"
APP="$APP_NAME.app"
VERSION="${VERSION:-1.0}"
DIST_DIR="dist"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/simple-video-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

./build.sh

mkdir -p "$DIST_DIR"
rm -f "$DMG"

echo "→ Creating drag-and-drop installer layout…"
ditto "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications - drop here"
cat > "$STAGING/INSTALL - read me.txt" <<TXT
Install Simple Video
====================

1. Drag "Simple Video.app" onto "Applications - drop here".
2. Wait for the copy to finish.
3. Open Simple Video from your Applications folder.

After installation, you can eject this disk image.
TXT

echo "→ Creating $DMG …"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "✓ Built installer: $(pwd)/$DMG"
echo "  Open it, then drag $APP onto \"Applications - drop here\"."

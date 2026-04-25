#!/bin/bash
# Build FFmpegGUI as a native macOS .app bundle
set -e

cd "$(dirname "$0")"
APP="FFmpeg GUI.app"

echo "→ Building (release)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/FFmpegGUI"
if [ ! -f "$BIN" ]; then
    echo "✗ Build failed - binary not found"
    exit 1
fi

echo "→ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/FFmpegGUI"
chmod +x "$APP/Contents/MacOS/FFmpegGUI"

# Copy icon if present
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
    ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FFmpeg GUI</string>
    <key>CFBundleDisplayName</key><string>FFmpeg GUI</string>
    <key>CFBundleIdentifier</key><string>local.gavincheng.ffmpeggui</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>FFmpegGUI</string>
    ${ICON_KEY}
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper doesn't block immediately on launch
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ Built: $(pwd)/$APP"
echo "  Double-click it in Finder, or run: open \"$APP\""

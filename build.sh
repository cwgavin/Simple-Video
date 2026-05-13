#!/bin/bash
# Build Simple Video as a native macOS .app bundle
set -e

cd "$(dirname "$0")"
APP="Simple Video.app"

echo "→ Building (release)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/SimpleVideo"
if [ ! -f "$BIN" ]; then
    echo "✗ Build failed - binary not found"
    exit 1
fi

echo "→ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Frameworks" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Resources/bin"

cp "$BIN" "$APP/Contents/MacOS/SimpleVideo"
chmod +x "$APP/Contents/MacOS/SimpleVideo"

copy_dir_contents() {
    local src="$1"
    local dest="$2"
    if [ -d "$src" ]; then
        cp -R "$src"/. "$dest"/
    fi
}

copy_executable_if_missing() {
    local dest="$1"
    shift

    if [ -x "$dest" ]; then
        return 0
    fi

    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            cp "$candidate" "$dest"
            chmod +x "$dest"
            return 0
        fi
    done

    return 1
}

copy_dir_contents "Resources/bin" "$APP/Contents/Resources/bin"

copy_executable_if_missing \
    "$APP/Contents/Resources/bin/ffmpeg" \
    "${SIMPLE_VIDEO_FFMPEG_BIN:-}" \
    /opt/homebrew/bin/ffmpeg \
    /usr/local/bin/ffmpeg \
    /opt/local/bin/ffmpeg || true

copy_executable_if_missing \
    "$APP/Contents/Resources/bin/ffprobe" \
    "${SIMPLE_VIDEO_FFPROBE_BIN:-}" \
    /opt/homebrew/bin/ffprobe \
    /usr/local/bin/ffprobe \
    /opt/local/bin/ffprobe || true

copy_executable_if_missing \
    "$APP/Contents/Resources/bin/whisper-cli" \
    "${SIMPLE_VIDEO_WHISPER_BIN:-}" \
    /opt/homebrew/bin/whisper-cli \
    /usr/local/bin/whisper-cli \
    /opt/local/bin/whisper-cli || true

is_system_dylib() {
    case "$1" in
        /System/*|/usr/lib/*|@*) return 0 ;;
        *) return 1 ;;
    esac
}

non_system_dylibs() {
    otool -L "$1" 2>/dev/null | awk 'NR > 1 { print $1 }' | while read -r dep; do
        if [ -n "$dep" ] && ! is_system_dylib "$dep"; then
            echo "$dep"
        fi
    done
}

add_rpath_if_missing() {
    local file="$1"
    local rpath="$2"
    if ! otool -l "$file" 2>/dev/null | grep -A2 LC_RPATH | grep -q "path $rpath "; then
        install_name_tool -add_rpath "$rpath" "$file" 2>/dev/null || true
    fi
}

bundle_dylib_dependencies() {
    local root
    local queue_file="$APP/Contents/Frameworks/.dylib-queue"
    local seen_file="$APP/Contents/Frameworks/.dylib-seen"
    : > "$queue_file"
    : > "$seen_file"

    for root in "$@"; do
        if [ -f "$root" ]; then
            non_system_dylibs "$root" >> "$queue_file"
        fi
    done

    while read -r dep; do
        [ -n "$dep" ] || continue
        grep -Fxq "$dep" "$seen_file" && continue
        echo "$dep" >> "$seen_file"

        if [ ! -f "$dep" ]; then
            echo "  ! missing dylib dependency: $dep"
            continue
        fi

        local name
        name="$(basename "$dep")"
        local bundled="$APP/Contents/Frameworks/$name"
        if [ ! -f "$bundled" ]; then
            cp "$dep" "$bundled"
            chmod u+w "$bundled"
            install_name_tool -id "@rpath/$name" "$bundled" 2>/dev/null || true
            non_system_dylibs "$bundled" >> "$queue_file"
        fi
    done < "$queue_file"

    local target
    for target in "$@"; do
        if [ -f "$target" ]; then
            add_rpath_if_missing "$target" "@executable_path/../../Frameworks"
        fi
    done

    while read -r dep; do
        [ -n "$dep" ] || continue
        local name
        name="$(basename "$dep")"
        local replacement="@rpath/$name"
        for target in "$@"; do
            if [ -f "$target" ]; then
                install_name_tool -change "$dep" "$replacement" "$target" 2>/dev/null || true
            fi
        done
        for target in "$APP/Contents/Frameworks"/*.dylib; do
            [ -f "$target" ] || continue
            install_name_tool -change "$dep" "$replacement" "$target" 2>/dev/null || true
        done
    done < "$seen_file"

    rm -f "$queue_file" "$seen_file"
}

echo "→ Bundling non-system runtime libraries…"
bundle_dylib_dependencies \
    "$APP/Contents/Resources/bin/ffmpeg" \
    "$APP/Contents/Resources/bin/ffprobe" \
    "$APP/Contents/Resources/bin/whisper-cli"

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
    <key>CFBundleName</key><string>Simple Video</string>
    <key>CFBundleDisplayName</key><string>Simple Video</string>
    <key>CFBundleIdentifier</key><string>local.gavincheng.simplevideo</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>SimpleVideo</string>
    ${ICON_KEY}
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign nested runtime code first, then the app wrapper.
for signed_item in "$APP/Contents/Resources/bin/"* "$APP/Contents/Frameworks/"*.dylib; do
    if [ -f "$signed_item" ]; then
        codesign --force --sign - "$signed_item" 2>/dev/null || true
    fi
done
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "→ Bundled runtime summary"
for tool in ffmpeg ffprobe whisper-cli; do
    if [ -x "$APP/Contents/Resources/bin/$tool" ]; then
        echo "  ✓ $tool bundled"
    else
        echo "  ! $tool not bundled"
    fi
done
if compgen -G "$APP/Contents/Frameworks/*.dylib" > /dev/null; then
    echo "  ✓ runtime dylibs bundled"
else
    echo "  i no extra runtime dylibs needed"
fi

echo "  i whisper models are downloaded by users into Application Support"

echo "✓ Built: $(pwd)/$APP"
echo "  Double-click it in Finder, or run: open \"$APP\""

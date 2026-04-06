#!/bin/bash
# Build a minimal .app wrapper so Spotlight can find "Wispr Addons" via Cmd+Space
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

# Build the Swift app
echo "Building VictorAddons Swift app..."
cd "$DIR"
swift build
echo "VictorAddons built."

APP_NAME="Victor Addons"
APP_DIR="/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building $APP_NAME.app..."

# Convert PNG to ICNS
ICONSET=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$DIR/app/icon_chat.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1
    DOUBLE=$((SIZE * 2))
    if [ $DOUBLE -le 1024 ]; then
        sips -z $DOUBLE $DOUBLE "$DIR/app/icon_chat.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1
    fi
done
ICNS_FILE="$DIR/app/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS_FILE"
rm -rf "$(dirname "$ICONSET")"

# Create app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ICNS_FILE" "$RESOURCES/AppIcon.icns"

# Compile native launcher (requests mic permission, then runs start.sh)
swiftc -O -o "$MACOS/$APP_NAME" "$DIR/launcher.swift" \
    -framework AVFoundation -framework Foundation

# Store repo path for the launcher to read
echo -n "$DIR" > "$RESOURCES/repo_path"

# Ad-hoc code sign so macOS recognizes it for microphone TCC prompt
codesign --force --sign - "$APP_DIR"

# Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>ro.victorrentea.macos-addons</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Victor Addons needs microphone access for live transcription.</string>
</dict>
</plist>
PLIST

echo "✅ Installed $APP_DIR"
echo "   Launch via Spotlight (Cmd+Space) → 'Victor Addons'"

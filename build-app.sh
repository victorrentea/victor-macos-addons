#!/bin/bash
# Build a minimal .app wrapper so Spotlight can find "Wispr Addons" via Cmd+Space
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

# Build the Swift app
echo "Building VictorAddons Swift app..."
cd "$DIR"
APP_NAME="Victor Addons"
APP_DIR="/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BUILD_CONFIG="release"

BUILD_TIMESTAMP=$(date "+%b %-d, %H:%M")
sed -i '' "s/static let BUILD_TIME = .*/static let BUILD_TIME = \"$BUILD_TIMESTAMP\"/" "$DIR/Sources/VictorAddons/MenuBarManager.swift"
echo "Build timestamp: $BUILD_TIMESTAMP"

swift build -c "$BUILD_CONFIG"
echo "VictorAddons built."

echo "Building $APP_NAME.app..."

# Convert PNG to ICNS
ICONSET=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$DIR/Sources/VictorAddons/Resources/icon_chat.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1
    DOUBLE=$((SIZE * 2))
    if [ $DOUBLE -le 1024 ]; then
        sips -z $DOUBLE $DOUBLE "$DIR/Sources/VictorAddons/Resources/icon_chat.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1
    fi
done
ICNS_FILE="$DIR/Sources/VictorAddons/Resources/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS_FILE"
rm -rf "$(dirname "$ICONSET")"

# Create app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ICNS_FILE" "$RESOURCES/AppIcon.icns"

# Use release binary as the app bundle executable.
# Avoids relying on debug-run artifacts that can create separate TCC entries.
cp "$DIR/.build/arm64-apple-macosx/$BUILD_CONFIG/VictorAddons" "$MACOS/$APP_NAME"

# Info.plist (must be written before signing)
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
    <key>NSAccessibilityUsageDescription</key>
    <string>Victor Addons needs accessibility access for keyboard shortcuts and clipboard monitoring.</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when provided.
# Example: export CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    if security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" | rg -Fq "Victor Addons Local Code Signing"; then
        SIGNING_IDENTITY="Victor Addons Local Code Signing"
    fi
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
    echo "⚠️  CODESIGN_IDENTITY not set; using ad-hoc signature (Accessibility may re-prompt after updates)."
    codesign --force --sign - "$APP_DIR"
fi

echo "✅ Installed $APP_DIR"
echo "   Launch via Spotlight (Cmd+Space) → 'Victor Addons'"

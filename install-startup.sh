#!/bin/bash
# Install victor-macos-addons as a macOS login item (LaunchAgent)
set -e

PLIST_NAME="ro.victorrentea.macos-addons.plist"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Unload old wispr-addons agent if present
OLD_PLIST="$HOME/Library/LaunchAgents/ro.victorrentea.wispr-addons.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    echo "Removed old wispr-addons LaunchAgent"
fi

# Install new unified agent
ln -sf "$PLIST_SRC" "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "✅ victor-macos-addons installed as login item"
echo "   Logs: tail -f /tmp/victor-macos-addons.log"

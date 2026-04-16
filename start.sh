#!/bin/bash
# Launch VictorAddons — unified Swift process (menu bar + overlay)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

LOG=/tmp/victor-macos-addons.log
echo "$(date '+%H:%M:%S') Starting VictorAddons..." >> "$LOG"

BUNDLE_BIN="/Applications/Victor Addons.app/Contents/MacOS/Victor Addons"
if [ ! -x "$BUNDLE_BIN" ]; then
    echo "$(date '+%H:%M:%S') VictorAddons not installed — run: ./build-app.sh" >> "$LOG"
    exit 1
fi

# Forward tablet→Mac port via USB (no-op if tablet not connected)
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
[ -x "$ADB" ] && "$ADB" reverse tcp:55123 tcp:55123 >> "$LOG" 2>&1 || true

exec "$BUNDLE_BIN" "wss://interact.victorrentea.ro" >> "$LOG" 2>&1

#!/bin/bash
# Launch VictorAddons — unified Swift process (menu bar + overlay)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

LOG=/tmp/victor-macos-addons.log
echo "$(date '+%H:%M:%S') Starting VictorAddons..." >> "$LOG"

VICTOR_BIN="$DIR/.build/arm64-apple-macosx/debug/VictorAddons"
if [ ! -x "$VICTOR_BIN" ]; then
    echo "$(date '+%H:%M:%S') VictorAddons not built — run: swift build" >> "$LOG"
    exit 1
fi

exec "$VICTOR_BIN" "wss://interact.victorrentea.ro" >> "$LOG" 2>&1

#!/bin/bash
# Launch all victor-macos-addons modules
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

LOG=/tmp/victor-macos-addons.log
echo "$(date '+%H:%M:%S') Starting victor-macos-addons..." >> "$LOG"

# --- desktop-overlay (Swift app, background) ---
OVERLAY_BIN="$DIR/desktop-overlay/.build/arm64-apple-macosx/debug/DesktopOverlay"
if [ -x "$OVERLAY_BIN" ]; then
    cd "$DIR/desktop-overlay"
    "$OVERLAY_BIN" "wss://interact.victorrentea.ro" >> "$LOG" 2>&1 &
    echo "$(date '+%H:%M:%S') desktop-overlay started (pid $!)" >> "$LOG"
else
    echo "$(date '+%H:%M:%S') desktop-overlay not built — skipping (run: cd desktop-overlay && swift build)" >> "$LOG"
fi

# --- app (Python menu bar app, foreground — needs main thread for GUI) ---
cd "$DIR/app"
echo "$(date '+%H:%M:%S') app starting..." >> "$LOG"
exec /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 -u app.py >> "$LOG" 2>&1

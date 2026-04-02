#!/bin/bash
# Launch all victor-macos-addons modules
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

LOG=/tmp/victor-macos-addons.log
echo "$(date '+%H:%M:%S') Starting victor-macos-addons..." >> "$LOG"

# --- wispr-flow (Python daemon) ---
cd "$DIR/wispr-flow"
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 app.py >> "$LOG" 2>&1 &
WISPR_PID=$!
echo "$(date '+%H:%M:%S') wispr-flow started (pid $WISPR_PID)" >> "$LOG"

# --- desktop-overlay (Swift app) ---
OVERLAY_BIN="$DIR/desktop-overlay/.build/arm64-apple-macosx/debug/DesktopOverlay"
if [ -x "$OVERLAY_BIN" ]; then
    cd "$DIR/desktop-overlay"
    "$OVERLAY_BIN" "wss://interact.victorrentea.ro" >> "$LOG" 2>&1 &
    OVERLAY_PID=$!
    echo "$(date '+%H:%M:%S') desktop-overlay started (pid $OVERLAY_PID)" >> "$LOG"
else
    echo "$(date '+%H:%M:%S') desktop-overlay not built — skipping (run: cd desktop-overlay && swift build)" >> "$LOG"
fi

# Wait for all children — if any exits, keep the others running
wait

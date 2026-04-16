#!/bin/bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:55123}"
ACTION="${1:-toggle}"
WAIT_SECONDS="${WAIT_SECONDS:-1.0}"

fetch_state() {
    curl -fsS "$BASE_URL/test/state"
}

print_state() {
    local label="$1"
    local json="$2"
    python3 - "$label" "$json" <<'PY'
import json
import sys

label = sys.argv[1]
state = json.loads(sys.argv[2])

print(f"{label} running={state.get('running')} enabled_pref={state.get('enabled_preference')} ui_transcribing={state.get('ui_transcribing')} icon={state.get('icon_mode')} menu=\"{state.get('menu_title')}\"")
PY
}

before="$(fetch_state)"
print_state "before" "$before"

case "$ACTION" in
    start)
        curl -fsS "$BASE_URL/test/transcription/start" >/dev/null
        ;;
    stop)
        curl -fsS "$BASE_URL/test/transcription/stop" >/dev/null
        ;;
    toggle)
        curl -fsS "$BASE_URL/test/transcription/toggle" >/dev/null
        ;;
    *)
        echo "Usage: $0 [start|stop|toggle]" >&2
        exit 2
        ;;
esac

sleep "$WAIT_SECONDS"

after="$(fetch_state)"
print_state "after " "$after"

python3 - "$ACTION" "$before" "$after" <<'PY'
import json
import sys

action = sys.argv[1]
before = json.loads(sys.argv[2])
after = json.loads(sys.argv[3])

ok = True
messages = []

if action == "toggle":
    if before.get("ui_transcribing") == after.get("ui_transcribing"):
        ok = False
        messages.append("ui_transcribing did not change")
elif action == "start":
    if not after.get("enabled_preference"):
        ok = False
        messages.append("enabled_preference is false after start")
elif action == "stop":
    if after.get("enabled_preference"):
        ok = False
        messages.append("enabled_preference is true after stop")

if after.get("running") != after.get("ui_transcribing"):
    ok = False
    messages.append("running/ui_transcribing mismatch")

if ok:
    print("PASS")
else:
    print("FAIL: " + "; ".join(messages))
    sys.exit(1)
PY

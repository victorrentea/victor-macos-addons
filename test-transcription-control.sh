#!/bin/bash
set -euo pipefail

# Transcription is driven solely by AC/battery now — there is no start/stop/
# toggle. The only headless hook left is a force-(re)start of Whisper, used
# here to confirm the pipeline comes up. Snapshot → start → re-snapshot.

BASE_URL="${BASE_URL:-http://127.0.0.1:55123}"
WAIT_SECONDS="${WAIT_SECONDS:-1.5}"

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

print(f"{label} running={state.get('running')} on_ac={state.get('on_ac')} "
      f"paused_battery={state.get('paused_battery')} "
      f"ui_transcribing={state.get('ui_transcribing')} "
      f"icon={state.get('icon_mode')} menu=\"{state.get('menu_title')}\"")
PY
}

before="$(fetch_state)"
print_state "before" "$before"

curl -fsS "$BASE_URL/test/transcription/start" >/dev/null

sleep "$WAIT_SECONDS"

after="$(fetch_state)"
print_state "after " "$after"

python3 - "$after" <<'PY'
import json
import sys

after = json.loads(sys.argv[1])

ok = True
messages = []

# On AC, a force-start must bring Whisper up. On battery it stays paused
# (the controller refuses to run on battery), which is also correct.
if after.get("on_ac") and not after.get("running"):
    ok = False
    messages.append("on AC but not running after force-start")

if after.get("running") != after.get("ui_transcribing"):
    ok = False
    messages.append("running/ui_transcribing mismatch")

if ok:
    print("PASS")
else:
    print("FAIL: " + "; ".join(messages))
    sys.exit(1)
PY

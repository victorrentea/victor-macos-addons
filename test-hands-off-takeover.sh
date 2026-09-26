#!/bin/bash
# ✋ End-to-end test of the hands-off TAKEOVER against the RUNNING app:
#   hands-off run "test" -- sleep 60 &   →   GET /test/hands-off/takeover
# and then: the sleep is gone, the wrapper exited 75 with the interruption line
# on stderr, the marker was written (holderPid = the wrapper), the locks are
# down, the 60 s refusal works, and --after-takeover lifts it.
#
# The locks really go up (on every screen) and the red ✋ really shows for 2 s,
# with a Basso — it is the real overlay, driven through its test hook instead of
# a click. The marker goes to a scratch file (`?marker=`), NOT the real
# ~/.victor-addons/hands-off.takeover, so running this does not make every
# other agent's `hands-off run` refuse for a minute.
#
# Refuses to run while someone else holds the locks: a takeover would kill THEIR
# automation.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="http://localhost:${VICTOR_ADDONS_PORT:-55123}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hands-off-takeover-test.XXXXXX")
export HANDS_OFF_TAKEOVER_FILE="$WORK/takeover.json"
HO="$DIR/hands-off.sh"
fails=0
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; fails=$((fails + 1)); }
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$1"; }

state=$(curl -fsS --max-time 3 "$BASE/hands-off/state") || { echo "app not answering on $BASE"; exit 2; }
if [ "$(printf '%s' "$state" | json active)" = "True" ]; then
  echo "locks are held by someone else right now ($state) — not taking them over"; exit 2
fi

echo "1. run a 60 s command under the locks, then take control"
"$HO" run "test takeover" -- /bin/sleep 60 2>"$WORK/stderr" &
wrapper=$!
child=""
for _ in $(seq 1 40); do
  child=$(curl -fsS --max-time 2 "$BASE/hands-off/state" | json childPid)
  [ -n "$child" ] && break
  /bin/sleep 0.1
done
[ -n "$child" ] && pass "wrapper $wrapper registered child $child" || fail "no childPid in /hands-off/state"
holder=$(curl -fsS "$BASE/hands-off/state" | json holderPid)
[ "$holder" = "$wrapper" ] && pass "holderPid is the wrapper" || fail "holderPid '$holder' != wrapper $wrapper"
[ "$(ps -o pgid= -p "$child" | tr -d ' ')" = "$child" ] && pass "child leads its own process group" \
  || fail "child is not a group leader"

answer=$(curl -fsS --max-time 3 "$BASE/test/hands-off/takeover?holder=$wrapper&marker=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$HANDS_OFF_TAKEOVER_FILE")")
echo "     takeover → $answer"
if [ "$(printf '%s' "$answer" | json reason)" = "holder-mismatch" ]; then
  echo "another agent raised the locks during the test — aborting without touching them"
  kill -TERM "$wrapper" 2>/dev/null; wait "$wrapper" 2>/dev/null; rm -rf "$WORK"; exit 2
fi
t0=$(date +%s)
wait "$wrapper"; rc=$?
echo "     wrapper exited $rc after $(( $(date +%s) - t0 ))s"

[ "$rc" = 75 ] && pass "exit code 75 (EX_TEMPFAIL)" || fail "exit code $rc, expected 75"
grep -Eq '^✋ HANDS-OFF INTERRUPTED: Victor took control at [0-9]{2}:[0-9]{2}:[0-9]{2} — stop what you were doing$' "$WORK/stderr" \
  && pass "stderr: $(grep INTERRUPTED "$WORK/stderr")" || { fail "interruption line missing"; cat "$WORK/stderr"; }
kill -0 "$child" 2>/dev/null && fail "sleep $child is still alive" || pass "sleep $child is gone"
[ -f "$HANDS_OFF_TAKEOVER_FILE" ] && pass "marker written: $(cat "$HANDS_OFF_TAKEOVER_FILE")" || fail "no marker"
[ "$(json holderPid <"$HANDS_OFF_TAKEOVER_FILE")" = "$wrapper" ] && pass "marker names the wrapper" || fail "marker holderPid wrong"
[ "$(curl -fsS "$BASE/hands-off/state" | json active)" = "False" ] && pass "locks are down" || fail "locks still up"

echo "2. a second run within 60 s is refused"
"$HO" run "grab it again" -- /usr/bin/true 2>"$WORK/stderr2"; rc=$?
[ "$rc" = 75 ] && grep -q "HANDS-OFF REFUSED" "$WORK/stderr2" && pass "refused, exit 75: $(cat "$WORK/stderr2")" \
  || { fail "not refused (rc $rc)"; cat "$WORK/stderr2"; }
[ "$(curl -fsS "$BASE/hands-off/state" | json active)" = "False" ] && pass "refusal raised no locks" || fail "refusal raised the locks"

echo "3. --after-takeover lifts the refusal; the command's own exit code comes back"
"$HO" run --after-takeover "Victor said go" -- /bin/sh -c 'exit 3' 2>/dev/null; rc=$?
[ "$rc" = 3 ] && pass "ran, exit code of the command (3) passed through" || fail "rc $rc, expected 3"
/bin/sleep 0.3
[ "$(curl -fsS "$BASE/hands-off/state" | json active)" = "False" ] && pass "locks released after the run" || fail "locks left up"

echo "4. the takeover route with no locks up is a no-op"
answer=$(curl -fsS "$BASE/test/hands-off/takeover?marker=$WORK/unused")
[ "$(printf '%s' "$answer" | json reason)" = "no-locks" ] && [ ! -f "$WORK/unused" ] && pass "no-locks, no marker" \
  || fail "unexpected: $answer"

rm -rf "$WORK"
[ "$fails" = 0 ] && echo "ALL PASSED" || echo "$fails FAILED"
exit "$fails"

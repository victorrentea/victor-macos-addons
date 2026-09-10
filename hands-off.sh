#!/bin/bash
# ✋🔒 hands-off — the one command an agent runs before it touches Victor's
# mouse or keyboard, and again the moment it lets go.
#
# While it is on, the app draws an amber frame on every screen, a badge riding
# the cursor, and four slowly pulsing 🔒 in the corners. That is the contract:
# **locks visible = don't touch the mouse or the keyboard.** Locks gone = yours
# again (the frame flashes green and a Tink plays).
#
# Usage:
#   hands-off start "click Restart to Update" [ttl] [agent]
#   hands-off end
#   hands-off state
#   hands-off run "click Restart to Update" -- some-command --args
#   hands-off demo [seconds]      # just show it, for eyeballing the animation
#
# `run` is the form to prefer: it releases on exit, on Ctrl-C and on a crash,
# so a dead agent never parks the locks on screen. The app's own ttl watchdog
# (default 120 s, max 900) is the backstop for the case where even that fails.
set -uo pipefail

PORT="${VICTOR_ADDONS_PORT:-55123}"
BASE="http://localhost:$PORT"
APP="/Applications/Victor Addons.app"

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# The door is the running app. If it is not up there is nothing to draw on, and
# silently proceeding would be the worst outcome — the agent would drive the
# machine with no warning on screen at all.
ensure_app() {
  curl -fsS --max-time 2 "$BASE/hands-off/state" >/dev/null 2>&1 && return 0
  [ -d "$APP" ] || { echo "hands-off: '$APP' is not installed" >&2; return 1; }
  open "$APP" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS --max-time 1 "$BASE/hands-off/state" >/dev/null 2>&1 && return 0
    /bin/sleep 0.5
  done
  echo "hands-off: Victor Addons is not answering on $BASE — NOT warning him. Do the GUI work anyway at your own risk." >&2
  return 1
}

start() {
  local what="${1:-}" ttl="${2:-120}" agent="${3:-${HANDS_OFF_AGENT:-claude}}"
  ensure_app || return 1
  curl -fsS --max-time 3 \
    "$BASE/hands-off/start?agent=$(urlencode "$agent")&what=$(urlencode "$what")&ttl=$(urlencode "$ttl")"
  echo
}

end() { curl -fsS --max-time 3 "$BASE/hands-off/end"; echo; }

state() { curl -fsS --max-time 3 "$BASE/hands-off/state"; echo; }

cmd="${1:-}"; shift || true
case "$cmd" in
  start) start "${1:-}" "${2:-120}" "${3:-}" ;;
  end|stop|release) end ;;
  state|status) state ;;
  run)
    what="${1:-}"; shift || true
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || { echo "usage: hands-off run \"what\" -- command…" >&2; exit 2; }
    # A generous ttl plus a trap, rather than a guess at the duration: the trap
    # is what normally releases, the ttl only covers a SIGKILL.
    start "$what" 900 >/dev/null
    trap 'end >/dev/null' EXIT INT TERM
    "$@"
    ;;
  demo)
    secs="${1:-12}"
    start "demo — uite lacătele" "$((secs + 5))"
    /bin/sleep "$secs"
    end
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

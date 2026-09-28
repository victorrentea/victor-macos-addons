#!/bin/bash
# ✋🔒 hands-off — the one command an agent runs before it touches Victor's
# mouse or keyboard, and again the moment it lets go.
#
# While it is on, the app draws an amber frame on every screen and four slowly
# pulsing 🔒 in the corners. That is the contract: **locks visible = don't
# touch the mouse or the keyboard.** Locks gone = yours again (the frame
# flashes green and a Tink plays). The "what" you pass is NOT shown on screen
# by itself (no bottom pill since 2026-09-28): Victor reads it by hovering a 🔒,
# so it has to say what you are doing and why you need his mouse, in words he
# understands at a glance.
#
# Usage:
#   hands-off start "click Restart to Update" [ttl] [agent]
#   hands-off end
#   hands-off state
#   hands-off run "click Restart to Update" -- some-command --args
#   hands-off run --after-takeover "…" -- cmd   # only once Victor said go again
#   hands-off takeover-status     # the last takeover, and whether it is fresh
#   hands-off demo [seconds]      # just show it, for eyeballing the animation
#
# `run` is the form to prefer: it releases on exit, on Ctrl-C and on a crash,
# so a dead agent never parks the locks on screen. The app's own ttl watchdog
# (default 120 s, max 900) is the backstop for the case where even that fails.
#
# ✋ TAKEOVER (2026-09-26). Victor can click a 🔒 TWICE within 1.5 s (any lock;
# since 2026-09-28 one click only arms) or press ⌃⌘⎋ twice to take the machine
# back. Then, for `run`:
#   - the command is SIGTERMed (its whole process group; SIGKILL after 3 s),
#   - this prints on stderr
#       ✋ HANDS-OFF INTERRUPTED: Victor took control at HH:MM:SS — stop what you were doing
#   - and exits 75 (EX_TEMPFAIL).
# STOP when you see that line: do not retry, do not re-grab the screen — ask
# him. For 60 s after a takeover `run` refuses to start (exit 75 again) unless
# given --after-takeover. `start … ; … ; end` holds no process the app could
# stop: the locks just drop and ~/.victor-addons/hands-off.takeover is written,
# so a start/end user must check `hands-off takeover-status` between steps.
set -uo pipefail

PORT="${VICTOR_ADDONS_PORT:-55123}"
BASE="http://localhost:$PORT"
APP="/Applications/Victor Addons.app"

TAKEOVER_MARK="${HANDS_OFF_TAKEOVER_FILE:-$HOME/.victor-addons/hands-off.takeover}"
TAKEOVER_COOLDOWN=60
EX_TAKEOVER=75

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
  local what="${1:-}" ttl="${2:-120}" agent="${3:-${HANDS_OFF_AGENT:-claude}}" holder="${4:-}"
  ensure_app || return 1
  local extra=""
  [ -n "$holder" ] && extra="&holder=$holder"
  curl -fsS --max-time 3 \
    "$BASE/hands-off/start?agent=$(urlencode "$agent")&what=$(urlencode "$what")&ttl=$(urlencode "$ttl")$extra"
  echo
}

# --- ✋ takeover ------------------------------------------------------------
# One python call reads the marker: "<age-seconds> <holderPid> <HH:MM:SS>".
takeover_info() {
  [ -f "$TAKEOVER_MARK" ] || return 1
  python3 - "$TAKEOVER_MARK" <<'PYEOF' 2>/dev/null
import json, os, sys, time
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
age = int(time.time() - os.path.getmtime(p))
at = d.get("atLocal") or time.strftime("%H:%M:%S", time.localtime(os.path.getmtime(p)))
print(age, d.get("holderPid", 0), at)
PYEOF
}

interrupted_line() {
  echo "✋ HANDS-OFF INTERRUPTED: Victor took control at $1 — stop what you were doing" >&2
}

takeover_status() {
  local info age holder at
  info=$(takeover_info) || { echo "no takeover recorded"; return 0; }
  read -r age holder at <<<"$info"
  echo "last takeover: $at (${age}s ago, holder pid $holder) — $TAKEOVER_MARK"
  [ "$age" -lt "$TAKEOVER_COOLDOWN" ] && return $EX_TAKEOVER
  return 0
}

end() { curl -fsS --max-time 3 "$BASE/hands-off/end"; echo; }

state() { curl -fsS --max-time 3 "$BASE/hands-off/state"; echo; }

cmd="${1:-}"; shift || true
case "$cmd" in
  start) start "${1:-}" "${2:-120}" "${3:-}" ;;
  end|stop|release) end ;;
  state|status) state ;;
  takeover-status) takeover_status; exit $? ;;
  run)
    after_takeover=0
    while [ "${1:-}" = "--after-takeover" ]; do after_takeover=1; shift; done
    what="${1:-}"; shift || true
    while [ $# -gt 0 ]; do
      case "$1" in
        --after-takeover) after_takeover=1; shift ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || { echo "usage: hands-off run [--after-takeover] \"what\" -- command…" >&2; exit 2; }

    # Victor just took the machine back: an agent must not grab it again
    # before it has read why. `--after-takeover` is the explicit "he said go".
    if [ "$after_takeover" = 0 ] && info=$(takeover_info); then
      read -r t_age _ t_at <<<"$info"
      if [ "$t_age" -lt "$TAKEOVER_COOLDOWN" ]; then
        echo "✋ HANDS-OFF REFUSED: Victor took control at $t_at (${t_age}s ago) — ask him before driving the GUI again; rerun with --after-takeover only once he said yes" >&2
        exit $EX_TAKEOVER
      fi
    fi

    # A generous ttl plus a trap, rather than a guess at the duration: the trap
    # is what normally releases, the ttl only covers a SIGKILL. `holder=$$` is
    # what lets a click on a 🔒 find us.
    start "$what" 900 "" "$$" >/dev/null

    taken=0
    child=""
    on_takeover() {
      taken=1
      [ -n "$child" ] && { kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null; }
    }
    forward() {  # Ctrl-C / kill of the wrapper: the child is in its own group, pass it on
      [ -n "$child" ] && { kill "-$1" -- "-$child" 2>/dev/null || kill "-$1" "$child" 2>/dev/null; }
      exit "$2"
    }
    trap on_takeover USR1
    trap 'forward INT 130' INT
    trap 'forward TERM 143' TERM
    trap 'forward HUP 129' HUP
    # Release only what is still ours: after a takeover the locks are already
    # down, and whatever went up since belongs to someone else.
    release_mine() {
      case "$(state 2>/dev/null)" in *"\"holderPid\":$$"[,}]*) end >/dev/null ;; esac
    }
    trap release_mine EXIT

    # Own process group (`set -m`), so a takeover kills the command and
    # everything it spawned — and only that, never the agent's shell above us.
    set -m
    "$@" &
    child=$!
    # Sentinel, in its own group too: if this wrapper is SIGKILLed (a tool
    # timeout that does not bother with TERM), the child must not keep driving
    # the screen with the locks gone.
    ( while kill -0 "$$" 2>/dev/null && kill -0 "$child" 2>/dev/null; do /bin/sleep 1; done
      kill -0 "$$" 2>/dev/null || kill -TERM -- "-$child" 2>/dev/null ) >/dev/null 2>&1 &
    set +m
    curl -fsS --max-time 3 "$BASE/hands-off/attach?holder=$$&child=$child" >/dev/null 2>&1

    # A takeover that landed between `start` and `attach` only reached us.
    [ "$taken" = 1 ] && on_takeover

    rc=0
    while :; do
      { wait "$child"; } 2>/dev/null
      rc=$?
      kill -0 "$child" 2>/dev/null || break
      [ "$taken" = 1 ] && break
    done

    # Belt and braces: the marker is written before any signal, so a child
    # that died before our USR1 arrived is still recognised as a takeover.
    if [ "$taken" = 0 ] && info=$(takeover_info); then
      read -r t_age t_holder _ <<<"$info"
      [ "$t_holder" = "$$" ] && [ "$t_age" -lt "$TAKEOVER_COOLDOWN" ] && taken=1
    fi

    if [ "$taken" = 1 ]; then
      # Give the app's TERM→KILL escalation its 3 s, but never hang on it.
      for _ in 1 2 3 4 5 6 7 8; do kill -0 "$child" 2>/dev/null || break; /bin/sleep 0.5; done
      t_at=$(date +%H:%M:%S)
      if info=$(takeover_info); then read -r _ _ t_at <<<"$info"; fi
      interrupted_line "$t_at"
      exit $EX_TAKEOVER
    fi
    exit "$rc"
    ;;
  demo)
    secs="${1:-12}"
    start "demo — uite lacătele" "$((secs + 5))"
    /bin/sleep "$secs"
    end
    ;;
  *)
    sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

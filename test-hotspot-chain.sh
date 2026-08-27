#!/bin/bash
# End-to-end test of the 📶 hotspot fallback: phone hotspot OFF → Mac notices it
# is offline → RFCOMM signal → Samsung routine → hotspot ON → Mac rejoins.
#
# THIS TEST TAKES YOUR INTERNET AWAY ON PURPOSE. That is the whole point, and it
# is also why it must never be run as a series of interactive commands: the shell
# issuing them is on the very link it is cutting. So it runs detached, logs to a
# file, and — whatever happens, including being killed — puts the hotspot back on
# and rejoins the Mac to it on the way out.
#
#   nohup ./test-hotspot-chain.sh > /dev/null 2>&1 &
#   tail -f /tmp/hotspot-chain-test.log
#
# Requirements: the phone on USB, and **unlocked** — the hotspot has no
# programmatic switch on Android 16 (see docs/hotspot-fallback.md), so both
# turning it off and putting it back is UI automation, and UI automation cannot
# get past the lock screen.

set -uo pipefail

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
LOG=/tmp/hotspot-chain-test.log
SSID=victor
IFACE=en0
PORT=55123
# How long the Mac gets to notice, signal, and be back online. The measured
# end-to-end figure is ~15s; this is deliberately several times that, because a
# test that gives up early reports a failure that isn't one.
BUDGET=90

exec >>"$LOG" 2>&1
say() { echo "$(date +%H:%M:%S) $*"; }

online() { ping -c1 -t2 1.1.1.1 >/dev/null 2>&1; }
hotspot_on() { "$ADB" shell ip -4 addr show ap_br_swlan0 2>/dev/null | grep -q "inet "; }

# --- UI automation, because there is no API -----------------------------------
# `uiautomator dump` only ever sees the front-most screen, so the settings page
# is re-opened before every read: our own activity coming to the front (which is
# exactly what the test provokes) would otherwise make the switch unreadable and
# look like "the hotspot did not come on".
# The page carries four switches (Mobile Hotspot, Bluetooth tethering and two
# more), so "the first switch" is a coin flip waiting to land wrong. The row is
# identified by its content-desc, which is also what carries `checked=`.
hotspot_row() {
    "$ADB" shell am start -a android.settings.TETHER_SETTINGS >/dev/null 2>&1
    sleep 2
    "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    "$ADB" shell cat /sdcard/ui.xml 2>/dev/null \
        | tr '>' '\n' \
        | grep 'class="android.widget.Switch"' \
        | grep 'content-desc="Mobile Hotspot"' \
        | head -1
}

# What the phone itself says the switch is set to — a second opinion on
# `hotspot_on`, and the one that reads right during the seconds the interface is
# coming up or going down.
switch_checked() {
    hotspot_row | grep -q 'checked="true"'
}

tap_hotspot_toggle() {
    local row; row=$(hotspot_row)
    if [ -z "$row" ]; then
        say "FAILED to find the Mobile Hotspot switch — is the phone unlocked?"
        return 1
    fi
    local bounds; bounds=$(echo "$row" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"')
    local x1 y1 x2 y2
    read -r x1 y1 x2 y2 <<<"$(echo "$bounds" | grep -o '[0-9]\+' | tr '\n' ' ')"
    say "tapping the Mobile Hotspot switch at $(( (x1 + x2) / 2 )),$(( (y1 + y2) / 2 ))"
    "$ADB" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 )) >/dev/null 2>&1
    sleep 3
}

# --- restore, come what may ---------------------------------------------------
restore() {
    say "--- restoring ---"
    for attempt in 1 2 3; do
        if hotspot_on || switch_checked; then break; fi
        say "hotspot still off, turning it back on (attempt $attempt)"
        tap_hotspot_toggle
        sleep 4
    done
    if hotspot_on; then say "hotspot is on"; else say "!!! COULD NOT TURN THE HOTSPOT BACK ON — do it by hand"; fi
    /usr/sbin/networksetup -setairportnetwork "$IFACE" "$SSID" >/dev/null 2>&1
    for _ in $(seq 1 20); do online && break; sleep 1; done
    if online; then say "Mac is back online"; else say "!!! Mac is still offline — join '$SSID' by hand"; fi
    "$ADB" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    "$ADB" shell svc power stayon false >/dev/null 2>&1
}
trap restore EXIT INT TERM

# --- the test -----------------------------------------------------------------
say "=========== hotspot chain test ==========="
"$ADB" shell svc power stayon usb >/dev/null 2>&1   # don't let it sleep mid-test

if ! "$ADB" get-state >/dev/null 2>&1; then say "no adb device — plug the phone in"; exit 1; fi
if ! hotspot_on; then say "hotspot is already off; nothing to take away"; exit 1; fi

say "hotspot is on, Mac online=$(online && echo yes || echo no) — turning the hotspot OFF"
tap_hotspot_toggle || exit 1

for _ in $(seq 1 15); do hotspot_on || break; sleep 1; done
if hotspot_on; then say "the toggle did not take — aborting"; exit 1; fi
say "hotspot is off"

# Confirm the Mac has actually lost the link before starting the clock: a ping
# keeps succeeding for a few seconds after the AP goes away, and a test that
# starts timing too early declares a win it did not have.
for _ in $(seq 1 20); do online || break; sleep 1; done
if online; then say "the Mac is still online without the hotspot — nothing to fall back to"; exit 0; fi
say "the Mac is offline; starting the clock"

START=$(date +%s)
SIGNALLED=no
while [ $(( $(date +%s) - START )) -lt $BUDGET ]; do
    if online; then
        say "BACK ONLINE after $(( $(date +%s) - START ))s"
        hotspot_on && say "and the hotspot is up"
        exit 0
    fi
    # The automatic path holds a 180s cooldown between attempts, which is longer
    # than this test; after 40s of waiting for it, ask explicitly instead so the
    # rest of the chain still gets measured.
    if [ "$SIGNALLED" = no ] && [ $(( $(date +%s) - START )) -ge 40 ]; then
        SIGNALLED=yes
        say "no automatic attempt yet — poking /test/hotspot"
        curl -s --max-time 5 "http://127.0.0.1:$PORT/test/hotspot" || true
        echo
    fi
    sleep 2
done
say "FAILED: still offline after ${BUDGET}s"
"$ADB" shell dumpsys usagestats 2>/dev/null | grep phoneaddons | grep ACTIVITY_RESUMED | tail -3
"$ADB" shell dumpsys wifi 2>/dev/null | grep CMD_SET_AP | tail -3
exit 1

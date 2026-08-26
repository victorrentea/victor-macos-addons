# 📶 Hotspot fallback — asking the phone for its hotspot

When this Mac is left without internet, `HotspotFallback` gets the phone
(Galaxy S24 Ultra) to turn its hotspot on, and joins it. Measured end to end:
**~15 s** from losing the connection to being back online.

## The chain

```
Mac has no internet
  → HotspotFallback opens an RFCOMM channel to the phone
  → victor-phone-addons accepts it and brings its activity to the front
  → Samsung "Modes and Routines" routine "Hotspot via app" fires on "App opened"
  → Mobile Hotspot on
  → the Mac is told explicitly to join 'victor'
```

Every hop in that chain is there because the shorter version does not work, and
each was measured on the device rather than assumed.

## Why Routines, and not the app itself

A sideloaded app cannot turn on tethering. `startTethering()` is
`signature|privileged` since Android 11. `com.android.shell` *does* hold
`TETHER_PRIVILEGED` on this phone (`granted=true`), but `cmd wifi start-softap`
is gated on **root uid** inside `WifiShellCommand`, so even ADB cannot reach it:

```
SecurityException: Uid 2000 does not have access to start-softap
    at WifiShellCommand.onCommand(WifiShellCommand.java:551)
```

Modes and Routines is a system app that holds the permission, so it does the
flipping. Shizuku would also work and was rejected deliberately: it has to be
re-armed after every reboot, and the moment that hurts most — a new room, no
Wi-Fi, phone freshly restarted — is exactly when re-arming is hardest.

## Why "App opened", and not "Bluetooth device connected"

The obvious trigger cannot be used. With the RFCOMM channel live and our app
reporting `connected: Victor Mac`, the Android *system* still reported:

```
ConnectionState: STATE_DISCONNECTED
Connected: 0
```

Android does not count an app-level RFCOMM socket as a device connection, and
that count is what Routines reads. Nor does a bare baseband link help: with
`blueutil --is-connected` = 1 and the phone reporting `ACL BR/EDR:Y`, Routines
said "No routines running" for five minutes. macOS, for its part, opens no
system profile to an Android phone at all since Apple removed Bluetooth PAN in
Monterey — so **no Mac can ever satisfy that condition**. Bluetooth here is a
signal, never a transport.

Two traps cost a full afternoon and are worth naming:

- Samsung auto-adds **"when routine ends → return to status before routine ran"**.
  On an *event* trigger the routine starts and ends immediately, so the hotspot
  came on and went straight back off. That switch has to be turned off, and its
  earlier presence also produced a false *positive*: an 8 s "hotspot came on"
  measurement that was the revert action firing, not the routine.
- `blueutil --disconnect` **does not drop the link** (exit 0, and the phone still
  reports `ACL BR/EDR:Y` twelve seconds later at 1 s polling). Anything built on
  producing a disconnect edge with it silently never fires.

## Why connectivity, not SSID

"Are we associated with a Wi-Fi network?" cannot be used as the trigger. Reading
the SSID needs Location Services, and a process without it is told the SSID is
empty *even while fully connected* — `networksetup -getairportnetwork en0`
returned nothing while the default route sat on the hotspot's own gateway. The
first version trusted that and ran the whole escalation against a healthy
connection. The verdict is now a real TCP handshake to 1.1.1.1:443, which also
catches a captive portal and an associated-but-dead AP.

## Why the join is explicit

macOS auto-join is not relied on. Observed live: the hotspot was up and visible
in the Wi-Fi menu while the Mac sat unassociated until it was clicked by hand.
Auto-join depends on a stored per-network flag and on where the network sits in
a 113-entry preferred list, either of which can quietly stop being what you
think. So the fallback asks — `networksetup -setairportnetwork` — from the 6th
second, every 3 s (the hotspot needs ~8 s to start beaconing).

That also makes the preferred-list order irrelevant, which is what an earlier
attempt to reorder `victor` to the end was for. It was abandoned: macOS promotes
the currently-joined network back to the top, so the order will not hold.
`networksetup` also **exits 0 when the join fails**, reporting the failure only
as text on stdout — so success is empty output, never the exit status.

## Home geofence

At home the rule is manual: `tzutze` is preferred and nothing should reach for
the phone. `HomeGeofence` suppresses the fallback within `HOME_RADIUS_M` (200 m)
of `HOME_LAT`/`HOME_LON`, read from `~/.training-assistants-secrets.env` — this
repo is public, and where somebody lives is not a build constant.

**A Mac has no GPS.** CoreLocation positions it by the Wi-Fi networks it can
see, so accuracy is tens of metres and a fix is unavailable where no known
networks are around. That is enough for a question that only has to be right to
within a building. An unavailable or stale fix answers **not home**: a needless
hotspot is recoverable by waiting, a wrongly suppressed one leaves the Mac
offline.

The fix is only asked for once we already know there is no internet — a menu-bar
app sees network changes all day, and a location fix costs radios.

## Toggle

**💬 → 👩🏻‍💻 Extra → 📶 Hotspot Fallback**, persisted in `UserDefaults`
(`HotspotFallback.enabled`, default on). Default on is safe: the feature does
nothing at all unless the Mac is already offline and away from home.

## After a phone reboot

The phone side comes back on its own, but not at once: Android delivers
`BOOT_COMPLETED` in priority waves and this app catches a late one. Measured on
the S24 Ultra, **~90 s** from power-on to `listening on SPP`. Two earlier reboot
tests looked like failures purely because they checked at 35 s.

So in the first minute or two after restarting the phone, the fallback has
nothing to connect to and the Mac will log
`the phone is not publishing the SPP channel`. Opening the phone app by hand
short-circuits the wait.

## The other half

The phone side is a separate repo, `victor-phone-addons` — a foreground service
holding an RFCOMM server socket, and nothing else. Its README carries the same
reasoning from the phone's side.

# 📶 Hotspot fallback — asking the phone for its hotspot

When this Mac is left without internet, `HotspotFallback` gets the phone
(Galaxy S24 Ultra) to turn its hotspot on, and joins it. Measured end to end
with `./test-hotspot-chain.sh` (27 Aug 2026), from the hotspot being switched
off to the Mac being back online: **9 s**. Timestamped on both sides:

```
06:26:02.6  phone   hotspot switched off
06:26:09.4  Mac     4 s grace elapsed, no internet — opening the channel
06:26:10.5  Mac     RFCOMM channel open (channel 9)
06:26:10    phone   ACTIVITY_RESUMED — the routine's trigger
06:26:11.9  phone   CMD_SET_AP 1 — the routine turned the hotspot on
06:26:14.7  Mac     online
```

The routine fires **1.5 s** after the signal; the rest is the Mac noticing and
the soft AP coming up.

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

**Android 16 closed the last door, so stop looking for one.** Re-checked on the
S24 Ultra (27 Aug 2026), because "surely an app can just do this" is a question
that comes back:

- `pm grant … TETHER_PRIVILEGED` → `SecurityException: … is not a changeable
  permission type`. It is `signature|privileged`; there is nothing to grant.
- `cmd wifi start-softap` is not even *listed* by `cmd wifi help` for uid 2000 —
  the uid gate inside `WifiShellCommand` is unchanged.
- The reflection trick every automation app used (`ConnectivityManager.startTethering`
  via a Dexmaker proxy, allowed by holding `WRITE_SETTINGS`) is **gone in
  Android 16**. The check is still in `TetheringService.hasTetherChangePermission`,
  and it now reads: *"After TetheringManager moves to public API, prevent
  third-party apps from being able to change tethering with only WRITE_SETTINGS
  permission"* → `if (mTethering.isTetheringWithSoftApConfigEnabled()) return false;`.
  Non-privileged callers get `TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION` (14).
  This is what killed Tasker's and MacroDroid's hotspot toggles too.
- The only escape hatches left in that method are **Device Owner** and
  **carrier-privileged**, neither of which this phone can be — `dpm
  set-device-owner` refuses on a device with accounts on it.
- And even on Android ≤15 the bypass would have been closed here anyway: this
  phone reports `isDunRequired: true` and
  `isCarrierConfigAffirmsEntitlementCheckRequired: true`, so
  `isTetherProvisioningRequired()` is satisfied and the WRITE_SETTINGS path is
  skipped regardless.

So the routine is not a workaround to be replaced later. It is the mechanism.

## The stale RFCOMM channel — the failure that looked like success

The chain worked once and then never again, and every log line said it was fine.
Traced 27 Aug 2026:

**The phone's channel number changes after every connection.** The beacon
re-creates its listening socket per connection (deliberately — a reused socket
goes silently deaf), and the Bluetooth stack assigns the new socket a *different*
RFCOMM channel. macOS caches the SDP record, `getServiceRecord` returns the
cached one, and `performSDPQuery(nil)` + a fixed 3 s sleep was not enough to be
sure the cache had been refreshed.

**And a wrong channel fails asynchronously.** `openRFCOMMChannelAsync` returns
`kIOReturnSuccess` for the *request*; the verdict arrives later in
`rfcommChannelOpenComplete`. The original delegate implemented only
`rfcommChannelData`, so the failure was never heard — the app logged
`RFCOMM channel open to the phone` and returned success every single time.

The evidence, from the Mac's own log:

```
17:35:56  RFCOMM channel open to the phone (channel 9)     ← worked
05:01:25  RFCOMM channel open to the phone (channel 10)    ← stale, opened nothing
05:47:30  RFCOMM channel open to the phone (channel 10)    ← stale, opened nothing
05:48:18  Hotspot fallback failed — channel is open but no internet followed
```

and, on the phone, `dumpsys usagestats` shows **no `ACTIVITY_RESUMED` at all**
for `ro.victorrentea.phoneaddons` at 05:47 — the socket was never accepted, so
the activity was never launched, so the routine had no event to see. A live SDP
query at 06:03 answered **channel 9**, while the Mac had been asking for 10 since
the previous evening.

Note what this does *not* look like: `dumpsys wifi` shows no `CMD_SET_AP` between
17:51 the day before and the manual toggle the next morning, and every Mac-side
line reads healthy. Nothing points at Bluetooth.

The fix is in `HotspotFallback.ChannelOpener`:

- a **callback-driven** SDP query (`sdpQueryComplete`), not a sleep, so the
  channel number is read only once the cache has actually been refreshed;
- `rfcommChannelOpenComplete` is implemented and **waited for**, so a refused
  channel is an error and not a log line claiming success;
- on refusal, the SDP query is re-run and the open retried **once** with whatever
  channel the phone is on now.

**IOBluetooth's callbacks need a run loop**, and they are delivered on the run
loop of the thread that *started* the operation. `HotspotFallback`'s work queue
is a `DispatchQueue` and has none — which is why the callbacks could not have
been heard even if they had been implemented, and why `openRFCOMMChannelSync`
with a nil delegate fails here with a bare `kIOReturnError`. So the Bluetooth
work now runs on a dedicated `RunLoopThread`. Not the main thread: an SDP query
plus an open plus a retry is up to 20 s, and the main thread serves the menu bar
and the `/test/*` hooks.

## Testing it without waiting for a real outage

`GET /test/hotspot` opens the channel now, whatever the Mac's connectivity, the
geofence and the cooldown. It answers with the **previous** attempt's outcome
(`last_channel_open`, `last_error`, `channel_is_open`) — the attempt itself is
slower than an HTTP response — so call it twice.

That only proves the Mac's half. For the whole chain there is
**`./test-hotspot-chain.sh`**, which turns the phone's hotspot off, waits for the
Mac to genuinely lose the link, times the recovery, and **restores the hotspot
and rejoins the Mac on the way out** whatever happens, including being killed.
Run it detached (`nohup … &`) and read `/tmp/hotspot-chain-test.log`: the shell
issuing the commands is sitting on the very link the test cuts. It needs the
phone **unlocked**, because with no API left (see above) turning the hotspot off
and back on is UI automation.

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

## The link has to be up before the SDP query

This is the one that made the lid-open fail while every deliberate test passed:
**`performSDPQuery` on a phone whose ACL link is down never comes back.** Not
slowly — at all. It returns `kIOReturnSuccess` and `sdpQueryComplete` simply
never fires.

Measured 27 Aug 2026, power-cycling the adapter to imitate a lid-close:

```
 6.1s  adapter power-cycled: connected=false
 6.1s  performSDPQuery -> 0
48.2s  TIMED OUT                              ← 42 s, no callback
```

and with `openConnection()` first:

```
 6.1s  adapter power-cycled: connected=false
10.2s  openConnection -> 0 after 4.0s, connected=true
10.2s  sdpQueryComplete status=0 after 0.0s
10.2s  channel from SDP = 9
10.4s  openComplete status=0
```

macOS will not page the phone on an SDP query's behalf; `openConnection()` will,
in **4.0 s**, after which the query answers instantly. So `ChannelOpener` brings
the baseband link up first whenever the device is disconnected, with a bounded
page timeout so an out-of-range phone costs one page rather than the thread.

Verified through the app itself, adapter power-cycled first (27 Aug 2026):

```
07:24:30.9  Mac     RFCOMM channel to the phone closed
07:24:42.3  Mac     Bluetooth link to the phone up in 2.6s   ← the new step
07:24:42.5  Mac     RFCOMM channel open (channel 9)
07:24:42    phone   ACTIVITY_RESUMED — the routine's trigger
```

**2.8 s** from a cold link to the signal delivered. The same situation before the
fix produced `the phone did not answer the SDP query in 15s`, twice, and nothing
at all on the phone.

**This is also why the old code appeared to work at all.** Its channel open —
against a cached number — *did* page the phone, so the link came up as a side
effect; it just opened a channel nobody was listening on. Every test run with
the link already warm passed. The only failing case was the only one that
matters: the lid opening in a new room.

A second consequence: with the link up, macOS answers an SDP query **out of its
own cache, in 0.0 s** — so re-querying after a refused channel would hand back
the same stale number. The retry therefore drops the link (`closeConnection()`)
before asking again, which is what forces a real fetch from the phone.

## Two numbers that made it look broken

Both found by running the chain for real, both fixed:

**The cooldown swallowed the lid-open.** The floor between attempts was 180 s,
inherited from when the escalation power-cycled the Bluetooth adapter and a
retry was genuinely expensive. What is left is an SDP query and a channel open,
which cost nothing — and 180 s was actively harmful: a wake landing inside it
did *nothing*, for up to three minutes, with one line in a log nobody is reading
(`📵 No internet (wake) but only 82s since last attempt — holding`). Observed
from the outside as "closed the lid, reopened it, Bluetooth didn't reconnect for
a minute". The floor is now **45 s**, and a **wake gets 10 s** — a lid-open is a
new room and a new situation by definition, which is the whole point of the
feature.

**The recovery budget was shorter than the recovery.** `waitAfterPlainConnect`
was 12 s, sized against a measured ~8 s hotspot spin-up. With the phone's Wi-Fi
switched off beforehand the soft AP has to tear the STA down first, and the same
chain took **30 s** — so the app gave up and logged `channel is open but no
internet followed` on a run that succeeded seconds later. Now 45 s; the loop
exits the moment the probe answers, so overshooting is free.

Related: the SDP watchdog was 6 s and produced a false negative on a cold ACL
link (a query answers in ~1 s once the link is up, but the phone has to be paged
first). Now 15 s.

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

# 📶 Roaming allowance warning

Asked for 25 Sep 2026: the roaming plan is **13 703 MB a month, reset on the
2nd**. On a day the phone has been roaming and **under 15%** of it is left, a
red bottom-left pill says `📶 Roaming: 1.8 GB left (12%)` and **stays until
hovered** (the moving dwell from `HoverMotionGate`; the pill then sinks). The
dismissal holds for the rest of that day only (`roaming.warning.dismissed.day`
in `UserDefaults`, so restarts don't bring it back). The next roaming day asks
again. On the phone, the ROAMING DATA card blinks a red bar under the same
condition.

## Who counts

The **phone** does. `RoamingUsage.kt` in `victor-phone-addons` already summed
roaming traffic for its card (`NetworkStatsManager`, `ROAMING_YES` buckets, all
UIDs, since the reset day). The ceiling (`LIMIT_BYTES`), the reset day and the
15% threshold (`LOW_FRACTION`) live there too, and travel with every reading.
The Mac only decides *whether to show it now* (`RoamingWarningPolicy`, unit-tested):

- the reading says `low`: roaming today (`today > 0` or `roamingNow`) **and**
  remaining < `lowFraction` of `limit`;
- the reading is **fresh** (< 1 h) and **from today**, since the phone's
  `today` counter is the phone's day, and yesterday's reading would claim
  yesterday's roaming;
- it has not been dismissed today.

MB are decimal (10^6), like the card. If the operator counts MiB, the real
ceiling is ~5% higher, so any error makes the warning come early, not late.

## Transport: a second RFCOMM service, not the beacon's

`PhoneRoamingMonitor` opens an RFCOMM channel to the phone every **20 min**
(and 30 s after wake) on the service
`7a1f3c52-9b4e-4d1a-8c6f-2e5b9d0a4f17` (`RoamingStatusChannel.kt`). The phone
answers with one line of JSON and waits for the Mac to hang up.

- **Not the SPP beacon.** There the *connection* is the signal: the phone
  brings its activity to the front and the Samsung routine turns the hotspot
  on. Asking about roaming on it would switch the hotspot on every poll.
- **Not HTTP.** The phone is on IP only while the Mac sits on its hotspot, and
  a roaming day on hotel Wi-Fi eats the same allowance.
- **The phone keeps its listening socket** between connections, unlike the
  beacon, so its RFCOMM channel number stays stable. That is the trap in
  `hotspot-fallback.md`. The Mac still goes through `PhoneChannelOpener`
  (extracted from `HotspotFallback` for this), so a moved channel is re-queried
  anyway.
- Cost: a Bluetooth page per poll, ~4 s cold. Hence 20 min, not less. Against a
  13.7 GB ceiling nothing that matters moves faster.

A phone without Usage access answers `{"error": …}`, which is **not** a
reading. It never reads as "nothing used".

## Testing

- `GET /test/roaming` polls the phone now and answers with the **previous**
  poll: `last_line` (the phone's raw JSON), `last_error`, `remaining_pct`, `low`.
  Call it twice, ~10 s apart.
- `GET /test/roaming/simulate/<pct>` fakes a roaming day with `pct`% left
  (`/simulate/off` clears it). The pill shows on **every** screen, the projected
  retina included, so don't preview it in front of a room.
- `GET /test/roaming/reset-dismissal` forgets today's dismissal.
- Phone side: `adb logcat -s RoamingStatus RoamingUsage`.

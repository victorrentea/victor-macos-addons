# 📶 Roaming allowance warning

Asked for 25 Sep 2026: the roaming plan is **13 703 MB a month, reset on the
2nd** (editable on the phone since 6 Oct 2026). On a day the phone has been
roaming and **under 10%** of it is left (15% until 6 Oct 2026), a
red bottom-left pill says `📶 Roaming: 1.8 GB left (12%)` and **stays until
hovered** (the moving dwell from `HoverMotionGate`; the pill then sinks). The
dismissal holds for the rest of that day only (`roaming.warning.dismissed.day`
in `UserDefaults`, so restarts don't bring it back). The next roaming day asks
again. On the phone, the ROAMING DATA card blinks a red bar under the same
condition.

## Who counts

The **phone** does. `RoamingUsage.kt` in `victor-phone-addons` already summed
roaming traffic for its card (`NetworkStatsManager`, `ROAMING_YES` buckets, all
UIDs, since the reset day). The ceiling (the card's "Monthly plan" row), the reset
day and the 10% threshold (`LOW_FRACTION`) live there too, and travel with every
reading as `limit` and `lowFraction`, so changing them needs no Mac release.
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

## 📵 The 1 GB reserve and the 📶 menu bar meter (14 Oct 2026)

Asked for after the laptop emptied the roaming allowance through the hotspot.
The Mac's log showed why nothing warned: from 13 Oct 11:58 on, **60 polls, zero
readings**. 40 said `the phone is not publishing the roaming status channel`,
three seconds after the *beacon's* channel had opened fine. So the hotspot kept
coming on, and the pill had nothing to decide on.

**The phone enforces, not the Mac.** Only the phone knows it is roaming *now*.
Back home the same Mac on the same hotspot costs nothing against the roaming
plan, and a Mac-side block would have no way to tell. `RoamingGuard.kt`
(`victor-phone-addons`): while `isNetworkRoaming` and under 1 GB left, the
beacon accepts the channel but does not bring the app to the front, so the
Samsung routine never fires. It shows a red overlay with a sound instead, and
rings again (at most every 10 min) while hotspot traffic keeps flowing under the
reserve, because the app cannot switch a running hotspot off. The reading
carries `hotspotBlocked` and `reserve`.

**The Mac only shows the number** (`RoamingMeter` + `RoamingMeterPolicy`,
unit-tested). It's a status item that exists only while the Mac is on
`victor`, and is hidden when a fresh reading says the phone is on its home
network. It shows `📶 3.2 GB`, orange under 3 GB, red under 1.5 GB, `📵` under
the phone's reserve, `~` once the reading is over 30 min old, `?` with none.
Between the phone's answers it **keeps moving**: what this Mac pulled through
`en0` since the phone's `readAt` is subtracted (64-bit sum of `if_data`
deltas every 5 s, since the 32-bit counters wrap at 4 GiB). While on the
hotspot it asks the phone every 5 min instead of 20. The menu has the breakdown
and "Ask the phone now".

## ⏸ Pause Claude on roaming data (14 Oct 2026)

`RoamingDataWatch` + `RoamingDataPolicy` (unit-tested) answer "is this Mac on
roaming data now?" every 5 s and write it to `~/.victor-addons/roaming-data.json`:

```json
{"country":"NL","onHotspot":true,"roamingData":true,"source":"phone","suspendClaude":true,"updatedAt":1791000000}
```

Roaming data means on `victor` **and** the phone roaming. The evidence for the
second half is ranked, because the phone has gone silent before:

1. a phone reading under 30 min old (`roamingNow`);
2. else the country of the geofence's last fix (`CLGeocoder`, one lookup per
   20 km or hour, under 6 h old);
3. else the system timezone. It can't see Bulgaria or Greece, so it comes last.

The top-level menu row **⏸ Pause Claude on roaming data** (default on, sits
under 🛜) sets `suspendClaude`. `~/.claude/hooks/roaming-gate.sh` is wired
beside `net-gate.sh` on UserPromptSubmit / PreToolUse / PostToolUse (timeout
7 days). It parks the turn while `roamingData && suspendClaude` and polls every
10 s. Unticking the row, leaving the hotspot or coming home wakes it. The hook
**fails open**: no file, unreadable, or `updatedAt` older than 120 s (app quit)
never parks anything. Log: `~/.claude/roaming-gate.log`.

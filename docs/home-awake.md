# 🏠 Home Wi-Fi keeps the screen on

The home switch, under 👩🏻‍💻 Extra. It sat next to 🔋 Claude prevents sleep until that row went to the top level (2026-09-17); the two are still the pair about the Mac staying up, they just no longer share a submenu. **While
the Mac is associated with a home Wi-Fi network, the screen does not lock
itself.** Leave that network and ordinary locking comes back on its own, with
nobody clicking anything.

Code: `HomeAwake.swift` (runtime + settings), `HomeAwakePolicy.swift` (the
decision), `DisplaySleepAssertion.swift` (the mechanism, shared with the ☕️
break screen), `HomeAwakePolicyTests.swift`. Menu row + toggle in
`MenuBarManager.swift`, wired in `AppDelegate.swift` right after `LidAwake`.

## What "does not lock" means — read this before being surprised

The mechanism is a **`kIOPMAssertionTypePreventUserIdleDisplaySleep`
assertion**. The display never idles → macOS never starts the screen saver →
"require password after the screen saver starts" never fires. That is the entire
route by which the Mac stops locking itself. Nothing here touches the lock
screen, the login window, or the password policy.

So it deliberately does **not** defeat a lock that was asked for:

| gesture | still locks the Mac at home? |
|---|---|
| ⌃⌘Q | **yes** |
| Lock Screen in the  menu | **yes** |
| a hot corner set to Lock Screen / Start Screen Saver | **yes** |
| closing the lid | **yes** |
| `pmset displaysleepnow` | **yes** |
| walking away and doing nothing | **no — that is the feature** |

An assertion vetoes an *idle timer*, never an explicit request. The first ⌃⌘Q at
home behaving exactly as before is this working, not a gap in it.

A side effect worth naming: with the display held on, `powerd` holds its own
`PreventUserIdleSystemSleep` ("Prevent sleep while display is on"), so the Mac
stays fully awake too. That is a consequence of the display staying up, not
something this asks for — and it is why leaving the assertion held off-network
would be a real bug rather than a cosmetic one.

## Why it exists, beyond not typing a password

**A locked session records nothing but the wallpaper.** That cost a
screen-recording run in `victor-effects`, and an unattended 03:00 capture job is
only possible on a Mac that is still logged in and lit when the job runs. The
convenience of not unlocking at home is the smaller half.

## The SSID is config, never a branch

`UserDefaults`, key **`HomeAwake.ssids`** — a comma-separated list, default
`tzutze`. A second home network, a rename, or a place that should count is one
line:

```sh
defaults write ro.victorrentea.macos-addons HomeAwake.ssids "tzutze,tzutze5"
# then: pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"
```

**`tzutze` is measured, not transcribed** (13 Sep 2026). Spoken it is "Țuțe", and
the network is not called that — it is six ASCII characters. Read off this Mac's
own interface while associated: `SSID_STR = tzutze`, BSSID `60:ce:41:be:14:d8`,
channel 36. A feature keyed on the phonetic spelling would have matched nothing,
silently, forever.

**The match is exact** — no case folding, no prefix. This Mac's preferred list
also carries `tzutze5`, `tzutze2.4` and `tzutze_5G`; a prefix match would adopt
all four without anyone deciding to, and whether they count is a question for the
config rather than for the matcher. They are **not** in the default. If the
screen starts locking at home, `GET /test/home-awake` will say which of them the
Mac actually landed on.

**Nil is not home.** CoreWLAN answers nil for Wi-Fi off, no Wi-Fi interface, and
withheld Location Services — none of which is evidence of being at home, and all
of which, read the other way, would pin the display awake with nothing left to
release it. Refusing to hold costs a screen that locks at home; holding wrongly
costs a screen that never locks anywhere.

## Reading the SSID: CoreWLAN, never `networksetup`

`CWWiFiClient.shared().interface()?.ssid()`. `HotspotFallback` paid for this
lesson on 11 Sep 2026 — `networksetup -getairportnetwork en0` answered "You are
not associated with an AirPort network" on a healthy, associated interface
(WPA3-transition + private MAC) while `ipconfig getifaddr en0` returned an
address on it. **`networksetup` is for acting, never for checking.**

`CWInterface.ssid()` needs Location Services, which this app already holds for
`HomeGeofence`. A process without it — every shell tool, including
`system_profiler` and `ipconfig getsummary`, which report `<redacted>` — cannot
answer this question at all.

## Events, with a clock behind them

- **`CWWiFiClient.startMonitoringEvent(with: .ssidDidChange)`** is the primary
  path: a network change re-evaluates immediately, delivered on CoreWLAN's queue
  and hopped onto this feature's own serial queue.
- **`.powerDidChange` as well**, because switching Wi-Fi *off* is a departure too
  and does not necessarily produce an SSID-change event. Off-network with the
  assertion still held is the exact failure this must not have.
- **`NSWorkspace.didWakeNotification`**, because the radio re-associates while
  nothing of ours is listening; by the time we run again the change has already
  happened.
- **A 60 s poll behind all three.** Not belt-and-braces for its own sake — the
  hotspot feature already paid for trusting edges alone: on 27 Aug 2026 an
  `NWPathMonitor` edge that never arrived left the Mac offline for five hours
  ("The night it never asked", docs/hotspot-fallback.md). Where the network is a
  *state* rather than an event, a clock has to be able to notice by itself. The
  poll is one in-process `CWInterface.ssid()` read a minute — no process spawn,
  10 s of leeway so the scheduler coalesces the wake-up.

The assertion is idempotent in both directions, so the poll simply restates what
it wants every minute and only a real edge reaches IOKit. The log is edge-only
too: a transition gets a line naming the SSID both ways, sixty restatements an
hour get none.

## It cannot leak

IOPM assertions belong to the pid that created them and **the kernel drops them
when the process exits** — including on the `pkill -f "Victor Addons"` half of
the standard rebuild loop, which runs no terminate handler. This is the one thing
it does strictly better than 🔋 next door, whose kernel `SleepDisabled` flag
deliberately survives to the next reboot.

Verify either way:

```sh
pmset -g assertions | grep -i PreventUserIdleDisplaySleep
pmset -g assertions | grep -i "home Wi-Fi"
```

## Why not `caffeinate`, and why not 🔋's machinery

**Not `caffeinate`:** the app is up all day anyway, so a subprocess would be a
second lifetime to keep in step with this one — and a `caffeinate` that outlives a
crash keeps the display awake off-network with nothing left to release it.

**Not `LidAwake`'s machinery**, despite the neighbouring row, and the distinction
is the whole of docs/lid-awake.md: 🔋 needs the kernel `SleepDisabled` flag
because **no assertion in the public API vetoes a closing lid** — clamshell sleep
is a different event. Here the event *is* an idle timer, which is precisely what
an assertion does veto. Different event, different tool. Reusing 🔋's flag would
also mean a sudoers rule and a Mac that refuses to sleep at all, for a feature
that only ever needed the screen to stay lit.

**What *was* reused:** `BreakTimerOverlay` already held exactly this assertion for
the fullscreen break screen, hand-rolled inline. That code is now
`DisplaySleepAssertion` and both features hold an instance of it — two
hand-rolled `IOPMAssertionCreateWithName` pairs are two places to leak an
assertion from.

## Default on

Unlike 🔋, which defaults **off** because a ticked row there means a Mac that
refuses to sleep *anywhere* on a flag that survives the app. This one cannot
reach past one address: it does nothing unless the interface is on a configured
SSID, it releases itself the moment that stops being true, and the assertion dies
with the process. Victor asked for a standing behaviour at home, not for a switch
to remember to flip.

## The tick means "armed", not "holding"

Same contract as 🔋 next door: a ticked row means *watching*, and a ticked row
while away from home with the screen locking normally is the honest state. Which
of the two it is right now is in the test hook, not in the menu.

## Testing it

```sh
curl -s localhost:55123/test/home-awake
```

```json
{"enabled":true,"ssid":"tzutze","home_ssids":["tzutze"],
 "at_home":true,"holding":true,"watching":true}
```

- `ssid` — what CoreWLAN says the interface is on (`null` = would not say).
- `at_home` — the policy's verdict.
- `holding` — whether the assertion is actually taken. **`at_home` true with
  `holding` false is the only genuinely broken state**, and it would mean IOKit
  refused the assertion (logged as such).
- `watching` — whether the timer and CoreWLAN events are armed.

To prove it end to end without waiting for an idle timer: `pmset -g assertions`
should list a `PreventUserIdleDisplaySleep` named "Victor Addons - home Wi-Fi,
screen must not idle-lock" while at home, and the system-wide
`PreventUserIdleDisplaySleep` counter should read 1. Untick the row and both go
away within the click.

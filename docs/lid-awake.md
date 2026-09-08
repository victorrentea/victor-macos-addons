# 🔋 Awake Lid Closed

The travel switch, under 👩🏻‍💻 Extra. Keeps the Mac **running with the lid shut,
on battery, with nothing plugged in** — the case it exists for is a `claude`
session mid-loop that has to survive the laptop going into a bag on a flight.

Code: `LidAwake.swift` (runtime), `LidAwakePolicy.swift` (the decision),
`LidAwakePolicyTests.swift`. Menu row + toggle in `MenuBarManager.swift`, wired
in `AppDelegate.swift` next to `CursorGlow`.

## Why `caffeinate` is the wrong tool, and what is the right one

This is the part that cost the research, so it is written down rather than
rediscovered:

**Every assertion in the public power API blocks *idle* sleep only.** That
includes `caffeinate` with any combination of flags, `IOPMAssertionCreate…`, and
the assertions this app and Claude Code already hold — you can see them in
`pmset -g`, on the `sleep` line, as `sleep prevented by …`. Closing the lid is
not idle sleep; it is **clamshell sleep**, a separate path, and no assertion
vetoes it. A `caffeinate -dimsu` and a closed lid still sleeps.

The one switch that works is the kernel's **`SleepDisabled`** flag:

```sh
sudo pmset -a disablesleep 1     # on
pmset -g | grep SleepDisabled    # verify: 1
sudo pmset -a disablesleep 0     # off
```

`IOPMrootDomain` treats it as a veto on sleep *including* the lid-close path, so
Apple's clamshell requirements (external display + keyboard + power adapter) are
bypassed entirely: battery, nothing attached, lid shut, still running. It is
undocumented — Apple can remove it — and it is also exactly what Amphetamine's
Closed-Display Mode does behind its UI. This feature is Amphetamine minus the
app. It reverts on reboot, and only on reboot.

Verified on this Mac: MacBook Pro 16" **M1 Max, macOS 15.7.7**.

## The sudoers rule

`pmset -a disablesleep` will not run as the user. Rather than a privileged
helper or the deprecated `AuthorizationExecuteWithPrivileges`, the app shells out
to `sudo -n` against one file that whitelists the two exact command lines,
arguments included, and nothing else:

`/etc/sudoers.d/victor-addons-disablesleep` (mode `0440`, owner `root:wheel`):

```
victorrentea ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Install it (validate first — a broken sudoers file locks you out of `sudo`):

```sh
sudo visudo -c -f /tmp/victor-addons-disablesleep \
  && sudo install -m 0440 -o root -g wheel /tmp/victor-addons-disablesleep /etc/sudoers.d/
```

`-n` in the app's invocation is deliberate: without it a missing rule would leave
the app hanging on an invisible password prompt instead of failing in a log line.

**Without this file the toggle cannot work**, and it says so — `setSleepDisabled`
reads the flag back after setting it, `setEnabled` returns false, and
`toggleLidAwakeAction` leaves the row **unticked**. A ticked row that isn't
actually holding the Mac awake is the single worst outcome this feature has, so
the tick is set from what the kernel reported, never optimistically from the
click.

## The 5-second beep is the proof, not decoration

While armed **and on battery and with the lid shut**, a `Tink` at
`NSSound.volume = 0.2` every 5 seconds. `NSSound.volume` is independent of the
system output volume, so it is 20% of whatever the speakers are set to.

It is the only signal that reaches through a closed lid, and **its absence is the
failure report**: if the beeping stops before the battery floor, the Mac slept
and the session died. That is why the beep rides the same timer that enforces the
floor — one timer, one heartbeat, no way for the audible half to outlive the
safety half.

Silent when the lid is open (a beep every 5 s at the desk would make the feature
unusable) and silent on AC (that is the clamshell case macOS supports natively).

## The 20% floor

With `SleepDisabled` set, the normal low-battery sleep never fires, so a
forgotten flag drains to empty. At **< 20%** the tick clears the flag, unticks
the row and lets the closed lid sleep the Mac the ordinary way.

- Checked **before** the beep, so the tick that stands down does not also sound
  like a healthy tick. Three `Basso` beeps say "this was the floor", which is
  distinguishable from silence ("the Mac died").
- 20 exactly still runs — "sub 20%" means below.
- **An unreadable battery is not a stand-down.** A failed read is not evidence of
  a low charge, and taking the machine down mid-flight on a missing number is the
  worse of the two mistakes.
- The floor does not apply on AC: at 4% and plugged in the number is going up.

## Lifecycle

- `LidAwakeSettings.isEnabled` is a `UserDefaults` bool, **default off**. Unlike
  🔄 Reverse Mouse Wheel this replaces no utility, and a Mac that silently
  refuses to sleep is not a state to wake up in by accident.
- On launch the app **re-arms** if it was left on, so the standard rebuild loop
  (`pkill` + `open`) cannot silently drop the lid guard mid-flight.
- Nothing clears the flag on quit, for the same reason. A `pkill` is SIGTERM and
  would not run a terminate handler anyway; the flag survives to the next reboot.
- Once a minute the tick re-reads `SleepDisabled` and re-asserts it if something
  else cleared it (a stray terminal, `pmset restoredefaults`). Once a minute, not
  every tick, so the steady state is one `pmset -g` a minute rather than twelve.
- `AppleClamshellState` on `IOPMrootDomain` is read straight from the IO registry
  rather than by shelling out to `ioreg`: this runs every five seconds for hours,
  on a battery.
- The 5 s timer carries 1 s of leeway so the scheduler coalesces its wake-up with
  others instead of waking the CPU alone — the one thing that matters when the
  point is battery life.

## What it does not solve

- **Heat.** Lid shut in a bag is no airflow. A `claude` session waiting on the
  network is nothing; a session compiling and running tests for an hour will
  throttle and the laptop will be hot.
- **Bluetooth output.** If the JBLs are the default output and out of range, the
  beep goes nowhere and the silence lies. Check the output device before closing
  the lid.
- **A dead app.** The floor is enforced by this process. If Victor Addons is not
  running, nothing stands the flag down (macOS's own emergency sleep at ~2-3%
  still fires, so nothing is bricked).

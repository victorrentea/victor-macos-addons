# 🔋 Claude prevents sleep

The travel switch, under 👩🏻‍💻 Extra. Keeps the Mac **running with the lid shut,
on battery, with nothing plugged in** — the case it exists for is a `claude`
session mid-loop that has to survive the laptop going into a bag on a flight.

**The label names the subject, and that is the contract.** It is Claude that
prevents the sleep, not the switch: a ticked row does not mean the Mac is being
held awake, it means the Mac stays up *while a Claude session is working*, and
is released the moment they all finish. A label like "Keep Awake" would promise
the thing this deliberately does not do.

Code: `LidAwake.swift` (runtime), `LidAwakePolicy.swift` (the decision),
`ClaudeActivity.swift` (is a session working?), `LidAwakePolicyTests.swift`.
Menu row + toggle in `MenuBarManager.swift`, wired in `AppDelegate.swift` next
to `CursorGlow`.

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

The file is checked in at `tools/victor-addons-disablesleep.sudoers`:

```sh
sudo visudo -c -f tools/victor-addons-disablesleep.sudoers \
  && sudo install -m 0440 -o root -g wheel \
       tools/victor-addons-disablesleep.sudoers \
       /etc/sudoers.d/victor-addons-disablesleep
```

`sudo` needs a tty, so this will not run from a non-interactive shell. From an
agent, the working route is the native authorization dialog:
`osascript -e 'do shell script "…" with administrator privileges'`.

`-n` in the app's invocation is deliberate: without it a missing rule would leave
the app hanging on an invisible password prompt instead of failing in a log line.

**Without this file the toggle cannot work**, and it says so — `setSleepDisabled`
reads the flag back after setting it, `setEnabled` returns false, and
`toggleLidAwakeAction` leaves the row **unticked**. A ticked row that isn't
actually holding the Mac awake is the single worst outcome this feature has, so
the tick is set from what the kernel reported, never optimistically from the
click.

## How it knows a Claude is working

Every tick, `ClaudeActivity.isClaudeWorking()` looks for **a live `caffeinate`
whose parent is a `claude`**.

Claude Code spawns `caffeinate -i -t 300` while it is doing something and lets
it expire five minutes later; it does **not** hold one while sitting idle at a
prompt. Measured on this Mac: **26 sessions open, 6 live `caffeinate`
children**, every one with a `claude` parent. So the process tracks *activity*,
not existence.

That distinction is the whole feature. Victor keeps dozens of sessions open all
day — "a claude process exists" would mean the Mac never sleeps again, which is
the exact failure this is meant to prevent.

- **Parentage, not the argument string.** `-i -t 300` is today's invocation and
  could change in any Claude Code release; a `caffeinate` with a `claude` parent
  stays true regardless. It also excludes a `caffeinate` started by hand in a
  terminal, which should not hold the laptop open for a session that isn't
  there.
- **The parent is matched by executable path, not by name — this cost a
  deploy.** `p_comm`, the name in the process table, is the *filename* of the
  binary, and Claude Code installs as
  `~/.local/share/claude/versions/2.1.265`: the kernel calls every session
  `2.1.265`. `ps -o comm=` prints `claude` only because that is `argv[0]`;
  `ps -o ucomm=` shows the truth. Matching `name == "claude"` found nothing
  while six sessions were working. `proc_pidpath` gives the real path, and a
  binary counts when the path *ends in* `/claude` or *contains* `/claude/` —
  the two install shapes. Not a substring search: `claude-gpt`, `claude-local`
  and `claude-docker` sit in the same folder, wrap other models or other
  machines, and must not hold this lid open.
- **The five-minute tail is a feature, not lag.** The last assertion outlives
  the last piece of work by up to 300 s, so a session pausing between turns —
  an API round-trip, a long tool call — does not drop the flag underneath
  itself. The Mac sleeps five minutes after the work genuinely stops.
- **Read via `sysctl(KERN_PROC_ALL)`**, the same source `pgrep` uses, not by
  shelling out to `ps`: no process spawn on a path that runs every ten seconds
  for hours on a battery, and no dependence on `ps` seeing the whole table
  (under a sandbox it does not — measured at 31 rows of several hundred).

## Two kinds of stop, and they are not the same

| | flag | row | why |
|---|---|---|---|
| **release** — no Claude working | cleared | **stays ticked** | The ordinary end of a session. Still watching: the next session to start work re-arms it with nobody clicking anything. |
| **stand down** — battery below 20% | cleared | **unticks** | A hard stop. Continuing to watch would mean re-arming at 19%. |

The flag is only touched **on a change**. The tick runs every ten seconds and
`sudo pmset` is a process spawn; re-stating a value that has not moved six times
a minute is the kind of waste that shows up in the only number this feature is
judged by.

## The heartbeat is the proof, not decoration

While a Claude is working **and we are on battery and the lid is shut**, a
**lub-dub every 10 seconds** at `NSSound.volume` 0.2 — a fraction of the system
output volume, so 0.2 is 20% of whatever the speakers are set to.

**The sound is the real one**, `13_heartbeat.mp3` — the same SFX the 💓 desktop
effect uses, out of the sounds folder shared with the tablet. Not the whole 7.1 s
loop: one beat is cut live out of it, the window `0.50 → 1.05 s`. Those bounds
come from `heartbeat_beats.json`, the same file the 💓 effect zooms to, where the
first pair of onsets lands at 0.59 s and 0.805 s and the next at 1.335 s — so the
window is exactly one lub-dub, with air either side and no clipping of the one
after. A recording of an actual heart is unmistakably a heart; two system `Pop`s
are two clicks that have to be *explained* as a heartbeat. (Two `Pop`s 0.28 s
apart remain the fallback if the shared sounds folder is missing, as it can be in
a dev build — it is a symlink into the Android app's assets, dereferenced into
the bundle by `build-app.sh`.)

The player is built once and rewound, never recreated per beat: this fires 360
times an hour on a battery, and `AVAudioPlayer` has no "play this range", so the
beat is ended by the clock at +0.55 s. Without that stop it would run on into the
next four beats of the loop and the 10-second silence — the part that carries the
signal — would never arrive.

**Two beats, not one, and that is the design.** A single repeating blip is a
machine noise — the ear files it away next to the fridge and stops hearing it. A
lub-dub is a *pulse*, and a pulse that stops is noticed without anyone having to
listen for it. That is this sound's entire job: a liveness signal for a laptop
nobody can see into, so it has to be the kind of sound whose **absence**
registers.

Because **its absence is the failure report**: if the pulse stops before the
battery floor, the Mac slept and the session died. That is why it rides the same
timer that enforces the floor — one timer, one heartbeat, no way for the audible
half to outlive the safety half.

Silent when the lid is open (a pulse every 10 s at the desk would make the
feature unusable) and silent on AC (that is the clamshell case macOS supports
natively) — in both cases the flag is still *held*, just not announced. Arming
plays one beat, so the click doubles as the volume check.

**System volume was the trap, and the beats now fix it themselves (2026-09-09).**
At an output volume of 13 — where this Mac was found — 20% of it is inaudible
even with the lid open, and the silence then means nothing: a proof nobody can
hear is not a proof. So the moment the pulse actually starts (lid shut, on
battery, a Claude working) `LidAwake.boostForBeats` parks the **system output at
80%** and remembers what was there; the moment it stops — the lid opened, the
Claude finished, the floor stood us down, the row unticked — that number goes
back. Nobody is going to reach into a bag and turn it up, and the level the Mac
happened to be left at when the lid came down has nothing to do with how loud a
bag needs.

Four things worth knowing about it:

- **Raise only.** Already past 80% stays where it is. The 80 is a floor under
  audibility, not a level, and quietening a laptop somebody deliberately turned
  up is the one change nobody asked for. The old value is remembered either way,
  so the restore stays symmetric.
- **`NSSound.volume` 0.2 is unchanged and multiplies with it** — the beat stays a
  discreet fifth of a loud machine rather than becoming an alarm.
- **Only the false→true edge captures the old value** (the same discipline
  `CoreAudioManager.pushVolumeDown` follows, for the same reason): a second
  capture while already raised would save 80% as "the original" and the restore
  would be a no-op forever.
- **The restore is one tick behind the lid**, up to ten seconds — opening the lid
  is not an event this watches, the 10 s timer notices it — so one loud beat can
  land in the room before the volume drops. That is the resolution the whole
  feature runs at. The three Basso beeps of a floor stand-down are deliberately
  let out *before* the restore (the disarm is delayed 1 s behind them): they are
  the last thing the bag ever says.

The volume moved is the **default output device's**, read and written by
`SystemOutputVolume` — not `CoreAudioManager`'s named `🔊OS Output` aggregate,
which is the music-mute path. A device that exposes no settable `VolumeScalar`
(some aggregates, some interfaces) is left alone and the beats play at whatever
the machine is set to; the master element is tried first, then channels 1 and 2.
Arming still plays one beat, which is now a check that the sound *exists* rather
than a check of the level. And none of this helps if the JBLs hold the default
output and are out of range.

## The 20% floor

With `SleepDisabled` set, the normal low-battery sleep never fires, so a
forgotten flag drains to empty. At **< 20%** the tick clears the flag, unticks
the row and lets the closed lid sleep the Mac the ordinary way.

- Checked **before** the Claude gate and before the heartbeat, so the tick that
  stands down neither sounds like a healthy pulse nor gets overtaken by a soft
  release. Three `Basso` beeps say "this was the floor", which is
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
  (`pkill` + `open`) cannot silently drop the lid guard mid-flight. Arming runs
  the first tick inline, so the state is right immediately rather than ten
  seconds later — and `holding` is seeded from what the kernel actually reports,
  never assumed.
- Nothing clears the flag on quit, for the same reason. A `pkill` is SIGTERM and
  would not run a terminate handler anyway; the flag survives to the next reboot.
- Once a minute (every 6th tick) the tick re-reads `SleepDisabled` and re-asserts it if something
  else cleared it (a stray terminal, `pmset restoredefaults`). Once a minute, not
  every tick, so the steady state is one `pmset -g` a minute rather than six.
- `AppleClamshellState` on `IOPMrootDomain` is read straight from the IO registry
  rather than by shelling out to `ioreg`: this runs every ten seconds for hours,
  on a battery.
- The 10 s timer carries 1 s of leeway so the scheduler coalesces its wake-up with
  others instead of waking the CPU alone — the one thing that matters when the
  point is battery life.

## What it does not solve

- **Heat.** Lid shut in a bag is no airflow. A `claude` session waiting on the
  network is nothing; a session compiling and running tests for an hour will
  throttle and the laptop will be hot.
- **Bluetooth output.** If the JBLs are the default output and out of range, the
  heartbeat goes nowhere and the silence lies. Check the output device before
  closing the lid.
- **A dead app.** The floor is enforced by this process. If Victor Addons is not
  running, nothing stands the flag down (macOS's own emergency sleep at ~2-3%
  still fires, so nothing is bricked).

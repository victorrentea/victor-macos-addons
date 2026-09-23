# 😴 Claude insomnia (was 🔋 Claude prevents sleep)

**Three states since 2026-09-21, in a submenu of their own** — `😴 Claude
insomnia` with `Off`, `Interactive only` and `Background too`, Victor's shape.
They are *ordered* (off ⊂ interactive ⊂ background), which is a picker rather
than two checkboxes: the combination a pair of switches would also have allowed
— hold the Mac up for the phone but not for the terminal in front of you —
means nothing. `interactive` asks only the process table, so a session driven
from the phone is exactly what it is declining to stay awake for.

That would normally throw away the rule below about not hiding this state, so
**the parent row carries the current mode in its own title** (`😴 Claude
insomnia — background too`): the menu still answers *what is it doing* at a
glance, and only *changing* it costs a hover. **The three rows use the classic
Mac checkmark** — `NSMenuItem.state`, Victor's call — which the rule in the next
paragraph forbids everywhere else in this app and which is free exactly here:
the check column AppKit reserves belongs to those three rows alone, and they
carry no leading emoji to be shifted. The rows are the words alone, with no
marker of their own in the text.
A Mac that had the old single switch on lands in `background`, which is what it
was already doing by then (`LidAwakeSettings.mode(stored:legacyEnabled:)`,
unit-tested) — nobody's lid guard changes underneath them on an update.

The history of the row it replaced, which is still the reason for its shape:

The travel switch, a **top-level menu row since 2026-09-17** (it spent its life under 👩🏻‍💻 Extra; Victor moved it out — this is the one state in the app that decides whether the Mac is awake inside a bag, and a state you have to open a submenu to see is a state you forget you left on). The row is **`Claude prevents sleep`, with no emoji**: a tick when it is on and nothing at all when it is off, which is what a checkbox looks like — a leading 🔋 would be something in front in *both* states. The name keeps the 🔋 everywhere else, it is just not on the row. The tick is **in the title** (`MenuBarManager.LidAwakeMenu`, unit-tested), never `NSMenuItem.state`: the native one makes AppKit reserve a check column for the whole menu and shifts every other row's text — including the leading emoji those rows are recognised by. Keeps the Mac **running with the lid shut,
on battery, with nothing plugged in** — the case it exists for is a `claude`
session mid-loop that has to survive the laptop going into a bag on a flight.

**The label names the subject, and that is the contract.** It is Claude that
stays awake, not the Mac on its own: a ticked row does not mean the Mac is being
held awake, it means the Mac stays up *while a Claude session is working*, and
is released the moment they all finish. A label like "Keep Awake" would promise
the thing this deliberately does not do.

Code: `LidAwake.swift` (runtime), `LidAwakePolicy.swift` (the decision),
`ClaudeActivity.swift` (is a session working? — **two** signals since 2026-09-21,
because a session driven from the phone answers neither `caffeinate` nor its own
`status` field), `LidAwakePolicyTests.swift`.
Menu row + toggle in `MenuBarManager.swift`, wired in `AppDelegate.swift` next
to the 🏠 Home Wi-Fi toggle (it used to sit next to `CursorGlow`, deleted
2026-09-14).

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
- **The daemon's own spares do not count** (2026-09-10, and this is why a Mac
  with nothing running would not sleep). Claude Code keeps pre-warmed processes
  around — `claude bg-spare --bg-spare /tmp/cc-daemon-501/…/claim.sock` and the
  `bg-pty-host` behind it — waiting to be handed to the next session. They run
  the *same binary from the same path* as a session and they spawn a
  `caffeinate -i -t 300` of their own: pid 51845 held one, let it expire and
  spawned another 30 seconds later, with nobody working. Counted as sessions,
  they hold the lid open forever and the pulse never stops.
  They are told apart by **`argv[1]`**, read with `sysctl(KERN_PROCARGS2)`, not
  by a substring of the command line: a session started as
  `claude -p "fix the bg-spare bug"` carries its prompt in `argv`, and a loose
  match would stop holding the lid open for the session most likely to be
  mid-flight. **The dashes are real, and cost the first cut of this**: `ps`
  shows `claude bg-spare --bg-spare …`, which reads as a subcommand, but
  `bg-spare` is part of `argv[0]` (the process title) and the actual `argv[1]`
  is `--bg-spare` — measured, against `--session-id` for a real session. The
  bare word matched nothing at all, so the exclusion would have shipped as a
  silent no-op. Leading dashes come off before the comparison.
  A claimed spare is never excluded: it drops the title when it becomes a
  session (verified — a live session's `argv` is the versioned binary path and
  its flags, with no `bg-` anywhere).
- **The holders are named in the log.** "Everything has finished and the Mac is
  still awake" cannot be answered by a boolean, so the moment the set of working
  pids changes the log says who: `held open by 1 working Claude session(s):
  52799`, and `the last working Claude (52799) finished` when it lets go. Naming
  them cost a debugging session on 2026-09-10 whose answer turned out to be *the
  Claude being asked to investigate* — every message to a session spawns a
  `caffeinate` that outlives the turn by five minutes. `GET
  /test/claude-activity` gives the same two lists on demand (`working`,
  `skipped_helpers`).
- **Read via `sysctl(KERN_PROC_ALL)`**, the same source `pgrep` uses, not by
  shelling out to `ps`: no process spawn on a path that runs every ten seconds
  for hours on a battery, and no dependence on `ps` seeing the whole table
  (under a sandbox it does not — measured at 31 rows of several hundred).

### The second signal: sessions driven from the phone (2026-09-21)

**A remote-control session holds no `caffeinate`, so everything above was blind
to it.** Victor asked the question the right way round — *"do remote sessions
keep the laptop awake when the row is on? they should"* — and the answer was no:
a turn started from the phone ran with the lid shut and the Mac went to sleep
underneath it.

Why, measured on 2026-09-21:

- A session driven from the phone is **not a terminal session**. The
  `claude remote-control` host (pid 66358, inside the `claude-rc` tmux) spawns
  one `claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_…`
  per session — four of them live that morning, all children of the host.
- **Headless Claude Code never starts a `caffeinate`.** In the CLI bundle
  (2.1.274) the sleep inhibitor is a ref-counted singleton with exactly **one**
  acquire site: an effect inside the terminal UI component,
  `if (status === "busy") acquire()`, released on cleanup and re-spawned every
  240 s. `--print` never renders that component. Verified twice with a
  `claude -p` doing ~50 s of real work — zero new `caffeinate`, only the
  interactive session's own — and on the live rig, where remote session 5914
  was appending to its transcript that very minute while holding nothing.
- So `isClaudeWorking()` said false, `LidAwake` released the flag, and the lid
  decided the rest. Battery and lid had nothing to do with it; the *signal* was
  missing.

**The transcript is the second signal, and was the first one shipped.** Claude Code appends to
`~/.claude/projects/<slug>/<sessionId>.jsonl` on every message — each assistant
turn, each tool call, each result — and stops the moment the session parks. On
the four live remote sessions: the two mid-work were **0** and **2.8 minutes**
old, the parked one **14 hours**. Same shape as a `caffeinate`: it tracks work,
not existence.

- **The session list comes from Claude Code's own presence files**,
  `~/.claude/sessions/<pid>.json`, which carry `pid`, `sessionId`, `cwd` and
  `entrypoint` (`cli` for a terminal, **`sdk-cli`** for a remote one).
- **Their `status` field leads the decision** (since the afternoon of the same
  day; it was dismissed in the morning, and that is corrected here).
  The first reading was a single sample: remote session 5914 at `"busy"` with
  `statusUpdatedAt` two seconds after its own start looked like a field written
  once and abandoned, which would have held the lid open forever. Re-measured
  the same afternoon across all 13 live sessions, it tracks: that session had
  been busy since it started, and the parked one sat at `"idle"` with a
  `statusUpdatedAt` **twelve seconds after** its last transcript line, 14 hours
  earlier — a clean falling edge on a session with no terminal UI. So it is a
  live signal, and a **more responsive and cheaper one** than the transcript:
  written at the moment of the change, no 64 KB tail, no grace period.
  So the rule is now:
  - `busy` → working, for as long as there is any **sign of life** — the more
    recent of the status change and the last transcript write, capped at 15
    minutes. Measured live: two sessions busy for 151 and 131 minutes with
    transcripts 24 and 18 seconds old, both genuinely inside long tool calls,
    both held. One blocked forever on something that never answers goes quiet in
    both clocks and is let go.
  - `idle` / `waiting` / `shell` → finished, with the transcript guarding the
    falling edge: a status that lags, or one left behind by a restart, cannot
    sleep the Mac while lines are still being written. The grace is **15
    seconds** rather than the 60 the transcript rule needed, because the end of
    a turn is now *stated* instead of inferred from the shape of the last line.
  - no `status` at all (an older CLI) → the transcript rule below, unchanged.
- **Only `sdk-cli` sessions are judged this way**, deliberately. A terminal
  session already answers the sharper signal, and its `caffeinate` is killed
  ~30 s after a turn ends (the `-t 300` is only the orphan backstop); giving all
  two dozen open terminals a five-minute tail instead would be a real
  regression.
- **The pid is still checked against the process table** — the presence file is
  deleted on exit but survives a crash, and `proc_pidpath` must still say
  `claude`, so a recycled pid cannot hold the lid.
- **The path is derived, not searched.** `cwd` → folder name is Claude Code's
  own encoding: everything outside `[A-Za-z0-9]` becomes a dash
  (`/Users/victorrentea/workspace` → `-Users-victorrentea-workspace`), checked
  against all 14 live sessions. There are **287** project directories on this
  Mac; walking them six times a minute to find one file is not worth it. The
  cost: a session resumed in a different directory than its presence file
  records looks silent — which is the behaviour of the day before this existed.
- **The mtime alone was too blunt in both directions, and the last line fixed
  both** (same day, after Victor asked why he now had to wait five minutes for a
  shut lid to sleep). The tail of the transcript says *which* of the two is
  happening, so it is read backwards to the first line that means something:
  - `stop_reason: "end_turn"` with nothing after it — the turn is over. **One
    minute** of grace and the Mac may sleep, instead of five. Not zero: the gap
    between one turn ending and the next queued message being picked up is a
    second or two of `end_turn`, and a tick landing in that gap would sleep the
    Mac in the middle of a conversation.
  - `stop_reason: "tool_use"`, or a `user` / `queue-operation` / `attachment`
    line last — the session is inside a tool call or thinking about the next
    one. Believed for up to **15 minutes**, which is what carries a long build
    across the old five-minute mark. The cap exists only so a session blocked
    forever on something that never answers cannot hold the lid open all night.
  - nothing decisive in the tail — the plain five-minute mtime rule, as before.
  **Sub-agent lines are skipped** (`isSidechain: true`): a subagent finishing
  with `end_turn` while its parent carries on would read as the whole session
  going idle, and on a shut lid that reads as "sleep now". Only the last 64 KB
  of the file is read — these transcripts reach 20 MB and this runs every ten
  seconds.

`GET /test/claude-activity` now answers `{working, remote, skipped_helpers}`,
with `remote` the pids counted through this half — the first thing to look at
when "it is working but the Mac slept" comes back.


## The internet gate: a parked Claude is not a working Claude (2026-09-15)

`ClaudeActivity` answers "is a session working?" and, on a laptop with no Wi-Fi,
it answers **yes to a session that cannot do a thing**. Since 2026-09-14 Victor's
`~/.claude/hooks/net-gate.sh` parks a turn the moment `api.anthropic.com` stops
answering and polls once a minute until it comes back — deliberately, because
Claude Code's internal retry ladder is a hardcoded ~3 minutes and a turn that
runs it out is killed with its work. That park is right for the session and
wrong for the lid: a parked turn is a **live** turn, Claude Code keeps refreshing
its `caffeinate`, and the pids are still named as holders. A bag out of Wi-Fi
range would hold the Mac awake all night waiting for a network that is not coming
back until the bag is opened — and then hit the 20% floor having done nothing.

So the tick asks a second question. The rule, in Victor's words: **only activity
with internet keeps the laptop on.**

- **Five minutes** (`LidAwakePolicy.offlineGrace`, 300 s — the same number as
  Claude Code's own `caffeinate -t`). Below it every Wi-Fi hiccup, AP roam and
  hotspot re-association is absorbed; above it the link is genuinely gone.
- **It is a release, not a stand-down.** The flag comes off, `pmset sleepnow`
  follows on a shut lid on battery exactly as it does for the ordinary ending,
  and **the row stays ticked**. An outage is a reason to stop holding, never a
  reason to stop watching: the first session to do real work once the link is
  back re-arms all of this with nobody clicking anything.
- **One flatline covers both endings.** From inside the bag "the work finished"
  and "the network died under it" mean the same thing — *this sleep is on
  purpose, not a crash* — and inventing a third sound would be one more thing to
  explain through a closed lid. The **log** is where they are told apart:
  `no internet for 312s — 3 Claude session(s) are parked, not working; letting
  the Mac sleep`, written once per outage, with `internet is back` on the way
  out. The floor keeps its own three Bassos, because that says something the
  other two do not.
- **The trade is stated, not hidden**: a session compiling for an hour with the
  Wi-Fi off no longer holds the lid open either. This feature was built for a
  mid-flight `claude` loop, not for an offline build, and Victor's rule decides
  the tie.

### How "offline" is measured — `InternetWatch.swift`

- **The host is `api.anthropic.com`**, not "the internet". The failure that
  matters is Claude Code being unable to reach *its* API, which is also what
  `net-probe.sh` tests, so a captive portal that carries LAN traffic but not
  Anthropic counts as offline. One TCP handshake proves DNS + TCP in one shot.
- **One failed probe is enough here**, unlike `HotspotFallback`'s two. There a
  bogus "offline" costs a `networksetup` join that takes the Wi-Fi down; here it
  only leaves a clock running that the next probe 30 s later resets. **The
  five-minute grace is the confirmation**, and it is a hundred times longer than
  any gap between two back-to-back probes.
- **Three sources, cheapest first.** `NWPathMonitor` says "no route" for free —
  the bag case, and no point burning four seconds on a handshake to learn it.
  Then the hooks' own `~/.claude/net-probe` stamp: `net-probe.sh` writes the
  epoch of every **successful** probe there, so a stamp under 45 s old is proof a
  Claude reached the API, for free. Only then a handshake of our own, at most
  every 30 s.
- **Missing evidence is never an outage.** `offlineFor()` returns 0 whenever the
  watch is not running or has never measured — the same discipline as the
  unreadable battery below: of the two possible mistakes, sleeping a Mac
  mid-flight because nobody was probing is much worse than holding it awake
  longer than needed.
- **Waking resets the clock.** The lid opens in a new room and the Mac has been
  "offline" for the whole sleep; judging it on that would sleep it again
  immediately. `didWakeNotification` restarts the five minutes and asks again.
- **It runs only while the row is ticked.** `LidAwake` starts and stops the watch
  with its own timer, so an unticked row costs nothing — and an armed one costs
  one handshake every 30 s, less than `HotspotFallback` already pays.
- Reported in `GET /test/lid-awake/state` as `offline_for` / `offline_grace`, so
  "why did it sleep in the bag" is one `curl` away.

## Two kinds of stop, and they are not the same

| | flag | row | why |
|---|---|---|---|
| **release** — no Claude working | cleared | **stays ticked** | The ordinary end of a session. Still watching: the next session to start work re-arms it with nobody clicking anything. |
| **farewell** — no Claude working, *and the pulse was audible* | cleared, after the flatline | **stays ticked** | Same release, announced first. See below. |
| **stand down** — battery below 20% | cleared | **unticks** | A hard stop. Continuing to watch would mean re-arming at 19%. |

**Clearing the flag is permission to sleep, not a sleep (2026-09-10).** The
kernel decides about a lid at the moment it closes; a veto withdrawn any time
after that is not a second close, so a Mac whose flag comes off while the lid is
already shut can sit awake in a bag until some idle timer eventually gets to it.
So every release that happens **with the lid shut and on battery** asks for the
sleep explicitly, with `pmset sleepnow` — the one `pmset` verb here that needs no
privileges, hence no sudoers rule. All three stops go through `hold(false)`, so
all three get it: the ordinary release, the farewell (after the tone, never
before), and the floor's stand-down.

Never on AC, and never with the lid open. Clamshell-on-power is the case Apple
supports natively, and a projector plugged into a closed laptop mid-workshop must
not be put to sleep by a heartbeat feature. With the lid shut on battery this
only gets where macOS was going anyway, sooner.

And **closing the lid with nothing working makes no sound at all**: nothing was
beating, so there is no ear mid-conversation to sign off to and the answer is a
plain `.release` (`testNoFarewellIfThePulseWasNotRunning`) — flag off, `pmset
sleepnow`, silence. The flatline is for the pulse that was audible right up to
the release, and only for that.

The flag is only touched **on a change**. The tick runs every ten seconds and
`sudo pmset` is a process spawn; re-stating a value that has not moved six times
a minute is the kind of waste that shows up in the only number this feature is
judged by.

## The heartbeat is the proof, not decoration

While a Claude is working **and we are on battery and the lid is shut**, a
**lub-dub every 10 seconds** at `NSSound.volume` **1.0** — full scale, on top of
whatever the system output is set to (which the beats park at 100% themselves
when they are allowed to, and unmute, below).

**It was 0.2 until 2026-09-10, and the silence guard is what changed it.** A
fifth was plenty while the beats could count on parking the output at 100%: a
fifth of a machine turned all the way up still carries through a bag. But the
boost is now refused whenever something else is playing, and 20% of an output
left at 13 is nothing at all — the pulse would go quiet in exactly the situation
it was still supposed to be reporting from. At 1.0 the beat sounds the same
whether or not the boost happened, and because the file is a *recording of a
heart* rather than a tone, full scale reads as a heartbeat and not as an alarm.

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
100%** and remembers what was there; the moment it stops — the lid opened, the
Claude finished, the floor stood us down, the row unticked — that number goes
back. Nobody is going to reach into a bag and turn it up, and the level the Mac
happened to be left at when the lid came down has nothing to do with how loud a
bag needs.

**80% was the first number and it was not loud enough** (raised to 100% the same
day). Through a closed lid, inside a rucksack, at 20% of 80% the lub-dub was
there in a quiet room and gone in an airport — and a pulse you have to strain
for cannot carry a failure report, because you can never be sure whether the
silence is the Mac or the room. There is no in-between setting worth defending
here: the volume is *already* being taken over and restored, so anything short
of the top is just an arbitrary handicap on the one signal the feature exists to
send.

**And only onto silence (2026-09-10).** If any other app is running an output
stream, the volume is left exactly where it is and the lub-dub plays at whatever
the machine was set to. Taking a Mac that is *playing music* to 100% is not a
louder proof, it is Victor's playlist at full blast — into a bag, or into the
room the retina is projecting to. The old value is not captured either, so the
boost is simply retried on the next tick: the moment the music stops, it happens
by itself, with nobody deciding anything.

The guard lives in `SystemAudioActivity.otherAppPlayingOutput()`, and **the
always-open plumbing is the whole difficulty of the question**. Read naively,
`kAudioProcessPropertyIsRunningOutput` says something is playing on this Mac
*permanently*: measured on a silent machine, `com.rogueamoeba.audiohijack` and
`ai.krisp.krispMac` both report 1 forever — Audio Hijack holds the `🔊OS Output`
loopback open as a listener (the same latching the RMS detector in
`CoreAudioManager` was written to get around) and Krisp keeps its virtual device
open the same way. Left in, they would mean the heartbeat never once raises its
volume. Neither is ever *the music*, so both are skipped by bundle prefix, and
so is this app's own process — the arming lub-dub plays one line before the
first tick asks the question, and it must not veto its own volume. A real player
is caught: with one `afplay` running, its process and only it showed up beside
those two.

**Walkie Talkie was the third one, and it had killed the boost outright
(2026-09-15).** Curling `/test/audio/playing` every 3 s for a minute on a silent
Mac returned `ro.victorrentea.wispr-relay` every single time, at an RMS of
exactly 0: the dictation overlay holds an output stream open permanently, the
same way Audio Hijack holds the loopback. Since it runs all day, the refusal was
permanent — `boosted:false` on a machine with the lid shut, on battery, beating
into a muted output — and the pulse had been inaudible for as long as Walkie
Talkie has been installed. It is listed by its **full** bundle id and not as
`ro.victorrentea.`, because the other app in that family is `victor-effects`,
the soundboard: that one *is* the music, and skipping it would mean taking the
room's playlist to 100%.

**Wispr Flow itself was the fourth, and it had killed the boost again
(2026-09-21).** Same symptom, reported the same way: lid shut, a remote session
working, no heartbeat at all. Sampled every 4 s on a silent Mac,
`com.electron.wispr-flow.helper` reported an open output stream every single
time at RMS 0 — the dictation app, running all day, holds the stream the way its
relay does. Beside it sat a **process with no bundle id at all**: Playwright's
`chrome-headless-shell` audio utility, left behind by the WhatsApp and LinkedIn
skills, which also holds one open at RMS 0. So the probe now falls back to the
binary's path when there is no bundle id, both to skip that one and to *name* it
in the refusal — `pid 46038` says nothing, `pid 46038 (chrome-headless-shell)`
says everything. Proven on the lid: with both skipped, a 40-second close beat
five times at `boosted:true`, where the same close an hour earlier had been
silent.

Why not the RMS tap that already exists: it measures the `🔊OS Output`
aggregate, which is the music-mute path's device and not what a laptop in a
rucksack is playing through. The process list needs no device to be present.
The prefix list is a liability if some future app latches the flag the same way,
so **the refusal is logged with the name of whoever caused it** ("`X` is playing
— leaving the output volume where it is", once per streak, not six times a
minute): one line says which app to add, instead of a boost that is quietly
never applied again. `GET /test/audio/playing` reports it as `other_app_playing`
next to the RMS numbers.

Four things worth knowing about it:

- **Raise only**, which at 100% now only ever means "already there". The guard
  stays because it is what keeps the restore symmetric — the old value is
  remembered either way — and because the target is a constant that has moved
  once already.
- **`NSSound.volume` multiplies with it** — at the pulse's 1.0 a boosted beat is
  the machine at full scale, and an unboosted one is full scale of whatever
  Victor had it on.
- **Only the false→true edge captures the old value** (the same discipline
  `CoreAudioManager.pushVolumeDown` follows, for the same reason): a second
  capture while already raised would save 100% as "the original" and the restore
  would be a no-op forever.
- **The restore is one tick behind the lid**, up to ten seconds — opening the lid
  is not an event this watches, the 10 s timer notices it — so one loud beat can
  land in the room before the volume drops. That is the resolution the whole
  feature runs at. The three Basso beeps of a floor stand-down are deliberately
  let out *before* the restore (the disarm is delayed 1 s behind them), and so
  is the flatline: they are the last thing the bag ever says.

**And mute is a second knob, not a low volume (2026-09-15).** Muting a Mac —
F10, the Control Centre slider, Wispr, anything — does not move `VolumeScalar`:
the device keeps reporting the level it had. So the boost above was happily
parking a *muted* machine at 100%, which is 100% of nothing, and the bag heard
no pulse and no flatline. It is also not a rare state: the lid comes down on a
muted laptop in a meeting, a library or a plane, which is precisely when the
session goes into the bag. `LidAwake.liftMute()` therefore takes the mute off on
the same edge that raises the volume, remembers it in `muteBeforeBeats`, and
`restoreMute()` puts it back on the way down.

- **The same refusal covers it.** Unmuting is only ever reached after
  `otherAppPlayingOutput()` came back empty — lifting a mute on a Mac with a
  stream open is the same violence as taking it to 100%, only with a slider
  between them, and both end with Victor's playlist in the room.
- **Asked on every tick**, unlike the volume, which is captured once on the
  false→true edge and then left alone. A volume nudged while the pulse is
  running still leaves a pulse; a mute switched on halfway through is total
  silence — and silence is the one thing this feature must not invent, because
  it is also how it reports a dead Mac. Measured cost: one CoreAudio property
  read per 10 s tick. (This is also why the first build of it did *not* work:
  capturing on the rising edge like the volume meant a Mac muted after the
  beats had started stayed muted, which `/test/lid-awake/state` showed as
  `muted:true, mute_lifted:false` for as long as you cared to poll it.)
- **Restored before the sleep, not after it** — the part that makes the Mac wake
  up as quiet as it went in. `hold(false)` is what calls `pmset sleepnow`, and
  every caller restores the audio on the line *after* that call: a line that may
  never run, because the sleep can freeze the machine mid-statement. So the
  restore is done inside `hold` itself, immediately before `sleepnow`, and the
  callers' own calls then find nothing owed. Waking up at full volume in the
  next meeting because a heartbeat needed to be heard hours earlier is the
  feature leaking out of the bag.
- **Arming says so.** The lub-dub the click plays is the sound check, and on a
  muted Mac it is inaudible — the mute is only lifted once the pulse actually
  starts, never at the desk. So `setEnabled` logs "the Mac is muted — this beat
  is inaudible; the pulse unmutes by itself once the lid is shut" instead of
  leaving that silence to read as a broken sound path.
- `GET /test/lid-awake/state` reports both halves: `muted` (what the device says
  right now, `null` if it has no mute control) and `mute_lifted` (whether we are
  holding one).

The volume moved is the **default output device's**, read and written by
`SystemOutputVolume` — not `CoreAudioManager`'s named `🔊OS Output` aggregate,
which is the music-mute path. A device that exposes no settable `VolumeScalar`
(some aggregates, some interfaces) is left alone and the beats play at whatever
the machine is set to; the master element is tried first, then channels 1 and 2.
Arming still plays one beat, which is now a check that the sound *exists* rather
than a check of the level. And none of this helps if the JBLs hold the default
output and are out of range.

## The flatline (2026-09-09)

When the last Claude finishes and the flag is about to come off, the pulse does
not just stop — the Mac plays **the 🫀 Pulse effect's flatline**,
`15_flatline.mp3`, whole (5.25 s: two last QRS beats, then the long tone), and
only then does `hold(false)` let the closed lid sleep the Mac.

**Because silence was overloaded.** The whole design above rests on the pulse's
*absence* being the failure report: no beat means the Mac slept and the session
died. But the healthy ending — the work finished, the Mac is allowed to sleep on
purpose — produced exactly the same silence. From inside a bag, "done" and "dead"
were the same sound.

**And more beats were not the answer.** The first version of this played five
last lub-dubs, which is still the same sound the bag has been hearing every ten
seconds all along — told apart from a live pulse only by *counting*, through a
closed lid, while doing something else. A flatline is not a quantity of
heartbeats, it is the opposite of one: the one ending a pulse can have that
nobody has to count or explain. It is also already in the shared sounds folder,
already mapped to the 🫀 Pulse desktop effect in `SoundEffectMap`, so the sound
the bag hears and the effect the room sees are the same recording.

- **Played whole, not cut.** Unlike `heartbeat()`, which slices one lub-dub out
  of the loop and stops it by the clock, this file *is* the event and runs start
  to finish; the release just waits `farewellLength` (5.30 s — the clip's 5.25 s
  rounded up so the tone is never truncated).
- **At 1.0, never under the pulse.** It was 0.8 against a pulse of 0.2 — louder,
  deliberately, because it plays once and is the last thing the bag ever says.
  With the pulse now at full scale, 0.8 would make the ending *quieter* than the
  beats it ends, which is the one thing this sound cannot be.
- **The player is built fresh, not cached.** `beatPlayer()` is cached because it
  fires every ten seconds for hours; this fires once per session, and holding a
  decoded 72 KB file all that time to use it once is the waste the cache exists
  to avoid. It is retained in `farewellPlayer` for the length of the clip — an
  `AVAudioPlayer` nobody holds is deallocated before it makes a sound.
- **The tone goes out *before* the flag drops.** `hold(false)` can sleep the Mac
  immediately, and a release-then-announce would cut the flatline off partway —
  which is the one shape that reads as a crash. Same discipline as the floor's
  three beeps, which delay their disarm rather than race it. The system volume is
  restored only after, for the same reason.
- **Whenever this release is the one that sleeps the Mac** (since 2026-09-23).
  It used to need `wasBeating` — the previous tick a `.beat`. Then Victor shut
  the lid right as the last Claude finished: the tick released before a single
  beat, `pmset sleepnow` ran, and the Mac went down in total silence — *"trebuie
  să aud un beep prelungit înainte să intre în sleep, ca să știu că n-a rămas pe
  heartbeat"*. The gate is now `holding` (we were keeping the lid open) plus lid
  shut and on battery: exactly the case that ends in `pmset sleepnow`. Once the
  flag is down the next tick sees `holding == false` and releases quietly, so it
  plays once. Lid open or on AC: plain `.release`, silent. `farewell()` also
  calls `boostForBeats(true)` itself now, since without a pulse nothing had
  taken the output up.
- **A deliberate disarm never plays it.** `decide` returns `.release` on
  `enabled: false` before it ever looks at `beating`. The sound is for the sleep
  nobody asked for, not the one that was clicked.
- **The floor still wins.** Below 20% the answer is `.standDown` and the three
  Bassos, because that says something different: this was the battery, not the
  work finishing.
- **A session that wakes up during the five seconds keeps the lid open.** The
  release is re-checked against `ClaudeActivity` after the clip; if a Claude is
  working again the flag is simply left up and the next tick carries on beating.
  Five seconds is long enough for that to happen, and dropping the flag
  underneath a live session is the failure this whole feature exists to prevent.
- **Fallback, dev builds only.** With no shared sounds folder there is no flat
  tone in the system sounds, so it plays the two `Pop` pairs the recording opens
  with (1.40 s apart) and then a `Submarine` under them, the nearest thing macOS
  ships to a long low note.

## The door: what the Mac says when it *does* sleep (2026-09-22)

`SleepChime.swift` + `SleepChimeTests.swift`. Not part of this feature's
machinery — it hangs off `NSWorkspace.willSleepNotification` in `AppDelegate`
and runs whatever the mode is — but it exists entirely because of it, and it is
the last piece of the argument the flatline started.

**Silence was still overloaded, one level up.** The flatline fixed "done" vs
"dead" *for a pulse that was already running*. It did nothing for the case
Victor actually stands in several times a day: the lid comes down and he waits,
three or four seconds, to hear whether a heartbeat starts. Nothing starts. That
silence had four readings and no way to tell them apart —

- the Mac went to sleep (the ordinary, correct one);
- 😴 Claude insomnia is `off`;
- it is armed, but nothing counted as working (nothing running, or running
  without internet past the five-minute grace, or a `background` session while
  the mode is `interactive`);
- the feature is broken — the sudoers rule gone, the app not running, `pmset`
  refusing.

The first is by far the most common, and it is the one worth a sound, because
saying it out loud leaves the other three as the only thing silence can mean.

**So sleep announces itself.** 🚪 `25_dark_door.mp3`, 1.5 s, once, as the Mac
goes down. After the lid closes there are now exactly two audible outcomes:

| what you hear | what happened |
|---|---|
| 💓 lub-dub every 10 s | awake, a Claude is working, insomnia is holding |
| 🚪 a door closing | asleep — whatever the reason |
| *nothing* | **something is wrong** |

The third row is the point. It is the first time a missing signal here means
only one thing.

**Why a door and not a fifth variation on the pulse.** Same argument as the
flatline's: through a closed bag the signals have to be distinguishable by
someone who is not looking and not counting. A door is neither a lub-dub nor a
continuous tone, so 💓 / 🫀 / 🚪 are three sounds you cannot mishear for each
other. Victor picked it from the shortlist on 2026-09-22.

**It blocks the sleep for its own length, deliberately.**
`willSleepNotification` is delivered before the machine goes down and macOS
waits for the observers to return, so `SleepChime.sound()` parks the main
thread until the file has played. `AddonSounds.play` is unusable here — it
dispatches to the main queue with `async`, which at that moment means "after
this handler returns", i.e. onto a sleeping Mac. `SleepChime.maxBlock` (3 s)
caps it so a swapped file can never turn closing the lid into a wait, and
`SleepChimeTests` asserts the file is shorter than the budget.

**The volume follows `boostForBeats`'s rules**, because it is the same
problem: a chime nobody can hear is not a signal. Lid shut **and** nothing else
playing → lift the mute, take the output to 100% — **on AC too since
2026-09-23** (it used to be battery only, and a muted Mac on its charger slept
in total silence). Lid open → play at whatever level Victor chose, because he is
looking at the screen and the screen already told him. Something else playing → chime at that
level and log which app refused the boost; unmuting a Mac with an open stream
is how a playlist ends up at full blast in a bag.

**And it restores before returning, in a `defer`.** The trap `hold()` documents
one section up, in a place with even less margin: here the very next thing that
happens is the machine sleeping, so a restore below the playback line is a
restore that a throw, the cap, or a freeze simply skips — and the Mac wakes up
unmuted at 100% in the next meeting. `SleepChimeTests` reads the source and
fails if the `defer` is not registered before the player starts.

**The two sounds compose rather than collide.** A `.farewell` tick plays the
5.25 s flatline, then `hold(false)` calls `pmset sleepnow`, which raises
`willSleepNotification`, which sounds the door. 🫀 then 🚪 is the whole story in
order: the session ended, and now the Mac is asleep.

**No counterpart on wake** (asked and declined, 2026-09-22): opening the lid
puts a screen in front of him, which is a better answer than a sound.

## A lid close is never silent, plugged in or not (2026-09-23, evening)

*"The beep at sleep should happen whether I'm on power or on battery … the
hardware beep if it keeps open, or the long beep if it goes to sleep."* The
morning's rule (three quick lub-dubs = awake, the long tone = asleep) only held
on battery, because everything here was gated on `!onAC`. Three holes, closed:

| lid comes down… | before | now |
|---|---|---|
| on AC, Mac sleeps (no external display) | tone at the slider's level — muted = silence | tone, unmuted at 100% (`SleepChimePolicy` no longer takes `onAC`) |
| on AC, Mac stays up (a Claude working, or clamshell with an external display, or 😴 `off` + `SleepDisabled`) | silence | three quick lub-dubs (`announceIfStayingUp`) |
| on AC, holding, the last Claude finishes, no external display | flag drops, Mac sits awake shut until idle sleep | 🫀 flatline + `pmset sleepnow`, same as on battery |

- **The lid watcher is always on** now — installed in `startIfEnabled` before
  the mode check, never removed — because the announcement does not depend on 😴
  being armed. It ticks first (only when armed) and then calls
  `announceIfStayingUp`, which skips if the tick itself just beat (battery +
  working already played the three beats).
- **"Does this close sleep the Mac?"** = `AppleClamshellCausesSleep` **and not**
  `SleepDisabled`. `AppleClamshellCausesSleep` on `IOPMrootDomain` is `No` in
  clamshell mode (AC + external display) and — measured — stays `Yes` with
  `SleepDisabled` up, so the two have to be combined. Also exposed as
  `clamshell_causes_sleep` in `/test/lid-awake/state`.
- **The continuous pulse is still battery-only.** On AC the lid close gets one
  confirmation, then silence: a lub-dub every 10 s in clamshell at the desk would
  make the feature unusable. The boost for those three beats is put back ~2 s
  later (`announcing` keeps a `.hold` tick from re-muting mid-way).
- **`pmset sleepnow` on AC only without an external display** — the projector
  plugged into a closed laptop mid-workshop is still never slept.

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

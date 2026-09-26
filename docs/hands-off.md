# ✋🔒 Hands off — the frame an agent raises while it drives the GUI
`HandsOffOverlay` + the pure `HandsOffSession`. Amber border on **every** screen,
four semi-transparent 🔒 pulsing in the corners of every screen, plus a badge riding
the cursor (`✋ codex — click pe Restart to Update`); on release the border turns green
for 0.5s, fades over 0.25s and a `Tink` plays. Raised over the
existing HTTP door, so any agent — codex, claude, a shell script — uses the same two calls:

```sh
curl "localhost:55123/hands-off/start?agent=claude&what=click%20pe%20Restart&ttl=120"
# … the GUI dance …
curl localhost:55123/hands-off/end
```

or, the same thing without remembering the URL — `./hands-off.sh`, symlinked as
`~/bin/hands-off`:

```sh
hands-off run "click pe Restart to Update" -- ./drive-the-gui.sh   # releases on exit/Ctrl-C/crash
hands-off start "click pe Restart" 120 ; … ; hands-off end
hands-off demo 10                                                  # just look at it
```
It starts the app if the door doesn't answer, and if it still doesn't it says so on
stderr instead of failing quietly — an agent that drives the mouse with no warning on
screen is exactly the situation this exists to prevent.

## ✋ Victor takes control — click a 🔒 (26 Sep 2026)
Victor, 2026-09-26: *"un mecanism prin care să pot întrerupe blocajul ecranului: un
click pe cele patru lăcățele din colțuri, și să comunice agentului care ținea lacătele
că am preluat controlul și să întrerupă ce făcea."* Until then the locks were one-way:
the agent said "don't touch" and the only way out was to fight the pointer or find the
right terminal for a Ctrl-C.

**The gesture.** A **real** click on any of the four 🔒 on any screen — or **⌃⌘⎋ twice
within 1 s** (the mouse may be mid-drag by a synthetic event; the keyboard is not).
Both are ignored when synthetic (source pid ≠ 0): the agent being stopped must not be
able to press the stop button, and a synthetic click that happens to land in a corner
must not stop itself. ⌃⌘⎋ is swallowed **only while the locks are up**; the rest of the
day it passes through untouched. Not ⌥⌘⎋: that is macOS' Force Quit, and pressing it
twice opens that window over whatever he is rescuing.

**What happens** (`HandsOffOverlay.takeover`, in this order, because the wrapper reads
them in this order):
1. the marker `~/.victor-addons/hands-off.takeover` is written — JSON with `at`,
   `atLocal`, `why` (the label), `agent`, `source` (`click`/`keyboard`/`test`),
   `holderPid`, `childPid`, `message`;
2. SIGUSR1 to the `hands-off run` wrapper, SIGTERM to its child's **process group**,
   SIGKILL 3 s later to whatever ignored it (logged);
3. the locks drop at once (`/hands-off/state` → `active:false`), while border, caption
   and corners turn **red with ✋** — "✋ Victor took control — stopping the agent" — for
   2 s with a **Basso**, then fade. No green flash and no Tink: green means "the agent
   gave it back", which is not what happened. Clicks during the red beat are the same
   takeover (`HandsOffTakeoverMachine`), and `SyntheticInputWatch` may not re-raise the
   locks during it (the dying command's last events would put them straight back).
4. the app log gets `✋ Hands off: TAKEOVER by Victor (click) at HH:MM:SS — was '…'; USR1→…, TERM→group …; marker …`.

**The contract an agent sees** (`hands-off run`):
```
✋ HANDS-OFF INTERRUPTED: Victor took control at 20:48:25 — stop what you were doing
```
on stderr, and **exit code 75** (`EX_TEMPFAIL`). For **60 s** after a takeover the next
`hands-off run` refuses (exit 75, `✋ HANDS-OFF REFUSED: …`) unless given
`--after-takeover` — so an agent cannot grab the screen straight back; it has to read
the message and ask. Otherwise `run` returns the command's own exit code, as before.

**How the wrapper is found.** `hands-off run` passes `holder=$$` on `/hands-off/start`,
starts the command in **its own process group** (`set -m`), then registers it with
`/hands-off/attach?holder=$$&child=$!`. The own group is what lets a takeover kill the
command *and everything it spawned* without touching the agent's shell above the
wrapper; if the child did not get its own group, only its pid is signalled
(`HandsOffKillPlan`, tested). Both pids are stored with their **process start time**
(`ProcessStamp`): a wrapper SIGKILLed mid-run leaves its pid in a session that lives
until the ttl, and by then the number may belong to something else — a stale stamp is
never signalled. A `begin` without a holder (the guard hook, a sub-step's `start`)
keeps the current holder while it is alive. On exit the wrapper releases the locks only
if `/hands-off/state` still names it as holder. Side effects of the own group: a
sentinel (also in its own group) kills the child if the wrapper is SIGKILLed, and
INT/TERM/HUP to the wrapper are forwarded to the child's group (Ctrl-C → 130).

**`hands-off start … ; … ; hands-off end`** registers no process — nor does the guard
hook or the auto-raise. A takeover then only drops the locks and writes the marker, so
**a start/end user must poll it** between steps: `hands-off takeover-status` prints the
last takeover and exits **75 while it is younger than 60 s**, 0 otherwise.

**The corners are no longer click-through.** Each 🔒 is now its own small panel
(`HandsOffLockView`, `ignoresMouseEvents = false`); the frame and the caption stay
click-through. The top two sit **below the menu bar** (`lockOrigins`, tested): on the
notched retina the bar is 37 pt, and a lock 24 pt from the top would swallow an agent's
click on the app menu. A synthetic click on a lock is absorbed and logged, not acted on.

Tests: `HandsOffTakeoverTests` (state machine, double press, kill plan, stamps, marker,
lock placement, routes) and `./test-hands-off-takeover.sh` against the running app
(the sleep is gone, exit 75, the stderr line, the marker, locks down, the 60 s refusal,
`--after-takeover`). The preview of both states: `GET /test/hands-off/render`.

## 🔒 The four corner locks (asked for 10 Sep 2026)
The border alone says *something is happening*; the locks say **what Victor must not
do** — hands off the mouse and the keyboard until they are gone. They pulse
0.95 → 0.35 → 0.95 over 2.4 s, `easeInEaseOut`, in sync on all four corners and all
screens.

- **Never fully transparent at the bottom of the pulse**: a glance that lands in the
  dark half of the cycle still has to answer the question.
- **Slow, not blinking**: fast blinking reads as an error the eye wants to dismiss;
  a slow breath reads as "still running".
- **In sync, not offset**: four things blinking on their own read as decoration,
  four breathing together read as one state the whole screen is in.
- **Corner + drop shadow, no plate**: the corner is where no app puts the content he
  was reading, and the shadow keeps the glyph legible over both a white document and a
  dark IDE without covering anything.
- Built, faded and torn down together with the frame panel — no second lifecycle to
  leak. (Since 26 Sep 2026 each is its own small clickable panel rather than a subview
  of the frame: see the takeover section above.)
`GET /hands-off/state` is the read-only snapshot (`{"active":true,"agent":…,"label":…,"remainingSec":…,"holderPid":…,"childPid":…}`, the pids only when `hands-off run` registered them),
which is how the behaviour is asserted from a script rather than from a screenshot.

**Why the frame is on every screen, not the cursor's:** automation *moves* the pointer, and a
warning that migrates between displays while you're looking at the other one is the one you miss.

**Why the ttl is not shown as a countdown:** it is a watchdog, not an estimate. An agent that
crashes or forgets `/hands-off/end` would otherwise leave the frame up all afternoon, and a
warning that never clears stops being read — so it releases itself (default 120s, capped 900s).
A number on screen would read as "this is how long it will take", and it only means "from here
on I stop believing you".

## 🔒🔒 The floor: `SyntheticInputWatch` (11 Sep 2026)
The section below used to argue "announce, not auto-detect". Reality settled it: over
10–11 Sep both codex and Claude drove Victor's mouse while he was working and **he saw
no lock at all** — in the frame's whole life the HTTP door had been called twice, both
by the session that wrote it. So there is now a listen-only `CGEventTap` that raises the
same locks for any synthetic input, announced or not.

- **Synthetic = `.eventSourceUnixProcessID` non-zero.** Hardware events arrive with 0.
- **Allowlist** (`SyntheticInputWatch.allowlist`): Wispr Flow, Walkie Talkie, this app,
  Karabiner, Raycast, Alfred, Logi, Hammerspoon, Keyboard Maestro — software that types
  *for* Victor at the moment he asks it to. Raising locks for his own dictation would
  train him to ignore locks. **That list is the whole false-positive risk; extend it
  rather than widening the pid test.**
- **System exemption** (`systemExemptPathPrefixes`): macOS' own accessibility daemon
  `AXVisualSupportAgent` ("Accessibility Services", under `UniversalAccess.framework`)
  re-posts Victor's hardware events with its own pid — ⌥+scroll screen Zoom and
  shake-to-find-the-pointer both live there. It raised the locks 18× on the morning of
  11 Sep 2026 with nobody driving anything. Matched on the **executable path**, not the
  display name, which any app could claim; `/System` is SIP-protected, so nothing an
  agent starts can land there. Apple daemons that merely echo his input only — never
  System Events, which is exactly how an agent clicks.
- Raised within ~1 s of the first event, released 5 s after the last one, **silently**
  (no Tink: an auto-raised frame goes up and down in bursts as a script works). An
  announced session always wins and keeps its own label.
- `.listenOnly` on purpose: this must never be able to swallow or delay one of Victor's
  own keystrokes.
- Measured working the same night: a Python `CGEventPost` loop → `{"active":true,
  "agent":"Python","label":"✋ Python — îți mișcă mouse-ul/tastatura"}`.

Two layers above it do the same job earlier, because only the caller knows *what* it is
doing: `~/.claude/hooks/hands-off-guard.sh` (a PreToolUse/PostToolUse/Stop hook on Bash
that arms on `osascript … System Events`, `cliclick`, `CGEventPost`, `screencapture -i`,
`codex exec`, headed browser drivers), and the rules written into `~/.claude/CLAUDE.md`
and `~/.codex/AGENTS.md`.

**Announce, not auto-detect** — the original reasoning, kept because it still explains
why the announced path exists at all. An event tap *could* spot synthetic input (the
posting PID rides on the event), but it would then fire for **codex too**, which does not
interrupt anything (see below), and a frame that cries wolf is ignored when it matters.

**Who actually needs this:** whoever drives the GUI the crude way — `osascript … activate` plus
`CGEventPost(kCGHIDEventTap, …)`, which physically moves Victor's pointer and pulls another app
to the front. That is Claude Code's only available path, and shell/AppleScript automation in
general. **Codex does not need it**: measured 22 Aug 2026 while codex clicked `7 × 6 =` in
Calculator through `@oai/sky` (its SkyLight-based computer-use client, installed at
`~/.codex/computer-use/`), sampling the real cursor and the frontmost app every 200 ms for 200 s —
the cursor never left the spot it was parked at, Terminal stayed frontmost throughout, and the
Calculator window sat at coordinates that on screen still showed Terminal. It also draws its own
indicator ("ChatGPT is using your computer · Esc to cancel", from
`~/.codex/computer-use/config.json`), so raising ours for it would double up.

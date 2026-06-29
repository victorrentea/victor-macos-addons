# Victor macOS Addons

macOS utilities for live training workshops, running on the trainer's Mac.
Single menu bar app (💬 icon) provides all functionality.

## Architecture

- **Single Swift process**: `VictorAddons` is the main application combining menu bar UI and overlay functionality
- **LaunchAgent**: `ro.victorrentea.macos-addons.plist` — starts on login, no KeepAlive
- **Components**: All features run in same process with direct method calls (no IPC needed)

## Features

### Menu Bar (MenuBarManager)
Menu bar app (💬 icon) with the following features:

**Active features:**
- **💬 Transcribing** — Whisper live transcription runs **automatically whenever the Mac is on AC power, and pauses on battery**. There is no schedule, no workday window, and **no manual start/stop** — the only input that matters is the power source. The single, tiny `TranscriptionController` owns this: on AC it starts Whisper (if not already running) and a **60s heartbeat** restarts it if the process died (crash/OOM) while still plugged in; on battery it stops Whisper. On AC→battery it shows a "paused on battery" banner; on battery→AC a "resumed on AC" banner and Whisper restarts automatically (unlike the old model, AC restoration **does** auto-resume). It captures **two channels at once** (`whisper_runner.py`): your mic (the "selected device", auto-picked by priority Wireless Mic → Room Speakerphone → XLR → Bose → MacBook, overridable in the menu submenu) written as `Victor:`, and the **audience from the `From Zoom` loopback** written as `Audience:`. The menu item is a **read-only status row** (💬 Transcribing / Off – On Battery / Transcribing (off) while momentarily down) that opens the **mic-source picker submenu** — no Start/Stop, no ⌘⌃T hotkey, no 🔒 lock. The menu-bar icon is the live status: source emoji while running, leaf on battery, blinking red stop icon when on AC but Whisper isn't running (an error worth flagging, at any hour).
- **Emotional 🥹 Paste (⌘⌃V)** — AI-powered text cleanup via Claude Haiku; intercepts Cmd+V to capture clipboard, Cmd+Ctrl+V cleans and re-pastes
- **Toggle Dark Mode (⌘⌃⌥D)** — toggles macOS dark/light mode via AppleScript
- **Mute 🎶 (auto)** — drops `🔊OS Output` device volume to 1% during Wispr Flow dictation, restores on stop. `CoreAudioManager` runs a single self-rescheduling `DispatchSourceTimer` on a serial `pollQueue`: normal cadence is 300ms; each Mouse 5 press extends a `boostedUntil` deadline by 1s during which the next ticks are scheduled 100ms apart. The Mouse 5 click handler also probes the loopback immediately (~150ms RMS/peak window, thresholds RMS 0.0002 / peak 0.0005) and — if music is playing — does a **speculative mute** without waiting for Wispr's recording state, capturing the current volume into `originalVolume` and setting `kAudioDevicePropertyVolumeScalar` to 0.01. Polls then confirm via `kAudioProcessPropertyIsRunningInput` on `com.electron.wispr-flow.*`. Restore is debounced: on Wispr `1→0` (or on a speculative mute that Wispr never confirms) we wait 1000ms of stable `recording=false` before restoring `originalVolume`; any `recording=true` read inside that window cancels the pending restore (`firstNotRecordingAt = nil`). The loopback check is **not** consulted on restore (a muted device reads silent and would falsely cancel restore). All state (`volumePushedDown`, `originalVolume`, `firstNotRecordingAt`, `boostedUntil`, `nextDeadline`) lives entirely on `pollQueue`, so reads/writes are sequential. Mouse 5 is observed via the event tap and passed through (Wispr still sees it); behavior on other triggers (right Opt-Cmd, hotkey, UI button, VAD, ESC) falls back to the boosted-or-normal poll alone. Caveats: an app crash mid-mute leaves the volume at 1% until next Wispr cycle; a manual volume-slider tweak during dictation is overwritten on restore. **Output-route guard:** the whole feature only works while the macOS default output is `🔊OS Output` (the loopback the app taps *and* whose volume it drops); if it drifts elsewhere (e.g. macOS resets to the built-in speakers after sleep), music bypasses the loopback and never ducks. On each Wispr-start edge `CoreAudioManager` reads the default-output name and, via the pure `OutputDriftPolicy`, posts a **transient native notification** ("🔇 Mute inactiv la dictare — Output = «…», nu 🔊OS Output") when it has drifted. Alerts **once per drift episode** and re-arms when a later Wispr-start sees `🔊OS Output` again (no spam). Not a permissions issue — Microphone TCC stays granted and the loopback tap still succeeds; it reads all-zero silence purely because nothing is routed through the device.
- **Re-paste (Wheel x 2)** — double-click mouse wheel re-pastes last intercepted text
- **📋 IntelliJ Git → Clipboard** — copies git remote URL + branch from frontmost IntelliJ project
- **Screenshot → Clipboard (⌃P)** / **Screenshot → Session Folder (⌃⇧P)** — `📸` captures the display under the cursor; Clipboard copies the JPG, Session Folder saves a timestamped JPG into the active session folder (`ScreenshotManager.sessionFolder`, set on `session_started`) or the default `addons-output` when no session is active
- **Display join link** — shows participant join URL banner at top of screen (enabled when session active); banner auto-hides after 20s with fade-out animation
- **☕️ Break (countdown watch)** — submenu of fixed durations (5/7/10/12/15/45 min, 1 hour) opens a draggable, resizable digital countdown overlay (`BreakTimerOverlay`): a big **red seven-segment** `MM:SS`. The segment shapes are **reverse-engineered polygons** traced from a reference LED watch (`Self.segPolys`, canonical cell 80×137; irregular hexagons — outer edge full width, inner edge beveled 45°), laid out in two pairs with the **digit↔colon gap halved**. **Unlit segments are not drawn** (absent, not dimmed); each lit segment gets a **2px black outline** so it reads on any backdrop. Finish time shown on a **single row** (one flag + one `HH:mm`, no AM/PM, in a **slightly larger** font), in the **picked country's** timezone — **default 🇷🇴 Romania / Europe/Bucharest**. The selection is **day-scoped**: it's persisted with the calendar day (`BreakTimer.country.tz` + `BreakTimer.country.day`) and `BreakCountry.loadSelected()` returns the pick only if it was made **today**, so **every new morning it resets to Romania**. **Clicking the flag/time row** opens a **searchable country dropdown** (`CountryPicker`): a borderless key panel whose search field filters a broad global list (`BreakCountry.all`) by name *contains* (typing "arg" → just Argentina), ↑/↓ move, ⏎/click pick, Esc/click-away close; each row shows flag + name + that country's current local time. With **no query, 🇷🇴 Romania is pinned at the top** (above a thin `NSBox` **divider**), then the rest alphabetically — a one-click "back home"; while filtering, only the contains-matches show (no pin/divider). The picker is a `Row` enum (`.country`/`.separator`); separators are never selectable and are skipped by all keyboard/selection helpers. The app is an accessory, so the picker calls `NSApp.activate` to receive keystrokes. Small controls left→right (+1/+3/+5, ⏸ pause/resume, ✕ close). Opens top-right at **20% of the main-screen width** (aspect 1.85), draggable (open/closed-hand cursor) and corner-resizable (OS diagonal resize cursors) with locked aspect ratio. The **backdrop is a separate opaque-black layer** (`bgView`): **fully transparent while the user is active** (only the outlined digits show), **fully opaque after 5 s idle**, with one GPU alpha fade per transition (no flicker). Re-clicking a duration resets the time in place. On expiry the gong plays **once** while the digits **blink for the gong's duration**, then the window **closes instantly**. Pure formatting/finish-time math lives in a unit-tested `BreakTimerModel`; an `epoch` counter cancels in-flight expiry on +Nm / re-click. The SVG generator + diff harness used to reverse-engineer the segment polygons lives in the session scratchpad (`build_svg.py`).
- **☠️ Kill port** — submenu with recent ports + custom port dialog
- **📸 Group Photo (daily 13:00)** — `GroupPhotoScheduler` (a 60s `DispatchSourceTimer`, pure unit-tested `isTriggerMinute(at:)` for hour 13, per-day dedupe via `lastFiredYMD`) fires once a day the moment local time hits **13:00**. If the **training-assistant daemon is connected** at that moment (`daemonConnected` — the local WS server has ≥1 client, tracked in `onClientCountChanged`), the Mac posts a **persistent** native notification (title `📸 Group Photo`, subtitle `Let's make some memories? :D`, `interruptionLevel = .timeSensitive`, sound): unlike the app's other notifications it is **never auto-removed**, so it stays in Notification Center until dismissed. To make it remain on screen until the user clicks ✕ (rather than slide away), the app's notification style must be set to **Alerts** (System Settings → Notifications → Victor Addons). A daemon not connected at 13:00 → skipped for the day (no retroactive fire). Stable per-day id `group-photo:YYYY-MM-DD` prevents duplicate stacking. Test hook: `GET /test/group-photo` posts it immediately, bypassing the time + connection gates.

**Tech**: Swift, AppKit, Anthropic API (Haiku)
**Secrets**: `WISPR_CLEANUP_ANTHROPIC_API_KEY` in `~/.training-assistants-secrets.env`

**Operational note (2026-06):** Transcription control was simplified to a single power-driven rule (on AC → run, on battery → pause) in `TranscriptionController`. The former `TranscriptionStateMachine` (off/on/onWorkday/battery + persisted UserDefaults state), `TranscriptionScheduler` (Mon–Fri 09:00–18:00 window + hard lock), the 18:00 `TranscriptionCountdownOverlay`, the ⌘⌃T toggle, and the menu Start/Stop were all removed. There is no persisted on/off state anymore; the launch UI starts not-running and the controller reflects the real process/power state.

### whisper-transcribe
Live dual-channel Whisper transcription engine (extracted from training-assistant daemon):
- **WhisperTranscriptionRunner** — captures audio from 2 sources, transcribes via mlx-whisper on Apple Silicon GPU
- Writes `[HH:MM] Speaker: text` lines to per-day files in `TRANSCRIPTION_FOLDER`
- Default devices: XLR mic (device 5) + Zoom loopback (device 17)
- Auto-detects Romanian/English, filters hallucinations, RMS-based silence skipping
- Queue-aware batching merges adjacent same-speaker chunks before inference; default wait budget is tuned for non-live subtitle use
- Adaptive quality can switch to a faster Whisper model when transcription backlog grows, then return to balanced quality when queue drains
- Startup guard: `WHISPER_PARENT_PID` is mandatory; runner exits early if missing/invalid (prevents unmanaged launches)
- Parent sentinel thread exits whisper when Swift parent dies; combined with Swift-side pre-start cleanup to reduce stale/orphan runners during automated app restarts

**Tech**: Python 3.12, mlx-whisper, sounddevice, numpy
**Config env vars**: `WHISPER_ME_DEVICE`, `WHISPER_AUDIENCE_DEVICE`, `WHISPER_MODEL`, `WHISPER_MODEL_FAST`, `WHISPER_CHUNK_SECONDS`, `WHISPER_SILENCE_THRESHOLD`, `WHISPER_BATCH_MAX_WAIT_SECONDS`, `WHISPER_BATCH_MAX_ITEMS`, `WHISPER_BATCH_MAX_AUDIO_SECONDS`, `WHISPER_ADAPTIVE_QUALITY`, `WHISPER_ADAPTIVE_BACKLOG_HIGH`, `WHISPER_ADAPTIVE_BACKLOG_LOW`, `TRANSCRIPTION_FOLDER`

### powerpoint-monitor
Polls PowerPoint via osascript every 3s, writes `activity-slides-YYYY-MM-DD.md`:
- Activity lines with per-slide timings: `10:51:00 AI Coding.pptx - s12:10s, s13:20s`
- Pointer last line: `AI Coding.pptx:15` (read by training-assistant daemon every 0.5s)
- New line only on deck change, timings accumulate on same line
- Always runs (no toggle)

**Tech**: Python 3.12, osascript
**Output**: `TRANSCRIPTION_FOLDER/activity-slides-YYYY-MM-DD.md`

### intellij-monitor
Polls IntelliJ via osascript every 10s (only when frontmost), sends `git_file_opened` WS message to daemon when the open file changes (deduplicates against last sent value):
- Skips duplicate consecutive lines
- Training-assistant daemon reads this to provide git repos list to session participants
- Always runs (no toggle)

**Tech**: Python 3.12, osascript, git CLI
**Output**: WS message `{"type": "git_file_opened", "url": "...", "branch": "...", "file": "..."}`

### Overlay Components (AppDelegate)
Fullscreen overlay and WebSocket integration for live sessions:
- **EmojiAnimator**: receives emoji reactions via WebSocket, animates sprites flying up the screen
- **ButtonBar**: floating button bar for host controls (sound effects, overlay toggle)
- **SoundManager**: plays sound effects (applause, drum roll, etc.) triggered by host
- **OverlayPanel**: transparent always-on-top NSPanel covering full screen
- **JoinLinkBanner**: displays participant join URL at top of screen; auto-hides after 20s with 3s fade-out

Connects to the training-assistant backend via WebSocket at `/ws/__overlay__`.
Receives session lifecycle events (`session_started`, `session_ended`) to enable/disable join link menu item.

**Sound → overlay-effect mapping (Mac-owned).** The tablet no longer decides
which sound triggers which visual effect. On every sound press it fires
`GET /sound/pressed/<file>` and on every stop `GET /sound/stopped/<file>` (bare
filenames), and the Mac looks the effect up in `SoundEffectMap.swift` — the
single source of truth (`onPress: [file → effect]`, `onStop: [file →
effect/stop]`) — then dispatches through the existing `onEffect` switch (reusing
all BT visual-compensation/sync logic). **Changing a mapping or adding a new
effect needs only a Mac rebuild — no tablet redeploy.** The siren
(`02_siren.mp3`) is the one exception: it drives the alarm overlay
(`/alarm/start`,`/alarm/stop`) and stays special-cased on the tablet. Effects
are CALayers on the overlay's `hostLayer`, animated via `CAKeyframeAnimation`
on `contents` from bundled gif frames (`Bundle.module`).
- **🩸 Blood drip** (sfx #40 `40_joker.mp3` → `blood-drip`): `blood-drip.gif`
  (white bg made transparent via ImageMagick `-coalesce -fuzz 20% -transparent`,
  full-canvas frames) shown as a blood band pinned to the **top of the screen**
  at full width (aspect-preserved, transparent backdrop over the live screen),
  drips/droplets falling; the ~1.6s loop plays **~1.5× slower**, repeating for
  the joker track (~9.0s) with a 0.25s fade-in and 0.6s fade-out tail.
- **🛰️ Sonar** (sfx #23 `23_radar.mp3` → `sonar`, `showSonar`): a full-screen
  black wash fades in (0→45% over 1s; darker **70% disc** inside the radar
  circle), then a phosphor-green radar **drawn entirely as CALayers** (no gif):
  muted-grey concentric rings + radial spokes; a **conic-gradient sweep arc**
  (bright +x leading edge, fading 100%→0% behind it, masked to the circle) that
  rotates **clockwise**. The sweep carries **ultrasound-style "reception noise"**
  (flickering green/black speckle frames generated in `makeSonarNoiseFrames`,
  masked to the wedge), and a fainter copy of the same noise covers the circle
  interior (background static; outside the circle is just the dark wash). A
  **💩 blip** (3× emoji, green glow) sits at the front's detection angle, hidden
  until found. The rotation is **keyframed** (not constant): ~0.5s beep-free
  lead-in, then the front sweeps over the 💩 on **three radar beeps** in the clip
  (clip times 0.104/2.211/3.879s; one full turn between detections). The Mac
  **owns the audio** here — `showSonar(playSound:true)` plays `23_radar.mp3`
  delayed (`soundStartRel` + 0.1s) so the beeps land on the three detections; the
  effect ends (fading out **while still rotating**) the moment the 3rd detection's
  1s fade finishes, so the front never sweeps the 💩 a 4th time unshown. Pure
  formatting/timing is derived up-front from `beepClip`/`detT`/`animEnd`.
  **Trigger:** the effect is driven from the **routed `/sound/play/23_radar.mp3`**
  path (`onSoundPlay` special-cases it → `showSonar(playSound:true)` instead of
  `playTabletSound`), so when the tablet routes its soundboard audio to the Mac,
  the radar press plays the synced SFX **and** the visual with no double audio and
  **no tablet change**. `23_radar.mp3` is therefore intentionally **absent from
  `SoundEffectMap`** (the press path would otherwise double-trigger it). `/test/sonar`
  and `/effect/sonar` call `showSonar` directly for headless testing.
- **💸 Money** (tile #53, repurposed from rain): the Android tile #53 now shows
  a plain **💸 emoji on white** but keeps its asset id `53_rain.mp3` (so the
  routing protocol/manifest are unchanged). `onSoundPlay` **special-cases
  `53_rain.mp3`** (like the radar): it fires `showMoneyRise()` and plays the
  **#57 checkmark "ching"** (`57_checkmark.mp3`) instead of the original rain,
  returning the checkmark's duration. `showMoneyRise` swarms ~16 money emojis
  (`💸💵💰🤑`) **up from the bottom edge to off the top**, swaying + tumbling
  while fading out — **one round per press ("ching")**. It is a fire-and-forget,
  **non-tracked** burst (each emoji layer self-removes), so pressing the tile
  repeatedly **stacks overlapping rounds**. `53_rain.mp3` is intentionally
  **absent from `SoundEffectMap`** so a press = a single ching + single round (no
  double-trigger). `/test/money` and `/effect/money` call `showMoneyRise` directly.
- **🕳️ Iris close** (tile #31, repurposed from Tarzan): a cinematic "iris out"
  blackout — **NO sound**. The Android tile #31 is redrawn as a **black circle
  with a white centre and four inward-pointing arrows** (vector `sfx_31_iris.xml`);
  its mp3 is a **silent clip** but keeps the asset id `31_tarzan.mp3` (protocol/
  manifest stable). It **stays in `SoundEffectMap`** (`31_tarzan.mp3` → `iris`):
  the **press path** drives the visual, so it isn't double-triggered. To make it
  truly soundless, `onSoundPlay` is special-cased to **play nothing** for
  `31_tarzan.mp3` (returns a ~0ms duration, not even the silent placeholder) —
  unlike radar/money, that branch does *not* trigger the effect (the press path
  already does). `showIrisClose` overlays a **radial
  `CAGradientLayer`** (square, side = screen diagonal, so the gradient is a true
  circle and location 1.0 lands on the corners) — transparent centre, opaque
  black edge, with a soft transition band. Animating the gradient `locations`
  shrinks the clear hole from the screen-circumscribing circle (nothing hidden)
  to nothing over **5s** (`.easeIn`) — black creeps in **from the corners** and
  swallows the screen. It then **dwells ~1s on full black and auto-fades back out
  over ~1s** to reveal the screen (no second press needed). **Pressing the tile
  again** before that auto-reveal cancels early with a quick (~0.35s) fade
  (`cancelIris`). The effect is deliberately **kept out of `activeEffects`** so
  `stopAllActiveEffects()` (which the tablet fires before *every* press) leaves it
  alone — that's what lets the second press reach `showIrisClose` and toggle
  instead of being wiped + restarted. `/test/iris` and `/effect/iris` call
  `showIrisClose` directly.

### Tablet sound routing (tablet → Mac playback)
The Android LaunchBreak tablet pings `GET /ping` every 5s (response carries `soundsHash`).
When the tablet has no BT speaker / wired headphones and the Mac answers, the tablet routes
soundboard playback here instead of playing locally:
- `GET /sound/play/<file>?vol=<0-100>` — one sound at a time, a new play preempts the
  current one; responds `{ok, durationMs}` (the tablet schedules its effect-stop chain from
  it); 404 for unknown files → tablet falls back to local playback
- `GET /sound/stop`; `/effect/stop-all` also stops the tablet-routed sound
- `GET /sound/volume/<pct>` — live player-level volume (never the macOS system volume)
  + plays `click.wav` (the tablet's generated 1800Hz tap) at the new level as feedback
- Watchdog: the routed sound is stopped if pings cease >12s (tablet crash / network drop)

**Anti-drift**: `Sources/VictorAddons/Resources/sounds` is a single folder symlink to
`victor-android/app/src/main/assets` (the canonical sound library; dereferenced into the
bundle by `build-app.sh`), so the protocol identifies sounds by bare filename.
`SoundsManifest` hashes every bundled mp3 (SHA-256, canonical "name:hash\n" lines);
`GET /sounds/manifest` returns the per-file map. A hash mismatch in `/ping` means a stale
Mac bundle — the tablet plays the differing files locally and shows an amber dot until
`build-app.sh` is re-run.

**Tech**: Swift, AppKit, AVFoundation, Swift Package Manager
**Build**: `swift build && swift test`

## Testing & Diagnostics

Headless local test hooks are exposed through `TabletHttpServer` on `127.0.0.1:55123` so tests do not need UI focus or menu clicking:

- `GET /test/state` — JSON snapshot of transcription state (`running`, `on_ac`, `paused_battery`, UI/menu/icon state)
- `GET /test/transcription/start` — force-(re)start Whisper for E2E checks (no-op if already running). There is no stop/toggle hook — transcription is driven solely by AC/battery
- `GET /test/audio/playing` — taps `🔊OS Output` loopback for ~150ms, returns `{playing, rms, peak, ...}`
- `GET /test/wispr/recording` — checks `kAudioProcessPropertyIsRunningInput` on `com.electron.wispr-flow.*`, returns `{recording}`
- `GET /test/break/<minutes>` — start/reset the ☕️ Break countdown overlay for N minutes
- `GET /test/break/close` — close the Break overlay
- `GET /test/break/picker?q=<query>` — open the country dropdown on the Break overlay, optionally pre-filtered (headless; verifies the contains-filter without stealing UI focus)
- `GET /test/tile` — tile Terminal windows (same action as ⌘⌃A); headless way to exercise `TerminalTiler`
- `GET /test/whip` — fire the 🔥 WIP Agent whip overlay (same action as ⌃W); NB leaves the overlay up until Esc
- `GET /test/group-photo` — post the 📸 Group Photo notification now, bypassing the 13:00 + daemon-connected gates
- `GET /test/wispr-output-drift` — post the 🔇 "Mute inactiv la dictare" output-route warning now, using the real current default-output name (bypasses the Wispr-start + drift-latch gates)
- `GET /test/sonar` — fire the 🛰️ Sonar overlay now (visual + synced `23_radar.mp3`); same as `/effect/sonar`. The tablet drives it by routing `GET /sound/play/23_radar.mp3` to the Mac (handled in `onSoundPlay`)
- `GET /test/money` — fire one round of the 💸 Money rising-dollars overlay now; same as `/effect/money`. The tablet drives it by routing `GET /sound/play/53_rain.mp3` to the Mac (handled in `onSoundPlay`), which also plays the #57 checkmark "ching"
- `GET /test/iris` — fire the 🕳️ Iris-close blackout now (5s close → 1s hold → auto fade-out reveal); same as `/effect/iris`. The tablet drives it via `GET /sound/pressed/31_tarzan.mp3` (mapped to `iris` in `SoundEffectMap`); a second press before the auto-reveal cancels it early. Silent — no paired sound
- `GET /ping`, `GET /sounds/manifest`, `GET /sound/play/<file>?vol=N`, `GET /sound/volume/<pct>`, `GET /sound/stop` — tablet sound routing (see Overlay Components)
- `GET /sound/pressed/<file>`, `GET /sound/stopped/<file>` — tablet reports a sound press/stop; the Mac maps it to an overlay effect via `SoundEffectMap` (e.g. `/sound/pressed/40_joker.mp3` → blood drip). `GET /effect/blood-drip` triggers the blood overlay directly.

For local E2E checks without stealing focus:

- `./test-transcription-control.sh` — snapshots `/test/state`, force-(re)starts Whisper via `/test/transcription/start`, and re-snapshots to confirm it came up.
- Uses only local HTTP endpoints; no UI focus needed.

## Deployment
- **App bundle**: `./build-app.sh` creates `/Applications/Victor Addons.app` (Spotlight-searchable)
- **LaunchAgent**: `./install-startup.sh` symlinks plist, loads LaunchAgent for login auto-start
- Re-run `build-app.sh` after changes to `start.sh`, icons, or app identity
- `start.sh` exports `VICTOR_ADDONS_ROOT` so the app can resolve `whisper-transcribe/whisper_runner.py` reliably when launched from `/Applications` bundle.

**Operational note (2026-04):** To avoid repeated Accessibility re-prompts across deploys, app builds should be signed with a stable identity. `build-app.sh` auto-detects and uses `Victor Addons Local Code Signing` from `login.keychain-db` when available (or `CODESIGN_IDENTITY` if set), otherwise falls back to ad-hoc signing.

**Operational note (2026-04):** On app launch, Accessibility is checked without forcing a system prompt (`AXIsProcessTrusted()`). Missing permission is reported in-app; prompting/opening System Settings should be user-initiated.

**Operational note (2026-05):** Single-instance lock + uniform launch behavior:
- `/tmp/VictorAddons.pid` lock with `proc-name` verification before SIGTERM (avoids killing unrelated PIDs after a stale PID file from a hard crash).
- SIGTERM is delivered via `DispatchSource.makeSignalSource` (not raw `signal()`), so the handler can call `AppDelegate.tearDownForReplacement()` which `SIGKILL`s the Whisper subprocess synchronously. Previous design left whisper orphan until its parent-watch sentinel noticed (up to 2s).
- New-instance grace timeout extended from 200ms to ~1s before falling back to SIGKILL on the previous instance.
- On launch, if stderr is not already a regular file (i.e. not piped by `start.sh`), `main.swift` redirects stdout/stderr to `/tmp/victor-macos-addons.log` itself — so launching via `open` (Spotlight, Login Items) logs to the same file as a LaunchAgent boot.
- Result: `pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"` and `launchctl kickstart -k gui/$UID/ro.victorrentea.macos-addons` are now behavioral equivalents.

**Operational note (2026-06):** `TerminalTiler` reads/writes Terminal window geometry through the in-process **Accessibility API** (`AXUIElement`), relying only on this app's own Accessibility grant (the same one behind the global event tap). It previously shelled out to `osascript` + "System Events" UI scripting, which needs a *separate* Automation (Apple Events) grant; after a re-sign that grant's stored code requirement no longer matched the running binary, so the Apple Event blocked on a consent prompt a headless `osascript` subprocess can't surface and tiling silently hit the 5s timeout (symptom: `AppleScript failed: Timed out after 5.0s` in the log; ⌘⌃A and the menu item both no-op). The AX path needs no Automation permission and never spawns a subprocess.

**Shortcuts/menu (2026-06):** The 🔥 menu item is **WIP Agent** (formerly "Whip Claude"), bound to **⌃W** globally (event tap, suppressed) and shown as ⌃W in the menu. NB ⌃W globally shadows the usual "delete word backwards" in terminals/editors. The bottom-left notification pill (`BottomLeftBanner`) renders the hover-hint chip ("Hover to undo/snooze/continue/Send") **pinned to the pill's bottom-left corner** (fixed — no longer riding/moving), with the **orange countdown bar filling the region to the right of the chip** (from the chip's right edge to the pill's right edge) left→right. Countdown banners are floored at **30% of the screen width** (`countdownMinWidthFraction`) so the fixed chip and the bar to its right always fit; plain (non-countdown) banners still hug their text. Reusable across every banner caller.

**Notes banner — outcome-flavored exits (2026-06):** Every *interactive* bottom-left pill ends one of two ways, and the exit animation tells the user **which**, so the gesture and the feedback match:
- **`dismissRisingFade()` — accept / commit.** The pill (and its hint) float straight up ~140px while fading over **~1s** (`.easeIn`), as if the text lifts off into the notes. Used when you **hover-confirm "Send prompt to notes?"** and when a paste's undo window **lapses un-hovered** (it stuck).
- **`dismissShatter()` — cancel a done action.** The pill vanishes instantly and a **short-lived fullscreen panel** sprays the pill's footprint into **triangular glass shards** fanned from a random impact point (`perimeterPoints` fan + per-shard bbox layer), each spinning and falling under a downward-gravity bias as it fades (~0.6–0.85s), plus a quick white impact pop. Fullscreen (not pill-sized) so shards fly past the 80px pill before fading; the panel auto-tears-down after the longest shard. Used when you **hover-to-undo a paste**.
- Wiring lives in `SessionNotesAppender`: a banner-free **`writeNotes`** core feeds both entry points (`pasteAndOfferUndo` for keypress pastes, the `offerPrompt` hover handler for prompt-capture); **`performUndo` returns `Bool`** so the caller shatters *only* when the undo actually landed. The old `"↩️ Undone"` / `"pasted in notes"` text flashes are gone — the animation **is** the feedback. The hover-approve window itself is `hoverActionDuration` (**7.5s**). Only the notes flows call these two methods; status/silent-mic banners still use plain `dismiss()`.

## AI Instructions
- After any significant design, architecture, or deployment change, proactively offer to save the decision to memory for future conversations.
- After any code change in this project, always: push to master (`git push`), run `./build-app.sh`, then restart the app (`pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"`).

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes

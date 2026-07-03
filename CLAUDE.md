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
- **☕️ Break (countdown watch)** — submenu of fixed durations (5/7/10/12/15/45 min, 1 hour) opens a draggable, resizable digital countdown overlay (`BreakTimerOverlay`): a big **red seven-segment** `MM:SS`. The segment shapes are **reverse-engineered polygons** traced from a reference LED watch (`Self.segPolys`, canonical cell 80×137; irregular hexagons — outer edge full width, inner edge beveled 45°), laid out in two pairs with the **digit↔colon gap halved**. **Unlit segments are not drawn** (absent, not dimmed); each lit segment gets a **2px black outline** so it reads on any backdrop. Finish time shown on a **single row** (one flag + one `HH:mm`, no AM/PM, in a **slightly larger** font), in the **picked country's** timezone. The selection is **day-scoped and auto-detected**: on the **first Break start of the day** `BreakCountry.autoSelectForToday()` auto-picks "where I am now" — the country matching the Mac's **live system timezone** (`TimeZone.current`, which macOS auto-updates by location as Victor travels; pure map `country(forTimeZoneIdentifier:)`, falling back to 🇷🇴 Romania when the zone isn't listed) — and **persists it for the rest of the day** (`BreakTimer.country.tz` + `BreakTimer.country.day`), so later starts today reuse the same value even if the zone shifts, and every new morning it re-detects. A **manual dropdown pick** made during the day is stored the same way and wins over the auto-pick. (`loadSelected()` is now the read-only, no-side-effect view of today's stored pick, defaulting to Romania.) **Clicking the flag/time row** opens a **searchable country dropdown** (`CountryPicker`): a borderless key panel whose search field filters a broad global list (`BreakCountry.all`) by name *contains* (typing "arg" → just Argentina), ↑/↓ move, ⏎/click pick, Esc/click-away close; each row shows flag + name + that country's current local time. With **no query, 🇷🇴 Romania is pinned at the top** (above a thin `NSBox` **divider**), then the rest alphabetically — a one-click "back home"; while filtering, only the contains-matches show (no pin/divider). The picker is a `Row` enum (`.country`/`.separator`); separators are never selectable and are skipped by all keyboard/selection helpers. The app is an accessory, so the picker calls `NSApp.activate` to receive keystrokes. Small controls left→right (+1/+3/+5, ⏸ pause/resume, ✕ close). Opens top-right at **20% of the main-screen width** (aspect 1.85), draggable (open/closed-hand cursor) and corner-resizable (OS diagonal resize cursors) with locked aspect ratio. The **backdrop is a separate opaque-black layer** (`bgView`): **opaque black by default at all times**, fading **fully transparent only while the cursor hovers over the timer panel** (`panel.frame.contains(mouseLocation)`, sampled every 0.15 s) so you can peek at what's underneath, then back to black when the cursor leaves — one GPU alpha fade per transition (no flicker). (This replaced the older idle-driven model that was transparent while active and went black after idle.) Re-clicking a duration resets the time in place. On expiry the gong plays **once** while the digits **blink for the gong's duration**, then the window **closes instantly**. Pure formatting/finish-time math lives in a unit-tested `BreakTimerModel`; an `epoch` counter cancels in-flight expiry on +Nm / re-click. The SVG generator + diff harness used to reverse-engineer the segment polygons lives in the session scratchpad (`build_svg.py`).
- **☠️ Kill port** — submenu with recent ports + custom port dialog
- **☕️→📝 Break-summary delta (`BreakSummaryLauncher` + `summarize-on-break.sh`)** — a break >= 5 min ("a section just ended, slack now") opens a Terminal running an unattended `claude` that advances the training-summary **delta**: it reads only the transcript past the `Discussion.md` watermark and appends the new section(s) to **Discussion.md only** (never `ai-summary.md`), so the wrap-up run is a tiny delta + cheap distill instead of one whole-day read. Runs on Victor's Claude **subscription** (`env -u ANTHROPIC_API_KEY`, not the depleted API key) with an empty `--strict-mcp-config` (no connectors = lean startup). A 90s launcher cooldown + a `/tmp/training-summarizer-break.lock` single-instance guard prevent double-runs (a break re-click just resets the timer). **Window lifetime is sentinel-driven, NOT Terminal's `busy` flag:** for a `do script` tab `busy` reads false during startup, so the old `repeat while busy … close` loop closed the window ~1s in and **SIGHUP-killed claude before it wrote anything** (the 2026-06-30 "terminal immediately exited" bug). Now the script writes a unique sentinel file (`ok`/`fail`) when it truly finishes and the launcher waits on that — **auto-closing only on `ok`**, leaving failures (and timeouts) on screen, with the script also blocking (`read`) on failure so the window survives regardless of Terminal prefs. All output is tee'd to a per-day `addons-output/break-summary-YYYY-MM-DD.log` (a closed window is never a lost post-mortem). The banner falls back to the **newest-mtime session folder** when the literal date isn't a substring of the folder name (multi-day sessions are named `2026-06-29..30 Topic`, so on day 2 `grep 2026-06-30` misses; claude's own Step 0 resolves it regardless). Trigger headlessly with `GET /test/break-summary`.
- **📸 Group Photo (break-triggered)** — instead of a fixed clock time, the Group Photo reminder fires at the **start of a qualifying break**. When a break starts (`MenuBarManager.onBreak` → `AppDelegate`), the pure, unit-tested `GroupPhotoBreakPolicy.shouldPrompt(breakMinutes:at:)` decides: a **lunch** break (≥ 60 min, any time of day) **or** an **afternoon** break (≥ 10 min starting at **13:00** local or later) qualifies; morning coffee breaks are ignored. The prompt only fires when the **training-assistant daemon is connected** (`daemonConnected` — the local WS server has ≥1 client, tracked in `onClientCountChanged`), i.e. there's an audience to photograph. `promptGroupPhoto` shows it through the app's **standard bottom-left `StatusBanner`** — the same overlay as "started" / "paused on battery" / etc. — with text `📸 Group Photo — Let's make some memories? :D`, the start chime, and a 12 s visible duration. It's **presence-gated** (`showOnPresence`), so if Victor stepped away it fades in the moment he's back at the Mac. Being the app's own always-on-top panel it shows **even while PowerPoint is presenting fullscreen / mirroring to a projector** — which is exactly when macOS would suppress a native notification silently into Notification Center (the reason we don't use one here; the "Allow Time Sensitive Notifications" toggle never appears for this locally-signed, un-entitled app anyway). Test hook: `GET /test/group-photo` shows the banner immediately, bypassing the break + connection gates.
- **🎬 Tablet video playback (offline snippets)** — the tablet's **page 2 ("Video Snippets")** plays **pre-downloaded** YouTube clips **fullscreen in IINA on the Retina**, seeking to a per-video start second, instead of opening the live URL in Chrome (the old `/open` path). Videos live in the **gitignored `videos/`** folder (`<youtubeId>.mp4` + a `videos.json` manifest of `{id,title,startSeconds,file,url}`), downloaded/registered by the **`add-training-video` skill** (`.claude/skills/add-training-video/` — `yt-dlp` forced to **H.264/AAC MP4** so AVFoundation can play it; `brew install yt-dlp`, ffmpeg already present). `VideoLibrary` reads the manifest and serves `GET /videos`; the tablet fetches that and builds tiles **dynamically**, so **adding a video needs no APK rebuild** (the tile thumbnail still comes from `img.youtube.com/vi/<id>`, memory-cached tablet-side, and the page only re-renders when the list changes — no ▶-placeholder flashing on reopen). Tapping a tile hits `GET /video/play/<id>` (optional `?t=` start override → the tablet sends one request via `MacLink.getSyncFast`); `VideoPlayer` **orchestrates the external IINA player** (not an in-app AVPlayer): it launches `iina-cli --no-stdin --mpv-start=<sec> --mpv-fullscreen=yes`, a new play **replaces** the previous player (`pkill -x IINA` before relaunch, so windows never stack), and the player is **auto-killed ~60 s after start** so a snippet never lingers on the projector. `GET /video/stop` closes it. Headless hooks: `GET /test/video/<id>` (play at the manifest second) and `GET /test/video/stop`.
- **🖥️ Auto display arrangement (projector workflow, `DisplayArrangementManager`)** — reshapes the displays automatically when a projector / room TV is plugged in or out, so Victor never re-does the venue setup by hand. Detection is `CGDisplayRegisterReconfigurationCallback` (fires on every hot-plug / mode / mirror change), **debounced ~1.2 s** so the hardware settles before we read + apply; the fix is **attempted only once per change** — we act only when the *scene* — `(hasProjector, hasASUS)` — actually changes, so if the set of monitors doesn't change there are **no further layout/mirror changes** (a manual re-layout Victor makes afterwards is left untouched). No self-loop: our own `CGCompleteDisplayConfiguration` callbacks compute the same scene and no-op, plus an `isApplying` guard + 1 s cooldown. Roles are resolved **live, not from a frozen profile** (works with any venue's projector, different EDID each time) and consult the persisted **`KnownDisplays`** ("mine") set: built-in = **Retina** (`CGDisplayIsBuiltin`); `NSScreen.localizedName` contains "ASUS" = the **ASUS MB166C** travel monitor; any **other known** external (home monitors / TV, added via "Trust current external displays") = a plain extended desktop that is **never mirrored and never disturbed**; anything else external = an **unknown = venue projector / room TV**. Two apply scenarios when an unknown external connects: **(1) projector + ASUS** → the projector *mirrors* the Retina at **1920×1080** ("what's projected to the room"), the **ASUS becomes primary/main** (origin `(0,0)`) on the right, Retina extended to **its left** (origin `-1920,0`); **(2) projector, no ASUS** → the projector simply *mirrors* the Retina (also dropped to 1920×1080), Retina stays main. **Unknown external unplugged** → revert to the standard rig: Retina **main** at its native mode, ASUS (if present) extended to the Retina's **right**. **At-home guard:** if a *known* non-ASUS external (home monitor / TV) is connected we assume Victor's own multi-display layout is set the way he wants and **auto-arrange keeps hands off entirely** (the manual force still overrides) — this also stops a home TV from ever being mirrored at 1080p. Applying is one atomic Quartz transaction (`CGBegin…/CGConfigureDisplayWithDisplayMode` + `CGConfigureDisplayMirrorOfDisplay` + `CGConfigureDisplayOrigin` + `CGCompleteDisplayConfiguration(.permanently)`) — no external tools, **no Screen-Recording permission** needed. The Retina's user-normal (native HiDPI) mode is captured the first time we observe a projector-free state and restored verbatim on revert. 1080p is found via `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes`, preferring a true non-HiDPI 1920×1080 @ 60 Hz. It **does not auto-apply on launch** (only on subsequent changes) so starting the app never reshuffles a happy layout; the menu item **🖥️ Fix display layout** and `GET /test/projector` force it on demand. On each applied change it flashes an **immediate** (not presence-gated) bottom-left `StatusBanner.showNow` for 8 s describing the new layout (e.g. "🖥️ Projector: mirror + ASUS primary"). Test hook: `GET /test/projector` force-applies now and returns a JSON snapshot (detected displays, resolved scene, 1080p availability).
- **🔴 Presentation detection + aggressive silent-transcription warning (`PresentationDetector` + `SilentTranscriptionWarning`)** — a louder "transcription isn't capturing anything" warning that fires **only while Victor is presenting**. "Presenting" is the OR of two signals: **(a) an unknown external display** connected (a venue projector / room TV — i.e. sharing the desktop to a room; `DisplayArrangementManager.onUnknownExternalChanged`, gated by `KnownDisplays` so the ASUS / trusted home monitors don't count) and **(b) a live meeting** — a meeting app (Zoom/Teams/Webex) **or a browser** (for web Meet/Teams/Webex) actively **capturing the microphone** (`kAudioProcessPropertyIsRunningInput`, polled every 3 s in `MeetingDetector`). An earlier version watched `🎙️TO Zoom`'s `IsRunningSomewhere`, but that virtual device is held open by its driver and reads "running" with **no call** — a permanent false positive; attributing live mic capture to a specific app is the reliable signal, and Whisper's own capture (a Python process) never matches the meeting/browser bundle prefixes. When presenting **and** the transcription file goes stale (`TranscriptionWatcher`, ~3 min no new lines), a **big red persistent banner** showing just **`😶😶😶`** (emoji-only on purpose — the banner is mirrored to the room during a presentation, so explicit words like "Transcription silent!" would alarm the audience; three silence faces on red mean it to Victor and read as innocuous to everyone else; no hover-hint text either) appears with a chime and **stays until transcription recovers or the presentation ends** (not the old gentle 5-min "😶" pill, which showed anytime — this is presentation-gated and aggressive). Hovering **snoozes** it for the current stale episode (the pill sinks straight down); it re-arms on recovery / presentation end / transcription restart. Outside a presentation it's completely silent. **`KnownDisplays`** is a **hardcoded, explicit list** of Victor's own displays, matched by case-insensitive name substring (`KnownDisplays.trustedNameSubstrings`, seeded with "ASUS"; edit the array to add home monitors / TV) — there is no dynamic "remember this display" mechanism. The bottom-left overlay (`BottomLeftBanner`) is **scaled ×1.5** (font + box) for presentation visibility. Test hooks: `GET /test/presentation` (JSON: presenting / meetingActive / unknownDisplayPresent + each external's known flag + `trustedNames`), `GET /test/presentation/warn` (force-preview the red banner, auto-dismisses after 6 s).

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
  blackout. The Android tile #31 is redrawn as a **black circle
  with a white centre and four inward-pointing arrows** (vector `sfx_31_iris.xml`);
  its own mp3 is a **silent clip** but keeps the asset id `31_tarzan.mp3` (protocol/
  manifest stable). It **stays in `SoundEffectMap`** (`31_tarzan.mp3` → `iris`):
  the **press path** drives the visual, so it isn't double-triggered. **Paired
  sound:** the iris was originally soundless, but to keep **every** tablet
  thumbnail audible on the Mac, `onSoundPlay` now special-cases `31_tarzan.mp3` to
  play the **dramatic gong** (`50_gong.mp3`, ~8.6s ≈ the iris length) — like
  radar/money, the routed play path owns the sound while the press path owns the
  visual. `showIrisClose` itself stays silent (the CALayer effect plays no audio).
  `showIrisClose` overlays a **radial
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
- `GET /test/break-summary` — fire the ☕️ break-summary delta run now (opens the self-closing Terminal + headless `claude` that advances Discussion.md), bypassing the >= 5 min + 90s-cooldown gates; same flow a real break triggers (`BreakSummaryLauncher.launchNow`)
- `GET /test/tile` — tile Terminal windows (same action as ⌘⌃A); headless way to exercise `TerminalTiler`
- `GET /test/whip` — fire the 🔥 WIP Agent whip overlay (same action as ⌃W); NB leaves the overlay up until Esc
- `GET /test/group-photo` — show the 📸 Group Photo bottom-left status banner now, bypassing the break-length + daemon-connected gates
- `GET /test/wispr-output-drift` — post the 🔇 "Mute inactiv la dictare" output-route warning now, using the real current default-output name (bypasses the Wispr-start + drift-latch gates)
- `GET /test/projector` — force-apply the 🖥️ display arrangement now (projector setup if an unknown external is detected, else the standard Retina-main + ASUS-right rig) and return a JSON snapshot: detected `retina`/`asus`/`projector` names, resolved `scene`, current `retinaMode`, and `retina1080Available`. Safe to run without a projector — it just re-asserts the standard layout (repositions the ASUS to the right)
- `GET /test/presentation` — JSON snapshot of the 🔴 presenting state: `presenting`, `meetingActive` (🎙️TO Zoom running), `unknownDisplayPresent`, each connected external with its `known` flag, the `knownNameRules`, and `trustedIdentityCount`. Read-only (no side effects)
- `GET /test/presentation/warn` — force-preview the aggressive red `😶😶😶` banner now (bypasses the presenting + stale gates); auto-dismisses after ~6 s
- `GET /test/known-displays/trust` — whitelist the currently-connected external displays as "mine" (home monitors / TV) by hardware identity; returns the JSON list of names added. Same as the 🖥️ Trust current external displays menu item
- `GET /test/sonar` — fire the 🛰️ Sonar overlay now (visual + synced `23_radar.mp3`); same as `/effect/sonar`. The tablet drives it by routing `GET /sound/play/23_radar.mp3` to the Mac (handled in `onSoundPlay`)
- `GET /test/money` — fire one round of the 💸 Money rising-dollars overlay now; same as `/effect/money`. The tablet drives it by routing `GET /sound/play/53_rain.mp3` to the Mac (handled in `onSoundPlay`), which also plays the #57 checkmark "ching"
- `GET /test/iris` — fire the 🕳️ Iris-close blackout now (5s close → 1s hold → auto fade-out reveal); same as `/effect/iris`. The tablet drives it via `GET /sound/pressed/31_tarzan.mp3` (mapped to `iris` in `SoundEffectMap`); a second press before the auto-reveal cancels it early. The `/test/iris` visual itself is silent; the tablet-routed press pairs it with the gong (`50_gong.mp3`) via `onSoundPlay`
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
- **`dismissSinking()` — cancel / say "no / stop".** The pill (and its hint) slide straight **DOWN** off the bottom of the screen over **~0.7s** (`.easeIn`, no fade — it's anchored at the bottom edge, so dropping it past its own height carries it fully out of view), the mirror image of the rising "accept". Used when you **hover-to-undo a paste** and when you **hover-to-snooze the 😶 silent-transcription warning** (`SilentTranscriptionWarning.snooze`) — in both cases the downward motion alone reads as "dismissed / put away".
- Wiring lives in `SessionNotesAppender`: a banner-free **`writeNotes`** core feeds both entry points (`pasteAndOfferUndo` for keypress pastes, the `offerPrompt` hover handler for prompt-capture); **`performUndo` returns `Bool`** so the caller sinks the pill *only* when the undo actually landed. The old `"↩️ Undone"` / `"pasted in notes"` text flashes are gone — the animation **is** the feedback. The hover-approve window itself is `hoverActionDuration` (**7.5s**). The notes flows and the silent-warning snooze use the rising/sinking pair; status banners still use plain `dismiss()`.

## AI Instructions
- After any significant design, architecture, or deployment change, proactively offer to save the decision to memory for future conversations.
- After any code change in this project, always: push to master (`git push`), run `./build-app.sh`, then restart the app (`pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"`).
- **Testing during a live workshop is fine — don't hold back.** Victor doesn't mind app restarts or transcription gaps mid-session. The only constraint: the **built-in retina display is what's projected to the room**, so do any *visual* testing (overlays, screenshots) on the **right-hand external screen** instead — never put test UI on the projected retina display. (Note: the ☕️ Break overlay's `defaultFrame()` always opens on the retina by design; drag it to the right monitor, or screenshot the right screen, when verifying during a session.)

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes

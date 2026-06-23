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
- **💬 Transcribing** — starts/stops Whisper live transcription; toggles icon to 💬-crossed when stopped. Schedule (`TranscriptionScheduler`): Mon–Fri 09:00 auto-starts and **locks** the toggle until 18:00 (during the lock, a stop click is dropped with a `🔒` banner; a start click is honored as recovery — useful after a crash or battery pause). 18:00 fires an unconditional auto-stop. Outside the window the user has full control; a manual ON persists until the next 18:00 weekday (e.g. Friday 19:00 → Monday 18:00). A 60s heartbeat inside the window restarts Whisper if the process died. Battery pauses transcription regardless of schedule; AC restoration does **not** auto-resume — the user must restart manually.
- **Emotional 🥹 Paste (⌘⌃V)** — AI-powered text cleanup via Claude Haiku; intercepts Cmd+V to capture clipboard, Cmd+Ctrl+V cleans and re-pastes
- **Toggle Dark Mode (⌘⌃⌥D)** — toggles macOS dark/light mode via AppleScript
- **Mute 🎶 (auto)** — drops `🔊OS Output` device volume to 1% during Wispr Flow dictation, restores on stop. `CoreAudioManager` runs a single self-rescheduling `DispatchSourceTimer` on a serial `pollQueue`: normal cadence is 300ms; each Mouse 5 press extends a `boostedUntil` deadline by 1s during which the next ticks are scheduled 100ms apart. The Mouse 5 click handler also probes the loopback immediately (~150ms RMS/peak window, thresholds RMS 0.0002 / peak 0.0005) and — if music is playing — does a **speculative mute** without waiting for Wispr's recording state, capturing the current volume into `originalVolume` and setting `kAudioDevicePropertyVolumeScalar` to 0.01. Polls then confirm via `kAudioProcessPropertyIsRunningInput` on `com.electron.wispr-flow.*`. Restore is debounced: on Wispr `1→0` (or on a speculative mute that Wispr never confirms) we wait 1000ms of stable `recording=false` before restoring `originalVolume`; any `recording=true` read inside that window cancels the pending restore (`firstNotRecordingAt = nil`). The loopback check is **not** consulted on restore (a muted device reads silent and would falsely cancel restore). All state (`volumePushedDown`, `originalVolume`, `firstNotRecordingAt`, `boostedUntil`, `nextDeadline`) lives entirely on `pollQueue`, so reads/writes are sequential. Mouse 5 is observed via the event tap and passed through (Wispr still sees it); behavior on other triggers (right Opt-Cmd, hotkey, UI button, VAD, ESC) falls back to the boosted-or-normal poll alone. Caveats: an app crash mid-mute leaves the volume at 1% until next Wispr cycle; a manual volume-slider tweak during dictation is overwritten on restore.
- **Re-paste (Wheel x 2)** — double-click mouse wheel re-pastes last intercepted text
- **📋 IntelliJ Git → Clipboard** — copies git remote URL + branch from frontmost IntelliJ project
- **Take Screenshot (⌃P)** — captures screenshot to timestamped file
- **Display join link** — shows participant join URL banner at top of screen (enabled when session active); banner auto-hides after 20s with fade-out animation
- **☕️ Break (countdown watch)** — submenu of fixed durations (5/7/10/12/15/45 min, 1 hour) opens a draggable, resizable digital countdown overlay (`BreakTimerOverlay`): a big **red custom-drawn seven-segment** `MM:SS` (segments are 4-vertex rectangles with uniform gaps; deep-red lit + solid dark-red ghost colors sampled from the reference) over a **frosted-glass (`NSVisualEffectView` behind-window blur) black** panel, the finish time shown in **local + CET** timezones with no AM/PM designator (e.g. `08:33 EEST` / `07:33 CEST`), and small controls left→right (+1/+3/+5, ⏸ pause/resume, ✕ close). Opens top-right at **20% of the main-screen width** (aspect 1.85) on first use (no persistence — it's draggable); the panel **accepts mouse events** (unlike `OverlayPanel`), drags from anywhere on the body (open/closed-hand cursor) and resizes from any of the 4 corners (OS diagonal resize cursors) with **locked aspect ratio**. The background **dims to 20% opacity while the user is active** (mouse/keyboard) and **eases back to 60% after 5 s idle** (CGEventSource idle polling) so it's unobtrusive while working but prominent during the break. Re-clicking a duration resets the time **in place** (keeps position/size). On expiry the gong plays **once** while the digits **blink for the gong's duration**, then the window **closes instantly**. While paused the countdown and finish-time displays freeze. Pure formatting/finish-time math lives in a unit-tested `BreakTimerModel`; the controller invalidates in-flight expiry blocks via an `epoch` counter so +Nm / re-click cancel a pending expiry. NB: the digits view is a subview of the glass `NSVisualEffectView` (layer-backed) — do **not** use `addClip()` in its `draw(_:)`, which silently clips out all content there.
- **☠️ Kill port** — submenu with recent ports + custom port dialog

**Tech**: Swift, AppKit, Anthropic API (Haiku)
**Secrets**: `WISPR_CLEANUP_ANTHROPIC_API_KEY` in `~/.training-assistants-secrets.env`

**Operational note (2026-04):** On app launch, transcribing UI state is derived from actual Whisper process state (not just persisted defaults) to avoid stale "Stop Transcribing" menu state when the process failed to start.

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

- `GET /test/state` — JSON snapshot of transcription state (`running`, preference flag, UI/menu/icon state)
- `GET /test/transcription/start`
- `GET /test/transcription/stop`
- `GET /test/transcription/toggle`
- `GET /test/audio/playing` — taps `🔊OS Output` loopback for ~150ms, returns `{playing, rms, peak, ...}`
- `GET /test/wispr/recording` — checks `kAudioProcessPropertyIsRunningInput` on `com.electron.wispr-flow.*`, returns `{recording}`
- `GET /test/break/<minutes>` — start/reset the ☕️ Break countdown overlay for N minutes
- `GET /test/break/close` — close the Break overlay
- `GET /ping`, `GET /sounds/manifest`, `GET /sound/play/<file>?vol=N`, `GET /sound/volume/<pct>`, `GET /sound/stop` — tablet sound routing (see Overlay Components)

For local E2E checks without stealing focus:

- `./test-transcription-control.sh [start|stop|toggle]`
- Uses only local HTTP control endpoints and validates runtime state transitions.

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

## AI Instructions
- After any significant design, architecture, or deployment change, proactively offer to save the decision to memory for future conversations.
- After any code change in this project, always: push to master (`git push`), run `./build-app.sh`, then restart the app (`pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"`).

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes

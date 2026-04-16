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
- **💬 Transcribing** — starts/stops Whisper live transcription; toggles icon to 💬-crossed when stopped
- **Emotional 🥹 Paste (⌘⌃V)** — AI-powered text cleanup via Claude Haiku; intercepts Cmd+V to capture clipboard, Cmd+Ctrl+V cleans and re-pastes
- **Toggle Dark Mode (⌘⌃⌥D)** — toggles macOS dark/light mode via AppleScript
- **Mute 🎶 (Mouse 5)** — pauses media, lowers loopback device volume during dictation
- **Re-paste (Wheel x 2)** — double-click mouse wheel re-pastes last intercepted text
- **📋 IntelliJ Git → Clipboard** — copies git remote URL + branch from frontmost IntelliJ project
- **Take Screenshot (⌃P)** — captures screenshot to timestamped file
- **Display join link** — shows participant join URL banner at top of screen (enabled when session active); banner auto-hides after 20s with fade-out animation
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

**Tech**: Swift, AppKit, AVFoundation, Swift Package Manager
**Build**: `swift build && swift test`

## Testing & Diagnostics

Headless local test hooks are exposed through `TabletHttpServer` on `127.0.0.1:55123` so tests do not need UI focus or menu clicking:

- `GET /test/state` — JSON snapshot of transcription state (`running`, preference flag, UI/menu/icon state)
- `GET /test/transcription/start`
- `GET /test/transcription/stop`
- `GET /test/transcription/toggle`

For local E2E checks without stealing focus:

- `./test-transcription-control.sh [start|stop|toggle]`
- Uses only local HTTP control endpoints and validates runtime state transitions.

## Deployment
- **App bundle**: `./build-app.sh` creates `/Applications/Victor Addons.app` (Spotlight-searchable)
- **LaunchAgent**: `./install-startup.sh` symlinks plist, loads LaunchAgent for login auto-start
- Re-run `build-app.sh` after changes to `start.sh`, icons, or app identity
- `start.sh` exports `VICTOR_ADDONS_ROOT` so the app can resolve `whisper-transcribe/whisper_runner.py` reliably when launched from `/Applications` bundle.

## AI Instructions
- After any significant design, architecture, or deployment change, proactively offer to save the decision to memory for future conversations.

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes

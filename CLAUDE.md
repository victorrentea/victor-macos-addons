# Victor macOS Addons

Multi-module macOS utilities for live training workshops, running on the trainer's Mac.
Single menu bar app (💬 icon) provides all functionality.

## Architecture

- **Single process**: `wispr-flow/app.py` is the main menu bar app (rumps)
- **LaunchAgent**: `ro.victorrentea.macos-addons.plist` — starts on login, no KeepAlive
- **Startup**: `start.sh` launches desktop-overlay (background) + wispr-flow (foreground)
- **Inter-module communication**: wispr-flow sends SIGUSR1 to desktop-overlay PID to toggle controls

## Modules

### wispr-flow
Python menu bar app (💬 icon) — the main entry point. All features are menu entries:

**Active features:**
- **💬 Transcribing** — starts/stops Whisper live transcription; toggles icon to 💬-crossed when stopped
- **Emotional 🥹 Paste (⌘⌃V)** — AI-powered text cleanup via Claude Haiku; intercepts Cmd+V to capture clipboard, Cmd+Ctrl+V cleans and re-pastes
- **Toggle Dark Mode (⌘⌃⌥D)** — toggles macOS dark/light mode via osascript
- **Mute 🎶 (Mouse 5)** — pauses media, lowers loopback device volume during dictation
- **Re-paste (Wheel x 2)** — double-click mouse wheel re-pastes last intercepted text
- **🎬 Show/Hide** — toggles desktop-overlay effects panel via SIGUSR1
- **📋 IntelliJ Git → Clipboard** — copies git remote URL + branch from frontmost IntelliJ project
- **☠️ Kill port** — submenu with recent ports + custom port dialog

**Tech**: Python 3.12, rumps, pyobjc, Anthropic API (Haiku)
**Secrets**: `WISPR_CLEANUP_ANTHROPIC_API_KEY` in `~/.training-assistants-secrets.env`
**Run**: `cd wispr-flow && python3 app.py`

### whisper-transcribe
Live dual-channel Whisper transcription engine (extracted from training-assistant daemon):
- **WhisperTranscriptionRunner** — captures audio from 2 sources, transcribes via mlx-whisper on Apple Silicon GPU
- Writes `[HH:MM] Speaker: text` lines to per-day files in `TRANSCRIPTION_FOLDER`
- Default devices: XLR mic (device 5) + Zoom loopback (device 17)
- Auto-detects Romanian/English, filters hallucinations, RMS-based silence skipping

**Tech**: Python 3.12, mlx-whisper, sounddevice, numpy
**Config env vars**: `WHISPER_ME_DEVICE`, `WHISPER_AUDIENCE_DEVICE`, `WHISPER_MODEL`, `WHISPER_CHUNK_SECONDS`, `WHISPER_SILENCE_THRESHOLD`, `TRANSCRIPTION_FOLDER`

### desktop-overlay
Swift/AppKit overlay app for live sessions (no separate menu bar icon):
- **EmojiAnimator**: receives emoji reactions via WebSocket, animates sprites flying up the screen
- **ButtonBar**: floating button bar for host controls (sound effects, overlay toggle)
- **SoundManager**: plays sound effects (applause, drum roll, etc.) triggered by host
- **OverlayPanel**: transparent always-on-top NSPanel covering full screen

Connects to the training-assistant backend via WebSocket at `/ws/__overlay__`.

**Tech**: Swift, AppKit, AVFoundation, Swift Package Manager
**Build**: `cd desktop-overlay && swift build && swift test`

## Installation
```bash
./install-startup.sh   # symlinks plist, loads LaunchAgent, removes old wispr-addons agent
```

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes

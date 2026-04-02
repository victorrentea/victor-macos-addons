# Victor macOS Addons

Multi-module macOS utilities for live training workshops, running on the trainer's Mac.

## Modules

### desktop-overlay
Swift/AppKit overlay app for live sessions:
- **EmojiAnimator**: receives emoji reactions via WebSocket, animates sprites flying up the screen
- **ButtonBar**: floating button bar for host controls (sound effects, overlay toggle)
- **SoundManager**: plays sound effects (applause, drum roll, etc.) triggered by host
- **OverlayPanel**: transparent always-on-top NSPanel covering full screen

Connects to the training-assistant backend via WebSocket at `/ws/__overlay__`.

**Tech**: Swift, AppKit, AVFoundation, Swift Package Manager
**Build**: `cd desktop-overlay && swift build && swift test`

### wispr-flow
Python daemon for keyboard/mouse interception and AI-powered text cleanup:
- **CGEventTap** intercepts all key and mouse events system-wide
- **Cmd+V capture**: stores clipboard content at each paste
- **Cmd+Ctrl+V**: sends captured text to Claude Haiku for grammar/filler cleanup, undoes original paste, re-pastes cleaned version
- **Cmd+Ctrl+Opt+V**: same but adds contextual emojis
- **Mouse Button 5** (Wispr Flow dictation toggle): pauses media, lowers loopback volume; pressing again restores
- **Escape while dictating**: restores volume and resumes media

Requires macOS Accessibility permission and `WISPR_CLEANUP_ANTHROPIC_API_KEY` in `~/.training-assistants-secrets.env`.

**Tech**: Python 3.12, pyobjc, Anthropic API (Haiku)
**Run**: `cd wispr-flow && python3 app.py`
**LaunchAgent**: `cd wispr-flow && ./install-startup.sh` (auto-start at login with KeepAlive)

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant builds and launches the desktop-overlay automatically

# Victor macOS Addons

Multi-module macOS app repository containing Swift/AppKit utilities for live training workshops.

## Modules

### desktop-overlay
Swift/AppKit overlay app that runs on the trainer's Mac during live sessions:
- **EmojiAnimator**: receives emoji reactions via WebSocket, animates sprites flying up the screen
- **ButtonBar**: floating button bar for host controls (sound effects, overlay toggle)
- **SoundManager**: plays sound effects (applause, drum roll, etc.) triggered by host
- **OverlayPanel**: transparent always-on-top NSPanel covering full screen

Connects to the training-assistant backend via WebSocket at `/ws/__overlay__`.

## Technology
- **Language**: Swift (Swift Package Manager)
- **Framework**: AppKit (macOS native)
- **Audio**: AVFoundation
- **Build**: `swift build` / `swift test`

## Development
```bash
cd desktop-overlay
swift build
swift test
```

## Related
- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant builds and launches this overlay automatically

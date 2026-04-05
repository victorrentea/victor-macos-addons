## Why

The macos-addons app currently communicates with the training-assistant daemon via filesystem polling (writing slide changes to a `.txt` file), and the emoji reaction display is already push-based via a remote WebSocket. Adding an embedded WebSocket server in macos-addons enables real-time bidirectional communication: the training-assistant daemon connects once and can push emoji reactions to the overlay while the addons app pushes current slide state as it changes — eliminating file I/O, polling delays, and the fragile dependency on a shared filesystem path.

## What Changes

- **New**: An embedded WebSocket server starts inside the macos-addons process (wispr-flow), listening on a configurable port (default `8765`)
- **New**: The training-assistant daemon connects to this WebSocket as a client instead of polling the slides activity file
- **New**: `powerpoint-monitor` pushes slide-change events over WebSocket instead of (or alongside) writing to the activity file
- **Remove**: The current slide pointer line in `activity-slides-YYYY-MM-DD.md` written by `powerpoint-monitor` is no longer needed once daemon migrates
- **New**: Emoji reactions arrive at the WebSocket server from the daemon and are forwarded to the desktop-overlay (replacing or augmenting the current path)

## Capabilities

### New Capabilities
- `ws-server`: Embedded WebSocket server in wispr-flow, managing client connections and message routing
- `slide-push`: powerpoint-monitor sends current slide/deck state as a WebSocket message on every change
- `emoji-receive`: WebSocket server accepts incoming emoji reaction messages from the daemon and forwards them to desktop-overlay

### Modified Capabilities
<!-- No existing spec files found; no delta specs needed -->

## Impact

- `wispr-flow/app.py` — starts/stops the WebSocket server as part of app lifecycle
- `powerpoint-monitor/monitor.py` — sends slide events via WebSocket in addition to (or instead of) file writes
- `desktop-overlay` — receives emoji trigger via new internal channel (SIGUSR1/pipe or direct call from ws-server)
- **New dependency**: `websockets` Python library (or `asyncio` + `websockets`)
- **No external port exposure required** — server binds to `127.0.0.1` only
- The training-assistant daemon (separate repo) needs a client-side change to connect to this server instead of polling the file

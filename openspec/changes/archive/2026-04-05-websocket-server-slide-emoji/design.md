## Context

Currently the macos-addons app communicates state to the training-assistant daemon exclusively through filesystem writes. `PowerPointMonitor` appends/rewrites an activity file and a pointer line (`deck:slide_number`) that the daemon polls every 0.5s. Emoji reactions flow in the opposite direction: the daemon pushes to the desktop-overlay via the remote training-assistant WebSocket at `/ws/__overlay__`, bypassing the macos-addons process entirely.

This design adds a local WebSocket server embedded in the `wispr-flow` process. It acts as a message hub: the training-assistant daemon (and optionally the desktop-overlay) connect to it. Slide changes are broadcast outward; emoji reactions arrive inward and are forwarded to the overlay.

## Goals / Non-Goals

**Goals:**
- Embedded `asyncio`-based WebSocket server in wispr-flow, starts with the app, binds to `127.0.0.1` only
- PowerPointMonitor pushes slide-change events via a thread-safe callback/queue to the WS server
- Training-assistant daemon connects as a client and receives slide events in real time
- Daemon can push emoji reaction messages to the same server; server routes them to the overlay
- Desktop-overlay connects to the local WS server instead of (or alongside) the remote backend

**Non-Goals:**
- Authentication or TLS — loopback-only, single-machine use
- Multi-client fan-out across multiple training-assistant instances
- Replacing the activity-slides file for the *timing* lines (those can continue for session archival)
- Any changes to the training-assistant daemon repo (only the protocol contract matters here)

## Decisions

### D1: asyncio server in a background thread with its own event loop

**Decision**: Spin up a dedicated `asyncio` event loop in a daemon thread at app startup; run the `websockets` server on it.

**Why**: `wispr-flow/app.py` uses `rumps` which drives the macOS main run loop on the main thread. Python's `asyncio` event loop cannot share the thread. A background thread with `loop.run_forever()` is the standard pattern for embedding asyncio into a non-async host.

**Alternative considered**: `asyncio.get_event_loop()` on main thread — incompatible with rumps/PyObjC main run loop.

### D2: Thread-safe queue to bridge PowerPointMonitor → WS server

**Decision**: `PowerPointMonitor` receives a `push_callback` (or writes to a `queue.SimpleQueue`). On slide change, it enqueues a message dict. The asyncio event loop's `call_soon_threadsafe` drains the queue and broadcasts to all connected clients.

**Why**: `PowerPointMonitor` runs on its own `threading.Thread`. Directly `await`ing from it is impossible. A queue + `call_soon_threadsafe` is the canonical asyncio bridge pattern.

**Alternative considered**: `loop.run_coroutine_threadsafe` — works but harder to cancel gracefully.

### D3: Desktop-overlay connects to local WS server for emoji

**Decision**: Instead of (or in addition to) the remote `/ws/__overlay__` path, the Swift desktop-overlay opens a WebSocket client connection to `ws://127.0.0.1:8765` and listens for `{"type":"emoji", ...}` messages.

**Why**: This removes the dependency on the remote training-assistant server for local overlay effects. The local WS server receives emoji from the daemon and can broadcast them to all connected clients — including the overlay running on the same machine.

**Alternative considered**: Keep the daemon → remote backend → overlay WebSocket path and only add the slide-push direction. Rejected because it keeps a fragile dependency on network connectivity during workshops and doesn't simplify the emoji path.

### D4: JSON message protocol with `type` discriminator

**Decision**:
```json
// slide event (server → clients):
{"type": "slide", "deck": "AI Coding.pptx", "slide": 15, "presenting": true}

// emoji event (client → server, server → overlay client):
{"type": "emoji", "emoji": "🎉", "count": 3}

// ping/keep-alive (either direction):
{"type": "ping"}
```

**Why**: Simple, human-readable, extensible. No binary framing needed for this message volume.

### D5: Port configurable via env var, default 8765

**Decision**: `WS_SERVER_PORT` env var, defaulting to `8765`.

**Why**: Keeps the default simple while allowing port conflicts to be resolved without code changes.

## Risks / Trade-offs

- **Port conflict** → Mitigation: log clearly on bind failure; server failure is non-fatal (rest of app continues)
- **Asyncio event loop leak on app quit** → Mitigation: `WsServer.stop()` called from `WisprAddonsApp.quit()`, which cancels tasks and stops the loop cleanly before `os._exit`
- **Desktop-overlay reconnect** → Mitigation: overlay client reconnects with exponential backoff; server tolerates connect/disconnect freely
- **File-based polling still runs** → Both mechanisms can coexist during transition; the slide pointer line in the file is harmless alongside WS push

## Migration Plan

1. Deploy this change; WS server starts automatically on app launch
2. Update training-assistant daemon to connect to `ws://127.0.0.1:8765` and switch from file-poll to WS for current-slide; keep file-poll as fallback for a session
3. Update desktop-overlay Swift client to connect locally; disable the remote `/ws/__overlay__` emoji path once confirmed
4. Remove pointer-line writes from `PowerPointMonitor` in a follow-up change once daemon migration is complete

## Open Questions

- Should slide events also carry deck path (not just filename) to help the daemon find the right git activity line?
- Should the server broadcast a "welcome" message with the current slide state when a new client connects, so the daemon gets immediate state on reconnect?

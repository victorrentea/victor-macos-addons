## 1. Dependencies & Project Setup

- [x] 1.1 Add `websockets` to `wispr-flow/requirements.txt` (or equivalent dep tracking)
- [x] 1.2 Verify `asyncio` + `websockets` can coexist with the rumps/PyObjC main run loop in a background thread (smoke test)

## 2. WS Server Core (`wispr-flow/ws_server.py`)

- [x] 2.1 Create `wispr-flow/ws_server.py` with `WsServer` class: asyncio server on `127.0.0.1`, port from `WS_SERVER_PORT` env (default `8765`)
- [x] 2.2 Manage connected-client set; handle connect/disconnect without crashing
- [x] 2.3 Implement `broadcast(message: dict)` — serialize to JSON and send to all connected clients
- [x] 2.4 Implement `relay(message: dict, sender_ws)` — broadcast to all clients *except* the sender
- [x] 2.5 Store last known slide state; send as welcome message to each new client on connect
- [x] 2.6 Implement `start()` — spin up asyncio event loop in daemon thread, start server
- [x] 2.7 Implement `stop()` — cancel tasks, close server, stop event loop cleanly
- [x] 2.8 Log bind error clearly and continue (non-fatal) if port is already in use

## 3. Message Handling in WS Server

- [x] 3.1 Implement inbound message dispatcher: parse JSON, route by `type` field
- [x] 3.2 Handle `{"type":"emoji",...}` — relay to all other connected clients
- [x] 3.3 Handle `{"type":"ping"}` — no-op (keep-alive, no response needed)
- [x] 3.4 Log warning and ignore unknown message types or malformed JSON

## 4. PowerPointMonitor → WS Server Integration

- [x] 4.1 Add `slide_callback: callable | None` parameter to `PowerPointMonitor.__init__`
- [x] 4.2 Call `slide_callback({"type":"slide","deck":..., "slide":..., "presenting":...})` in `_tick()` on every state change (slide or deck change)
- [x] 4.3 In `wispr-flow/app.py`, pass `ws_server.push_slide` as the callback when constructing `PowerPointMonitor`
- [x] 4.4 Implement `WsServer.push_slide(event: dict)` — enqueue the event and use `loop.call_soon_threadsafe` to broadcast from the asyncio thread

## 5. wispr-flow App Lifecycle Integration

- [x] 5.1 Instantiate `WsServer` at app startup in `WisprAddonsApp.__init__`
- [x] 5.2 Call `ws_server.start()` early in app startup (before PowerPoint tracking starts)
- [x] 5.3 Call `ws_server.stop()` in the `quit()` method before `os._exit`
- [x] 5.4 Log server start/stop with port number for easy debugging

## 6. Desktop-Overlay Swift Client

- [x] 6.1 Add WebSocket client in the overlay's Swift code that connects to `ws://127.0.0.1:<port>` (read port from env or hardcode default `8765`)
- [x] 6.2 On `{"type":"emoji",...}` message received, trigger the existing emoji animation logic
- [x] 6.3 Implement reconnect with exponential backoff (e.g., 1s, 2s, 4s, max 30s)
- [x] 6.4 Add Swift test for emoji message parsing

## 7. Verification

- [ ] 7.1 Manual test: start app, connect `wscat` or `websocat` to `ws://127.0.0.1:8765`, advance a PowerPoint slide → confirm JSON slide event received
- [ ] 7.2 Manual test: send `{"type":"emoji","emoji":"🎉","count":3}` from wscat → confirm second connected client receives it
- [ ] 7.3 Manual test: quit app → confirm server shuts down and connection closes cleanly
- [ ] 7.4 Manual test: desktop-overlay receives emoji and animates on screen end-to-end
<!-- Manual verification tasks require running the app -->

"""Embedded WebSocket server for wispr-flow.

Runs on a dedicated asyncio event loop in a background daemon thread.
Clients (training-assistant daemon, desktop-overlay) connect here to:
  - Receive slide-change events pushed by PowerPointMonitor.
  - Send emoji messages that are relayed to all other connected clients.
"""

import asyncio
import json
import os
import threading

try:
    import websockets
    import websockets.server
    _AVAILABLE = True
except ImportError:
    _AVAILABLE = False


def _log(msg: str) -> None:
    from datetime import datetime
    print(f"[{datetime.now().strftime('%H:%M:%S')}] [ws-server] {msg}", flush=True)


class WsServer:
    PORT = int(os.environ.get("WS_SERVER_PORT", "8765"))

    def __init__(self):
        self._clients: set = set()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._server = None
        self._thread: threading.Thread | None = None
        self._last_slide: dict | None = None  # last known slide state for welcome msg

    # ── Public API (callable from any thread) ────────────────────────────────

    def start(self) -> None:
        if not _AVAILABLE:
            _log("websockets library not installed — server disabled")
            return
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, daemon=True, name="ws-server")
        self._thread.start()

    def stop(self) -> None:
        if self._loop and self._loop.is_running():
            self._loop.call_soon_threadsafe(
                lambda: self._loop.create_task(self._shutdown())
            )

    def push_slide(self, event: dict) -> None:
        """Called from PowerPointMonitor thread when slide state changes."""
        self._last_slide = event
        if self._loop and self._loop.is_running():
            self._loop.call_soon_threadsafe(
                lambda: self._loop.create_task(self._broadcast(event))
            )

    # ── Internal asyncio ──────────────────────────────────────────────────────

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(self._start_server())
        if self._server:
            self._loop.run_forever()

    async def _start_server(self) -> None:
        try:
            self._server = await websockets.serve(
                self._handler, "127.0.0.1", self.PORT
            )
            _log(f"Listening on ws://127.0.0.1:{self.PORT}")
        except OSError as e:
            _log(f"Failed to bind on port {self.PORT}: {e} — server disabled")

    async def _shutdown(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        self._loop.stop()

    async def _handler(self, websocket) -> None:
        self._clients.add(websocket)
        _log(f"Client connected ({len(self._clients)} total)")
        try:
            if self._last_slide:
                await websocket.send(json.dumps(self._last_slide))
            async for raw in websocket:
                await self._dispatch(raw, websocket)
        except Exception:
            pass
        finally:
            self._clients.discard(websocket)
            _log(f"Client disconnected ({len(self._clients)} remaining)")

    async def _dispatch(self, raw: str, sender) -> None:
        try:
            msg = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            _log("Malformed JSON from client — ignored")
            return
        msg_type = msg.get("type")
        if msg_type == "emoji":
            await self._relay(msg, sender)
        elif msg_type == "ping":
            pass  # keep-alive, no response needed
        else:
            _log(f"Unknown message type '{msg_type}' — ignored")

    async def _broadcast(self, msg: dict) -> None:
        if not self._clients:
            return
        text = json.dumps(msg)
        for ws in set(self._clients):
            try:
                await ws.send(text)
            except Exception:
                pass

    async def _relay(self, msg: dict, sender) -> None:
        text = json.dumps(msg)
        for ws in set(self._clients):
            if ws is sender:
                continue
            try:
                await ws.send(text)
            except Exception:
                pass

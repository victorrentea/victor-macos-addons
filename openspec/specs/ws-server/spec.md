### Requirement: Server starts with the app
The wispr-flow process SHALL start an embedded WebSocket server on `127.0.0.1` at port `WS_SERVER_PORT` (default `8765`) when the app launches. The server SHALL run on a dedicated asyncio event loop in a daemon thread.

#### Scenario: Normal startup
- **WHEN** the wispr-flow app starts
- **THEN** a WebSocket server is listening on `ws://127.0.0.1:8765` within 2 seconds

#### Scenario: Port override via env var
- **WHEN** `WS_SERVER_PORT=9000` is set in the environment
- **THEN** the server listens on port `9000` instead of `8765`

#### Scenario: Port conflict on startup
- **WHEN** the configured port is already in use
- **THEN** the server logs an error and the rest of the app continues normally (non-fatal)

### Requirement: Server stops cleanly on app quit
The WS server SHALL be stopped before the process exits, cancelling all active connections and the event loop.

#### Scenario: Quit from menu
- **WHEN** the user selects Quit from the menu bar
- **THEN** all WebSocket connections are closed and the server thread exits before `os._exit` is called

### Requirement: Multiple simultaneous clients supported
The server SHALL accept connections from multiple clients concurrently (daemon + overlay + any monitoring tool).

#### Scenario: Two clients connected
- **WHEN** both the training-assistant daemon and the desktop-overlay are connected
- **THEN** slide events are delivered to both; emoji events sent by either client are forwarded to all other connected clients

### Requirement: Clients may connect and disconnect freely
The server SHALL tolerate clients connecting and disconnecting at any time without crashing or losing state.

#### Scenario: Client reconnects after disconnect
- **WHEN** a client disconnects and reconnects
- **THEN** the server accepts the new connection and resumes message delivery

### Requirement: Welcome message on connect
When a client connects, the server SHALL immediately send the last known slide state (if any) so the client does not have to wait for the next slide change.

#### Scenario: Daemon connects mid-session
- **WHEN** a client connects while PowerPoint is already open on slide 15 of "AI Coding.pptx"
- **THEN** the server sends `{"type":"slide","deck":"AI Coding.pptx","slide":15,"presenting":false}` immediately upon connection

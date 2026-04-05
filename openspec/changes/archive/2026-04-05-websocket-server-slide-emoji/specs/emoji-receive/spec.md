## ADDED Requirements

### Requirement: Emoji messages accepted from connected clients
The WS server SHALL accept `{"type":"emoji","emoji":"<char>","count":<int>}` messages from any connected client and broadcast them to all *other* connected clients.

#### Scenario: Daemon sends emoji reaction
- **WHEN** the training-assistant daemon sends `{"type":"emoji","emoji":"🎉","count":5}` to the local WS server
- **THEN** all other connected clients (e.g., the desktop-overlay) receive the same message

#### Scenario: Unknown message type ignored
- **WHEN** a client sends a message with an unrecognised `type` field
- **THEN** the server logs a warning and does not crash or disconnect the client

#### Scenario: Malformed JSON ignored
- **WHEN** a client sends non-JSON data
- **THEN** the server logs a warning and ignores the message; the connection remains open

### Requirement: Desktop-overlay receives emoji via local WS
The desktop-overlay Swift app SHALL connect to the local WS server (`ws://127.0.0.1:<WS_SERVER_PORT>`) and listen for `{"type":"emoji",...}` messages to trigger the on-screen animation.

#### Scenario: Overlay connected, emoji arrives
- **WHEN** the desktop-overlay is connected and a `{"type":"emoji","emoji":"🥹","count":3}` message is broadcast
- **THEN** the overlay displays 3 instances of the 🥹 emoji animation on screen

#### Scenario: Overlay not connected
- **WHEN** the desktop-overlay is not running and a client sends an emoji
- **THEN** no animation occurs; no error is raised on the server

### Requirement: Emoji message forwarded without modification
The WS server SHALL relay the original emoji message payload unchanged to recipient clients.

#### Scenario: Relay fidelity
- **WHEN** the daemon sends `{"type":"emoji","emoji":"👏","count":10}`
- **THEN** the overlay receives exactly `{"type":"emoji","emoji":"👏","count":10}`

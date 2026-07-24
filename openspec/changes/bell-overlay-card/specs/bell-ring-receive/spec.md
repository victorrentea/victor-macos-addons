## ADDED Requirements

### Requirement: bell_ring messages accepted from the connected daemon
The local WS server SHALL accept `{"type":"bell_ring","caller":"<name>"}` messages from a connected client (the training-assistant daemon) and SHALL surface them through a new `onBellRing(caller)` callback dispatched on the main thread. The message is delivered on the existing loopback server (`ws://127.0.0.1:8765`); no transport change is required.

#### Scenario: Daemon sends a bell
- **WHEN** the training-assistant daemon sends `{"type":"bell_ring","caller":"Ana Pop"}` to the local WS server
- **THEN** the server SHALL invoke `onBellRing("Ana Pop")` on the main thread

#### Scenario: Missing caller falls back to a neutral name
- **WHEN** a `bell_ring` message arrives with no `caller` field
- **THEN** the server SHALL invoke `onBellRing` with a neutral placeholder name (e.g. "Someone") rather than crashing or ignoring the bell

#### Scenario: Malformed bell message does not crash the server
- **WHEN** a client sends non-JSON data or a `bell_ring` with a malformed payload
- **THEN** the server SHALL log a warning and keep the connection open, exactly as it does for other message types

### Requirement: bell_ring handling is additive to existing message types
Adding `bell_ring` SHALL NOT change the handling of existing message types (`display_emoji`, `session_started`, `session_ended`, `pdf_export_alarm`, `ping`); unknown types SHALL continue to be logged and ignored.

#### Scenario: Existing messages unaffected
- **WHEN** a `display_emoji` message arrives after `bell_ring` support is added
- **THEN** it SHALL still trigger the emoji animation exactly as before

#### Scenario: Older overlay tolerates bell_ring
- **WHEN** a build without `bell_ring` support receives a `bell_ring` message
- **THEN** it SHALL log the unknown type and ignore it without error

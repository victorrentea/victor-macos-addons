## ADDED Requirements

### Requirement: Slide change published over WebSocket
When `PowerPointMonitor` detects a slide or deck change, it SHALL publish a slide event to the WS server for broadcast to all connected clients. No message SHALL be sent when the slide and deck are unchanged between polls.

#### Scenario: Slide number changes
- **WHEN** the user advances to slide 16 in "AI Coding.pptx"
- **THEN** the server broadcasts `{"type":"slide","deck":"AI Coding.pptx","slide":16,"presenting":false}` to all connected clients within one polling interval (≤3s)

#### Scenario: Presentation mode started
- **WHEN** the user starts the PowerPoint slideshow (presenting mode)
- **THEN** the broadcast message includes `"presenting":true`

#### Scenario: Deck changes
- **WHEN** the user switches from "AI Coding.pptx" to "Clean Code.pptx"
- **THEN** the server broadcasts a new slide event with the new deck name and current slide number

#### Scenario: Same slide on consecutive polls
- **WHEN** the polling interval fires but the slide and deck are unchanged
- **THEN** no WebSocket message is sent

#### Scenario: PowerPoint not running
- **WHEN** PowerPoint is closed
- **THEN** no slide events are published (the server does not broadcast a null/empty event)

### Requirement: Slide push is non-blocking
The slide change callback from `PowerPointMonitor` SHALL NOT block the monitor's polling thread. Enqueuing MUST return immediately.

#### Scenario: No clients connected
- **WHEN** a slide changes but no clients are connected to the WS server
- **THEN** the event is discarded (not buffered for future clients, except for the last-state welcome message)

### Requirement: File-based slide pointer continues in parallel
The existing `activity-slides-YYYY-MM-DD.md` pointer-line write behavior SHALL continue unchanged alongside the WebSocket push, to preserve backwards compatibility during the daemon migration.

#### Scenario: Both mechanisms active
- **WHEN** a slide changes
- **THEN** the file is updated as before AND a WebSocket event is broadcast

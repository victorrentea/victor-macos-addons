## ADDED Requirements

### Requirement: Receive session lifecycle events via WebSocket
The system SHALL receive and process session lifecycle events from the training-assistant daemon via WebSocket connection.

#### Scenario: Session started event received
- **WHEN** the daemon sends a session started event with participant URL over WebSocket
- **THEN** the system SHALL store the participant URL and mark the session as active

#### Scenario: Session ended event received
- **WHEN** the daemon sends a session ended event over WebSocket
- **THEN** the system SHALL clear the participant URL and mark the session as inactive

### Requirement: Track session active state
The system SHALL maintain a boolean state indicating whether a session is currently active based on received lifecycle events.

#### Scenario: Session becomes active
- **WHEN** a session started event is received
- **THEN** the session active state SHALL be set to true

#### Scenario: Session becomes inactive
- **WHEN** a session ended event is received
- **THEN** the session active state SHALL be set to false

#### Scenario: Initial state before any events
- **WHEN** the application starts and no session events have been received
- **THEN** the session active state SHALL be false

### Requirement: Store participant URL
The system SHALL store the participant URL received from session lifecycle events and make it available for display.

#### Scenario: URL stored from session start
- **WHEN** a session started event contains participant URL "interact.victorrentea.ro/xyz789"
- **THEN** the system SHALL store this URL for display purposes

#### Scenario: URL updated on new session started event
- **WHEN** a new session started event contains a different participant URL
- **THEN** the system SHALL update the stored URL to the new value

#### Scenario: URL cleared on session end
- **WHEN** a session ended event is received
- **THEN** the system SHALL clear the stored participant URL

### Requirement: Enable menu item based on session state
The wispr-flow menu bar app SHALL enable the "Display join link" menu item only when a session is active.

#### Scenario: Menu enabled when session active
- **WHEN** the session active state becomes true
- **THEN** the "Display join link" menu item SHALL be enabled

#### Scenario: Menu disabled when session inactive
- **WHEN** the session active state becomes false
- **THEN** the "Display join link" menu item SHALL be disabled

#### Scenario: Menu disabled at startup
- **WHEN** the application starts
- **THEN** the "Display join link" menu item SHALL be disabled until a session event is received

### Requirement: Synchronize state between wispr-flow and desktop-overlay
The system SHALL synchronize session state and participant URL between the wispr-flow menu bar app and desktop-overlay.

#### Scenario: State synchronized on session start
- **WHEN** desktop-overlay receives a session started event
- **THEN** wispr-flow SHALL be notified to enable the "Display join link" menu item

#### Scenario: State synchronized on session end
- **WHEN** desktop-overlay receives a session ended event
- **THEN** wispr-flow SHALL be notified to disable the "Display join link" menu item

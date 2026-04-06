## ADDED Requirements

### Requirement: Display participant join URL in full-width banner
The system SHALL display the participant join URL in a banner at the top of the screen when triggered by the menu bar app.

#### Scenario: Banner display on menu activation
- **WHEN** the user clicks the "Display join link" menu item in wispr-flow
- **THEN** desktop-overlay displays a full-width banner at the top of the screen containing the participant URL

#### Scenario: Banner positioning and layout
- **WHEN** the banner is displayed
- **THEN** the banner SHALL span the entire width of the screen and be positioned at the very top

### Requirement: Banner visual styling
The system SHALL render the banner with a transparent background and monospaced font.

#### Scenario: Transparent background rendering
- **WHEN** the banner is displayed
- **THEN** the banner background SHALL be transparent, allowing screen content to be visible beneath it

#### Scenario: Monospaced font rendering
- **WHEN** the banner is displayed
- **THEN** the URL text SHALL be rendered in a monospaced font for easy reading and transcription

### Requirement: URL format without protocol prefix
The system SHALL display the participant URL without the http:// or https:// prefix.

#### Scenario: Protocol prefix removal
- **WHEN** the daemon sends a participant URL like "https://interact.victorrentea.ro/abc123"
- **THEN** the banner SHALL display only "interact.victorrentea.ro/abc123"

#### Scenario: URL already without prefix
- **WHEN** the daemon sends a participant URL like "interact.victorrentea.ro/abc123"
- **THEN** the banner SHALL display "interact.victorrentea.ro/abc123" unchanged

### Requirement: Banner auto-hide after timeout
The banner SHALL automatically hide 20 seconds after being displayed, with a 3 second fade-out animation.

#### Scenario: Banner auto-hides after 20 seconds
- **WHEN** the banner is displayed via menu activation
- **THEN** the banner SHALL remain fully visible for 17 seconds, then fade out over 3 seconds

#### Scenario: Fade-out animation timing
- **WHEN** the 20 second timer reaches 17 seconds
- **THEN** the banner SHALL begin fading from full opacity to transparent over the remaining 3 seconds

#### Scenario: Timer resets on re-display
- **WHEN** the banner is hidden and then displayed again via menu activation
- **THEN** a new 20 second timer SHALL start from the time of display with full opacity

### Requirement: Banner manual dismissal
The system SHALL allow the banner to be dismissed early by clicking the menu item again.

#### Scenario: Toggle banner via menu
- **WHEN** the user clicks "Display join link" while the banner is already showing
- **THEN** the banner SHALL be hidden immediately without fade animation and the 20 second timer SHALL be cancelled

#### Scenario: Manual dismissal during fade-out
- **WHEN** the user clicks "Display join link" while the banner is fading out
- **THEN** the banner SHALL be hidden immediately, stopping the fade animation

### Requirement: Banner dismissal on session end
The banner SHALL be automatically hidden when a session ended event is received.

#### Scenario: Auto-dismiss on session end
- **WHEN** the daemon sends a session ended event
- **THEN** the banner SHALL be automatically hidden immediately without fade animation if currently displayed and the 20 second timer SHALL be cancelled

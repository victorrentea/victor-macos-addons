## Why

During live training sessions, participants need an easy way to join the interactive session. Currently, the training-assistant daemon knows when a session is active and has the participant join URL, but there's no visual way for the host to display this information on screen for participants to see and type in.

## What Changes

- Add WebSocket message handling in VictorAddons AppDelegate to receive session lifecycle events (session_started, session_ended) and participant URL from training-assistant daemon
- Add new "Display join link" menu item to MenuBarManager that displays the participant URL in a full-width banner at the top of the screen
- Menu item is enabled only when a session is active (daemon has sent session_started event)
- Menu item is disabled when session is inactive (daemon sends session_ended event)
- Banner displays URL without http/https prefix, using monospaced font with semi-transparent background spanning full screen width
- Banner auto-hides after 20 seconds with 3 second fade-out animation
- All components run in same Swift process with direct method calls (no IPC needed)

## Capabilities

### New Capabilities
- `session-join-banner`: Display participant join URL in a full-width banner at top of screen with transparent background and monospaced font
- `session-lifecycle-tracking`: Track session active/inactive state based on WebSocket messages from training-assistant daemon to enable/disable menu controls

### Modified Capabilities
<!-- No existing capabilities are being modified at the requirements level -->

## Impact

- **AppDelegate**: Add WebSocket message handlers for session_started and session_ended events; store session state; add JoinLinkBanner instance
- **MenuBarManager**: Add "Display join link" menu item with enabled/disabled state tracking; add callback to toggle banner display
- **JoinLinkBanner (new)**: New NSPanel subclass for displaying banner with fade-out animation
- **training-assistant (external)**: Must send new WebSocket messages for session_started (with participant URL) and session_ended events

## Context

The victor-macos-addons project is a single Swift application (`VictorAddons`) with:
- **AppDelegate**: Main coordinator that manages WebSocket connection to training-assistant daemon, handles all application state
- **MenuBarManager**: Manages menu bar UI (💬 icon) with menu items for various features
- **OverlayPanel**: Full-screen transparent overlay for UI elements (emoji animations, button bar)
- **training-assistant**: External backend daemon (not in this repo) that manages workshop sessions and provides WebSocket connection

Currently, AppDelegate connects to the training-assistant daemon via WebSocket to receive emoji reaction events. The daemon knows when sessions are active and has the participant join URL, but there's no way to display this information on screen.

All components run in the same Swift process - no inter-process communication needed.

## Goals / Non-Goals

**Goals:**
- Display participant join URL on screen in a full-width banner when host activates the menu item
- Banner auto-hides after 20 seconds
- Enable/disable the "Display join link" menu item based on session active state
- Receive session lifecycle events and participant URL via existing WebSocket connection
- Strip http/https prefix from participant URL before display

**Non-Goals:**
- Modifying the training-assistant daemon's WebSocket protocol (assume new messages will be added there)
- Changing the existing emoji reaction or button bar functionality
- Adding authentication or validation of the participant URL
- Supporting multiple simultaneous sessions

## Decisions

### Decision 1: Extend existing WebSocket connection in AppDelegate
**Choice**: Add new message handlers to AppDelegate's existing WebSocket client for session lifecycle events.

**Rationale**: AppDelegate already maintains a WebSocket connection for emoji reactions. Reusing this connection is simpler than creating a second connection.

**Alternatives considered**:
- Separate WebSocket connection: Unnecessary overhead, would require managing two connections

### Decision 2: Session state in AppDelegate
**Choice**: AppDelegate stores session state (isActive boolean, participantUrl optional string) as instance variables.

**Rationale**:
- Simple, direct - all state in one place
- AppDelegate already coordinates all major components
- No IPC needed - just direct method calls within same process

**Alternatives considered**:
- Separate state manager class: Over-engineering for simple boolean + string state

### Decision 3: Direct method calls for UI updates
**Choice**: When session state changes, AppDelegate directly calls methods on MenuBarManager to enable/disable menu item. When menu item is clicked, MenuBarManager calls back to AppDelegate to show/hide banner.

**Rationale**:
- Everything runs in same process - direct method calls are simplest
- Follows existing pattern (e.g., whisperManager.onStateChanged callback to menuBarManager)
- No signals, files, or other IPC mechanisms needed

**Alternatives considered**:
- File-based IPC: Unnecessary complexity when everything is in-process
- Signals: Only needed for separate processes

### Decision 4: Banner as NSPanel positioned at top of screen
**Choice**: Implement banner as a new NSPanel instance positioned at top of screen, with semi-transparent background and NSTextField for URL display. Auto-hide after 20 seconds using Timer, with 3 second fade-out animation.

**Rationale**:
- NSPanel provides always-on-top behavior needed for banner
- Transparent background and custom styling are straightforward with AppKit
- Timer-based auto-hide is simple and reliable
- NSAnimationContext provides smooth fade-out animation (alphaValue from 1.0 to 0.0 over 3 seconds)
- Fade starts at 17 seconds, completes at 20 seconds

**Alternatives considered**:
- Add to existing OverlayPanel: Banner has different positioning and lifecycle, separation is cleaner
- Use NSWindow: NSPanel provides simpler API for utility windows
- Instant hide without fade: Less polished user experience

### Decision 4a: Fade-out animation timing
**Choice**: Use NSTimer to trigger fade-out at 17 seconds, then NSAnimationContext for 3 second fade animation.

**Rationale**:
- Clean separation: Timer schedules the fade, NSAnimationContext handles the animation
- Manual dismiss and session end should hide immediately (no fade) by cancelling timer and setting alphaValue to 0
- Fade during auto-hide provides visual warning that banner is disappearing

**Alternatives considered**:
- Single timer checking every frame: More complex, less efficient
- Fade entire duration: Too distracting, defeats purpose of displaying URL clearly

### Decision 5: WebSocket message format
**Choice**: Expect training-assistant daemon to send JSON messages with the following structure:
```json
{"type": "session_started", "participant_url": "https://interact.victorrentea.ro/abc123"}
{"type": "session_ended"}
```

**Rationale**:
- Consistent with typical JSON-based WebSocket protocols
- `type` field allows for future message types
- `participant_url` includes full URL, AppDelegate strips protocol as needed
- Single `session_started` event covers both initial start and resume cases (simpler state machine)

## Risks / Trade-offs

**[Risk]** Banner may overlap with menu bar or other UI elements
→ **Mitigation**: Position banner just below menu bar with appropriate padding. Test on multiple screen sizes.

**[Risk]** Training-assistant daemon changes to WebSocket protocol are outside this repo's control
→ **Mitigation**: Document expected message format clearly. Add error handling for unexpected message types.

**[Risk]** User may miss banner if it auto-hides while they're looking away
→ **Mitigation**: 20 second timeout provides reasonable window. User can click menu item again to re-show banner.

**[Trade-off]** Auto-hide timer starts on show, not on last interaction
→ **Accepted**: Simpler implementation. Banner serves as temporary display, not interactive element.

**[Trade-off]** Fade-out animation only on auto-hide, not on manual/session-end dismiss
→ **Accepted**: Manual dismiss and session end should be instant for responsiveness. Fade is only for auto-hide to provide gentle visual warning.

## Migration Plan

**Deployment steps:**
1. Update AppDelegate to handle new WebSocket messages (session_started, session_ended) and store session state
2. Add JoinLinkBanner class as NSPanel subclass
3. Update MenuBarManager to add "Display join link" menu item
4. Wire up callbacks between AppDelegate and MenuBarManager
5. Run `swift build` and `swift test`
6. Run `build-app.sh` to rebuild app bundle
7. Test with training-assistant daemon sending new WebSocket messages
8. Update training-assistant daemon to send new WebSocket messages (external coordination required)

**Rollback strategy:**
- If changes cause issues, revert Swift code changes and rebuild
- Menu item can be left in place (will remain disabled) if WebSocket messages are not being sent
- Session state is in-memory only, no cleanup needed

## Open Questions

**Q**: Should the banner be dismissible by clicking on it?
**A**: No - keep it simple. Auto-hide after 20s or session_ended event. User can also click menu item to toggle.

**Q**: What should happen if desktop-overlay WebSocket disconnects while session is active?
**A**: Existing WebSocket reconnection logic should handle this. Session state persists in AppDelegate until explicit session_ended message received.

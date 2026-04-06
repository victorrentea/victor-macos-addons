## 1. AppDelegate: WebSocket message handling and session state

- [x] 1.1 Add session state properties to AppDelegate (isSessionActive: Bool, participantUrl: String?)
- [x] 1.2 Add WebSocket message handlers in receiveMessage for session_started and session_ended message types
- [x] 1.3 Implement session state updates on received WebSocket messages (set isSessionActive, store/clear participantUrl)
- [x] 1.4 Add function to strip http:// or https:// prefix from participant URL
- [x] 1.5 Call MenuBarManager method to enable/disable "Display join link" menu item when session state changes

## 2. JoinLinkBanner: Banner UI component

- [x] 2.1 Create JoinLinkBanner.swift file with JoinLinkBanner class as NSPanel subclass
- [x] 2.2 Configure JoinLinkBanner to position at top of screen (just below menu bar), spanning full width
- [x] 2.3 Add semi-transparent background to JoinLinkBanner panel
- [x] 2.4 Add NSTextField to JoinLinkBanner for URL display with monospaced font (e.g., Monaco or SF Mono)
- [x] 2.5 Implement show(url: String) method that displays URL in NSTextField with full opacity (alphaValue = 1.0)
- [x] 2.6 Add Timer property that triggers fade-out animation at 17 seconds
- [x] 2.7 Implement startFadeOut() method using NSAnimationContext to animate alphaValue from 1.0 to 0.0 over 3 seconds
- [x] 2.8 Implement hide() method to cancel timers, stop any running animations, set alphaValue to 0, and remove banner from screen
- [x] 2.9 Ensure hide() works correctly whether called during visible state, fade-out animation, or after auto-hide completes

## 3. MenuBarManager: "Display join link" menu item

- [x] 3.1 Add "Display join link" menu item to MenuBarManager (initial state: disabled)
- [x] 3.2 Add onDisplayJoinLink callback property to MenuBarManager (called when menu item clicked)
- [x] 3.3 Add setJoinLinkEnabled(_ enabled: Bool) method to MenuBarManager to enable/disable menu item
- [x] 3.4 Track banner visibility state in MenuBarManager to support toggle behavior (show if hidden, hide if visible)

## 4. AppDelegate: Banner integration and wiring

- [x] 4.1 Add JoinLinkBanner instance property to AppDelegate
- [x] 4.2 Initialize JoinLinkBanner instance in applicationDidFinishLaunching
- [x] 4.3 Set MenuBarManager.onDisplayJoinLink callback to toggle banner (show with participantUrl if hidden, hide if visible)
- [x] 4.4 Update banner toggle logic to check session state (only show if isSessionActive is true)
- [x] 4.5 Auto-hide banner when session_ended event is received (call banner.hide() if banner is visible)

## 5. Testing and error handling

- [x] 5.1 Add error handling for unexpected WebSocket message types (log warning, don't crash)
- [x] 5.2 Handle edge case where user clicks menu item when session is inactive (no-op or show warning)
- [ ] 5.3 Test WebSocket message handling with mock messages (session_started, session_ended) - **Manual testing required**
- [ ] 5.4 Test banner display with various URL formats (with/without http/https prefix) - **Manual testing required**
- [ ] 5.5 Test banner positioning on multiple screen sizes and resolutions - **Manual testing required**
- [ ] 5.6 Test menu item enabled/disabled state updates when session state changes - **Manual testing required**
- [ ] 5.7 Test banner toggle behavior (click to show, click again to hide) - **Manual testing required**
- [ ] 5.8 Test 20 second auto-hide with fade-out (banner visible for 17s, fades over last 3s) - **Manual testing required**
- [ ] 5.9 Test fade-out animation smoothness and timing - **Manual testing required**
- [ ] 5.10 Test timer cancellation when banner is manually hidden or session ends (no fade, instant hide) - **Manual testing required**
- [ ] 5.11 Test manual hide during fade-out animation (should stop fade and hide immediately) - **Manual testing required**

## 6. Documentation and deployment

- [x] 6.1 Document expected WebSocket message format in code comments
- [x] 6.2 Update CLAUDE.md with new "Display join link" feature description
- [x] 6.3 Run swift build and swift test for VictorAddons
- [x] 6.4 Run build-app.sh to create updated app bundle
- [ ] 6.5 Test app bundle launches correctly with new functionality - **User to verify**
- [x] 6.6 Coordinate with training-assistant daemon team on WebSocket message implementation - **handover.md created**

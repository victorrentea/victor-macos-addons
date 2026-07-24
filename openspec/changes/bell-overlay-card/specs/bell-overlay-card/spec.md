## ADDED Requirements

### Requirement: A bell plays a sound and shows a persistent bottom-left card
When the overlay receives a bell (via `onBellRing(caller)`), it SHALL play a bell sound and SHALL show a bottom-left card carrying the caller's name. The card SHALL be persistent — it SHALL NOT auto-fade on a timer — and SHALL remain until the host dismisses it by hovering.

#### Scenario: Bell shows the card and plays a sound
- **WHEN** the overlay receives `onBellRing("Ana Pop")`
- **THEN** it SHALL play a bell sound
- **AND** SHALL show a bottom-left card containing the caller's name

#### Scenario: Card persists until hover
- **WHEN** a bell card is showing and no interaction occurs
- **THEN** the card SHALL remain on screen indefinitely (no auto-fade timer)

#### Scenario: Hover dismisses the card
- **WHEN** the host moves the cursor over the bell card
- **THEN** the card SHALL dismiss with the sinking "put away" animation

### Requirement: Card copy is exactly the specified wording
The bell card text SHALL be exactly `🔔 [Name] is calling you` with the caller's name substituted for `[Name]`.

#### Scenario: Card wording with a real name
- **WHEN** the caller name is "Ana Pop"
- **THEN** the card SHALL read `🔔 Ana Pop is calling you`

### Requirement: Multiple bells stack rather than overwrite
When more than one bell arrives close together, the overlay SHALL keep each bell visible (a small stack) rather than replacing an existing card, so a second caller is not silently lost.

#### Scenario: Two bells are both visible
- **WHEN** a bell from "Ana" is showing and a bell from "Dan" arrives
- **THEN** both callers SHALL be represented on screen (as a small stack or a coalesced card), not just the latest

### Requirement: Card reaches the host over fullscreen presentation
The bell card SHALL be shown via the app's own always-on-top overlay (not a native macOS notification), so it appears even while PowerPoint is presenting fullscreen or mirroring to a projector.

#### Scenario: Bell shown during fullscreen slides
- **WHEN** a bell arrives while PowerPoint is presenting fullscreen on the projected display
- **THEN** the bell card SHALL still appear (the always-on-top overlay is not suppressed the way a native notification would be)

### Requirement: Headless test hook previews the card
The app SHALL expose a `GET /test/bell` HTTP hook (via the local test server) that shows a bell card with a sample caller name immediately, bypassing the need for a live daemon connection, for headless verification without stealing UI focus.

#### Scenario: Test hook shows a sample card
- **WHEN** `GET /test/bell` is requested
- **THEN** the overlay SHALL show a bell card with a sample name so it can be verified on the right-hand external screen

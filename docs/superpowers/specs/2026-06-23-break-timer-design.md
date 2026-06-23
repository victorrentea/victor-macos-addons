# Break Timer Overlay — Design

**Date:** 2026-06-23
**Status:** Approved (design), pending implementation plan

## Summary

A new **☕️ Break** menu in the menu-bar app whose submenu offers fixed
durations. Clicking a duration shows a draggable, resizable digital countdown
"watch" overlay on the desktop. The overlay counts down in cyan seven-segment
digits over a semi-transparent black background, shows the wall-clock finish
time in two timezones, and provides small in-overlay controls (close, pause,
add-minutes). When the countdown reaches zero it gongs twice, blinks twice, and
fades away.

## Menu

Top-level item **☕️ Break** with a submenu of durations:

- `5 minutes`
- `7 minutes`
- `10 minutes`
- `12 minutes`
- `15 minutes`
- `45 minutes`
- `1 hour`

Each item invokes a new `MenuBarManager.onBreak: ((Int) -> Void)?` callback with
the duration in **minutes**. Placement: as a top-level menu item near the
`⭐️ Effects` submenu (exact position easy to adjust).

## Components

New file `Sources/VictorAddons/BreakTimerOverlay.swift` containing:

### `BreakTimerPanel : NSPanel`
- Borderless, `.nonactivatingPanel`, transparent (`isOpaque = false`,
  `backgroundColor = .clear`, `hasShadow = false`).
- Floats above everything: `level` = maximum window level (same as
  `OverlayPanel`).
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
  .ignoresCycle]` so it shows over all spaces. **Not** `.stationary` — it must
  move when dragged.
- **Accepts mouse events** (the key difference from `OverlayPanel`, which sets
  `ignoresMouseEvents = true`).

### `BreakTimerView : NSView`
- Draws the rounded background: black at **20% opacity** (80% transparent).
- Draws the big cyan **seven-segment** `MM:SS` digits (fully opaque) with faint
  "ghost" unlit segments behind them, like the reference image.
- Draws the two finish-time labels (see Look & Layout).
- Hosts the small control buttons (bottom-right).
- Handles **drag vs. corner-resize** hit-testing in `mouseDown`/`mouseDragged`:
  - Pointer within ~16 px of a corner → resize that corner.
  - Pointer on a button → the button handles the click (no drag).
  - Pointer anywhere else on the body → move the whole window.
- All elements (digit size, label size, button size, corner radius) scale with
  the window size.

### `BreakTimerController`
- Owns the single panel instance and the 1-second countdown `Timer`.
- State: `remainingSeconds`, `paused`, current window frame.
- API:
  - `start(minutes:)` — open or reuse the window, set remaining, start counting.
  - `addMinutes(_:)` — extend remaining (and thus push finish time later).
  - `togglePause()` — freeze/continue.
  - `close()` — tear down window + timer.
- Single instance: only one timer window exists at a time.

### `BreakTimerModel` (pure, unit-tested)
- `format(remaining:) -> String` — seconds → `MM:SS`, where minutes may exceed
  59 (e.g. `60:00` for one hour, counting down to `00:00`).
- `finishDate(now:remaining:) -> Date` — `now + remaining`.
- Timezone formatting helpers — finish time as `h:mm a` plus a timezone label,
  for both the local timezone and CET.

## Behavior

### Open / re-click
- **Fresh open** (window not currently shown): appears at the **default
  position** — top-right of the **main screen**, width = **25% of the main
  screen width**, height derived from the content aspect ratio, with a small
  margin from the screen edges. No persistence across app restarts (the window
  is draggable, so repositioning is cheap).
- **Re-click while already open**: the window stays exactly where it is (keep
  position & size); only the remaining time resets to the newly chosen duration
  and counting restarts.

### Drag
- Click anywhere on the body (except a button or corner zone) and drag — moves
  the window to any position on **any screen**.

### Resize
- Drag any of the **4 corners** to resize.
- **Aspect ratio is locked** during resize so it always looks like a watch.
- A minimum size is enforced.
- All content scales proportionally to the window.

### Controls (small, subtle cyan buttons, bottom-right like the reference)
- **✕** — close the timer immediately.
- **⏸ / ▶** — pause ↔ resume. While paused the countdown freezes and the
  finish-time displays freeze (they do not slide forward).
- **+1m / +3m / +5m** — add that many minutes to the remaining time; the finish
  time displays move later accordingly. Work whether running or paused.

### Expiry sequence (at `00:00`)
1. Gong strike #1 (`50_gong.mp3`).
2. Digits blink #1 (off→on).
3. Gong strike #2.
4. Digits blink #2 (off→on).
5. Fade out (~0.5 s) and close the window.

Exact inter-step timing is tunable; the two gongs are two distinct audible
strikes and the digits blink twice before the fade.

## Look & Layout

- Background: black at 20% opacity, rounded corners. All digits/text fully
  opaque.
- Center: large cyan seven-segment `MM:SS`, with ghost (dim) segments behind.
- Bottom-left, stacked:
  - Local finish time + local timezone label, e.g. `5:10 PM EEST`.
  - CET finish time + `CET`/`CEST` label, e.g. `4:10 PM CEST`.
  - Finish time = current time + remaining; recomputed while running, frozen
    while paused.
- Bottom-right: the five small control buttons.
- Local timezone uses `TimeZone.current`; CET uses `TimeZone(identifier:
  "Europe/Paris")`.

## Digit rendering

Custom Core Graphics seven-segment drawing (chosen over bundling a TTF font or
using a plain monospaced font):

- Each digit drawn as 7 segments; lit segments bright cyan, unlit segments a
  faint cyan ghost — reproduces the reference look exactly.
- Scales crisply at any window size; no external font asset or licensing to
  bundle.

## Wiring

- `MenuBarManager`: build the `☕️ Break` submenu; add `onBreak: ((Int) -> Void)?`
  and an `@objc` action that reads the duration from the menu item's
  `representedObject`.
- `AppDelegate`: instantiate a `BreakTimerController`; set
  `menuBarManager.onBreak = { minutes in controller.start(minutes: minutes) }`.

## Testing

- `BreakTimerModel` unit tests (in the existing `swift test` suite):
  - `MM:SS` formatting, including minutes ≥ 60 (e.g. `60:00`, `45:00`, `07:00`).
  - `finishDate` math (now + remaining).
  - Dual-timezone finish-time formatting (local + CET) with stable, injectable
    `now` and timezones.
- Window/drag/resize behavior verified manually after `./build-app.sh` and app
  restart.

## Out of scope

- Persisting window position/size across app restarts.
- Sound other than the existing `50_gong.mp3`.
- Per-screen default positioning (default is always the main screen).

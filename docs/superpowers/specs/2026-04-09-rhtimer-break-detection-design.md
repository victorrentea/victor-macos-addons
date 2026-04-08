# RH Timer Break Detection — Design

**Date:** 2026-04-09

## Problem

During training workshops, the trainer gives breaks using RH Timer (macOS app "Timer RH"). When the countdown ends, RH Timer hides its window. The trainer often forgets exactly when the break ended and when the session resumed.

## Goal

Automatically detect when the RH Timer window disappears and show a live "Resumed Xm ago" entry in the menu bar app, so the trainer always knows how long ago the break ended.

## Detection Mechanism

`CGWindowListCopyWindowInfo` is polled every **30 seconds**. The signal is the window owned by `"Timer RH"` with name `"Timers"` and `kCGWindowIsOnscreen == true`. Experimentally confirmed:

- Timer visible → `kCGWindowIsOnscreen = true`
- Timer hidden → `kCGWindowIsOnscreen = nil/false`

On a `true → false` transition, `breakEndedAt` is recorded as the current timestamp.

## Components

### `RHTimerMonitor` (new class)

- Starts a repeating `Timer` every 30 seconds
- Queries CGWindowList for `"Timer RH"` / `"Timers"` window onscreen status
- Tracks `wasVisible: Bool` (previous state)
- On `true → false` transition: fires `onBreakEnded: (() -> Void)?`
- Runs for the lifetime of the app

### Menu item in `MenuBarManager`

- Placed **above** the Transcribe toggle
- Stores `breakEndedAt: Date?`
- In `menuNeedsUpdate`:
  - Hidden if `breakEndedAt` is nil
  - Hidden if `breakEndedAt` is more than **3 hours** ago (assumed not in training)
  - Otherwise shows `"Resumed Xm ago"` (e.g. `"Resumed 8m ago"`, `"Resumed 1h 3m ago"`)
- Item is always disabled (display only)

### Wiring in `AppDelegate`

- Creates and starts `RHTimerMonitor`
- Wires `onBreakEnded` to set `breakEndedAt` on `MenuBarManager`

## Format of elapsed time

- Under 60 minutes: `"Resumed 8m ago"`
- 60 minutes or more: `"Resumed 1h 3m ago"`

## Out of scope

- Persisting `breakEndedAt` across app restarts
- Detecting break start (only end matters)
- Multiple break tracking (only the last break is shown)

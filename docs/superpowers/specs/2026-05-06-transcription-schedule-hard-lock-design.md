# Transcription Schedule — Hard Lock + Notifications

**Date:** 2026-05-06
**Component:** `MenuBarManager`, `AppDelegate`, `TranscriptionScheduler`

## Problem

Today, during the work window (Mon–Fri 09:00–17:59) the transcription menu item is still
clickable. A stop click is silently dropped with an overlay banner ("🔒 Transcription
locked…"); a start click is honored as a recovery path. The user wants the menu item
to be visibly **disabled** during the window — neither start nor stop should be
options. They also want lightweight macOS notifications at the schedule boundaries
instead of the existing overlay banner.

## Requirements

1. **Menu disabled in window.** During Mon–Fri 09:00–17:59, the transcribe menu item
   shows `🔒 Transcribing 9–18` and is disabled (`isEnabled = false`).
2. **Menu enabled outside window.** Outside the window the existing Start/Stop
   behavior applies unchanged.
3. **Auto-on at 09:00.** Unchanged from today — battery guard still applies (do not
   start on battery, per the project's battery rule).
4. **Auto-off at 18:00.** Unchanged — stop and clear `transcribingEnabled`.
5. **Notifications at boundaries.** A non-persistent macOS notification fires only on
   actual state transitions:
   - 09:00 → "Transcribing started" — only if `ensureOn` actually started Whisper
     (i.e. it was off and not battery-blocked).
   - 18:00 → "Transcribing stopped" — only if `forceOff` actually stopped a running
     Whisper.
   - The existing `overlayInfo("🌙 18:00 …")` banner is removed.
6. **Recovery during the window.** The 60s heartbeat in `TranscriptionScheduler`
   already restarts a crashed Whisper. The previous "click start to recover"
   affordance is no longer needed and is removed.

## Design

### MenuBarManager

`updateTranscribeTitle()` gets a new branch checked **before** the existing
battery/source branches:

```swift
if TranscriptionScheduler.isLockedOn() {
    transcribeItem.title = "🔒 Transcribing 9–18"
    transcribeItem.isEnabled = false
    return
}
```

The function is already invoked when state changes; we additionally call it from
`refreshDynamicItems()` so the enabled state is correct each time the menu opens
(no extra timer needed).

### AppDelegate

`toggleTranscription` loses its `if TranscriptionScheduler.isLockedOn() { … }`
block. The menu cannot invoke the callback while locked; the test endpoints
retain their own lock check, which is unchanged.

`scheduler.ensureOn` returns a `Bool` (or sets a captured flag) indicating
whether it actually started Whisper. On a true transition, post a notification
"Transcribing started". The battery and `isRunning` guards are unchanged.

`scheduler.forceOff` likewise notifies "Transcribing stopped" only when it
actually stopped Whisper. The `overlayInfo("🌙 18:00 — transcription
auto-stopped")` line is deleted.

A new helper `postScheduleNotification(title:body:)` mirrors
`postPowerNotification` (default sound, 10s auto-clear).

### TranscriptionScheduler

No structural change. The closures' return value can stay `Void` if AppDelegate
captures a "did transition" flag inside the closure body using the same
`whisperManager?.isRunning` / battery checks it already has.

## Out of Scope

- Test HTTP endpoints — current lock check there is unchanged.
- Battery rule — unchanged.
- Persisted preference (`transcribingEnabled`) semantics — unchanged.

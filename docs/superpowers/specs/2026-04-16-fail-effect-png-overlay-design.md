# Fail Effect: Display Latest Downloads PNG

**Date:** 2026-04-16
**Scope:** New tablet-triggered overlay effect tied to `fail.mp3` (sfx #19 on the tablet).

## Goal

When the trainer taps the `fail.mp3` button on the Android tablet (sfx index 19, 1-indexed), the Mac displays the most-recent PNG file from `~/Downloads`, centered on screen, scaled to 50% of screen height, for the duration of the sound (~3.2s).

## Trigger Flow

1. **Tablet** (`victor-android/.../MainActivity.kt`): `fail.mp3` already plays locally on tap. Add `"fail.mp3" -> macEffect("fail")` to the `when` block (~line 324) so it also calls `GET http://Victor-Mac.local:55123/effect/fail`.
2. **Mac** (`TabletHttpServer`): already routes `/effect/<name>` → `onEffect("fail")`. No change.
3. **AppDelegate** (`Sources/VictorAddons/AppDelegate.swift:101-115`): add `case "fail": self?.animator.showFail()` to the existing switch.
4. **EmojiAnimator** (`Sources/VictorAddons/EmojiAnimator.swift`): new `showFail()` method.

## `showFail()` Behavior

- Look up the most-recent `.png` in `~/Downloads` by file modification time.
- If none → log via `overlayInfo` and return (silent no-op; sound still plays on tablet).
- Load as `NSImage`. If load fails → log + return.
- Compute target size: `height = screen.height * 0.5`, width preserves aspect ratio.
- Display centered on screen using the existing `overlayView` (mirrors patterns in `showFear`, `showGameOver`).
- Use `trackEffect("fail", layer: ..., duration: 3.2)` so a second tap during playback is a no-op (consistent with other effects).
- Fade out over 0.3s at the tail.

## Constants

- Sound duration: **3.2s** (matches `fail.mp3` measured via `afinfo`). Hardcoded; if the sound is later swapped, this is updated alongside.
- Image height: **50% of screen height**.

## Edge Cases

- **No PNG in Downloads** → silent no-op, log only.
- **PNG fails to load** → silent no-op, log only.
- **Multiple monitors** → use the screen the overlay window is currently on (existing convention).
- **Re-tap during playback** → ignored (covered by `trackEffect`).

## Files Touched

- `victor-android/app/src/main/java/ro/victorrentea/helloworld/MainActivity.kt` (1 line added).
- `victor-macos-addons/Sources/VictorAddons/AppDelegate.swift` (1 case added).
- `victor-macos-addons/Sources/VictorAddons/EmojiAnimator.swift` (~30 lines: new method).

## Out of Scope

- Filtering by alpha channel (any PNG accepted).
- Reading the sound's actual duration at runtime.
- Tablet-side UI changes beyond the single mapping line.

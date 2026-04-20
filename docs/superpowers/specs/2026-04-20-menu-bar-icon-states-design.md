# Menu Bar Icon States Design

**Date:** 2026-04-20  
**Status:** Approved

## Overview

Enhance the menu bar icon to visually reflect all transcription states using SF Symbol badges drawn programmatically over the existing base icons.

## States

| State | Base Icon | Badge (bottom-right, 6×6pt) |
|---|---|---|
| Running — normal | `icon_chat.png` (template) | SF Symbol for active source |
| Running — stale | `icon_chat.png` | `⚠️` emoji (unchanged) |
| Paused by battery | `pause.fill` SF Symbol (programmatic) | `bolt.fill`, yellow |
| Stopped manually | `icon_chat_off.png` (red, no template) | none |

## Source Badge Mapping

`transcribeSource` is an emoji string sent by Python via `VICTOR_SOURCE:` prefix. Swift maps it to a SF Symbol for the badge:

| Emoji | SF Symbol name | Device |
|---|---|---|
| `💻` | `laptopcomputer` | MacBook built-in mic |
| `🎙️` | `mic.fill` | XLR / stage mic |
| `🎧` | `headphones` | Bose / headphones |
| `🎤` | `mic.circle.fill` | DJI / unknown |

## Battery-Pause State

A new `isPausedByBattery: Bool` flag is added to `MenuBarManager`.  
`AppDelegate` sets it:
- `onSwitchToBattery`: `setTranscribing(false)` + `setPausedByBattery(true)`
- `onSwitchToAC`: `setPausedByBattery(false)` + `setTranscribing(true)`

Icon for this state: `pause.fill` SF Symbol (full size, ~14pt) centered in 18pt canvas, with a `bolt.fill` badge (6pt) in bottom-right corner, tinted yellow.

## Icon Rendering

All compositing is done in `refreshMenuIcon()` in `MenuBarManager.swift`.  
A new private helper `makeCompositeIcon(base:badgeSymbol:badgeColor:)` handles:
1. Draw base image (either `NSImage` from PNG or SF Symbol) into 18×18pt canvas
2. Draw badge SF Symbol at 6×6pt in bottom-right corner with specified color

For battery-pause, no PNG base is needed — draw `pause.fill` SF Symbol directly as the base at full size.

## Python Changes

Add `"dji": "🎤"` to `_DEVICE_SHORT_NAMES` in `whisper_runner.py`.  
The DJI mic device name substring needs to be verified against actual device string (likely `"dji"`).

## Badge Dimensions

- Canvas: 18×18pt (36×36px at 2x Retina)
- Badge: 6×6pt = bottom-right 1/3 of canvas
- Badge origin: `(12pt, 0pt)` from canvas bottom-left

## Files Changed

- `Sources/VictorAddons/MenuBarManager.swift` — new states, new `isPausedByBattery` flag, refactored `refreshMenuIcon()`, new `makeCompositeIcon()` helper
- `Sources/VictorAddons/AppDelegate.swift` — wire `setPausedByBattery` calls in `PowerMonitor` callbacks
- `whisper-transcribe/whisper_runner.py` — add DJI entry to `_DEVICE_SHORT_NAMES`

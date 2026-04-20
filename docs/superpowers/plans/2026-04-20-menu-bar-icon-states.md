# Menu Bar Icon States Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance menu bar icon to show source badge when transcribing, pause+lightning when paused by battery, and keep existing stopped/stale states.

**Architecture:** Add `isPausedByBattery` flag to `MenuBarManager`, refactor `refreshMenuIcon()` to dispatch on all 5 states, add `makeCompositeIcon()` helper for SF Symbol badge rendering, wire AppDelegate PowerMonitor callbacks, add DJI device mapping to Python.

**Tech Stack:** Swift, AppKit, SF Symbols (macOS 12+), Python 3.12

---

## Files

| File | Change |
|---|---|
| `Sources/VictorAddons/MenuBarManager.swift` | Add `isPausedByBattery`, `setPausedByBattery()`, `makeCompositeIcon()`, `sourceBadgeSymbol()`, refactor `refreshMenuIcon()`, update `transcriptionDebugState()` |
| `Sources/VictorAddons/AppDelegate.swift` | Wire `setPausedByBattery` in PowerMonitor callbacks |
| `whisper-transcribe/whisper_runner.py` | Add `"dji"` entry to `_DEVICE_SHORT_NAMES` |
| `Tests/VictorAddonsTests/MenuBarIconTests.swift` | New: unit tests for `transcriptionDebugState()` covering all states |

---

## Task 1: Add DJI device name to Python

**Files:**
- Modify: `whisper-transcribe/whisper_runner.py:178-183`

- [ ] **Step 1: Add DJI entry**

In `whisper_runner.py`, update `_DEVICE_SHORT_NAMES`:

```python
_DEVICE_SHORT_NAMES = {
    "xlr": "🎙️",
    "bose": "🎧",
    "vic bose": "🎧",
    "macbook": "💻",
    "dji": "🎤",
}
```

- [ ] **Step 2: Commit**

```bash
git add whisper-transcribe/whisper_runner.py
git commit -m "feat(whisper): add DJI mic device name mapping"
```

---

## Task 2: Add `isPausedByBattery` state to MenuBarManager

**Files:**
- Modify: `Sources/VictorAddons/MenuBarManager.swift`
- Create: `Tests/VictorAddonsTests/MenuBarIconTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/VictorAddonsTests/MenuBarIconTests.swift`:

```swift
import XCTest
@testable import VictorAddons

final class MenuBarIconTests: XCTestCase {

    func testIconModeOffWhenNotTranscribing() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(false)
        XCTAssertEqual(mgr.transcriptionDebugState().iconMode, "off")
    }

    func testIconModeBatteryPauseWhenPausedByBattery() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(false)
        mgr.setPausedByBattery(true)
        XCTAssertEqual(mgr.transcriptionDebugState().iconMode, "battery_pause")
    }

    func testIconModeOffAfterBatteryPauseCleared() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(false)
        mgr.setPausedByBattery(true)
        mgr.setPausedByBattery(false)
        XCTAssertEqual(mgr.transcriptionDebugState().iconMode, "off")
    }

    func testIconModeOnWhenTranscribing() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(true)
        XCTAssertEqual(mgr.transcriptionDebugState().iconMode, "on")
    }

    func testIconModeStaleWhenTranscribingAndStale() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(true)
        mgr.setTranscriptionStale(true)
        XCTAssertEqual(mgr.transcriptionDebugState().iconMode, "stale")
    }

    func testBatteryPauseClearedWhenTranscribingResumes() {
        let mgr = MenuBarManager()
        mgr.setTranscribing(false)
        mgr.setPausedByBattery(true)
        mgr.setTranscribing(true)
        XCTAssertFalse(mgr.transcriptionDebugState().isPausedByBattery)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/victorrentea/workspace/victor-macos-addons
swift test --filter MenuBarIconTests 2>&1 | tail -20
```

Expected: compile error — `setPausedByBattery` not found, `isPausedByBattery` not found.

- [ ] **Step 3: Add property and method to MenuBarManager**

In `MenuBarManager.swift`, add after `private var isTranscriptionStale: Bool = false` (line ~29):

```swift
private var isPausedByBattery: Bool = false
```

In the `transcriptionDebugState()` method, add `isPausedByBattery` to `TranscriptionDebugState` struct and its return — change the struct (lines ~8-14) to:

```swift
struct TranscriptionDebugState {
    let isTranscribing: Bool
    let isStale: Bool
    let isPausedByBattery: Bool
    let source: String
    let menuTitle: String
    let iconMode: String
}
```

Update `transcriptionDebugState()` return:

```swift
func transcriptionDebugState() -> TranscriptionDebugState {
    let iconMode: String
    if isTranscribing && isTranscriptionStale {
        iconMode = "stale"
    } else if isTranscribing {
        iconMode = "on"
    } else if isPausedByBattery {
        iconMode = "battery_pause"
    } else {
        iconMode = "off"
    }
    return TranscriptionDebugState(
        isTranscribing: isTranscribing,
        isStale: isTranscriptionStale,
        isPausedByBattery: isPausedByBattery,
        source: transcribeSource,
        menuTitle: transcribeItem.title,
        iconMode: iconMode
    )
}
```

Add new public method after `setTranscriptionStale(_:)`:

```swift
func setPausedByBattery(_ paused: Bool) {
    isPausedByBattery = paused
    refreshMenuIcon()
}
```

Also update `setTranscribing(_:)` to clear battery pause when transcription resumes:

```swift
func setTranscribing(_ active: Bool) {
    isTranscribing = active
    if active { isPausedByBattery = false }
    updateTranscribeTitle()
    refreshMenuIcon()
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter MenuBarIconTests 2>&1 | tail -20
```

Expected: all 6 tests PASS. If `transcribeItem` is nil (no menu built), tests may crash — `MenuBarManager.setup()` builds the menu. But these tests only call `setTranscribing`/`setPausedByBattery`/`transcriptionDebugState`, not `transcribeItem`... wait, `updateTranscribeTitle()` accesses `transcribeItem`. Add a guard in `updateTranscribeTitle()`:

```swift
private func updateTranscribeTitle() {
    guard transcribeItem != nil else { return }
    let suffix = transcribeSource.isEmpty ? "" : " \(transcribeSource)"
    transcribeItem.title = isTranscribing ? "Stop Transcribing\(suffix)" : "Start Transcribing"
}
```

Re-run if needed:

```bash
swift test --filter MenuBarIconTests 2>&1 | tail -20
```

Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/MenuBarManager.swift Tests/VictorAddonsTests/MenuBarIconTests.swift
git commit -m "feat(icon): add isPausedByBattery state to MenuBarManager"
```

---

## Task 3: Wire AppDelegate PowerMonitor callbacks

**Files:**
- Modify: `Sources/VictorAddons/AppDelegate.swift:182-193`

- [ ] **Step 1: Update onSwitchToBattery**

Replace the existing `pm.onSwitchToBattery` block (~line 182) with:

```swift
pm.onSwitchToBattery = { [weak self, weak whisperManager] in
    guard whisperManager?.isRunning == true else { return }
    self?.autoStoppedByBattery = true
    stopTranscription()
    self?.menuBarManager.setPausedByBattery(true)
    self?.postPowerNotification("Transcription paused — on battery")
}
```

- [ ] **Step 2: Update onSwitchToAC**

Replace the existing `pm.onSwitchToAC` block (~line 188) with:

```swift
pm.onSwitchToAC = { [weak self] in
    guard self?.autoStoppedByBattery == true else { return }
    self?.autoStoppedByBattery = false
    self?.menuBarManager.setPausedByBattery(false)
    startTranscription()
    self?.postPowerNotification("Transcription resumed — plugged in")
}
```

Note: `setPausedByBattery(false)` is called before `startTranscription()` so the icon goes from `battery_pause` → `off` → `on` as `onStateChanged` fires from whisper.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/VictorAddons/AppDelegate.swift
git commit -m "feat(icon): wire setPausedByBattery in PowerMonitor callbacks"
```

---

## Task 4: Implement composite icon rendering

**Files:**
- Modify: `Sources/VictorAddons/MenuBarManager.swift` — `refreshMenuIcon()`, `makeWarnIcon()`, add `makeCompositeIcon()`, `makeSourceBadgeIcon()`, `makeBatteryPauseIcon()`, `sourceBadgeSymbol()`

- [ ] **Step 1: Add `sourceBadgeSymbol()` helper**

Add after `makeWarnIcon()`:

```swift
private func sourceBadgeSymbol(for source: String) -> String {
    switch source {
    case "💻": return "laptopcomputer"
    case "🎙️": return "mic.fill"
    case "🎧": return "headphones"
    default: return "mic.circle.fill"
    }
}
```

- [ ] **Step 2: Add `makeCompositeIcon()` helper**

Add after `sourceBadgeSymbol()`:

```swift
private func makeCompositeIcon(base: NSImage, badgeSymbolName: String, badgeColor: NSColor) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let result = NSImage(size: size)
    result.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    let badgeRect = NSRect(x: 12, y: 0, width: 6, height: 6)
    let badgeConfig = NSImage.SymbolConfiguration(paletteColors: [badgeColor])
    if let badge = NSImage(systemSymbolName: badgeSymbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(badgeConfig) {
        badge.draw(in: badgeRect)
    }
    result.unlockFocus()
    return result
}
```

- [ ] **Step 3: Add `makeBatteryPauseIcon()` helper**

Add after `makeCompositeIcon()`:

```swift
private func makeBatteryPauseIcon() -> NSImage? {
    let size = NSSize(width: 18, height: 18)
    let result = NSImage(size: size)
    result.lockFocus()
    let pauseConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
    if let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(pauseConfig) {
        pause.draw(in: NSRect(x: 1, y: 2, width: 12, height: 14))
    }
    let boltConfig = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(boltConfig) {
        bolt.draw(in: NSRect(x: 12, y: 0, width: 6, height: 6))
    }
    result.unlockFocus()
    return result
}
```

- [ ] **Step 4: Refactor `refreshMenuIcon()`**

Replace the entire `refreshMenuIcon()` method with:

```swift
private func refreshMenuIcon() {
    guard let button = statusItem.button else { return }

    // 1. Stopped manually
    if !isTranscribing && !isPausedByBattery {
        if let url = Bundle.module.url(forResource: "icon_chat_off", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        }
        return
    }

    // 2. Paused by battery
    if !isTranscribing && isPausedByBattery {
        button.image = makeBatteryPauseIcon()
        return
    }

    // 3. Running + stale
    if isTranscriptionStale {
        button.image = makeWarnIcon()
        return
    }

    // 4. Running + source badge
    guard let url = Bundle.module.url(forResource: "icon_chat", withExtension: "png"),
          let base = NSImage(contentsOf: url) else { return }
    base.size = NSSize(width: 18, height: 18)

    if transcribeSource.isEmpty {
        base.isTemplate = true
        button.image = base
    } else {
        let symbolName = sourceBadgeSymbol(for: transcribeSource)
        button.image = makeCompositeIcon(base: base, badgeSymbolName: symbolName, badgeColor: .labelColor)
    }
}
```

- [ ] **Step 5: Build and run all tests**

```bash
swift build 2>&1 | tail -10
swift test 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/VictorAddons/MenuBarManager.swift
git commit -m "feat(icon): SF Symbol source badge and battery-pause icon"
```

---

## Task 5: Deploy and smoke test

- [ ] **Step 1: Push, build app, restart**

```bash
git push
./build-app.sh
pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"
```

- [ ] **Step 2: Verify running state with source badge**

Start transcription from menu. Check menu bar icon shows chat bubble with small source icon in bottom-right corner. The source badge should match the active device (laptop, mic, headphones).

```bash
curl -s http://127.0.0.1:55123/test/state | python3 -m json.tool
```

Expected: `"iconMode": "on"`, `"source"` is non-empty.

- [ ] **Step 3: Verify stopped state**

Stop transcription from menu. Icon should show crossed-out chat bubble (red).

```bash
curl -s http://127.0.0.1:55123/test/state | python3 -m json.tool
```

Expected: `"iconMode": "off"`.

- [ ] **Step 4: Note on battery-pause visual test**

Battery-pause state (`iconMode: "battery_pause"`) can only be triggered by actually unplugging the Mac while transcription is running. Verify visually if convenient, otherwise trust the unit tests in Task 2.

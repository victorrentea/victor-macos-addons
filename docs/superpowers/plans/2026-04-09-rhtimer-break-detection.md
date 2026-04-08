# RH Timer Break Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when the RH Timer countdown window hides and show a live "Resumed Xm ago" menu item above the Transcribe toggle.

**Architecture:** A new `RHTimerMonitor` class polls the CGWindowList every 30s for the "Timer RH" / "Timers" window's onscreen status. On a visible→hidden transition it fires a callback that sets `breakEndedAt` on `MenuBarManager`, which then renders the elapsed time label dynamically in `menuNeedsUpdate`.

**Tech Stack:** Swift, AppKit, CoreGraphics (`CGWindowListCopyWindowInfo`)

---

## File Map

- **Create:** `Sources/VictorAddons/RHTimerMonitor.swift` — polling logic + transition detection
- **Create:** `Tests/VictorAddonsTests/RHTimerMonitorTests.swift` — unit tests for transition detection and time formatting
- **Modify:** `Sources/VictorAddons/MenuBarManager.swift` — add `breakEndedAt`, new menu item, update `refreshDynamicItems`
- **Modify:** `Sources/VictorAddons/AppDelegate.swift` — create monitor, wire `onBreakEnded`

---

## Task 1: `RHTimerMonitor` with injectable window checker

**Files:**
- Create: `Sources/VictorAddons/RHTimerMonitor.swift`
- Create: `Tests/VictorAddonsTests/RHTimerMonitorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VictorAddonsTests/RHTimerMonitorTests.swift`:

```swift
import XCTest
@testable import VictorAddons

final class RHTimerMonitorTests: XCTestCase {

    func testNoCallbackIfNeverVisible() {
        var fired = false
        let monitor = RHTimerMonitor(windowChecker: { false })
        monitor.onBreakEnded = { fired = true }
        monitor.checkOnce()
        monitor.checkOnce()
        XCTAssertFalse(fired)
    }

    func testNoCallbackIfAlwaysVisible() {
        var fired = false
        let monitor = RHTimerMonitor(windowChecker: { true })
        monitor.onBreakEnded = { fired = true }
        monitor.checkOnce()
        monitor.checkOnce()
        XCTAssertFalse(fired)
    }

    func testCallbackFiredOnVisibleToHiddenTransition() {
        var callCount = 0
        var isVisible = true
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        monitor.checkOnce()   // visible — no callback
        isVisible = false
        monitor.checkOnce()   // hidden after visible — fires callback
        XCTAssertEqual(callCount, 1)
    }

    func testCallbackFiredOnlyOnce() {
        var callCount = 0
        var isVisible = true
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        monitor.checkOnce()   // visible
        isVisible = false
        monitor.checkOnce()   // fires
        monitor.checkOnce()   // still hidden — no repeat
        XCTAssertEqual(callCount, 1)
    }

    func testCallbackFiredAgainAfterReappearance() {
        var callCount = 0
        var isVisible = false
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        isVisible = true
        monitor.checkOnce()   // visible
        isVisible = false
        monitor.checkOnce()   // fires (1)
        isVisible = true
        monitor.checkOnce()   // visible again
        isVisible = false
        monitor.checkOnce()   // fires (2)
        XCTAssertEqual(callCount, 2)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/victorrentea/workspace/victor-macos-addons
swift test --filter RHTimerMonitorTests 2>&1 | tail -20
```

Expected: compile error — `RHTimerMonitor` not found.

- [ ] **Step 3: Create `RHTimerMonitor.swift`**

```swift
import Foundation
import CoreGraphics

class RHTimerMonitor {
    var onBreakEnded: (() -> Void)?

    private let windowChecker: () -> Bool
    private var wasVisible: Bool = false
    private var timer: Timer?

    /// Production init — uses real CGWindowList
    convenience init() {
        self.init(windowChecker: RHTimerMonitor.isTimerWindowVisible)
    }

    /// Testable init — inject custom window checker
    init(windowChecker: @escaping () -> Bool) {
        self.windowChecker = windowChecker
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkOnce()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Exposed for testing; called by timer in production
    func checkOnce() {
        let isVisible = windowChecker()
        if wasVisible && !isVisible {
            onBreakEnded?()
        }
        wasVisible = isVisible
    }

    private static func isTimerWindowVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "Timer RH" &&
            (w[kCGWindowName as String] as? String) == "Timers" &&
            (w[kCGWindowIsOnscreen as String] as? Bool) == true
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter RHTimerMonitorTests 2>&1 | tail -10
```

Expected: `Test Suite 'RHTimerMonitorTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/RHTimerMonitor.swift Tests/VictorAddonsTests/RHTimerMonitorTests.swift
git commit -m "feat: add RHTimerMonitor with transition detection"
```

---

## Task 2: Elapsed time formatting (TDD)

**Files:**
- Modify: `Sources/VictorAddons/RHTimerMonitor.swift` — add `static func formatElapsed(_:) -> String`
- Modify: `Tests/VictorAddonsTests/RHTimerMonitorTests.swift` — add formatting tests

- [ ] **Step 1: Write the failing tests**

Append to `RHTimerMonitorTests`:

```swift
    func testFormatElapsedMinutesOnly() {
        XCTAssertEqual(RHTimerMonitor.formatElapsed(300), "Resumed 5m ago")
        XCTAssertEqual(RHTimerMonitor.formatElapsed(59), "Resumed 0m ago")
        XCTAssertEqual(RHTimerMonitor.formatElapsed(3540), "Resumed 59m ago")
    }

    func testFormatElapsedHoursAndMinutes() {
        XCTAssertEqual(RHTimerMonitor.formatElapsed(3600), "Resumed 1h ago")
        XCTAssertEqual(RHTimerMonitor.formatElapsed(3660), "Resumed 1h 1m ago")
        XCTAssertEqual(RHTimerMonitor.formatElapsed(5400), "Resumed 1h 30m ago")
        XCTAssertEqual(RHTimerMonitor.formatElapsed(7320), "Resumed 2h 2m ago")
    }
```

- [ ] **Step 2: Run to confirm they fail**

```bash
swift test --filter RHTimerMonitorTests 2>&1 | grep -E "error:|FAILED|passed"
```

Expected: compile error — `formatElapsed` not found.

- [ ] **Step 3: Add `formatElapsed` to `RHTimerMonitor.swift`**

Add this static method to `RHTimerMonitor`:

```swift
    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 3600 {
            return "Resumed \(seconds / 60)m ago"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m > 0 ? "Resumed \(h)h \(m)m ago" : "Resumed \(h)h ago"
    }
```

- [ ] **Step 4: Run tests**

```bash
swift test --filter RHTimerMonitorTests 2>&1 | tail -10
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/RHTimerMonitor.swift Tests/VictorAddonsTests/RHTimerMonitorTests.swift
git commit -m "feat: add elapsed time formatting to RHTimerMonitor"
```

---

## Task 3: Menu item in `MenuBarManager`

**Files:**
- Modify: `Sources/VictorAddons/MenuBarManager.swift`

- [ ] **Step 1: Add `breakEndedAt` and the menu item**

In `MenuBarManager`, add these two properties alongside the other `private` properties (after `private var sessionActive: Bool = false`):

```swift
    private(set) var resumeItem: NSMenuItem!
    var breakEndedAt: Date?
```

- [ ] **Step 2: Insert the menu item above `transcribeItem` in `buildMenu()`**

In `buildMenu()`, find the line:
```swift
        transcribeItem = addItem("Start Transcribing", action: #selector(toggleTranscribe))
```

Insert **before** it:

```swift
        resumeItem = addItem("Resumed …", action: nil)
        resumeItem.isEnabled = false
        resumeItem.isHidden = true
```

- [ ] **Step 3: Update `refreshDynamicItems()` to render the label**

At the end of `refreshDynamicItems()`, append:

```swift
        if let endedAt = breakEndedAt {
            let elapsed = Int(Date().timeIntervalSince(endedAt))
            if elapsed < 3 * 3600 {
                resumeItem.title = RHTimerMonitor.formatElapsed(elapsed)
                resumeItem.isHidden = false
            } else {
                resumeItem.isHidden = true
            }
        } else {
            resumeItem.isHidden = true
        }
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/MenuBarManager.swift
git commit -m "feat: add break resume menu item to MenuBarManager"
```

---

## Task 4: Wire monitor in `AppDelegate`

**Files:**
- Modify: `Sources/VictorAddons/AppDelegate.swift`

- [ ] **Step 1: Add `rhTimerMonitor` property**

In `AppDelegate`, add alongside the other private properties (e.g. after `private var ijMonitor`):

```swift
    private var rhTimerMonitor: RHTimerMonitor?
```

- [ ] **Step 2: Create and start monitor in `applicationDidFinishLaunching`**

Find the block where `menuBarManager` is created (around `menuBarManager = MenuBarManager()`). After `menuBarManager.setup()` is called, add:

```swift
        let rhMonitor = RHTimerMonitor()
        rhMonitor.onBreakEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.breakEndedAt = Date()
            }
        }
        rhMonitor.start()
        self.rhTimerMonitor = rhMonitor
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Run all tests**

```bash
swift test 2>&1 | tail -15
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/AppDelegate.swift
git commit -m "feat: wire RHTimerMonitor into AppDelegate"
```

---

## Task 5: Manual smoke test + build app

- [ ] **Step 1: Build and install the app**

```bash
./build-app.sh
```

- [ ] **Step 2: Smoke test**

1. Open RH Timer, start a short countdown (e.g. 10 seconds)
2. Wait for the timer to finish and its window to disappear (or manually close it after making it visible)
3. Open the Victor Addons menu bar — within 30s of the next poll, "Resumed Xm ago" should appear above "Start Transcribing"
4. Open the menu again a minute later — the counter should have incremented

- [ ] **Step 3: Commit build timestamp update**

After `build-app.sh` updates `BUILD_TIME` in `MenuBarManager.swift`:

```bash
git add Sources/VictorAddons/MenuBarManager.swift
git commit -m "chore: update build timestamp after RH Timer feature"
```

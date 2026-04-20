# Magnifier Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fullscreen screen magnifier triggered by Option+Scroll that Zoom meeting software captures — unlike native macOS Accessibility Zoom which operates post-compositor and is invisible to screen sharing.

**Architecture:** SCStream captures the built-in Retina display at 30fps; each frame's `IOSurface` is set as a fullscreen `NSPanel`'s `CALayer.contents`; `CALayer.contentsRect` (a normalized sub-rect) selects the viewport on the GPU — zero CPU copy. `EventTapManager` intercepts and suppresses Option+Scroll, forwarding the delta to `MagnifierController` which manages zoom factor (1×–15×), viewport, and stream lifecycle.

**Tech Stack:** Swift, ScreenCaptureKit (`SCStream`, `SCShareableContent`), AppKit (`NSPanel`, `CALayer`), CoreGraphics (CGEvent tap), AVFoundation (existing)

---

### Task 1: Add NSScreenCaptureUsageDescription to Info.plist

**Files:**
- Modify: `build-app.sh`

- [ ] **Step 1: Add key to Info.plist block in build-app.sh**

In `build-app.sh`, find the line:
```xml
    <key>NSMicrophoneUsageDescription</key>
    <string>Victor Addons needs microphone access for live transcription.</string>
```

Add directly after it:
```xml
    <key>NSScreenCaptureUsageDescription</key>
    <string>Victor Addons uses screen capture for the magnifier zoom overlay.</string>
```

- [ ] **Step 2: Commit**

```bash
git add build-app.sh
git commit -m "chore(magnifier): add NSScreenCaptureUsageDescription to Info.plist"
```

---

### Task 2: Intercept Option+Scroll in EventTapManager

**Files:**
- Modify: `Sources/VictorAddons/EventTapManager.swift`

- [ ] **Step 1: Add onZoomScroll callback**

In the `// MARK: Callbacks` section (after `onToggleTranscription`), add:

```swift
var onZoomScroll: ((Double) -> Void)?
```

- [ ] **Step 2: Add scrollWheel to event mask**

In `start()`, change `eventsOfInterest` to:

```swift
let eventsOfInterest: CGEventMask =
    CGEventMask(1 << CGEventType.keyDown.rawValue) |
    CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
    CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
    CGEventMask(1 << CGEventType.scrollWheel.rawValue)
```

- [ ] **Step 3: Handle Option+Scroll in handleEvent**

After the `otherMouseUp` block and before the `// Keyboard events` guard (around line 128), add:

```swift
// Option+Scroll → magnifier zoom (suppress native macOS zoom)
if type == .scrollWheel {
    let flags = event.flags
    guard flags.contains(.maskAlternate) &&
          !flags.contains(.maskCommand) &&
          !flags.contains(.maskControl) else {
        return Unmanaged.passUnretained(event)
    }
    let delta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    if delta != 0 {
        DispatchQueue.global().async { [weak self] in self?.onZoomScroll?(delta) }
    }
    return nil  // suppress — prevents native macOS zoom from activating
}
```

- [ ] **Step 4: Verify build**

```bash
swift build 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/EventTapManager.swift
git commit -m "feat(magnifier): intercept Option+Scroll in EventTapManager"
```

---

### Task 3: Create MagnifierController — panel, layer, zoom skeleton

**Files:**
- Create: `Sources/VictorAddons/MagnifierController.swift`
- Modify: `Sources/VictorAddons/AppDelegate.swift`

This task builds the NSPanel + CALayer wiring and zoom state machine. `startStream()` is a placeholder (shows black panel) — SCStream is added in Task 4.

- [ ] **Step 1: Create MagnifierController.swift**

Create `Sources/VictorAddons/MagnifierController.swift` with the full content below:

```swift
import AppKit
import ScreenCaptureKit
import CoreGraphics

class MagnifierController: NSObject {

    // MARK: - Tuning constants
    private static let minZoom: Double = 1.0
    private static let maxZoom: Double = 15.0
    private static let zoomMultiplier: Double = 0.15   // zoom change per scroll delta unit
    private static let maxZoomStep: Double = 0.5       // cap per single event
    private static let panSpeedPixelsPerSec: Double = 600.0
    private static let edgeThresholdPoints: Double = 80.0
    static let streamFPS: CMTimeScale = 30

    // MARK: - Screen geometry (buffer pixels = physical Retina pixels)
    private let screen: NSScreen
    let bufferW: CGFloat
    let bufferH: CGFloat

    // MARK: - State
    enum State { case inactive, starting, active, stopping }
    private(set) var state: State = .inactive
    private(set) var zoomFactor: Double = 1.0
    var viewportOrigin: CGPoint = .zero  // top-left, buffer pixels

    // MARK: - UI
    let panel: NSPanel
    let contentLayer: CALayer

    // MARK: - Stream / timers
    var stream: SCStream?
    private var panTimer: Timer?
    private var lastPanTime: Date = .now
    var firstFrameReceived = false

    // MARK: - Init

    init(screen: NSScreen) {
        self.screen = screen
        let scale = screen.backingScaleFactor
        self.bufferW = screen.frame.width * scale
        self.bufferH = screen.frame.height * scale

        let p = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = false
        p.alphaValue = 0

        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.backgroundColor = NSColor.black.cgColor

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        p.contentView = view

        self.panel = p
        self.contentLayer = layer
        super.init()
    }

    // MARK: - Public API

    func adjustZoom(scrollDelta: Double) {
        DispatchQueue.main.async { [weak self] in self?.handleZoom(scrollDelta) }
    }

    // MARK: - Zoom state machine

    private func handleZoom(_ delta: Double) {
        // Negative delta = scroll down = zoom in on macOS scroll convention
        let step = max(-Self.maxZoomStep, min(Self.maxZoomStep, -delta * Self.zoomMultiplier))
        let newZoom = max(Self.minZoom, min(Self.maxZoom, zoomFactor + step))

        switch state {
        case .inactive:
            guard newZoom > 1.0 else { return }
            zoomFactor = newZoom
            activate()
        case .active, .starting:
            if newZoom <= 1.0 {
                deactivate()
            } else {
                zoomFactor = newZoom
                clampViewport()
                updateContentsRect()
            }
        case .stopping:
            break
        }
    }

    func activate() {
        guard state == .inactive else { return }
        state = .starting
        firstFrameReceived = false

        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        viewportOrigin = CGPoint(x: (bufferW - vw) / 2, y: (bufferH - vh) / 2)

        panel.orderFrontRegardless()
        panel.alphaValue = 0
        startStream()
    }

    func deactivate() {
        guard state == .active || state == .starting else { return }
        state = .stopping
        zoomFactor = 1.0
        panTimer?.invalidate()
        panTimer = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
        let s = stream
        stream = nil
        if let s { Task { try? await s.stopCapture() } }
        state = .inactive
    }

    // MARK: - Viewport helpers

    func clampViewport() {
        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        viewportOrigin.x = max(0, min(bufferW - vw, viewportOrigin.x))
        viewportOrigin.y = max(0, min(bufferH - vh, viewportOrigin.y))
    }

    func updateContentsRect() {
        let vw = bufferW / CGFloat(zoomFactor)
        let vh = bufferH / CGFloat(zoomFactor)
        let nx = viewportOrigin.x / bufferW
        // CALayer contentsRect uses bottom-left origin; buffer row 0 = top of screen → flip Y
        let ny = 1.0 - (viewportOrigin.y + vh) / bufferH
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contentsRect = CGRect(x: nx, y: ny, width: vw / bufferW, height: vh / bufferH)
        CATransaction.commit()
    }

    // MARK: - Pan timer

    func startPanTimer() {
        lastPanTime = .now
        panTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.panTick()
        }
    }

    private func panTick() {
        guard state == .active else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastPanTime)
        lastPanTime = now

        let cursor = NSEvent.mouseLocation           // global coords, y=0 at bottom of primary screen
        let scale = screen.backingScaleFactor
        let relX = cursor.x - screen.frame.minX     // relative to our screen's origin
        let relY = cursor.y - screen.frame.minY

        // Convert to buffer pixels with top-left origin
        let cx = relX * scale
        let cy = (screen.frame.height - relY) * scale

        let threshold = CGFloat(Self.edgeThresholdPoints) * scale
        let speed = CGFloat(Self.panSpeedPixelsPerSec) * scale * CGFloat(dt)

        func frac(_ dist: CGFloat) -> CGFloat { max(0, (threshold - dist) / threshold) }

        let dxRight = frac(bufferW - cx) - frac(cx)
        let dyDown  = frac(bufferH - cy) - frac(cy)

        viewportOrigin.x += speed * dxRight
        viewportOrigin.y += speed * dyDown

        clampViewport()
        updateContentsRect()
    }

    // MARK: - Stream placeholder (replaced in Task 4)

    private func startStream() {
        // Placeholder: shows black panel immediately to verify panel/layer wiring.
        // Replace this entire method in Task 4.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.state == .starting else { return }
            self.state = .active
            self.panel.alphaValue = 1.0
            self.startPanTimer()
        }
    }
}
```

- [ ] **Step 2: Wire up in AppDelegate.swift**

Add property near the other `private var` declarations at the top of `AppDelegate`:
```swift
private var magnifierController: MagnifierController?
```

In `applicationDidFinishLaunching`, right after the line `overlayPanel = OverlayPanel(screen: builtInScreen)`:
```swift
magnifierController = MagnifierController(screen: builtInScreen)
```

In `applicationDidFinishLaunching`, right after `eventTap.start()`:
```swift
eventTap.onZoomScroll = { [weak self] delta in
    self?.magnifierController?.adjustZoom(scrollDelta: delta)
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 4: Smoke-test black panel**

```bash
./build-app.sh && pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"
```

Hold Option, scroll down. A black fullscreen panel should cover the built-in screen within ~100ms. Scroll up with Option until zoom returns to 1× — panel disappears. If it doesn't appear, check Console.app for `MagnifierController` log lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/MagnifierController.swift Sources/VictorAddons/AppDelegate.swift
git commit -m "feat(magnifier): add MagnifierController panel/layer/zoom skeleton"
```

---

### Task 4: Replace stream placeholder with SCStream capture

**Files:**
- Modify: `Sources/VictorAddons/MagnifierController.swift`

- [ ] **Step 1: Replace startStream() with the real SCStream implementation**

In `MagnifierController.swift`, replace the entire `// MARK: - Stream placeholder` section:

```swift
// MARK: - Stream placeholder (replaced in Task 4)

private func startStream() {
    // Placeholder: shows black panel immediately to verify panel/layer wiring.
    // Replace this entire method in Task 4.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, self.state == .starting else { return }
        self.state = .active
        self.panel.alphaValue = 1.0
        self.startPanTimer()
    }
}
```

With:

```swift
// MARK: - Stream

private func startStream() {
    Task { [weak self] in
        guard let self else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first(where: {
                CGDisplayIsBuiltin($0.displayID) != 0
            }) else {
                overlayError("MagnifierController: no built-in display found")
                await MainActor.run { self.state = .inactive }
                return
            }

            // Exclude our panel to prevent feedback loop (magnifier capturing itself)
            let myWindowID = CGWindowID(await MainActor.run { self.panel.windowNumber })
            let excludedWindows = content.windows.filter { $0.windowID == myWindowID }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            config.width = Int(self.bufferW)
            config.height = Int(self.bufferH)
            config.minimumFrameInterval = CMTime(value: 1, timescale: Self.streamFPS)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(
                self, type: .screen,
                sampleHandlerQueue: .global(qos: .userInteractive)
            )
            try await stream.startCapture()
            await MainActor.run { self.stream = stream }
        } catch {
            overlayError("MagnifierController: stream start failed: \(error)")
            await MainActor.run { self.state = .inactive }
        }
    }
}
```

- [ ] **Step 2: Add SCStreamOutput and SCStreamDelegate extensions**

At the bottom of `MagnifierController.swift`, outside the class body, add:

```swift
// MARK: - SCStreamOutput

extension MagnifierController: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .starting || self.state == .active else { return }
            self.contentLayer.contents = surface
            self.updateContentsRect()

            if !self.firstFrameReceived {
                self.firstFrameReceived = true
                self.state = .active
                self.panel.alphaValue = 1.0
                self.startPanTimer()
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension MagnifierController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        overlayError("MagnifierController: stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in self?.deactivate() }
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -30
```

Expected: no errors. If `SCStreamDelegate` protocol conformance gives a warning about optional method, that's fine.

- [ ] **Step 4: Deploy and test real capture**

```bash
./build-app.sh && pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"
```

Hold Option, scroll down. The magnifier should appear showing actual screen content (zoomed in, not black). Verify:
- Content is the center of the screen (initial viewport is centered)
- Moving cursor to screen edges causes the content to pan
- Scrolling back out with Option hides the overlay

**If the image appears vertically flipped** (upside down), the CALayer coordinate system convention is opposite to what we assumed. Change the `ny` line in `updateContentsRect()`:

```swift
// From:
let ny = 1.0 - (viewportOrigin.y + vh) / bufferH
// To:
let ny = viewportOrigin.y / bufferH
```

- [ ] **Step 5: Commit**

```bash
git add Sources/VictorAddons/MagnifierController.swift
git commit -m "feat(magnifier): add SCStream zero-copy IOSurface capture at 30fps"
```

---

### Task 5: Tune and verify feel

No new code — empirical verification and constant tuning.

- [ ] **Step 1: Verify panning direction**

With zoom ~3×, move cursor to the RIGHT edge of the screen. The content should pan RIGHT (showing more of the right side of the screen). If it pans the wrong way, swap `dxRight` sign in `panTick()`:

```swift
// Change:
let dxRight = frac(bufferW - cx) - frac(cx)
// To:
let dxRight = frac(cx) - frac(bufferW - cx)
```

Similarly for vertical: moving to BOTTOM edge should show more of the bottom. If inverted, swap `dyDown`:

```swift
// Change:
let dyDown = frac(bufferH - cy) - frac(cy)
// To:
let dyDown = frac(cy) - frac(bufferH - cy)
```

- [ ] **Step 2: Tune zoom sensitivity**

One physical scroll notch on a standard mouse gives `scrollWheelEventDeltaAxis1` ≈ 3. With `zoomMultiplier = 0.15`, that's `3 × 0.15 = 0.45` zoom per notch. If too coarse, lower to `0.08`; if too slow, raise to `0.25`.

```swift
private static let zoomMultiplier: Double = 0.15
```

- [ ] **Step 3: Tune pan speed**

If panning feels sluggish, increase `panSpeedPixelsPerSec`. If it flies too fast, decrease it.

```swift
private static let panSpeedPixelsPerSec: Double = 600.0
```

- [ ] **Step 4: Commit any tuning changes**

```bash
git add Sources/VictorAddons/MagnifierController.swift
git commit -m "fix(magnifier): tune zoom sensitivity and pan speed"
```

(Skip if no changes needed.)

---

### Task 6: Full deploy and Zoom screen-share verification

- [ ] **Step 1: Final build and install**

```bash
./build-app.sh && pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"
```

- [ ] **Step 2: Verify in Zoom screen sharing**

1. Start a Zoom meeting and share the built-in screen
2. Open the shared-screen preview in another window or check on another device
3. Hold Option + scroll down → participants should see the zoomed-in view
4. Move cursor to screen edges → viewport pans (participants see the pan)
5. Option + scroll up to 1× → overlay disappears, participants see normal screen

This confirms our NSPanel (a real window) is captured by Zoom, unlike native macOS zoom.

- [ ] **Step 3: Push**

```bash
git push
```

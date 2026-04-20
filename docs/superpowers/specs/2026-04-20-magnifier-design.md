# Magnifier Overlay — Design Spec
Date: 2026-04-20

## Problem

macOS Accessibility Zoom (Option+Scroll) zooms at the WindowServer/compositor level — after screen capture tools read the framebuffer. Zoom meeting software therefore sees the unzoomed screen. Trainers need a zoom tool whose output IS captured by Zoom screen sharing.

## Solution

A fullscreen `NSPanel` that displays a magnified view of the screen, implemented as a real window (captured by all screen sharing tools like any other window). Content is fed by ScreenCaptureKit (`SCStream`) using the zero-copy `IOSurface → CALayer.contents` path. Viewport selection is done via `CALayer.contentsRect` on the GPU — no CPU image processing.

## Behavior

- **Trigger**: Option+Scroll (same gesture as native zoom), intercepted and suppressed via `CGEvent` tap
- **Zoom range**: 1×–15×, step ≈ 0.3 per scroll delta unit
- **Activation**: first Option+ScrollDown when at 1× → stream starts, panel appears
- **Deactivation**: Option+ScrollUp back to 1× → panel hides, stream stops
- **No Escape shortcut** — scroll back out is the only way to deactivate
- **Panning**: edge-triggered — viewport only pans when cursor is within 80pt of a screen edge; pan speed proportional to distance into the edge zone (600 px/sec max)
- **Target screen**: built-in Retina display only

## Architecture

### New file: `MagnifierController.swift`

Single class owning all zoom state:
- `zoomFactor: Double` (1.0–15.0)
- `viewportOrigin: CGPoint` (in buffer pixels, top-left origin)
- `NSPanel` at `.screenSaver` level (above existing `.statusBar` overlay)
- `CALayer` with `contentsRect` for zero-copy GPU viewport selection
- `SCStream` at 30fps (30fps cap via `minimumFrameInterval`)
- `CVDisplayLink` pan timer at 60fps (only while active)
- State machine: `INACTIVE → STARTING → ACTIVE → STOPPING → INACTIVE`

Public API:
```swift
func adjustZoom(scrollDelta: Double)   // called by EventTapManager
```

### Modified: `EventTapManager.swift`

- Add `CGEventType.scrollWheel` to `eventsOfInterest` mask
- Add `var onZoomScroll: ((Double) -> Void)?`
- In `handleEvent`: if Option modifier + scroll → extract `kCGScrollWheelEventDeltaAxis1`, call `onZoomScroll?(delta)`, return `nil` (suppress native zoom)

### Modified: `AppDelegate.swift`

- Add `var magnifierController: MagnifierController?`
- In `applicationDidFinishLaunching`: instantiate, wire `eventTap.onZoomScroll`

### Modified: `build-app.sh`

- Add `NSScreenCaptureUsageDescription` to Info.plist (required for SCKit TCC prompt description)

## Frame Pipeline (zero-copy)

```
SCStream (display capture, 30fps)
  └─ didOutputSampleBuffer
       └─ CMSampleBufferGetImageBuffer → CVPixelBuffer
            └─ CVPixelBufferGetIOSurface → IOSurface (GPU memory)
                 └─ DispatchQueue.main { layer.contents = surface }
                      └─ layer.contentsRect = currentViewportRect  (GPU crops+scales)
```

## Feedback Loop Prevention

The magnifier panel must not appear in its own SCStream input (would create a zoomed mirror of itself). Approach:
1. Show panel at `alpha=0` before stream starts
2. Query `SCShareableContent` (async ~100ms)
3. Find our `NSPanel` in `content.windows` by matching `windowID`
4. `SCContentFilter(display: display, excludingWindows: [ourSCWindow])`
5. Start stream; on first frame → `panel.alpha = 1`

## Viewport Maths (buffer-pixel space)

```
scale          = screen.backingScaleFactor          // 2.0 on Retina
bufferW/H      = screen.frame.width/height × scale  // e.g. 2560×1600
viewportSize   = (bufferW / zoom, bufferH / zoom)

// Edge-triggered pan (CVDisplayLink, 60fps):
cursorPx       = (cursor.x × scale, (screenH - cursor.y) × scale)  // flip Y
threshold      = 80 × scale  // in pixels
for each edge:
    fraction   = clamp((threshold - distToEdge) / threshold, 0, 1)
    viewportOrigin ± fraction × 600px/s × dt
viewportOrigin = clamped to valid range

// contentsRect (normalized 0–1):
contentsRect   = CGRect(vx/bW, vy/bH, 1/zoom, 1/zoom)
layer.contentsRect = contentsRect
```

## SCStream Configuration

```swift
config.width                 = Int(bufferW)
config.height                = Int(bufferH)
config.minimumFrameInterval  = CMTime(value: 1, timescale: 30)  // 30fps cap
config.pixelFormat           = kCVPixelFormatType_32BGRA
config.scalesToFit           = false
config.showsCursor           = false  // avoid double-cursor in zoomed view
```

## NSPanel Configuration

```swift
panel.level                  = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
panel.collectionBehavior     = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.ignoresMouseEvents     = true   // events handled via CGEvent tap
panel.isOpaque               = false
panel.backgroundColor        = .black  // shown briefly during startup (~100ms)
```

## Performance

- **While inactive**: zero CPU/GPU overhead (stream stopped)
- **While active**: ~5-10% GPU (hardware capture path on Apple Silicon), ~1% CPU
- 30fps cap halves GPU vs 60fps; suitable for showing code
- All rendering GPU-side via IOSurface → CALayer (no CPU copy)

## Files Changed

| File | Change |
|------|--------|
| `Sources/VictorAddons/MagnifierController.swift` | New — ~200 lines |
| `Sources/VictorAddons/EventTapManager.swift` | Add scroll interception |
| `Sources/VictorAddons/AppDelegate.swift` | Wire up MagnifierController |
| `build-app.sh` | Add NSScreenCaptureUsageDescription to Info.plist |

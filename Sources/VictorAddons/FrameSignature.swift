import CoreFoundation
import IOSurface

/// A cheap fingerprint of a captured frame: one pixel in 64 (every 8th of every 8th
/// row), mixed into 64 bits. Two ScreenCaptureKit streams here receive frames whose
/// pixels did not change — 🔎 `ShareZoom` films the display its own window covers, and
/// every frame it shows damages that display again, so the stream answered with
/// another full-screen frame ~50×/s for a desktop that changed ~3×/s (measured
/// 2026-10-15; `dirtyRects` reported the whole screen each time, so they cannot tell
/// the echo from a real change). Skipping a frame whose fingerprint is unchanged
/// breaks the loop. A character typed on a Retina is ~14×28 px, so it lands on the
/// grid; what can slip through (a 2 px caret blink) is caught by `EchoFilter`'s
/// periodic forced refresh.
enum FrameSignature {
    static func of(_ surface: IOSurface) -> UInt64 {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return 0 }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        var hash: UInt64 = 0xcbf29ce484222325
        var row = 0
        while row < height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < width {
                hash = (hash ^ UInt64(line[x])) &* 0x100000001b3
                x += 8
            }
            row += 8
        }
        return hash
    }
}

/// Decides, on the frame queue, whether a frame is worth showing. Not thread-safe:
/// one per stream, used only on that stream's sample-handler queue.
struct EchoFilter {
    /// Show an unchanged frame anyway after this long, for what the grid misses.
    static let forcedRefresh: CFTimeInterval = 0.25

    private var last: UInt64?
    private var shownAt: CFTimeInterval = 0
    private(set) var shown = 0
    private(set) var skipped = 0

    mutating func shouldShow(_ surface: IOSurface, now: CFTimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        let signature = FrameSignature.of(surface)
        if signature == last, now - shownAt < Self.forcedRefresh {
            skipped += 1
            return false
        }
        last = signature
        shownAt = now
        shown += 1
        return true
    }

    mutating func reset() { self = EchoFilter() }
}

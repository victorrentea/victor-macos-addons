import CoreGraphics
import Foundation

/// Where the crosshair drag actually was, so the confirmation border can frame
/// **the crop** instead of the whole screen.
///
/// `screencapture -i` reports nothing about the region it took — the jpg carries
/// a size and no origin — so the rectangle is reconstructed from the drag that
/// produced it: the cursor position when the left button went down and when it
/// came back up, sampled while the subprocess owns the screen.
///
/// It reads the **button state**, not events: `CGEventSource.buttonState` is a
/// snapshot of the session's current input state, so it works from any thread
/// and, unlike an event tap, cannot be starved by screencapture's own overlay
/// swallowing the mouse. The sampling costs one syscall every 8 ms for the few
/// seconds the selection is up.
///
/// It answers with a rectangle only for a genuine drag. A space-bar *window*
/// pick is a click — down and up land on the same point — and comes back nil,
/// which the caller reads as "don't draw anything", the honest answer.
final class CropDragTracker {
    /// Global CoreGraphics coordinates (origin top-left of the primary display).
    private var lastDown: CGPoint?
    private var pending: (down: CGPoint, up: CGPoint)?
    private let lock = NSLock()
    private var running = false

    private let interval: TimeInterval

    init(sampleInterval: TimeInterval = 0.008) {
        self.interval = sampleInterval
    }

    func start() {
        lock.lock(); running = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.loop() }
    }

    /// Stop sampling and hand back the last completed drag, in global CG coords.
    func stop() -> CGRect? {
        lock.lock()
        running = false
        let drag = pending
        lock.unlock()
        guard let drag else { return nil }
        return CropFlashGeometry.rect(from: drag.down, to: drag.up)
    }

    private func loop() {
        var wasDown = false
        while true {
            lock.lock()
            let alive = running
            lock.unlock()
            guard alive else { return }

            let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            if isDown != wasDown, let point = CGEvent(source: nil)?.location {
                lock.lock()
                if isDown {
                    lastDown = point
                } else if let down = lastDown {
                    pending = (down, point)
                    lastDown = nil
                }
                lock.unlock()
                wasDown = isDown
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

/// Pure geometry for the crop border: building the dragged rectangle, flipping
/// it into Cocoa's coordinate system, and — the load-bearing part — deciding
/// whether it may be trusted at all.
enum CropFlashGeometry {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// CG global (y **down** from the primary display's top) → Cocoa global
    /// (y **up** from the primary display's bottom), the flip every window
    /// placement in this app has to make.
    static func cocoaRect(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Does the drag we watched actually describe the picture that was saved?
    ///
    /// The border is a claim about *where* the crop was, and a claim in the
    /// wrong place is worse than no claim at all — so the drag is checked
    /// against the file's own pixel dimensions before it is drawn. Anything
    /// that doesn't match (a window pick, a drag we started sampling too late,
    /// a selection resized with the modifier keys) fails, and the caller draws
    /// nothing.
    static func matchesCapture(drag: CGRect,
                               imagePixels: CGSize,
                               scale: CGFloat,
                               tolerancePoints: CGFloat = 8) -> Bool {
        guard scale > 0, drag.width >= 8, drag.height >= 8,
              imagePixels.width > 0, imagePixels.height > 0 else { return false }
        let expected = CGSize(width: imagePixels.width / scale, height: imagePixels.height / scale)
        return abs(expected.width - drag.width) <= tolerancePoints
            && abs(expected.height - drag.height) <= tolerancePoints
    }

    /// A border thick enough to read, never so thick it swallows a small crop.
    static func borderThickness(for rect: CGRect) -> CGFloat {
        max(4, min(24, min(rect.width, rect.height) * 0.12))
    }
}

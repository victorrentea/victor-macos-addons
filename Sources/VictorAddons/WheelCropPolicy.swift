import CoreGraphics
import Foundation

/// 🛞 The wheel, pressed and dragged (or pressed and held) with nothing else
/// going on: the ⌃P crop, straight from the mouse (Victor, 2026-10-09: *"when I
/// drag with my wheel directly, without having to press anything before, it
/// will cut a piece of the screen … if I press down and hold for a while the
/// wheel, it should turn into a crop — like when I hold ⌃P for longer"*).
///
/// A press cannot be told from a click at the press — the difference is what
/// the hand does next — so the press always goes on to the app underneath, and
/// only a press that **moved** or **stayed down** becomes a crop.
enum WheelCropPolicy {
    /// Walkie Talkie's `areaDragThreshold`, on purpose: the same button arms
    /// the same overlay there during a dictation, and one gesture should not
    /// have two thresholds. Comfortably past a hand's tremor — a click is
    /// never perfectly still.
    static let dragThreshold: CGFloat = 12

    /// The ⌃P hold, so "hold it a moment" means one length of time on the key
    /// and on the wheel.
    static let holdSeconds: TimeInterval = ScreenshotHoldPolicy.holdSeconds

    static func isDrag(from anchor: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - anchor.x, point.y - anchor.y) >= dragThreshold
    }
}

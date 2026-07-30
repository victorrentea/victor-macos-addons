import CoreGraphics
import Foundation

/// Pure decision helper: "is the cursor *actively being moved* inside the pill,
/// or is it merely parked there?"
///
/// A resting cursor is not an intention. The bottom-left banner sits exactly
/// where the hand naturally leaves the mouse (bottom of the screen), so a pill
/// that appears under a motionless cursor used to confirm/undo itself after the
/// dwell simply because nobody touched anything. The dwell therefore only counts
/// while the cursor keeps landing in *different* positions: it must move at least
/// `minMoveDistance` points at least once in every `windowSeconds` slice.
/// Stop moving for one slice and the dwell resets to zero.
///
/// Movement is measured against a rolling anchor that follows the cursor, so a
/// slow continuous drag qualifies just as well as a jiggle — what never
/// qualifies is a cursor that stays put.
struct HoverMotionGate {
    /// Every half-second slice must contain movement (Victor's rule).
    static let windowSeconds: TimeInterval = 0.5
    /// Points the cursor must travel to count as moved. Big enough that trackpad
    /// micro-jitter / a nudged desk isn't read as intent, small enough that any
    /// deliberate wiggle passes.
    static let minMoveDistance: CGFloat = 4

    private var anchor: CGPoint
    private var windowStart: TimeInterval
    private var movedInWindow: Bool

    init(position: CGPoint, now: TimeInterval) {
        anchor = position
        windowStart = now
        movedInWindow = false
    }

    /// Feed one cursor sample. Returns `false` when the slice that just closed
    /// contained no movement — the caller resets the dwell progress. The gate
    /// re-arms itself either way, so the user can start moving again and build
    /// the dwell up from zero.
    mutating func admit(position: CGPoint, now: TimeInterval) -> Bool {
        if hypot(position.x - anchor.x, position.y - anchor.y) >= Self.minMoveDistance {
            movedInWindow = true
            anchor = position
        }
        guard now - windowStart >= Self.windowSeconds else { return true }
        let moved = movedInWindow
        // Open the next slice from here regardless of the verdict.
        windowStart = now
        movedInWindow = false
        anchor = position
        return moved
    }
}

import CoreGraphics
import Foundation

/// 🔎 The arithmetic of `ShareZoom`, with no screen, stream or event tap in sight.
enum ShareZoomPolicy {

    /// Ceiling of the dial. macOS's own magnifier goes to 40×, but past ~10× a
    /// retina shows a handful of characters and nobody on a call is helped by that.
    static let maxFactor: CGFloat = 10

    /// One wheel notch is a **factor**, not an addend — the 🔍 Pink Panther glass's
    /// reasoning: a dial that adds a constant feels coarse at the bottom of its range
    /// and sluggish at the top. 1.15 puts 1× → 2× five notches apart.
    static let notchFactor: CGFloat = 1.15

    /// Trackpad pixels worth one notch. Continuous scrolls arrive in many small
    /// deltas; without this a two-finger flick crosses the whole range at once.
    static let pixelsPerNotch: CGFloat = 12

    /// The most notches one wheel event may count for. A fast spin on a wheel with
    /// acceleration reports deltas of 5–10 lines per event, which would jump 2× → 8×.
    static let maxNotchesPerEvent: CGFloat = 3

    /// The next target factor after one scroll event.
    ///
    /// `delta` is the event's vertical delta **after** `ScrollReversal`, in the same
    /// convention as the ⌘-scroll terminal font zoom it sits next to: negative =
    /// bigger. Matching that branch is deliberate — the same wheel, turned the same
    /// way, should mean "closer" for both zooms, and that branch's direction was
    /// calibrated by hand on this machine.
    static func step(_ factor: CGFloat, delta: Double, continuous: Bool) -> CGFloat {
        guard delta != 0 else { return factor }
        let notches: CGFloat
        if continuous {
            notches = CGFloat(-delta) / pixelsPerNotch
        } else {
            let n = min(abs(CGFloat(delta)), maxNotchesPerEvent)
            notches = delta < 0 ? n : -n
        }
        let next = factor * pow(notchFactor, notches)
        return min(max(next, 1), maxFactor)
    }

    /// One frame of easing towards `target` (called at 120 Hz). macOS animates its
    /// own zoom; a factor that jumps a notch at a time reads as a stutter.
    static func ease(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        let next = current + (target - current) * 0.3
        return abs(target - next) < 0.002 ? target : next
    }

    /// Below this the zoom is over: the window goes away and the stream stops.
    static func isOff(current: CGFloat, target: CGFloat) -> Bool {
        target <= 1 && current < 1.005
    }

    /// The slice of the screen to blow up, in the screen's own points (origin at
    /// its bottom-left, like `NSScreen.frame`).
    ///
    /// **The pointer is the fixed point of the magnification**: the pixel physically
    /// under the cursor is drawn exactly where the cursor is. That single choice is
    /// what makes the overlay usable without touching a single input event — the
    /// window is click-through, so a click lands on whatever is *really* under the
    /// pointer, and with this geometry that is also what the zoomed picture *shows*
    /// under it. Any other anchor (centre on the pointer, pan at the edges) would
    /// draw one thing under the cursor and click another.
    ///
    /// The consequence is the panning feel: moving the cursor by `d` slides the
    /// picture by `(1 - factor)·d`, and with the cursor at an edge of the screen
    /// the matching edge of the desktop is in view — the whole desktop is reachable
    /// by sweeping the pointer across, never out of it.
    static func sourceRect(screenSize: CGSize, pointer: CGPoint, factor: CGFloat) -> CGRect {
        let k = max(factor, 1)
        let p = CGPoint(x: min(max(pointer.x, 0), screenSize.width),
                        y: min(max(pointer.y, 0), screenSize.height))
        return CGRect(x: p.x * (1 - 1 / k),
                      y: p.y * (1 - 1 / k),
                      width: screenSize.width / k,
                      height: screenSize.height / k)
    }

    /// `sourceRect` in the unit space of a `CALayer.contentsRect`.
    static func contentsRect(screenSize: CGSize, pointer: CGPoint, factor: CGFloat) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let r = sourceRect(screenSize: screenSize, pointer: pointer, factor: factor)
        return CGRect(x: r.minX / screenSize.width,
                      y: r.minY / screenSize.height,
                      width: r.width / screenSize.width,
                      height: r.height / screenSize.height)
    }
}

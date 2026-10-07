import CoreGraphics
import Foundation

/// 🔎 The arithmetic of `ShareZoom`, with no screen, stream or event tap in sight.
///
/// All points are in the zoomed screen's own coordinates (origin at its bottom-left,
/// like `NSScreen.frame` minus its origin). The state is the **origin of the visible
/// slice** plus the factor; the slice is always `screenSize / factor` big.
enum ShareZoomPolicy {

    /// Ceiling of the dial: 8×, which is 80 % of the first build's 10× (Victor,
    /// 2026-10-01). macOS's own magnifier goes to 40×, but past this a retina
    /// shows a handful of characters and nobody on a call is helped by that.
    static let maxFactor: CGFloat = 8

    /// One wheel notch is a **factor**, not an addend — the 🔍 Pink Panther glass's
    /// reasoning: a dial that adds a constant feels coarse at the bottom of its range
    /// and sluggish at the top. It was 1.15 for the first build and Victor found the
    /// steps too big — twice on the same day (2026-10-01, *"înjumătățește pașii"*,
    /// then *"make the zoom step smaller"*). Halved **in the log domain** both times:
    /// ⁴√1.15 ≈ 1.036, so four notches now do what one did and 1× → 2× is twenty.
    static let notchFactor: CGFloat = pow(1.15, 0.25)

    /// Trackpad pixels worth one notch. Continuous scrolls arrive in many small
    /// deltas; without this a two-finger flick crosses the whole range at once.
    static let pixelsPerNotch: CGFloat = 12

    /// The most notches one wheel event may count for. A fast spin on a wheel with
    /// acceleration reports deltas of 5–10 lines per event.
    static let maxNotchesPerEvent: CGFloat = 3

    /// The next target factor after one scroll event.
    ///
    /// `delta` is the event's vertical delta **after** `ScrollReversal`; **positive =
    /// closer**. The first build copied the ⌘-scroll terminal font zoom's sign and
    /// came out backwards (Victor, 2026-10-01: *"l-ai făcut pe dos"*) — that branch
    /// maps the wheel to ⌘- / ⌘= keystrokes, not to "towards the screen", so its
    /// sign was never the one to copy.
    ///
    /// A **trackpad** delta counts the other way. `ScrollReversal` leaves continuous
    /// scrolls alone, so they arrive in natural-scrolling sign: two fingers up is
    /// negative. The system magnifier (⌥+scroll) zooms in on fingers up; using the
    /// wheel's sign made ⌥⇧ do the opposite (Victor, 2026-10-07: *"inverse ca
    /// accessibility"*).
    static func step(_ factor: CGFloat, delta: Double, continuous: Bool) -> CGFloat {
        guard delta != 0 else { return factor }
        let notches: CGFloat
        if continuous {
            notches = -CGFloat(delta) / pixelsPerNotch
        } else {
            let n = min(abs(CGFloat(delta)), maxNotchesPerEvent)
            notches = delta > 0 ? n : -n
        }
        let next = factor * pow(notchFactor, notches)
        // Ten notches up and ten down multiply out to 1.0000001, not 1 — and a
        // target above 1 is a zoom that never switches itself off.
        if next < 1.01 { return 1 }
        return min(next, maxFactor)
    }

    /// One frame of easing towards `target` (called at 120 Hz). macOS animates its
    /// own zoom; a factor that jumps a notch at a time reads as a stutter.
    static func ease(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        let next = current + (target - current) * 0.18
        return abs(target - next) < 0.002 ? target : next
    }

    /// Below this the zoom is over: the window goes away.
    static func isOff(current: CGFloat, target: CGFloat) -> Bool {
        target <= 1 && current < 1.005
    }

    // MARK: - Where the slice is

    /// After the factor changes from `from` to `to`, the slice origin that keeps the
    /// pointer's spot where it was on the glass — macOS zooms *about the pointer*,
    /// so what you were looking at grows under the cursor instead of sliding away.
    static func rezoom(origin: CGPoint, from: CGFloat, to: CGFloat,
                       pointer: CGPoint, screenSize: CGSize) -> CGPoint {
        let drawnAt = cursorPoint(pointer: pointer, origin: origin, factor: from)
        let moved = CGPoint(x: pointer.x - drawnAt.x / max(to, 1),
                            y: pointer.y - drawnAt.y / max(to, 1))
        return clamp(origin: moved, factor: to, screenSize: screenSize)
    }

    /// **The picture only moves when the pointer pushes against the edge of the
    /// slice** — macOS's "only when the pointer reaches an edge" panning, the one
    /// Victor uses (`closeViewPanningMode = 1`). The first build kept the pointer as
    /// the fixed point of the magnification instead, so the whole desktop slid under
    /// every mouse move (2026-10-01: *"nu e aceeași experiență"*).
    static func pan(origin: CGPoint, pointer: CGPoint, factor: CGFloat, screenSize: CGSize) -> CGPoint {
        let k = max(factor, 1)
        let w = screenSize.width / k, h = screenSize.height / k
        var o = origin
        if pointer.x < o.x { o.x = pointer.x }
        if pointer.x > o.x + w { o.x = pointer.x - w }
        if pointer.y < o.y { o.y = pointer.y }
        if pointer.y > o.y + h { o.y = pointer.y - h }
        return clamp(origin: o, factor: k, screenSize: screenSize)
    }

    static func clamp(origin: CGPoint, factor: CGFloat, screenSize: CGSize) -> CGPoint {
        let k = max(factor, 1)
        let maxX = screenSize.width - screenSize.width / k
        let maxY = screenSize.height - screenSize.height / k
        return CGPoint(x: min(max(origin.x, 0), maxX), y: min(max(origin.y, 0), maxY))
    }

    /// Where the desktop point `pointer` is drawn on the glass. With the hardware
    /// cursor hidden, this is where the drawn cursor goes — and since a click lands
    /// on `pointer` itself, it lands on exactly what the drawn cursor is over.
    static func cursorPoint(pointer: CGPoint, origin: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(x: (pointer.x - origin.x) * factor, y: (pointer.y - origin.y) * factor)
    }

    /// The slice in the unit space of a `CALayer.contentsRect`.
    static func contentsRect(origin: CGPoint, factor: CGFloat, screenSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let k = max(factor, 1)
        return CGRect(x: origin.x / screenSize.width, y: origin.y / screenSize.height,
                      width: 1 / k, height: 1 / k)
    }
}

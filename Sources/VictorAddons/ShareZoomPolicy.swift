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
    /// ⁴√1.15 ≈ 1.036, so four notches did what one did and 1× → 2× was twenty.
    /// Then 20 % bigger, again in the log domain (2026-10-29, *"să meargă mai repede
    /// zoom in și zoom out, un pic"*): 1.15^0.3 ≈ 1.043, 1× → 2× in about seventeen.
    /// And 20 % again the next night (2026-10-30, *"un step de zoom … cu 20% mai
    /// mare"*): 1.15^0.36 ≈ 1.052, 1× → 2× in about fourteen. And 20 % once more
    /// the same night (*"+20% larger increments on wheel"*): 1.15^0.432 ≈ 1.062,
    /// 1× → 2× in about twelve.
    static let notchFactor: CGFloat = pow(1.15, 0.432)

    /// Victor's smooth wheel zooms **the way the macOS magnifier does**: ×1.01 per
    /// 12 px of delta, so speed counts (2026-10-30, *"al nostru vrea să fie cât mai
    /// aproape de comportamentul ăluia"*). Measured with `ZoomScrollRecorder` on a
    /// hand's ⌥+scroll into the magnifier: one slow detent (12 px) was exactly ×1.01,
    /// sixty of them took 1× to 1.83×; a fast spin — Logi Options+ accelerates it to
    /// 400–1131 px per event — took 1× to 33× in 240 ms. The one-notch-per-event rule
    /// before it made a slow detent six times too big and a fast spin nearly dead:
    /// *"mai elastic când dau mai repede"* was the magnifier, not us.
    static let nativeFactorPerPixel: CGFloat = pow(1.01, 1.0 / 12)

    /// Trackpad pixels worth one notch. Continuous scrolls arrive in many small
    /// deltas; without this a two-finger flick crosses the whole range at once.
    static let pixelsPerNotch: CGFloat = 12

    /// The most notches one wheel event may count for. A fast spin on a wheel with
    /// acceleration reports deltas of 5–10 lines per event.
    static let maxNotchesPerEvent: CGFloat = 3

    /// Where a scroll came from, as far as an event can tell.
    enum Source {
        /// A notched wheel scrolling in lines (`isContinuous == 0`).
        case wheel
        /// A wheel that scrolls in pixels: Logi Options+ "smooth scrolling" turns
        /// Victor's M650 continuous, so it looks like a trackpad except that it
        /// carries **no gesture phase** — a trackpad's and a Magic Mouse's events
        /// always do (began/changed/ended, or a momentum phase).
        case smoothWheel
        /// Two fingers: continuous, with a phase.
        case trackpad

        static func of(continuous: Bool, phase: Int64, momentumPhase: Int64) -> Source {
            if !continuous { return .wheel }
            return phase == 0 && momentumPhase == 0 ? .smoothWheel : .trackpad
        }
    }

    /// How many notches closer (positive) or farther (negative) one scroll event is,
    /// by the rules under `step`. 🔦 `GlassSpotlight`'s zoom reads the same count, so
    /// both zooms turn the same way under the same wheel.
    static func notches(delta: Double, source: Source) -> CGFloat {
        switch source {
        case .trackpad:
            return -CGFloat(delta) / pixelsPerNotch
        case .smoothWheel:
            return delta > 0 ? 1 : delta < 0 ? -1 : 0
        case .wheel:
            let n = min(abs(CGFloat(delta)), maxNotchesPerEvent)
            return delta > 0 ? n : -n
        }
    }

    /// The next target factor after one scroll event.
    ///
    /// `delta` is the event's delta **after** `ScrollReversal`. The rule is "the same
    /// way as ⌥+scroll in the system magnifier": wheel up and fingers up = closer.
    ///
    /// - **Any wheel: positive = closer.** Measured on 2026-10-15 from the event log:
    ///   Victor's wheel-up arrived as `continuous=1 phase=0`, positive (Logi Options+
    ///   smooth scrolling). This morning's "the zoom is reversed" was that wheel, but
    ///   only the *notched* sign got flipped, which his mouse never sends — so the
    ///   notched wheel is back on the 2026-10-01 calibration, positive = closer.
    /// - **Trackpad: negative = closer.** `ScrollReversal` leaves it alone, so it
    ///   arrives in natural-scrolling sign: two fingers up is negative (2026-10-07,
    ///   *"inverse ca accessibility"*).
    /// - **A smooth wheel follows its delta, like the macOS magnifier**
    ///   (`nativeFactorPerPixel`). From 2026-10-15 to 10-30 it counted one notch per
    ///   event, because a flick slammed the zoom to 8× before anything was on screen
    ///   (the "hung halfway"); the `Stage` prepared per display has since cut a cold
    ///   start to 78 ms, and the magnifier does exactly that slam.
    static func step(_ factor: CGFloat, delta: Double, source: Source) -> CGFloat {
        guard delta != 0 else { return factor }
        let next = source == .smoothWheel
            ? factor * pow(nativeFactorPerPixel, CGFloat(delta))
            : factor * pow(notchFactor, notches(delta: delta, source: source))
        // Ten notches up and ten down multiply out to 1.0000001, not 1 — and a
        // target above 1 is a zoom that never switches itself off. Only on the way
        // out: a slow detent from 1× is ×1.01 exactly, and snapping that back to 1
        // would leave the zoom unable to start.
        if next < factor, next < 1.01 { return 1 }
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

    /// How fast the drawn cursor crosses the **glass** while zoomed, as a share of how
    /// fast an unzoomed one crosses the screen (`ZoomPointerSpeed`). One number for
    /// every factor: the hand covers the same stretch of glass per centimetre whether
    /// the zoom is 2× or 8×, so on the desktop the pointer goes exactly 1/factor as far,
    /// times this — sensitivity **proportional** to the zoom.
    ///
    /// The steps, all 2026-10-27: the factor with slow moves lost to rounding (*"abia
    /// dacă pot să mișc"*), then √factor with the rounding fixed (*"prea rapid"*), the
    /// factor (*"un pic prea repede"*), ^1.25 (*"prea rapid"*), ^1.5. A power is never
    /// proportional: on the glass ^1.5 is 1/√factor — 0.82 at 1.5×, 0.5 at 4×, 0.35 at
    /// 8× — and Victor, 2026-10-29: *"la un zoom mic mouse-ul se mișcă foarte rapid, la
    /// un zoom adânc abia se mișcă"*. 0.5 is what ^1.5 gave at 4×, the middle of the dial.
    static let defaultGlassSpeed: CGFloat = 0.5

    /// How many times slower the mouse goes at `factor`: `factor / glassSpeed`, so the
    /// glass sees `glassSpeed` at every factor — except at the bottom of the dial, where
    /// that would jump from 1 to 2 the instant the zoom starts. There it is `factor²`
    /// (the glass sees 1/factor), which starts from 1 at 1× and meets `factor / glassSpeed`
    /// at factor = 1/glassSpeed (2× for 0.5); the smaller of the two is always the one.
    static func pointerSlowdown(_ factor: CGFloat, glassSpeed: CGFloat = defaultGlassSpeed) -> CGFloat {
        let k = max(factor, 1)
        let s = min(max(glassSpeed, 0.05), 1)
        return min(k * k, k / s)
    }

    /// Is this move one `ZoomPointerSpeed` should follow rather than slow down — the
    /// cursor put somewhere by someone else (a warp, a display change) instead of
    /// moved by the hand? Told apart by the event's own delta: a hand's move lands
    /// at `last + delta` (`now` is where WindowServer put it, from our last warp), a
    /// foreign one lands somewhere the delta does not explain. Never by the size of
    /// the jump: until 2026-10-29 every move of ≥ 400 pt went through unscaled, and
    /// slowed 4× the hand throws the pointer to the other monitor in moves that big
    /// — it came back at full speed (*"vine cu foarte mare sensibilitate"*). The
    /// `|delta|` margin covers an event placed before our last warp had landed: it
    /// is off by at most that warp's step, which is shorter than its delta.
    static func followsUnscaled(now: CGPoint, last: CGPoint, delta: CGVector) -> Bool {
        let missed = hypot(now.x - last.x - delta.dx, now.y - last.y - delta.dy)
        return missed > max(foreignJump, hypot(delta.dx, delta.dy))
    }
    static let foreignJump: CGFloat = 400

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

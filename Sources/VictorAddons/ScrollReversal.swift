import CoreGraphics
import Foundation

/// Reverses the mouse wheel's scroll direction — both axes — and leaves the
/// trackpad alone. This replaces **Scroll Reverser**
/// (`com.pilotmoon.scroll-reverser`), uninstalled on 2026-09-07, and reproduces
/// the exact preferences it was carrying:
///
/// | key | value | meaning |
/// |---|---|---|
/// | `InvertScrollingOn` | 1 | the app was doing something at all |
/// | `ReverseY` | *absent* | its default, **on** — vertical reversed |
/// | `ReverseX` | 1 | non-default, deliberately turned on — horizontal reversed too |
/// | `ReverseMouse` | *absent* | its default, **on** |
/// | `ReverseTrackpad` | 0 | non-default, deliberately turned **off** |
///
/// So: **negate both axes of a wheel, touch nothing a trackpad sends.**
///
/// **Why it moved into this app.** Walkie Talkie also holds a session tap, but
/// it is not something to be assumed running — it carries a 2.5 GB Whisper model
/// and is quit when the memory is wanted elsewhere. This app is a LaunchAgent
/// that is up from login to shutdown, which is the only place a transform that
/// has to apply to *every* scroll of the day can live.
///
/// **The trackpad is told apart by continuity, not by device**, which is the
/// same test Scroll Reverser makes and the only one available: a CGEventTap
/// cannot see which device produced an event. A trackpad (and a Magic Mouse)
/// scrolls in *pixels*, continuously — `scrollWheelEventIsContinuous` is 1 — and
/// a notched wheel scrolls in *lines*, with that field 0. The distinction is
/// what Victor actually wants: reversing a trackpad on a Mac whose system
/// "natural scrolling" is already on (`com.apple.swipescrolldirection = 1` here)
/// would put the two-finger gesture back to front, and the whole reason he ran
/// Scroll Reverser was to reverse the *mouse* out of that setting while leaving
/// the trackpad in it.
///
/// **Every delta field is negated, not just the line delta.** A scroll event
/// carries the same motion three times over — `DeltaAxis` (lines, what an old
/// app reads), `PointDeltaAxis` (pixels) and `FixedPtDeltaAxis` (a fixed-point
/// refinement of the pixels, what a smooth-scrolling app reads). Flipping only
/// the first is the classic bug in every hand-rolled scroll reverser: the
/// terminal obeys and Chrome carries on scrolling the original way.
///
/// **All six are read before any is written.** Setting one field can make the
/// window server recompute its siblings, so a read-modify-write interleaved
/// across the six could negate a value that had already been negated for us.
enum ScrollReversal {

    /// A trackpad's continuous, pixel-based scrolling is left exactly as it
    /// arrived; only a notched wheel is turned around.
    static func shouldReverse(isContinuous: Int64) -> Bool {
        isContinuous == 0
    }

    /// Negate the event's deltas in place, if it came from a wheel.
    ///
    /// Mutating the event rather than swallowing it and posting a replacement is
    /// the same choice the ⌥ emoji layer makes one file over, for the same two
    /// reasons: a posted event would re-enter our own tap, and one event in is
    /// one event out, which is what a scroll's momentum and phase fields assume.
    ///
    /// Returns whether anything was changed, which is only of interest to tests.
    @discardableResult
    static func apply(to event: CGEvent) -> Bool {
        guard shouldReverse(isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous)) else {
            return false
        }

        let lineY  = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineX  = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

        // Only fields that actually carry a value are written back. A wheel with
        // no horizontal motion leaves axis 2 at zero, and -0 is not a value any
        // reader is expecting to have to cope with.
        if lineY  != 0 { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineY) }
        if lineX  != 0 { event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lineX) }
        if pointY != 0 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointY) }
        if pointX != 0 { event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pointX) }
        if fixedY != 0 { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedY) }
        if fixedX != 0 { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedX) }

        return true
    }
}

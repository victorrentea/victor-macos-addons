import CoreGraphics

/// 🐶💨 Pure geometry for the dog that keeps out of the cursor's way during the
/// 💓 heartbeat. Everything the dog has to decide is a function of the overlay
/// bounds, the dog's own box and one point, so it lives out here where it can be
/// tested without a screen — the same bargain as `CropFlashGeometry`.
///
/// The rule the whole file serves: **the cursor is where the beat happens**, and
/// the beat is a lens of `HeartbeatBump.radius(in:)` — well over half the screen
/// wide. So the dog is never a thing you have to chase off; it is always already
/// on the other half, and it steps aside far enough that no part of it sits
/// inside the disc that is about to pulse.
///
/// Coordinates are the overlay's: bottom-origin, y growing upward.
enum HeartbeatDogFlee {

    /// The silhouette is narrower than its box — the trimmed PNG still carries
    /// transparent corners either side of the ears — so the box is pulled in
    /// before anything is measured against it. Without it the dog gives way to a
    /// cursor that is visibly beside it, which reads as a bug rather than as a
    /// dog minding the beat.
    static let hitInset: CGFloat = 0.14

    /// Half the width of the *visible* dog inside a box of `boxWidth`.
    static func visibleHalfWidth(ofBoxWidth boxWidth: CGFloat) -> CGFloat {
        boxWidth * (0.5 - hitInset)
    }

    /// The two resting centres. The dog is centred *inside its half*, so they are
    /// simply the quarter and three-quarter marks of the screen — which is why
    /// none of this needs to know how wide the dog is.
    static func restingCenterX(onRight: Bool, boundsWidth: CGFloat) -> CGFloat {
        boundsWidth * (onRight ? 0.75 : 0.25)
    }

    /// Dead band around the midline, as a fraction of the width, inside which the
    /// dog keeps whichever half it is already on. Without it a cursor parked on
    /// the seam makes the dog leap back and forth on every poll: the crossing is
    /// a one-pixel event, and hysteresis is what turns it into a decision.
    static let midlineHysteresis: CGFloat = 0.04

    /// Which half the dog belongs on: **the one the cursor is not in.** Inside the
    /// dead band the previous answer stands.
    static func shouldBeOnRight(cursorX: CGFloat, wasOnRight: Bool, boundsWidth: CGFloat) -> Bool {
        let mid = boundsWidth / 2
        let band = boundsWidth * midlineHysteresis
        if cursorX < mid - band { return true }    // cursor left  → dog right
        if cursorX > mid + band { return false }   // cursor right → dog left
        return wasOnRight
    }

    /// Where the dog should actually stand: the quarter mark of its half, pushed
    /// further out — never inward — until its silhouette clears `clearRadius`
    /// around the cursor, then clamped so the box cannot leave the overlay.
    ///
    /// The push is what answers "it must give way a little if the mouse comes
    /// right over it": with the lens as wide as it is, a cursor near the middle
    /// reaches into the far half, and the sidestep is simply how far out that
    /// reach ends. Clamping to the frame can leave a sliver of overlap when the
    /// cursor sits by the seam — that is deliberate, a dog half off the screen
    /// would be the worse of the two failures.
    static func parkedCenterX(onRight: Bool, cursorX: CGFloat, boxWidth: CGFloat,
                              clearRadius: CGFloat, boundsWidth: CGFloat) -> CGFloat {
        let need = clearRadius + visibleHalfWidth(ofBoxWidth: boxWidth)
        let resting = restingCenterX(onRight: onRight, boundsWidth: boundsWidth)
        let clear = onRight ? max(resting, cursorX + need) : min(resting, cursorX - need)
        let lo = boxWidth / 2
        let hi = boundsWidth - boxWidth / 2
        guard lo <= hi else { return boundsWidth / 2 }   // dog wider than the screen
        return min(max(clear, lo), hi)
    }

    /// Sidesteps shorter than this are not worth a hop — the dog would twitch on
    /// every poll while the mouse drifts. Anything smaller is simply not moved.
    static let minStep: CGFloat = 8

    /// Height of the leap's arc: proportional to how far the dog has to go, so a
    /// short hop is a short hop. The cap is a guard for unusual overlay shapes —
    /// on the retina the distance term governs even the longest leap it can make
    /// (half the screen ≈ 212 pt of arc against a 216 pt cap).
    static func apex(fromX: CGFloat, toX: CGFloat, boundsHeight: CGFloat) -> CGFloat {
        min(boundsHeight * 0.22, abs(toX - fromX) * 0.28)
    }

    /// How long a move takes. `full` is the cross-the-screen leap; a sidestep is
    /// paced down from it by the *square root* of the distance, so a 40 pt step
    /// is quick without a 700 pt leap looking hurried. The floor keeps the
    /// smallest steps from being a snap.
    static func hopDuration(distance: CGFloat, boundsWidth: CGFloat, full: Double) -> Double {
        guard boundsWidth > 0, distance > 0 else { return full }
        let reach = boundsWidth / 2          // the two quarter marks, i.e. a full leap
        let ratio = min(1, distance / reach).squareRoot()
        return full * Double(max(0.3, ratio))
    }
}

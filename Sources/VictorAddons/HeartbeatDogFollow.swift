import CoreGraphics

/// 🐶 Pure geometry for the dog that keeps the 💓 heartbeat company. Everything
/// the dog has to decide is a function of the overlay bounds, its own box and one
/// point, so it lives out here where it can be tested without a screen — the same
/// bargain as `HeartbeatBump` and `CropFlashGeometry`.
///
/// **It used to be the exact opposite.** Until 2026-09-06 this file was
/// `HeartbeatDogFlee`: the dog bolted to the half of the screen the cursor was
/// not in. That joke stopped working once Victor started *zooming the room's
/// projector in on the beat* — the dog was then reliably in the half nobody was
/// looking at, i.e. off the projected frame entirely. So the rule inverted: the
/// dog is now **adjacent to the beat**, parked as close to the pulsing disc as it
/// can get without any of it sitting inside, with its **face** — not its centre —
/// as the thing held near the lens.
///
/// Three decisions, in the order they constrain each other:
///
/// 1. **Which side of the cursor.** The one with more room, with hysteresis on
///    the midline so a cursor parked on the seam doesn't make the dog oscillate.
/// 2. **How far along that side.** Far enough that the near edge of the
///    silhouette is outside the lens, then pulled back into the frame — except
///    the dog's *back* is allowed to hang off the outer edge, up to
///    `maxBackOverflow`. A cropped rump is a cheaper failure than a face that has
///    been dragged away from the beat.
/// 3. **How high.** The face rides at the cursor's own height, which routinely
///    puts the chest and shoulders below y = 0. That is intended, and it is what
///    Victor asked for: the photo is cropped at the chest anyway, so a dog
///    leaning in from off the bottom edge reads better than a whole dog parked
///    politely in frame.
///
/// Coordinates are the overlay's: bottom-origin, y growing upward.
enum HeartbeatDogFollow {

    // MARK: - The silhouette, measured off the asset

    /// Where the dog's face sits inside `heartbeat-dog.png` (1024 × 1162, muzzle
    /// pointing right), as a fraction of the box: x from the left edge, y from
    /// the **top**. This is the point the whole placement is written around —
    /// "put the dog near the beat" is really "put *this* point near the beat",
    /// and the difference between the two is most of the dog.
    static let faceFracX: CGFloat = 0.60
    static let faceFracYFromTop: CGFloat = 0.15

    /// The far edge of the silhouette on the muzzle's side, at head height — the
    /// ear and cheek reach 0.86 while the muzzle itself stops around 0.72, so the
    /// ear is what actually has to clear the disc. Measured off the alpha channel
    /// at a 60/255 threshold, not eyeballed.
    ///
    /// The chest lower down is wider still (0.99), but it sits ~400 pt below the
    /// face, where the lens circle has already curved away by more than the extra
    /// width — checked against the retina numbers, it clears.
    static let headSideFracX: CGFloat = 0.86

    /// The other ear runs right off the opposite edge of the trimmed PNG, so the
    /// back of the silhouette is the box edge.
    static let backSideFracX: CGFloat = 0.0

    /// Face → near edge of the silhouette, horizontally. This is the slack that
    /// has to be added on top of the lens radius so that the *ear*, not the face,
    /// is what sits on the circle.
    static func faceToNearEdge(boxWidth: CGFloat) -> CGFloat {
        boxWidth * (headSideFracX - faceFracX)
    }

    /// Face → back edge of the silhouette. What decides how far the dog can be
    /// pushed outward before its rump leaves the frame.
    static func faceToBackEdge(boxWidth: CGFloat) -> CGFloat {
        boxWidth * (faceFracX - backSideFracX)
    }

    /// Face → top of the box, i.e. how far the ears rise above the face. The
    /// sink-below-the-beat fallback has to clear *those*, not the face.
    static func faceToTop(boxHeight: CGFloat) -> CGFloat {
        boxHeight * faceFracYFromTop
    }

    /// Where the face anchor sits relative to the layer's `position` (its centre),
    /// for the facing the dog will have on that side. The layer is mirrored by a
    /// scale about its own centre, so the x offset simply flips with it.
    static func faceOffset(onRight: Bool, boxSize: CGSize) -> CGVector {
        CGVector(dx: (onRight ? -1 : 1) * (faceFracX - 0.5) * boxSize.width,
                 dy: (0.5 - faceFracYFromTop) * boxSize.height)
    }

    // MARK: - Which side

    /// Breathing room between the silhouette and the edge of the lens. Small on
    /// purpose: "as close as possible without overlapping" was the ask, so this
    /// is the width of "not touching", not a comfortable gap.
    static let clearMargin: CGFloat = 18

    /// How much of the box may hang off the outer edge of the screen, as a
    /// fraction of its width — the rump, always, since the dog faces inward.
    /// Clamping the box fully into frame instead would shove the face back inside
    /// the pulsing disc, which is the one thing this placement exists to avoid.
    static let maxBackOverflow: CGFloat = 0.25

    /// Dead band around the midline, as a fraction of the width, inside which the
    /// dog keeps whichever side it is already on. Without it a cursor parked on
    /// the seam makes the dog leap back and forth on every poll: the crossing is
    /// a one-pixel event, and hysteresis is what turns it into a decision.
    static let midlineHysteresis: CGFloat = 0.04

    /// Which side of the cursor the dog stands on: **the side with more room**,
    /// which for a cursor in the left half is the right. Inside the dead band the
    /// previous answer stands.
    static func shouldBeOnRight(cursorX: CGFloat, wasOnRight: Bool, boundsWidth: CGFloat) -> Bool {
        let mid = boundsWidth / 2
        let band = boundsWidth * midlineHysteresis
        if cursorX < mid - band { return true }    // cursor left  → dog to its right
        if cursorX > mid + band { return false }   // cursor right → dog to its left
        return wasOnRight
    }

    // MARK: - Where the face goes

    /// Lowest the face is allowed to sink when the frame forces the dog under the
    /// beat, as a fraction of the height — but never *above* the cursor, because
    /// a cursor already down at the floor is a beat down at the floor, and the
    /// face belongs beside it.
    static let faceFloorFraction: CGFloat = 0.10

    /// The face anchor's target, in overlay points.
    ///
    /// One constraint drives all of it: **the near-top corner of the silhouette —
    /// the ear on the beat's side — must stay outside the lens circle.** There
    /// are two ways to buy that clearance and they are spent in a fixed order,
    /// cheapest cost first:
    ///
    /// 1. **Step sideways**, up to the point where `maxBackOverflow` of the box
    ///    hangs off the outer edge. Free: it costs only rump.
    /// 2. **Sink**, if the frame ate the sidestep — drop the dog until it is
    ///    *below* the beat rather than beside it. Costs body below the bottom
    ///    edge, which Victor explicitly signed off on, but it runs out at
    ///    `faceFloorFraction`: a face below the floor is no dog at all.
    /// 3. **Step sideways past the budget**, once sinking is exhausted. The rump
    ///    hangs off further than anyone would design for, and the only hard stop
    ///    is the face itself staying inside the frame. Overlapping the beat is
    ///    worse than a cropped dog: the dog is a *sibling* of the capture layer,
    ///    so it does not pulse — it just covers the one part of the screen the
    ///    projector is zoomed into.
    ///
    /// On the retina, with the cursor anywhere but hard on the midline, step 1
    /// alone answers it and the other two never run.
    static func facePoint(onRight: Bool, cursor: CGPoint, boxSize: CGSize,
                          clearRadius: CGFloat, bounds: CGRect) -> CGPoint {
        let near = faceToNearEdge(boxWidth: boxSize.width)
        let back = faceToBackEdge(boxWidth: boxSize.width)
        let ears = faceToTop(boxHeight: boxSize.height)
        let want = clearRadius + clearMargin
        let dir: CGFloat = onRight ? 1 : -1

        // A dog wider than the screen has no placement worth the name.
        let slack = boxSize.width * maxBackOverflow
        let lo = back - slack, hi = bounds.width - back + slack
        guard lo <= hi else { return CGPoint(x: bounds.width / 2, y: cursor.y) }

        // 1. The sidestep, on its budget.
        var faceX = min(max(cursor.x + dir * (want + near), lo), hi)
        var faceY = cursor.y
        let gap = max(0, abs(faceX - cursor.x) - near)   // cursor → near edge

        if gap < want {
            // 2. Sink, as far as the floor allows.
            let sinkNeeded = (want * want - gap * gap).squareRoot() + ears
            let sinkAvailable = cursor.y - min(cursor.y, bounds.height * faceFloorFraction)
            let sink = min(sinkNeeded, sinkAvailable)
            faceY = cursor.y - sink

            // 3. Still short? Buy the rest sideways, at any width.
            if sink < sinkNeeded {
                let bought = max(0, sink - ears)         // vertical clearance the sink won
                let needed = (want * want - bought * bought).squareRoot()
                faceX = min(max(cursor.x + dir * (needed + near), 0), bounds.width)
            }
        }

        // The ears must not leave the TOP of the frame — unlike the bottom, there
        // is no more dog up there to crop.
        faceY = min(faceY, bounds.height - ears)
        return CGPoint(x: faceX, y: faceY)
    }

    /// The layer `position` (its centre) that puts the face where `facePoint`
    /// says it goes.
    static func position(onRight: Bool, cursor: CGPoint, boxSize: CGSize,
                         clearRadius: CGFloat, bounds: CGRect) -> CGPoint {
        let face = facePoint(onRight: onRight, cursor: cursor, boxSize: boxSize,
                             clearRadius: clearRadius, bounds: bounds)
        let offset = faceOffset(onRight: onRight, boxSize: boxSize)
        return CGPoint(x: face.x - offset.dx, y: face.y - offset.dy)
    }

    // MARK: - Motion

    /// Moves shorter than this are not worth animating — the dog would twitch on
    /// every poll while the mouse drifts by a pixel.
    static let minStep: CGFloat = 4

    /// Height of the leap's arc when the dog changes sides: proportional to how
    /// far it has to go, so a short hop is a short hop. The cap is a guard for
    /// unusual overlay shapes — on the retina the distance term governs even the
    /// longest leap it can make.
    static func apex(fromX: CGFloat, toX: CGFloat, boundsHeight: CGFloat) -> CGFloat {
        min(boundsHeight * 0.22, abs(toX - fromX) * 0.28)
    }

    /// How long a side change takes. `full` is the cross-the-screen leap; a
    /// shorter one is paced down from it by the *square root* of the distance, so
    /// a 40 pt hop is quick without a 700 pt leap looking hurried. The floor keeps
    /// the smallest ones from being a snap.
    static func hopDuration(distance: CGFloat, boundsWidth: CGFloat, full: Double) -> Double {
        guard boundsWidth > 0, distance > 0 else { return full }
        let reach = boundsWidth / 2          // the two quarter marks, i.e. a full leap
        let ratio = min(1, distance / reach).squareRoot()
        return full * Double(max(0.3, ratio))
    }
}

import CoreGraphics

/// 💓 Pure geometry for the **local** bulge that the heartbeat beats with.
///
/// The effect used to scale the whole captured screen 1.0 → 1.30 around the
/// cursor. That put the biggest displacement exactly where the eye is *not*
/// looking: a corner 1500 pt away from the pivot swept ~450 pt on every thump,
/// so the periphery lurched while the thing under the pointer barely moved.
/// Two beats of that reads as vertigo rather than as a pulse.
///
/// So the zoom is gone and a `CIBumpDistortion` took its place: a convex lens
/// that magnifies a disc under the cursor and is **exactly identity outside its
/// radius** — the periphery is not merely moved less, it is not moved at all.
/// What is left of the old zoom is a `breatheScale` hair of whole-screen
/// motion, pivoted at the centre so it stays symmetric.
///
/// Same bargain as `HeartbeatDogFlee` and `CropFlashGeometry`: every decision
/// here is a function of the overlay bounds, so it lives out where it can be
/// tested without a screen.
enum HeartbeatBump {

    /// How much of the screen the lens covers. The first ask was "those 10% of
    /// the screen under the mouse", and area — not width — is what the eye
    /// judges that by, hence `radius(in:)` solving πr² = fraction · W · H.
    ///
    /// On 2026-08-27 Victor asked for the beat to be **twice as big — its size,
    /// not its amplitude**. The size of a disc is how wide it reads, i.e. its
    /// radius, so doubling that quadruples the surface it sits on: 10% → 40%.
    /// The bargain the rewrite made survives it untouched — outside the radius
    /// `CIBumpDistortion` is still the identity, so a wider lens costs the
    /// periphery exactly nothing, it just leaves a thinner still margin.
    static let areaFraction: CGFloat = 0.40

    /// Peak `inputScale` of the bump, i.e. how convex the lens gets at the top
    /// of a lub or a dub. 0.5 roughly doubles the middle of the disc — the same
    /// punch the old 1.30 zoom had, minus the swept periphery. Past ~0.7 the
    /// centre stretches into a fisheye smear.
    ///
    /// This is the *amplitude* Victor explicitly did NOT want changed when the
    /// lens grew: `inputScale` is relative to the radius, so a lens of twice the
    /// size bulges by the same factor over twice the distance — bigger, not
    /// punchier. Leave it where it is when tuning `areaFraction`.
    static let peakScale: CGFloat = 0.5

    /// The residual whole-screen breathe, kept deliberately tiny (the old value
    /// was 1.30). It is what stops the screen from looking frozen between the
    /// lens pulses; at 1.02 a corner travels well under 20 pt, which registers
    /// as the screen being alive rather than as the room tilting.
    static let breatheScale: CGFloat = 1.02

    /// Radius of the lens, in the overlay's points: the disc whose area is
    /// `areaFraction` of the screen. On the retina (1728 × 1117 pt) that is
    /// ~496 pt — a lens about four sevenths of the screen wide.
    static func radius(in bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return (bounds.width * bounds.height * areaFraction / .pi).squareRoot()
    }

    /// The lens centre in layer points, from the unit-square cursor anchor that
    /// `layerAnchor(forGlobalMouse:…)` already computes for the effect.
    ///
    /// Deliberately **not** clamped away from the edges: with the cursor in a
    /// corner the right answer is a quarter-lens in that corner, not a whole
    /// one that has drifted inward off the pointer.
    static func center(forAnchor anchor: CGPoint, bounds: CGRect) -> CGPoint {
        CGPoint(x: anchor.x * bounds.width, y: anchor.y * bounds.height)
    }
}

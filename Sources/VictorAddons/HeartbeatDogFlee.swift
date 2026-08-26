import CoreGraphics

/// 🐶💨 Pure geometry for the dog that bolts away from the cursor during the 💓
/// heartbeat. Everything the flee has to decide is a function of the overlay
/// bounds, the dog's current box and one point, so it lives out here where it
/// can be tested without a screen — the same bargain as `CropFlashGeometry`.
///
/// Coordinates are the overlay's: bottom-origin, y growing upward.
enum HeartbeatDogFlee {

    /// The silhouette is narrower than its box — the trimmed PNG still carries
    /// transparent corners either side of the ears — so the box is pulled in
    /// before the hit test. Without it the dog bolts from a cursor that is
    /// visibly beside it, which reads as a bug rather than as a scare.
    static let hitInset: CGFloat = 0.14

    /// The two resting centres. The dog is centred *inside its half*, so they are
    /// simply the quarter and three-quarter marks of the screen — which is why
    /// none of this needs to know how wide the dog is.
    static func restingCenterX(onRight: Bool, boundsWidth: CGFloat) -> CGFloat {
        boundsWidth * (onRight ? 0.75 : 0.25)
    }

    /// Whether `cursor` counts as having landed on a dog occupying `box`.
    static func isStartled(cursor: CGPoint, box: CGRect) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        return box.insetBy(dx: box.width * hitInset, dy: 0).contains(cursor)
    }

    /// Height of the leap's arc: proportional to how far the dog has to go, so a
    /// short hop is a short hop. The cap is a guard for unusual overlay shapes —
    /// on the retina the distance term governs even the longest leap it can make
    /// (half the screen ≈ 212 pt of arc against a 216 pt cap).
    static func apex(fromX: CGFloat, toX: CGFloat, boundsHeight: CGFloat) -> CGFloat {
        min(boundsHeight * 0.22, abs(toX - fromX) * 0.28)
    }
}

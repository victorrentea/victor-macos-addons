import XCTest
@testable import VictorAddons

/// A retina-sized overlay: 1512 × 982 points, bottom-origin — the same one
/// `HeartbeatDogFleeTests` uses, so the two read as one effect.
private let W: CGFloat = 1512
private let H: CGFloat = 982

final class HeartbeatBumpTests: XCTestCase {

    // The whole point of the rewrite: the lens covers the tenth of the screen
    // Victor asked for, measured as AREA (πr² = 0.10 · W · H), not as width.
    func testLensCoversATenthOfTheScreenByArea() {
        let r = HeartbeatBump.radius(in: CGRect(x: 0, y: 0, width: W, height: H))
        let area = CGFloat.pi * r * r
        XCTAssertEqual(area / (W * H), HeartbeatBump.areaFraction, accuracy: 0.0001)
    }

    // …which is a lens roughly a seventh of the screen wide. Stated as a plain
    // number so a future tweak to `areaFraction` has to face what it looks like.
    func testLensRadiusOnTheRetina() {
        let r = HeartbeatBump.radius(in: CGRect(x: 0, y: 0, width: W, height: H))
        XCTAssertEqual(r, 217.4, accuracy: 0.1)
        XCTAssertLessThan(2 * r, W / 3)
    }

    // A degenerate overlay (no screen yet) must not produce a NaN radius that
    // would poison CIBumpDistortion.
    func testEmptyBoundsGiveNoLens() {
        XCTAssertEqual(HeartbeatBump.radius(in: .zero), 0)
    }

    // The lens sits exactly on the cursor: the anchor is the unit-square mouse
    // position `layerAnchor(forGlobalMouse:…)` hands over.
    func testCentreFollowsTheCursorAnchor() {
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        XCTAssertEqual(HeartbeatBump.center(forAnchor: CGPoint(x: 0.5, y: 0.5), bounds: bounds),
                       CGPoint(x: 756, y: 491))
        XCTAssertEqual(HeartbeatBump.center(forAnchor: CGPoint(x: 0.25, y: 0.75), bounds: bounds),
                       CGPoint(x: 378, y: 736.5))
    }

    // Not clamped inward: a cursor in the corner gets a corner lens, not one
    // that has slid off the pointer to keep its whole circle on screen.
    func testCornerCursorKeepsTheLensOnTheCorner() {
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        XCTAssertEqual(HeartbeatBump.center(forAnchor: .zero, bounds: bounds), .zero)
        XCTAssertEqual(HeartbeatBump.center(forAnchor: CGPoint(x: 1, y: 1), bounds: bounds),
                       CGPoint(x: W, y: H))
    }

    // The periphery is the whole complaint this change answers. The old effect
    // scaled everything by 1.30 around the cursor; what is left is a breathe
    // small enough that the far corner travels under 20 pt.
    func testResidualBreatheBarelyMovesTheFarCorner() {
        let halfDiagonal = (W * W + H * H).squareRoot() / 2
        let drift = halfDiagonal * (HeartbeatBump.breatheScale - 1)
        XCTAssertLessThan(drift, 20)
        // …versus the 270 pt it used to sweep at 1.30.
        XCTAssertGreaterThan(halfDiagonal * 0.30, 250)
    }
}

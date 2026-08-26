import XCTest
@testable import VictorAddons

/// A retina-sized overlay: 1512 × 982 points, bottom-origin.
private let W: CGFloat = 1512
private let H: CGFloat = 982

final class HeartbeatDogFleeTests: XCTestCase {

    // The dog is centred inside its half, so the resting centres are the
    // quarter marks — whatever the dog's width turns out to be.
    func testRestingCentresAreTheQuarterMarks() {
        XCTAssertEqual(HeartbeatDogFlee.restingCenterX(onRight: false, boundsWidth: W), 378)
        XCTAssertEqual(HeartbeatDogFlee.restingCenterX(onRight: true, boundsWidth: W), 1134)
    }

    func testTheTwoRestingCentresAreMirrorImages() {
        let left = HeartbeatDogFlee.restingCenterX(onRight: false, boundsWidth: W)
        let right = HeartbeatDogFlee.restingCenterX(onRight: true, boundsWidth: W)
        XCTAssertEqual(left, W - right, accuracy: 0.001)
    }

    // 462 × 524 is the dog at 2/3 scale, bottom-aligned in the left half.
    private let box = CGRect(x: 147, y: 0, width: 462, height: 524)

    func testCursorOnTheDogStartlesIt() {
        XCTAssertTrue(HeartbeatDogFlee.isStartled(cursor: CGPoint(x: 378, y: 260), box: box))
    }

    func testCursorBesideTheDogDoesNot() {
        XCTAssertFalse(HeartbeatDogFlee.isStartled(cursor: CGPoint(x: 900, y: 260), box: box))
    }

    func testCursorAboveTheDogDoesNot() {
        XCTAssertFalse(HeartbeatDogFlee.isStartled(cursor: CGPoint(x: 378, y: 700), box: box))
    }

    /// The whole point of the inset: the transparent corners either side of the
    /// ears are inside the box but outside the dog, and must not startle it.
    func testTheTransparentMarginBesideTheEarsIsNotTheDog() {
        let justInsideTheBox = CGPoint(x: box.minX + 10, y: 300)
        XCTAssertTrue(box.contains(justInsideTheBox))
        XCTAssertFalse(HeartbeatDogFlee.isStartled(cursor: justInsideTheBox, box: box))
    }

    func testInsetIsHorizontalOnly_theFeetAreStillTheDog() {
        let atTheFloor = CGPoint(x: 378, y: 1)
        XCTAssertTrue(HeartbeatDogFlee.isStartled(cursor: atTheFloor, box: box))
    }

    func testAnEmptyBoxStartlesNothing() {
        XCTAssertFalse(HeartbeatDogFlee.isStartled(cursor: .zero, box: .zero))
    }

    // On the retina the DISTANCE term governs even for the longest leap the dog
    // can make (half the screen): 756 * 0.28 = 211.68, just under the 216.04 cap.
    // The cap is a guard for other geometries, not what shapes the normal hop.
    func testFullLeapIsShapedByTheDistanceNotTheCap() {
        let apex = HeartbeatDogFlee.apex(fromX: 378, toX: 1134, boundsHeight: H)
        XCTAssertEqual(apex, 211.68, accuracy: 0.001)
        XCTAssertLessThan(apex, H * 0.22)
        XCTAssertLessThan(apex, H / 2)          // nowhere near leaving the screen
    }

    // …and on a short, wide overlay the cap is what keeps the dog in frame.
    func testCapBindsOnAShortOverlay() {
        let apex = HeartbeatDogFlee.apex(fromX: 0, toX: W, boundsHeight: 300)
        XCTAssertEqual(apex, 300 * 0.22, accuracy: 0.001)
    }

    func testShortLeapGetsAShortArc() {
        let apex = HeartbeatDogFlee.apex(fromX: 378, toX: 478, boundsHeight: H)
        XCTAssertEqual(apex, 28, accuracy: 0.001)
    }

    func testLeapingBackwardsArcsJustAsHigh() {
        XCTAssertEqual(HeartbeatDogFlee.apex(fromX: 1134, toX: 378, boundsHeight: H),
                       HeartbeatDogFlee.apex(fromX: 378, toX: 1134, boundsHeight: H))
    }
}

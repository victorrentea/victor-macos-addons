import XCTest
@testable import VictorAddons

/// A retina-sized overlay: 1512 × 982 points, bottom-origin.
private let W: CGFloat = 1512
private let H: CGFloat = 982

/// 462 × 524 is the dog at 2/3 scale, bottom-aligned in the left half.
private let boxWidth: CGFloat = 462

/// The lens the dog has to stay out of, for this overlay: ~435 pt.
private let lens = HeartbeatBump.radius(in: CGRect(x: 0, y: 0, width: W, height: H))

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

    /// The whole point of the inset: the transparent corners either side of the
    /// ears are inside the box but outside the dog, so the silhouette that has to
    /// clear the beat is narrower than the layer.
    func testVisibleWidthIsNarrowerThanTheBox() {
        XCTAssertEqual(HeartbeatDogFlee.visibleHalfWidth(ofBoxWidth: boxWidth), 166.32, accuracy: 0.001)
        XCTAssertLessThan(HeartbeatDogFlee.visibleHalfWidth(ofBoxWidth: boxWidth), boxWidth / 2)
    }

    // MARK: - Which half

    func testCursorOnTheLeftPutsTheDogOnTheRight() {
        XCTAssertTrue(HeartbeatDogFlee.shouldBeOnRight(cursorX: 200, wasOnRight: false, boundsWidth: W))
    }

    func testCursorOnTheRightPutsTheDogOnTheLeft() {
        XCTAssertFalse(HeartbeatDogFlee.shouldBeOnRight(cursorX: 1300, wasOnRight: true, boundsWidth: W))
    }

    /// Crossing the seam is a one-pixel event; without the dead band a cursor
    /// resting on it would make the dog leap back and forth on every poll.
    func testInsideTheDeadBandTheDogKeepsItsHalf() {
        let justLeftOfCentre = W / 2 - W * HeartbeatDogFlee.midlineHysteresis / 2
        XCTAssertTrue(HeartbeatDogFlee.shouldBeOnRight(cursorX: justLeftOfCentre,
                                                       wasOnRight: true, boundsWidth: W))
        XCTAssertFalse(HeartbeatDogFlee.shouldBeOnRight(cursorX: justLeftOfCentre,
                                                        wasOnRight: false, boundsWidth: W))
    }

    func testPastTheDeadBandTheDogCommits() {
        let clearlyLeft = W / 2 - W * HeartbeatDogFlee.midlineHysteresis - 1
        XCTAssertTrue(HeartbeatDogFlee.shouldBeOnRight(cursorX: clearlyLeft,
                                                       wasOnRight: false, boundsWidth: W))
        let clearlyRight = W / 2 + W * HeartbeatDogFlee.midlineHysteresis + 1
        XCTAssertFalse(HeartbeatDogFlee.shouldBeOnRight(cursorX: clearlyRight,
                                                        wasOnRight: true, boundsWidth: W))
    }

    // MARK: - The sidestep

    private func parked(onRight: Bool, cursorX: CGFloat) -> CGFloat {
        HeartbeatDogFlee.parkedCenterX(onRight: onRight, cursorX: cursorX,
                                       boxWidth: boxWidth, clearRadius: lens, boundsWidth: W)
    }

    /// A cursor far out on its own side reaches nowhere near the other half, so
    /// the dog just stands at its quarter mark.
    func testACursorInTheFarCornerLeavesTheDogAtRest() {
        XCTAssertEqual(parked(onRight: true, cursorX: 60),
                       HeartbeatDogFlee.restingCenterX(onRight: true, boundsWidth: W))
    }

    /// The ask: the beat is what the cursor is aiming at, and no part of the dog
    /// may sit inside it.
    func testTheDogEndsUpOutsideTheBeat() {
        let cursorX: CGFloat = 640                      // left half, but near the seam
        let x = parked(onRight: true, cursorX: cursorX)
        let nearEdge = x - HeartbeatDogFlee.visibleHalfWidth(ofBoxWidth: boxWidth)
        XCTAssertGreaterThanOrEqual(nearEdge, cursorX + lens - 0.001)
    }

    /// A cursor creeping toward the middle pushes the dog further out, never back
    /// in: the sidestep is one-way, away from the beat.
    func testTheSidestepOnlyEverPushesOutward() {
        var previous = parked(onRight: true, cursorX: 0)
        for cursorX in stride(from: CGFloat(0), through: W / 2, by: 40) {
            let x = parked(onRight: true, cursorX: cursorX)
            XCTAssertGreaterThanOrEqual(x, previous - 0.001)
            previous = x
        }
    }

    func testTheSidestepIsMirroredOnTheLeftHalf() {
        XCTAssertEqual(parked(onRight: false, cursorX: W - 640),
                       W - parked(onRight: true, cursorX: 640), accuracy: 0.001)
    }

    /// Clearing the beat outright is not always possible — a cursor by the seam
    /// reaches most of the far half. Then the frame wins: a dog half off the
    /// screen would be the worse of the two failures.
    func testTheDogNeverLeavesTheFrame() {
        for cursorX in stride(from: CGFloat(0), through: W, by: 24) {
            for onRight in [true, false] {
                let x = parked(onRight: onRight, cursorX: cursorX)
                XCTAssertGreaterThanOrEqual(x, boxWidth / 2 - 0.001)
                XCTAssertLessThanOrEqual(x, W - boxWidth / 2 + 0.001)
            }
        }
    }

    func testADogWiderThanTheScreenIsSimplyCentred() {
        XCTAssertEqual(HeartbeatDogFlee.parkedCenterX(onRight: true, cursorX: 100,
                                                      boxWidth: W * 1.5, clearRadius: lens,
                                                      boundsWidth: W), W / 2)
    }

    // MARK: - The arc and its pacing

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

    func testACrossScreenLeapTakesTheFullDuration() {
        XCTAssertEqual(HeartbeatDogFlee.hopDuration(distance: W / 2, boundsWidth: W, full: 0.42),
                       0.42, accuracy: 0.0001)
    }

    func testASidestepIsQuickerThanALeapButNotASnap() {
        let step = HeartbeatDogFlee.hopDuration(distance: 40, boundsWidth: W, full: 0.42)
        XCTAssertLessThan(step, 0.42)
        XCTAssertGreaterThanOrEqual(step, 0.42 * 0.3 - 0.0001)   // the floor
    }

    func testTinyDistancesAreStillPacedByTheFloor() {
        XCTAssertEqual(HeartbeatDogFlee.hopDuration(distance: 0.5, boundsWidth: W, full: 0.42),
                       0.42 * 0.3, accuracy: 0.0001)
    }
}

import XCTest
@testable import VictorAddons

/// A retina-sized overlay: 1512 × 982 points, bottom-origin.
private let W: CGFloat = 1512
private let H: CGFloat = 982
private let bounds = CGRect(x: 0, y: 0, width: W, height: H)

/// 462 × 524 is the dog at 2/3 of the aspect-fit of half this overlay.
private let box = CGSize(width: 462, height: 524)

/// The lens the dog has to stay out of, for this overlay: ~435 pt.
private let lens = HeartbeatBump.radius(in: bounds)

private func face(onRight: Bool, cursor: CGPoint) -> CGPoint {
    HeartbeatDogFollow.facePoint(onRight: onRight, cursor: cursor, boxSize: box,
                                 clearRadius: lens, bounds: bounds)
}

/// Where the near edge of the silhouette ends up, i.e. the ear that has to clear
/// the pulsing disc.
private func nearEdgeX(onRight: Bool, cursor: CGPoint) -> CGFloat {
    let f = face(onRight: onRight, cursor: cursor)
    let near = HeartbeatDogFollow.faceToNearEdge(boxWidth: box.width)
    return onRight ? f.x - near : f.x + near
}

/// How much of the box hangs off either side of the frame.
private func overflow(cursor: CGPoint) -> CGFloat {
    let onRight = HeartbeatDogFollow.shouldBeOnRight(cursorX: cursor.x, wasOnRight: true,
                                                     boundsWidth: W)
    let p = HeartbeatDogFollow.position(onRight: onRight, cursor: cursor, boxSize: box,
                                        clearRadius: lens, bounds: bounds)
    return max(0, box.width / 2 - p.x) + max(0, p.x + box.width / 2 - W)
}

final class HeartbeatDogFollowTests: XCTestCase {

    // MARK: - Which side

    func testCursorOnTheLeftPutsTheDogToItsRight() {
        XCTAssertTrue(HeartbeatDogFollow.shouldBeOnRight(cursorX: 200, wasOnRight: false, boundsWidth: W))
    }

    func testCursorOnTheRightPutsTheDogToItsLeft() {
        XCTAssertFalse(HeartbeatDogFollow.shouldBeOnRight(cursorX: 1300, wasOnRight: true, boundsWidth: W))
    }

    /// Crossing the seam is a one-pixel event; without the dead band a cursor
    /// resting on it would make the dog leap back and forth on every poll.
    func testInsideTheDeadBandTheDogKeepsItsSide() {
        let justLeftOfCentre = W / 2 - W * HeartbeatDogFollow.midlineHysteresis / 2
        XCTAssertTrue(HeartbeatDogFollow.shouldBeOnRight(cursorX: justLeftOfCentre,
                                                         wasOnRight: true, boundsWidth: W))
        XCTAssertFalse(HeartbeatDogFollow.shouldBeOnRight(cursorX: justLeftOfCentre,
                                                          wasOnRight: false, boundsWidth: W))
    }

    func testPastTheDeadBandTheDogCommits() {
        let clearlyLeft = W / 2 - W * HeartbeatDogFollow.midlineHysteresis - 1
        XCTAssertTrue(HeartbeatDogFollow.shouldBeOnRight(cursorX: clearlyLeft,
                                                         wasOnRight: false, boundsWidth: W))
        let clearlyRight = W / 2 + W * HeartbeatDogFollow.midlineHysteresis + 1
        XCTAssertFalse(HeartbeatDogFollow.shouldBeOnRight(cursorX: clearlyRight,
                                                          wasOnRight: true, boundsWidth: W))
    }

    // MARK: - The face is what gets parked

    /// The whole inversion in one assertion: the dog is now *beside* the beat,
    /// not on the far half of the screen.
    func testTheFaceSitsJustOutsideTheBeatNotAcrossTheScreen() {
        let cursor = CGPoint(x: 400, y: H / 2)
        let f = face(onRight: true, cursor: cursor)
        let reach = f.x - cursor.x
        XCTAssertGreaterThan(reach, lens)                 // outside the disc…
        XCTAssertLessThan(reach, lens + box.width / 2)    // …but hugging it
    }

    /// "As close as possible without overlapping": it is the ear, not the face,
    /// that sits on the circle, so the face is exactly one ear further out.
    func testTheEarLandsOnTheEdgeOfTheDisc() {
        let cursor = CGPoint(x: 400, y: H / 2)
        let edge = nearEdgeX(onRight: true, cursor: cursor)
        XCTAssertEqual(edge - cursor.x, lens + HeartbeatDogFollow.clearMargin, accuracy: 0.001)
    }

    func testNoPartOfTheSilhouetteEverEntersTheDisc() {
        for x in stride(from: CGFloat(0), through: W, by: 24) {
            for y in stride(from: CGFloat(0), through: H, by: 24) {
                let cursor = CGPoint(x: x, y: y)
                let onRight = HeartbeatDogFollow.shouldBeOnRight(cursorX: x, wasOnRight: true,
                                                                 boundsWidth: W)
                let f = face(onRight: onRight, cursor: cursor)
                // The corner of the silhouette nearest the beat: near edge
                // horizontally, ear-top vertically.
                let corner = CGPoint(x: nearEdgeX(onRight: onRight, cursor: cursor),
                                     y: f.y + HeartbeatDogFollow.faceToTop(boxHeight: box.height))
                let d = ((corner.x - x) * (corner.x - x) + (corner.y - y) * (corner.y - y)).squareRoot()
                XCTAssertGreaterThanOrEqual(d, lens, "cursor \(cursor) put the dog inside the beat")
            }
        }
    }

    func testThePlacementIsMirroredOnTheOtherSide() {
        let cursor = CGPoint(x: 640, y: 300)
        let mirrored = CGPoint(x: W - 640, y: 300)
        XCTAssertEqual(face(onRight: false, cursor: mirrored).x,
                       W - face(onRight: true, cursor: cursor).x, accuracy: 0.001)
    }

    // MARK: - Height: the face tracks the cursor, the body may leave the frame

    func testTheFaceRidesAtTheCursorsOwnHeight() {
        for y in stride(from: CGFloat(120), through: H - 120, by: 40) {
            XCTAssertEqual(face(onRight: true, cursor: CGPoint(x: 300, y: y)).y, y, accuracy: 0.001)
        }
    }

    /// The ask, stated as a test: a beat low on the screen is allowed to leave
    /// most of the dog below the bottom edge rather than drag its face upward.
    func testALowBeatPushesTheBodyOffTheBottom() {
        let cursor = CGPoint(x: 300, y: 90)
        let p = HeartbeatDogFollow.position(onRight: true, cursor: cursor, boxSize: box,
                                            clearRadius: lens, bounds: bounds)
        XCTAssertLessThan(p.y - box.height / 2, 0)                  // body below the floor
        XCTAssertEqual(face(onRight: true, cursor: cursor).y, 90, accuracy: 0.001)
    }

    /// …but there is no dog above the ears to crop, so the top is a hard stop.
    func testTheEarsNeverLeaveTheTopOfTheFrame() {
        for y in stride(from: CGFloat(0), through: H, by: 20) {
            let f = face(onRight: true, cursor: CGPoint(x: 300, y: y))
            XCTAssertLessThanOrEqual(f.y + HeartbeatDogFollow.faceToTop(boxHeight: box.height),
                                     H + 0.001)
        }
    }

    func testTheFaceNeverSinksOutOfSight() {
        for x in stride(from: CGFloat(0), through: W, by: 24) {
            for y in stride(from: CGFloat(0), through: H, by: 24) {
                let onRight = HeartbeatDogFollow.shouldBeOnRight(cursorX: x, wasOnRight: true,
                                                                 boundsWidth: W)
                XCTAssertGreaterThanOrEqual(face(onRight: onRight, cursor: CGPoint(x: x, y: y)).y, 0)
            }
        }
    }

    // MARK: - The frame

    /// Away from the seam the sidestep is cheap: the dog barely leans off the
    /// edge, nowhere near its budget.
    func testAwayFromTheSeamTheDogStaysWellInsideItsBudget() {
        for x in stride(from: CGFloat(0), through: W, by: 24) {
            guard abs(x - W / 2) > W * HeartbeatDogFollow.midlineHysteresis else { continue }
            for y in stride(from: CGFloat(0), through: H, by: 24) {
                XCTAssertLessThanOrEqual(overflow(cursor: CGPoint(x: x, y: y)),
                                         box.width * HeartbeatDogFollow.maxBackOverflow,
                                         "cursor (\(x), \(y)) hung too much of the dog off the edge")
            }
        }
    }

    /// A cursor held on the midline *and* low on the screen is the one case that
    /// spends past the budget: neither half has room and there is no sink left,
    /// so the dog steps further out and lets more of its rump go. Still a third
    /// of the box at worst — a cropped dog beats a covered beat.
    func testTheSeamIsTheOnlyPlaceThatSpendsPastTheBudget() {
        var worst: CGFloat = 0
        for x in stride(from: CGFloat(0), through: W, by: 8) {
            for y in stride(from: CGFloat(0), through: H, by: 8) {
                worst = max(worst, overflow(cursor: CGPoint(x: x, y: y)))
            }
        }
        XCTAssertGreaterThan(worst, box.width * HeartbeatDogFollow.maxBackOverflow)
        XCTAssertLessThanOrEqual(worst, box.width * 0.35)
    }

    /// The one hard stop of the emergency sidestep: whatever else gets cropped,
    /// the face has to be on the screen.
    func testTheFaceIsAlwaysInsideTheFrame() {
        for x in stride(from: CGFloat(0), through: W, by: 24) {
            for y in stride(from: CGFloat(0), through: H, by: 24) {
                let onRight = HeartbeatDogFollow.shouldBeOnRight(cursorX: x, wasOnRight: true,
                                                                 boundsWidth: W)
                let f = face(onRight: onRight, cursor: CGPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(f.x, 0)
                XCTAssertLessThanOrEqual(f.x, W)
                XCTAssertLessThanOrEqual(f.y, H)
            }
        }
    }

    /// The mirror flips which end of the box the face is at, so the layer centre
    /// lands on opposite sides of the same face point.
    func testTheFaceOffsetFlipsWithTheDog() {
        let left = HeartbeatDogFollow.faceOffset(onRight: false, boxSize: box)
        let right = HeartbeatDogFollow.faceOffset(onRight: true, boxSize: box)
        XCTAssertEqual(left.dx, -right.dx, accuracy: 0.001)
        XCTAssertEqual(left.dy, right.dy, accuracy: 0.001)
        XCTAssertGreaterThan(left.dy, 0)          // the face is above the box's centre
    }

    func testPositionAndFacePointAgree() {
        let cursor = CGPoint(x: 500, y: 400)
        let p = HeartbeatDogFollow.position(onRight: true, cursor: cursor, boxSize: box,
                                            clearRadius: lens, bounds: bounds)
        let o = HeartbeatDogFollow.faceOffset(onRight: true, boxSize: box)
        let f = face(onRight: true, cursor: cursor)
        XCTAssertEqual(p.x + o.dx, f.x, accuracy: 0.001)
        XCTAssertEqual(p.y + o.dy, f.y, accuracy: 0.001)
    }

    func testADogWiderThanTheScreenIsSimplyCentred() {
        let huge = CGSize(width: W * 1.5, height: box.height)
        XCTAssertEqual(HeartbeatDogFollow.facePoint(onRight: true, cursor: CGPoint(x: 100, y: 400),
                                                    boxSize: huge, clearRadius: lens,
                                                    bounds: bounds).x, W / 2)
    }

    // MARK: - The leap between sides

    // On the retina the DISTANCE term governs even for the longest leap the dog
    // can make (half the screen): 756 * 0.28 = 211.68, just under the 216.04 cap.
    func testFullLeapIsShapedByTheDistanceNotTheCap() {
        let apex = HeartbeatDogFollow.apex(fromX: 378, toX: 1134, boundsHeight: H)
        XCTAssertEqual(apex, 211.68, accuracy: 0.001)
        XCTAssertLessThan(apex, H * 0.22)
    }

    func testCapBindsOnAShortOverlay() {
        XCTAssertEqual(HeartbeatDogFollow.apex(fromX: 0, toX: W, boundsHeight: 300),
                       300 * 0.22, accuracy: 0.001)
    }

    func testShortLeapGetsAShortArc() {
        XCTAssertEqual(HeartbeatDogFollow.apex(fromX: 378, toX: 478, boundsHeight: H),
                       28, accuracy: 0.001)
    }

    func testLeapingBackwardsArcsJustAsHigh() {
        XCTAssertEqual(HeartbeatDogFollow.apex(fromX: 1134, toX: 378, boundsHeight: H),
                       HeartbeatDogFollow.apex(fromX: 378, toX: 1134, boundsHeight: H))
    }

    func testACrossScreenLeapTakesTheFullDuration() {
        XCTAssertEqual(HeartbeatDogFollow.hopDuration(distance: W / 2, boundsWidth: W, full: 0.42),
                       0.42, accuracy: 0.0001)
    }

    func testAShortHopIsQuickerButNotASnap() {
        let step = HeartbeatDogFollow.hopDuration(distance: 40, boundsWidth: W, full: 0.42)
        XCTAssertLessThan(step, 0.42)
        XCTAssertGreaterThanOrEqual(step, 0.42 * 0.3 - 0.0001)   // the floor
    }

    func testTinyDistancesAreStillPacedByTheFloor() {
        XCTAssertEqual(HeartbeatDogFollow.hopDuration(distance: 0.5, boundsWidth: W, full: 0.42),
                       0.42 * 0.3, accuracy: 0.0001)
    }
}

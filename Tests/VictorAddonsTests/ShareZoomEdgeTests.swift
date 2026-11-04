import XCTest
@testable import VictorAddons

/// 🔎 One red door per neighbouring monitor; everywhere else pushing pans (2026-11-04).
final class ShareZoomEdgeTests: XCTestCase {
    // A 1000×600 display at the origin, the ASUS to its right; zoomed 4×, slice in the middle.
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let slice = CGRect(x: 375, y: 225, width: 250, height: 150)
    let rightDoor = [ShareZoomEdge.Door(side: .right, span: 270...330)]

    func confine(_ x: CGFloat, _ y: CGFloat, in s: CGRect? = nil) -> CGPoint {
        ShareZoomEdge.confine(CGPoint(x: x, y: y), slice: s ?? slice, display: display, doors: rightDoor)
    }

    /// The door fills red with the drawn cursor still `reach` away from its stretch of
    /// frame, not only on it. `near` takes Cocoa coordinates: y grows up, so the 270…330
    /// door is at 270…330 of 600 too.
    func testTheDoorLightsUpWithTheDrawnCursorStillAwayFromIt() {
        func near(_ x: CGFloat, _ y: CGFloat) -> ShareZoomEdge.Door? {
            ShareZoomEdge.door(near: CGPoint(x: x, y: y), doors: rightDoor, display: display,
                               depth: 17, reach: 120)
        }
        XCTAssertEqual(near(990, 300)?.side, .right, "on it")
        XCTAssertEqual(near(870, 300)?.side, .right, "120 pt ahead of it, across the side")
        XCTAssertEqual(near(990, 445)?.side, .right, "120 pt ahead of it, along the side")
        XCTAssertNil(near(860, 300), "further in than the reach")
        XCTAssertNil(near(990, 455), "further along than the reach")
    }

    /// Far from the bottom-left origin, as the ASUS is, and at the very last pixel.
    func testADoorIsFoundOnADisplayAwayFromTheOriginUpToTheScreensEdge() {
        let asus = CGRect(x: 1728, y: 100, width: 1000, height: 600)
        let top = [ShareZoomEdge.Door(side: .top, span: 2200...2260)]
        let d = ShareZoomEdge.door(near: CGPoint(x: 500, y: 600), doors: top, display: asus, depth: 17, reach: 0)
        XCTAssertEqual(d?.side, .top)
    }

    func testAMoveInsideTheSliceStaysPut() {
        XCTAssertEqual(confine(400, 300), CGPoint(x: 400, y: 300))
    }

    /// Through the door: onto the ASUS, at the height the drawn cursor had.
    func testCrossingAtTheDoorLandsOnTheNextDisplayAtTheGlassHeight() {
        let out = confine(630, 300)
        XCTAssertEqual(out.x, 1000)
        XCTAssertEqual(out.y, 300, accuracy: 0.01)   // 225 + 75 → glass (75 × 4) = 300
    }

    /// Same side, a monitor beyond it, but past the door: the pointer pushes on past
    /// the slice's edge, so the slice follows it (`ShareZoomPolicy.pan`).
    func testBesideTheDoorPushingPansEvenWithAMonitorBeyond() {
        // 340 → glass (340 − 225) × 4 = 460, well below the door.
        XCTAssertEqual(confine(630, 340), CGPoint(x: 630, y: 340))
    }

    /// The side with no door at all pans the same way.
    func testNoDoorLetsThePointerPushPastTheSlice() {
        XCTAssertEqual(confine(360, 300), CGPoint(x: 360, y: 300))
    }

    /// …but never off the zoomed display itself, door-less side or not.
    func testPushingStaysOnTheZoomedDisplay() {
        let s = CGRect(x: 0, y: 225, width: 250, height: 150)
        XCTAssertEqual(confine(-5, 300, in: s), CGPoint(x: 0, y: 300))
        let far = CGRect(x: 750, y: 225, width: 250, height: 150)
        XCTAssertEqual(confine(1004, 340, in: far), CGPoint(x: 999, y: 340))
    }

    /// The pointer past the slice, waiting for the tick to pan: still no way out but the door.
    func testPastTheSliceTheDoorIsStillTheOnlyWayOut() {
        XCTAssertEqual(confine(640, 340).x, 640)
        XCTAssertEqual(confine(640, 300).x, 1000)
    }

    func testComingBackEntersWhereTheHandCrossesTheGlass() {
        let entry = ShareZoomEdge.fromGlass(CGPoint(x: 999, y: 300), slice: slice, display: display)
        XCTAssertEqual(entry.x, 624.75, accuracy: 0.01)
        XCTAssertEqual(entry.y, 300, accuracy: 0.01)
        XCTAssertTrue(slice.contains(entry))
    }

    /// Back in far from the door: the entry is in the slice, so the pan has nothing to do.
    func testComingBackAwayFromTheDoorEntersTheSliceToo() {
        let entry = ShareZoomEdge.fromGlass(CGPoint(x: 999, y: 20), slice: slice, display: display)
        XCTAssertTrue(slice.contains(entry))
    }

    // MARK: - doors

    /// 10 % of the shared stretch, in its middle, with a Retina-sized side.
    func testTheDoorIsTheMiddleTenPercentOfTheSide() {
        let doors = ShareZoomEdge.doors(display: display, others: [
            display, CGRect(x: 1000, y: 0, width: 800, height: 600)])
        XCTAssertEqual(doors, [ShareZoomEdge.Door(side: .right, span: 270...330)])
    }

    /// Of the stretch the two *share*: only there is a monitor beyond the door.
    func testAShorterMonitorGetsTheDoorInTheMiddleOfWhatTheyShare() {
        let doors = ShareZoomEdge.doors(display: display, others: [CGRect(x: 1000, y: 300, width: 800, height: 800)])
        XCTAssertEqual(doors, [ShareZoomEdge.Door(side: .right, span: 435...465)])
    }

    /// A wider monitor on top, centred: the whole top side is shared.
    func testAMonitorAboveOverhangingTheSide() {
        let doors = ShareZoomEdge.doors(display: display, others: [CGRect(x: -100, y: -700, width: 1200, height: 700)])
        XCTAssertEqual(doors, [ShareZoomEdge.Door(side: .top, span: 450...550)])
    }

    /// Under the notch the top door sits two thirds along; the other sides keep their middle.
    func testANotchMovesOnlyTheTopDoor() {
        let doors = ShareZoomEdge.doors(display: display, others: [
            CGRect(x: 0, y: -600, width: 1000, height: 600),
            CGRect(x: 1000, y: 0, width: 800, height: 600)], notched: true)
        XCTAssertEqual(doors[0].side, .top)
        XCTAssertEqual((doors[0].span.lowerBound + doors[0].span.upperBound) / 2, 666.67, accuracy: 0.01)
        XCTAssertEqual(doors[0].span.upperBound - doors[0].span.lowerBound, 100, accuracy: 0.01)
        XCTAssertEqual(doors[1], ShareZoomEdge.Door(side: .right, span: 270...330))
    }

    func testEveryNeighbourHasItsDoorAndADistantOneNone() {
        let doors = ShareZoomEdge.doors(display: display, others: [
            CGRect(x: -800, y: 0, width: 800, height: 600),
            CGRect(x: 1000, y: 0, width: 800, height: 600),
            CGRect(x: 1800, y: 0, width: 800, height: 600),      // past the right one
            CGRect(x: 1000, y: -500, width: 800, height: 500)])  // only a corner touches
        XCTAssertEqual(doors.map(\.side), [.left, .right])
    }

    func testTheDoorsStretchOfFrameIsInLocalCocoaCoordinates() {
        let d = CGRect(x: 100, y: 50, width: 1000, height: 600)
        let right = ShareZoomEdge.Door(side: .right, span: 320...380)
        XCTAssertEqual(right.strip(on: d, depth: 15), CGRect(x: 985, y: 270, width: 15, height: 60))
        let left = ShareZoomEdge.Door(side: .left, span: 320...380)
        XCTAssertEqual(left.strip(on: d, depth: 15), CGRect(x: 0, y: 270, width: 15, height: 60))
        let top = ShareZoomEdge.Door(side: .top, span: 550...650)
        XCTAssertEqual(top.strip(on: d, depth: 15), CGRect(x: 450, y: 585, width: 100, height: 15))
        let bottom = ShareZoomEdge.Door(side: .bottom, span: 550...650)
        XCTAssertEqual(bottom.strip(on: d, depth: 15), CGRect(x: 450, y: 0, width: 100, height: 15))
    }
}

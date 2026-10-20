import XCTest
@testable import VictorAddons

/// 🔦 The scroll zoom's arithmetic: where the box is drawn on the way to the
/// middle, how big it gets, and which scrolls are the zoom's.
final class GlassSpotlightZoomTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// Wide and low on the left: the height is what has room to spare.
    private let box = CGRect(x: 50, y: 100, width: 200, height: 100)

    func testUnzoomedTheBoxIsDrawnWhereItIs() {
        XCTAssertEqual(GlassSpotlightZoom.frame(box: box, screen: screen, progress: 0), box)
    }

    func testFullZoomIsCentredAndFillsEightyPercentOfTheTighterSide() {
        let full = GlassSpotlightZoom.frame(box: box, screen: screen, progress: 1)
        XCTAssertEqual(full.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(full.midY, screen.midY, accuracy: 0.001)
        // 800 / 200 = 4 across, 640 / 100 = 6.4 up: the width decides.
        XCTAssertEqual(full.width, 800, accuracy: 0.001)
        XCTAssertEqual(full.height, 400, accuracy: 0.001)
    }

    func testATallBoxIsLimitedByTheHeight() {
        let tall = CGRect(x: 600, y: 300, width: 100, height: 200)
        let full = GlassSpotlightZoom.frame(box: tall, screen: screen, progress: 1)
        XCTAssertEqual(full.height, 640, accuracy: 0.001)
        XCTAssertEqual(full.width, 320, accuracy: 0.001)
    }

    func testABoxAlreadyBiggerThanEightyPercentOnlySlidesToTheMiddle() {
        let big = CGRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertEqual(GlassSpotlightZoom.maxScale(box: big, screen: screen), 1)
        let full = GlassSpotlightZoom.frame(box: big, screen: screen, progress: 1)
        XCTAssertEqual(full.size, big.size)
        XCTAssertEqual(full.midX, screen.midX, accuracy: 0.001)
    }

    func testHalfwayIsHalfwayInPlaceAndInSize() {
        let half = GlassSpotlightZoom.frame(box: box, screen: screen, progress: 0.5)
        XCTAssertEqual(half.width, 500, accuracy: 0.001)   // 1 → 4×, halfway 2.5×
        XCTAssertEqual(half.midX, (box.midX + screen.midX) / 2, accuracy: 0.001)
    }

    func testTenNotchesGoAllTheWayAndNoFurther() {
        var p: CGFloat = 0
        for _ in 0..<9 { p = GlassSpotlightZoom.step(p, notches: 1) }
        XCTAssertLessThan(p, 1)
        p = GlassSpotlightZoom.step(p, notches: 1)
        XCTAssertEqual(p, 1, accuracy: 0.0001)
        XCTAssertEqual(GlassSpotlightZoom.step(p, notches: 3), 1)
        XCTAssertEqual(GlassSpotlightZoom.step(0.05, notches: -3), 0)
    }

    func testUnzoomedOnlyTheGlassTakesTheScroll() {
        let hole = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertTrue(GlassSpotlightZoom.takesScroll(at: CGPoint(x: 500, y: 500), screen: screen, hole: hole, zoomed: false))
        XCTAssertFalse(GlassSpotlightZoom.takesScroll(at: CGPoint(x: 150, y: 150), screen: screen, hole: hole, zoomed: false),
                       "in the box the app underneath scrolls")
        XCTAssertFalse(GlassSpotlightZoom.takesScroll(at: CGPoint(x: 1500, y: 150), screen: screen, hole: hole, zoomed: false),
                       "another screen")
    }

    func testZoomedTheWholeScreenTakesTheScroll() {
        let hole = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertTrue(GlassSpotlightZoom.takesScroll(at: CGPoint(x: 150, y: 150), screen: screen, hole: hole, zoomed: true))
        XCTAssertFalse(GlassSpotlightZoom.takesScroll(at: CGPoint(x: 1500, y: 150), screen: screen, hole: hole, zoomed: true))
    }

    func testTheCaptureIsTheBoxPlusItsFeatherClippedToTheScreen() {
        let atEdge = CGRect(x: 10, y: 300, width: 100, height: 100)
        let capture = GlassSpotlightZoom.capture(box: atEdge, feather: 40, screen: screen)
        XCTAssertEqual(capture, CGRect(x: 0, y: 260, width: 150, height: 180))
    }

    func testBothZoomsCountTheSameNotches() {
        XCTAssertEqual(ShareZoomPolicy.notches(delta: 2, source: .wheel), 2)
        XCTAssertEqual(ShareZoomPolicy.notches(delta: -50, source: .smoothWheel), -1)
        XCTAssertEqual(ShareZoomPolicy.notches(delta: -24, source: .trackpad), 2, "fingers up is closer")
    }
}

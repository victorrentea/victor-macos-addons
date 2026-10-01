import XCTest
@testable import VictorAddons

final class ShareZoomPolicyTests: XCTestCase {

    private let screen = CGSize(width: 1728, height: 1117)

    /// The one property everything else hangs on: the desktop pixel under the
    /// cursor is drawn under the cursor, so a click-through window clicks right.
    func testThePointerIsTheFixedPointOfTheMagnification() {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1728, y: 1117), CGPoint(x: 300, y: 900), CGPoint(x: 1500, y: 40)] {
            for k in [1.5, 2.0, 7.3] as [CGFloat] {
                let r = ShareZoomPolicy.sourceRect(screenSize: screen, pointer: p, factor: k)
                let drawnAt = CGPoint(x: (p.x - r.minX) * k, y: (p.y - r.minY) * k)
                XCTAssertEqual(drawnAt.x, p.x, accuracy: 0.001)
                XCTAssertEqual(drawnAt.y, p.y, accuracy: 0.001)
            }
        }
    }

    func testTheSliceNeverLeavesTheScreen() {
        for p in [CGPoint(x: -50, y: -50), CGPoint(x: 5000, y: 5000), CGPoint(x: 864, y: 558)] {
            let r = ShareZoomPolicy.sourceRect(screenSize: screen, pointer: p, factor: 4)
            XCTAssertGreaterThanOrEqual(r.minX, 0)
            XCTAssertGreaterThanOrEqual(r.minY, 0)
            XCTAssertLessThanOrEqual(r.maxX, screen.width + 0.001)
            XCTAssertLessThanOrEqual(r.maxY, screen.height + 0.001)
        }
    }

    func testAtTheCornerTheMatchingCornerOfTheDesktopIsInView() {
        let r = ShareZoomPolicy.contentsRect(screenSize: screen, pointer: CGPoint(x: 1728, y: 1117), factor: 2)
        XCTAssertEqual(r.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(r.maxY, 1, accuracy: 0.0001)
        XCTAssertEqual(r.width, 0.5, accuracy: 0.0001)
    }

    func testAtOneTimesTheWholeScreenIsShown() {
        let r = ShareZoomPolicy.contentsRect(screenSize: screen, pointer: CGPoint(x: 400, y: 400), factor: 1)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Same direction as the ⌘-scroll terminal font zoom: negative = closer.
    func testNegativeDeltaZoomsIn() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -1, continuous: false), 1.15, accuracy: 0.0001)
        XCTAssertEqual(ShareZoomPolicy.step(2, delta: 1, continuous: false), 2 / 1.15, accuracy: 0.0001)
    }

    func testOneFastSpinCountsForAtMostThreeNotches() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -10, continuous: false), pow(1.15, 3), accuracy: 0.0001)
    }

    func testTrackpadPixelsAccumulateIntoNotches() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -12, continuous: true), 1.15, accuracy: 0.0001)
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -3, continuous: true), pow(1.15, 0.25), accuracy: 0.0001)
    }

    func testTheDialStopsAtOneAndAtTheCeiling() {
        XCTAssertEqual(ShareZoomPolicy.step(1.05, delta: 3, continuous: false), 1)
        XCTAssertEqual(ShareZoomPolicy.step(9.9, delta: -3, continuous: false), ShareZoomPolicy.maxFactor)
    }

    func testEasingLandsExactlyOnTheTarget() {
        var c: CGFloat = 1
        for _ in 0..<60 { c = ShareZoomPolicy.ease(c, toward: 2) }
        XCTAssertEqual(c, 2)
        XCTAssertFalse(ShareZoomPolicy.isOff(current: c, target: 2))
        for _ in 0..<60 { c = ShareZoomPolicy.ease(c, toward: 1) }
        XCTAssertTrue(ShareZoomPolicy.isOff(current: c, target: 1))
    }
}

import XCTest
@testable import VictorAddons

final class ShareZoomPolicyTests: XCTestCase {

    private let screen = CGSize(width: 1728, height: 1117)

    // MARK: - The dial

    /// Positive (after `ScrollReversal`) = closer. The first build had it backwards.
    func testPositiveDeltaZoomsIn() {
        XCTAssertGreaterThan(ShareZoomPolicy.step(1, delta: 1, continuous: false), 1)
        XCTAssertLessThan(ShareZoomPolicy.step(2, delta: -1, continuous: false), 2)
    }

    /// Steps halved twice (in the log domain): four notches make the first build's one.
    func testFourNotchesMakeTheFirstBuildsOneNotchStep() {
        var f: CGFloat = 1
        for _ in 0..<4 { f = ShareZoomPolicy.step(f, delta: 1, continuous: false) }
        XCTAssertEqual(f, 1.15, accuracy: 0.0001)
    }

    func testTheCeilingIsEightyPercentOfTheOldTen() {
        XCTAssertEqual(ShareZoomPolicy.maxFactor, 8)
    }

    func testOneFastSpinCountsForAtMostThreeNotches() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: 10, continuous: false),
                       pow(ShareZoomPolicy.notchFactor, 3), accuracy: 0.0001)
    }

    func testTrackpadPixelsAccumulateIntoNotches() {
        // Fingers up = negative (natural scrolling) = closer, like ⌥+scroll.
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -12, continuous: true), ShareZoomPolicy.notchFactor, accuracy: 0.0001)
        XCTAssertLessThan(ShareZoomPolicy.step(2, delta: 12, continuous: true), 2)
    }

    func testTheDialStopsAtOneAndAtTheCeiling() {
        XCTAssertEqual(ShareZoomPolicy.step(1.05, delta: -3, continuous: false), 1)
        XCTAssertEqual(ShareZoomPolicy.step(7.9, delta: 3, continuous: false), ShareZoomPolicy.maxFactor)
    }

    func testScrollingBackAsFarAsInLandsOnExactlyOne() {
        var f: CGFloat = 1
        for _ in 0..<20 { f = ShareZoomPolicy.step(f, delta: 1, continuous: false) }
        for _ in 0..<20 { f = ShareZoomPolicy.step(f, delta: -1, continuous: false) }
        XCTAssertEqual(f, 1)
    }

    func testEasingLandsExactlyOnTheTarget() {
        var c: CGFloat = 1
        for _ in 0..<120 { c = ShareZoomPolicy.ease(c, toward: 2) }
        XCTAssertEqual(c, 2)
        XCTAssertFalse(ShareZoomPolicy.isOff(current: c, target: 2))
        for _ in 0..<120 { c = ShareZoomPolicy.ease(c, toward: 1) }
        XCTAssertTrue(ShareZoomPolicy.isOff(current: c, target: 1))
    }

    // MARK: - Zooming is about the pointer

    func testZoomingKeepsThePointersSpotUnderThePointer() {
        let p = CGPoint(x: 400, y: 900)
        var o = CGPoint.zero
        var k: CGFloat = 1
        for next in [1.3, 2.0, 3.7, 2.2] as [CGFloat] {
            o = ShareZoomPolicy.rezoom(origin: o, from: k, to: next, pointer: p, screenSize: screen)
            k = next
            let drawn = ShareZoomPolicy.cursorPoint(pointer: p, origin: o, factor: k)
            XCTAssertEqual(drawn.x, p.x, accuracy: 0.001)
            XCTAssertEqual(drawn.y, p.y, accuracy: 0.001)
        }
    }

    // MARK: - Panning only at the edge

    func testMovingInsideTheSliceDoesNotPan() {
        let o = CGPoint(x: 300, y: 200)
        let k: CGFloat = 2   // slice 864 × 558.5
        for p in [CGPoint(x: 301, y: 201), CGPoint(x: 700, y: 500), CGPoint(x: 1163, y: 757)] {
            XCTAssertEqual(ShareZoomPolicy.pan(origin: o, pointer: p, factor: k, screenSize: screen), o)
        }
    }

    func testPushingAnEdgeDragsTheSliceAlong() {
        let o = CGPoint(x: 300, y: 200)
        let right = ShareZoomPolicy.pan(origin: o, pointer: CGPoint(x: 1200, y: 400), factor: 2, screenSize: screen)
        XCTAssertEqual(right.x, 1200 - 864, accuracy: 0.001)
        XCTAssertEqual(right.y, 200)
        let left = ShareZoomPolicy.pan(origin: o, pointer: CGPoint(x: 250, y: 400), factor: 2, screenSize: screen)
        XCTAssertEqual(left.x, 250)
        // …and the drawn cursor sits on the glass's edge, not past it.
        let drawn = ShareZoomPolicy.cursorPoint(pointer: CGPoint(x: 1200, y: 400), origin: right, factor: 2)
        XCTAssertEqual(drawn.x, screen.width, accuracy: 0.001)
    }

    func testTheSliceNeverLeavesTheScreen() {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1728, y: 1117)] {
            let o = ShareZoomPolicy.pan(origin: CGPoint(x: 800, y: 500), pointer: p, factor: 4, screenSize: screen)
            XCTAssertGreaterThanOrEqual(o.x, 0)
            XCTAssertGreaterThanOrEqual(o.y, 0)
            XCTAssertLessThanOrEqual(o.x + screen.width / 4, screen.width + 0.001)
            XCTAssertLessThanOrEqual(o.y + screen.height / 4, screen.height + 0.001)
        }
    }

    func testContentsRectIsTheSliceInUnitSpace() {
        let r = ShareZoomPolicy.contentsRect(origin: CGPoint(x: 864, y: 0), factor: 2, screenSize: screen)
        XCTAssertEqual(r, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }
}

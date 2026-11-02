import XCTest
@testable import VictorAddons

/// 🔎 The slice's edge is the screen's edge; resting in the outer 10 % pans (2026-11-02).
final class ShareZoomEdgeTests: XCTestCase {
    // A 1000×600 display at the origin, the ASUS to its right; zoomed 4×, slice in the middle.
    let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let slice = CGRect(x: 375, y: 225, width: 250, height: 150)
    func rightOnly(_ p: CGPoint) -> Bool { p.x >= 1000 && p.x < 2000 && p.y >= 0 && p.y < 600 }

    func testAMoveInsideTheSliceStaysPut() {
        let p = CGPoint(x: 400, y: 300)
        XCTAssertEqual(ShareZoomEdge.confine(p, slice: slice, display: display, hasDisplay: rightOnly), p)
    }

    /// Fast past the right edge: onto the ASUS, at the height the drawn cursor had.
    func testCrossingTheSliceEdgeLandsOnTheNextDisplayAtTheGlassHeight() {
        let out = ShareZoomEdge.confine(CGPoint(x: 630, y: 300), slice: slice, display: display, hasDisplay: rightOnly)
        XCTAssertEqual(out.x, 1000)
        XCTAssertEqual(out.y, 300, accuracy: 0.01)   // 225 + 75 → glass (75 × 4) = 300
    }

    /// No display on the left: held at the slice's edge, so the dwell can take over.
    func testNoDisplayBeyondHoldsThePointerAtTheEdge() {
        let out = ShareZoomEdge.confine(CGPoint(x: 360, y: 300), slice: slice, display: display, hasDisplay: rightOnly)
        XCTAssertEqual(out, CGPoint(x: 375, y: 300))
    }

    func testComingBackEntersWhereTheHandCrossesTheGlass() {
        let entry = ShareZoomEdge.fromGlass(CGPoint(x: 999, y: 300), slice: slice, display: display)
        XCTAssertEqual(entry.x, 624.75, accuracy: 0.01)
        XCTAssertEqual(entry.y, 300, accuracy: 0.01)
        XCTAssertTrue(slice.contains(entry))
    }

    func testTheBandIsTheOuterTenPercent() {
        XCTAssertNil(ShareZoomEdge.depth(500, length: 1000))
        XCTAssertNil(ShareZoomEdge.depth(899, length: 1000))
        XCTAssertEqual(ShareZoomEdge.depth(950, length: 1000)!, 0.5, accuracy: 0.001)
        XCTAssertEqual(ShareZoomEdge.depth(1000, length: 1000)!, 1, accuracy: 0.001)
        XCTAssertEqual(ShareZoomEdge.depth(0, length: 1000)!, -1, accuracy: 0.001)
    }

    func testThePanWaitsThreeHundredMilliseconds() {
        var d = ShareZoomEdge.Dwell()
        XCTAssertFalse(d.due(depth: 0.5, now: 10))
        XCTAssertFalse(d.due(depth: 0.5, now: 10.29))
        XCTAssertTrue(d.due(depth: 0.5, now: 10.3))
        // Out of the band and back: the clock starts over.
        XCTAssertFalse(d.due(depth: nil, now: 10.4))
        XCTAssertFalse(d.due(depth: 0.5, now: 10.5))
        // The other side starts over too.
        XCTAssertTrue(d.due(depth: 0.5, now: 10.8))
        XCTAssertFalse(d.due(depth: -0.5, now: 10.9))
    }

    func testDeeperInTheBandPansFaster() {
        let slow = ShareZoomEdge.step(depth: 0.1, length: 1000, factor: 4, dt: 0.1)
        let fast = ShareZoomEdge.step(depth: 1, length: 1000, factor: 4, dt: 0.1)
        XCTAssertGreaterThan(fast, slow)
        XCTAssertLessThan(ShareZoomEdge.step(depth: -1, length: 1000, factor: 4, dt: 0.1), 0)
    }
}

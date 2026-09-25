import XCTest
@testable import VictorAddons

/// The 📏 ruler's arithmetic: what box a drag makes and what it reads.
final class RulerGeometryTests: XCTestCase {

    func testADragInAnyDirectionMakesThePositiveBox() {
        let box = RulerGeometry.box(from: NSPoint(x: 100, y: 80), to: NSPoint(x: 40, y: 20), lockAxis: false)
        XCTAssertEqual(box, NSRect(x: 40, y: 20, width: 60, height: 60))
    }

    /// ⇧ turns the box into a straight line along whichever axis the drag
    /// mostly followed.
    func testShiftLocksToTheDominantAxis() {
        let across = RulerGeometry.box(from: .zero, to: NSPoint(x: 120, y: 7), lockAxis: true)
        XCTAssertEqual(across.size, NSSize(width: 120, height: 0))
        let down = RulerGeometry.box(from: .zero, to: NSPoint(x: 5, y: -90), lockAxis: true)
        XCTAssertEqual(down, NSRect(x: 0, y: -90, width: 0, height: 90))
    }

    /// On a retina the pixels lead and the points follow; on a 1× screen they
    /// are the same number, so it is said once.
    func testRetinaReadsPixelsThenPoints() {
        let r = RulerGeometry.readout(size: NSSize(width: 240, height: 36), scale: 2)
        XCTAssertEqual(r.pixels, "480 × 72 px")
        XCTAssertEqual(r.points, "240 × 36 pt")
        XCTAssertNil(RulerGeometry.readout(size: NSSize(width: 240, height: 36), scale: 1).points)
    }

    /// A retina pointer sits on half points: 119.5 pt is 239 px, not 238.
    func testHalfPointsRoundToTheRightPixel() {
        XCTAssertEqual(RulerGeometry.readout(size: NSSize(width: 119.5, height: 0.5), scale: 2).pixels, "239 × 1 px")
    }
}

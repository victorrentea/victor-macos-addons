import XCTest
@testable import VictorAddons

/// 🔦 The glass's mask, read back pixel by pixel: clear in the box, opaque past
/// the feather, a ramp between — and the right way up (a CGImage's first row is
/// its top, the canvas counts y up from the bottom).
final class GlassSpotlightMaskTests: XCTestCase {

    private let canvas = CGSize(width: 400, height: 300)
    /// Low and to the left, so a mask drawn upside down would miss it.
    private let hole = CGRect(x: 50, y: 40, width: 100, height: 80)
    private let feather: CGFloat = 40

    private func alpha(atX x: Int, y: Int) -> UInt8 {
        let image = GlassSpotlightMask.image(canvas: canvas, hole: hole, feather: feather)!
        let data = image.dataProvider!.data! as Data
        let row = image.height - 1 - y
        return data[row * image.bytesPerRow + x]
    }

    func testTheBoxIsClearRightUpToItsEdge() {
        XCTAssertEqual(alpha(atX: 100, y: 80), 0, "middle of the box")
        XCTAssertEqual(alpha(atX: 51, y: 41), 0, "just inside its corner — the feather is outside the box")
        XCTAssertEqual(alpha(atX: 148, y: 118), 0)
    }

    func testEverythingPastTheFeatherIsGlass() {
        XCTAssertEqual(alpha(atX: 390, y: 290), 255, "far corner")
        XCTAssertEqual(alpha(atX: 100, y: 170), 255, "above the box, past the feather")
        XCTAssertEqual(alpha(atX: 200, y: 80), 255, "right of the box, past the feather")
    }

    func testTheEdgeRampsInsteadOfCutting() {
        let near = alpha(atX: 160, y: 80)    // 10 pt out
        let mid = alpha(atX: 170, y: 80)     // 20 pt out
        let far = alpha(atX: 182, y: 80)     // 32 pt out
        XCTAssertGreaterThan(near, 0)
        XCTAssertLessThan(near, mid)
        XCTAssertLessThan(mid, far)
        XCTAssertLessThan(far, 255)
    }

    func testTheMaskIsTheCanvasSizeAtOnePixelAPoint() {
        let image = GlassSpotlightMask.image(canvas: canvas, hole: hole, feather: feather)!
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
    }

    /// The glass comes up only once the box covers 5% of its screen.
    func testRevealsAtFivePercentOfTheScreen() {
        let screen = CGRect(x: 1728, y: 37, width: 1920, height: 1080)   // 5% = 103 680 pt²
        XCTAssertFalse(GlassSpotlight.reveals(CGRect(x: 0, y: 0, width: 400, height: 250), on: screen))
        XCTAssertTrue(GlassSpotlight.reveals(CGRect(x: 0, y: 0, width: 432, height: 240), on: screen))
    }
}

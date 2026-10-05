import XCTest
@testable import VictorAddons

/// ⌃⌥⌘ (+fn) + arrow: which screen is "that way", and where the window lands on it.
/// Rectangles in AX's top-left space; the layout is this Mac's usual desk —
/// Retina in the middle, ASUS to its right, the Dell above.
final class WindowScreenMovePolicyTests: XCTestCase {

    private let retina = CGRect(x: 0, y: 25, width: 1512, height: 957)
    private let asus = CGRect(x: 1512, y: 100, width: 1920, height: 1080)
    private let dell = CGRect(x: -200, y: -1080, width: 1920, height: 1080)
    private var screens: [CGRect] { [retina, asus, dell] }

    func testNeighbours() {
        XCTAssertEqual(WindowScreenMovePolicy.neighbour(of: 0, .right, in: screens), 1)
        XCTAssertEqual(WindowScreenMovePolicy.neighbour(of: 0, .up, in: screens), 2)
        XCTAssertEqual(WindowScreenMovePolicy.neighbour(of: 1, .left, in: screens), 0)
        XCTAssertEqual(WindowScreenMovePolicy.neighbour(of: 2, .down, in: screens), 0)
    }

    func testNothingThatWayStaysPut() {
        XCTAssertNil(WindowScreenMovePolicy.neighbour(of: 0, .left, in: screens))
        XCTAssertNil(WindowScreenMovePolicy.neighbour(of: 0, .down, in: screens))
    }

    /// Straight above beats above-and-far-to-the-side, even when the latter is nearer.
    func testSharedEdgeWins() {
        let src = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let above = CGRect(x: 0, y: -1600, width: 1000, height: 800)
        let aside = CGRect(x: 1100, y: -500, width: 400, height: 300)
        XCTAssertEqual(WindowScreenMovePolicy.neighbour(of: 0, .up, in: [src, above, aside]), 1)
    }

    func testScreenHoldingMostOfTheWindow() {
        let w = CGRect(x: 1400, y: 200, width: 800, height: 600)  // mostly on the ASUS
        XCTAssertEqual(WindowScreenMovePolicy.screenIndex(containing: w, in: screens), 1)
    }

    func testLeftHalfStaysALeftHalf() {
        let half = CGRect(x: 0, y: 25, width: 756, height: 957)
        XCTAssertEqual(WindowScreenMovePolicy.relocate(half, from: retina, to: asus),
                       CGRect(x: 1512, y: 100, width: 960, height: 1080))
    }

    func testFilledWindowFillsTheTarget() {
        XCTAssertEqual(WindowScreenMovePolicy.relocate(asus, from: asus, to: retina), retina)
    }

    func testNeverLargerOrOutsideTheTarget() {
        let w = CGRect(x: 1500, y: 90, width: 1950, height: 1100)  // overhangs the ASUS
        let r = WindowScreenMovePolicy.relocate(w, from: asus, to: retina)
        XCTAssertTrue(retina.contains(r), "\(r)")
    }

    func testHalves() {
        XCTAssertEqual(WindowScreenMovePolicy.half(of: retina, .left), CGRect(x: 0, y: 25, width: 756, height: 957))
        XCTAssertEqual(WindowScreenMovePolicy.half(of: retina, .right), CGRect(x: 756, y: 25, width: 756, height: 957))
        XCTAssertEqual(WindowScreenMovePolicy.half(of: asus, .up), CGRect(x: 1512, y: 100, width: 1920, height: 540))
        XCTAssertEqual(WindowScreenMovePolicy.half(of: asus, .down), CGRect(x: 1512, y: 640, width: 1920, height: 540))
    }

    /// fn turns the arrows into Home/End/PgUp/PgDn — that is the "other screen" signal.
    func testFnArrowsMeanAnotherScreen() {
        XCTAssertEqual(WindowScreenMove.Key(keyCode: 123), .half(.left))
        XCTAssertEqual(WindowScreenMove.Key(keyCode: 115), .screen(.left))
        XCTAssertEqual(WindowScreenMove.Key(keyCode: 119), .screen(.right))
        XCTAssertEqual(WindowScreenMove.Key(keyCode: 116), .screen(.up))
        XCTAssertEqual(WindowScreenMove.Key(keyCode: 121), .screen(.down))
        XCTAssertNil(WindowScreenMove.Key(keyCode: 0))
    }
}

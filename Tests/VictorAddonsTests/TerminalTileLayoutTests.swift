import XCTest
@testable import VictorAddons

/// Where ⌘⌃A puts each Terminal window — quadrants for the first four, a cascade
/// over the bottom-right one for everything after that.
final class TerminalTileLayoutTests: XCTestCase {

    private typealias Rect = TerminalTileLayout.Rect

    /// A 2000×1200 display at the origin: quadrants are ~1000×600 each.
    private let display = Rect(x: 0, y: 0, w: 2000, h: 1200)
    private var quads: [Rect] { TerminalTileLayout.quadrants(of: display) }

    private func win(_ x: Int, _ y: Int) -> Rect { Rect(x: x, y: y, w: 300, h: 200) }

    // MARK: - Up to four: unchanged behaviour

    func testEachWindowGoesToTheQuadrantItIsAlreadyIn() {
        let windows = [win(1500, 800), win(100, 100), win(1500, 100), win(100, 800)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(out, [quads[3], quads[0], quads[1], quads[2]])
    }

    func testOneWindowTakesTheNearestQuadrantAndNothingElseMoves() {
        let out = TerminalTileLayout.frames(windows: [win(1500, 800)], display: display)
        XCTAssertEqual(out, [quads[3]])
    }

    func testNoWindowsNoFrames() {
        XCTAssertEqual(TerminalTileLayout.frames(windows: [], display: display), [])
    }

    // MARK: - The fifth window on

    func testTheFifthWindowSitsOnTopOfTheBottomRightTileWithoutHidingIt() {
        let windows = (0..<5).map { _ in win(100, 100) }
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(out.count, 5)
        let base = quads[3]
        // Offset by one step, so the tile underneath keeps its own title bar.
        XCTAssertEqual(out[4].x, base.x + TerminalTileLayout.cascadeStep)
        XCTAssertEqual(out[4].y, base.y + TerminalTileLayout.cascadeStep)
        XCTAssertEqual(out[4].x2, base.x2)
        XCTAssertEqual(out[4].y2, base.y2)
    }

    /// The one that broke it the first time: offset and depth have to agree.
    /// `TerminalTiler` raises the pile back-to-front, so the front-most window —
    /// the first extra — has to be the one stepped *furthest* down-right; every
    /// window behind it then shows a whole title bar above it.
    func testTheFrontMostExtraIsTheLowestOneSoTitleBarsStackUpwards() {
        let windows = (0..<7).map { _ in win(100, 100) }
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        let pile = Array(out.dropFirst(4))
        XCTAssertEqual(pile.count, 3)
        XCTAssertGreaterThan(pile[0].y, pile[1].y)
        XCTAssertGreaterThan(pile[1].y, pile[2].y)
        XCTAssertGreaterThan(pile[0].x, pile[1].x)
        // The deepest one is the front-most window and sits in the corner.
        XCTAssertEqual(pile[0].x2, quads[3].x2)
        XCTAssertEqual(pile[0].y2, quads[3].y2)
    }

    func testCascadedWindowsStepDownRightAndStayInsideTheQuadrant() {
        let windows = (0..<8).map { _ in win(100, 100) }
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        let base = quads[3]
        // Back-to-front: slot order, the way the fan is drawn from the corner down.
        let pile = Array(out.dropFirst(4).reversed())
        XCTAssertEqual(pile.count, 4)

        for (a, b) in zip(pile, pile.dropFirst()) {
            XCTAssertEqual(b.x - a.x, TerminalTileLayout.cascadeStep)
            XCTAssertEqual(b.y - a.y, TerminalTileLayout.cascadeStep)
            XCTAssertEqual(a.w, b.w, "the pile is one size, so it reads as a stack")
            XCTAssertEqual(a.h, b.h)
        }
        // One step clear of the tile it lies on, so that title bar shows too.
        XCTAssertEqual(pile.first!.x, base.x + TerminalTileLayout.cascadeStep)
        XCTAssertEqual(pile.first!.y, base.y + TerminalTileLayout.cascadeStep)
        // Flush with the quadrant's far corner: nothing spills off the screen.
        XCTAssertEqual(pile.last!.x2, base.x2)
        XCTAssertEqual(pile.last!.y2, base.y2)
    }

    func testTheCascadeNeverCoversTheOtherThreeTiles() {
        let windows = (0..<12).map { _ in win(100, 100) }
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        let base = quads[3]
        for f in out.dropFirst(4) {
            XCTAssertGreaterThanOrEqual(f.x, base.x)
            XCTAssertGreaterThanOrEqual(f.y, base.y)
            XCTAssertLessThanOrEqual(f.x2, base.x2)
            XCTAssertLessThanOrEqual(f.y2, base.y2)
        }
    }

    func testAManyDeepPileTightensItsStepInsteadOfShrinkingAway() {
        let base = quads[3]
        let pile = TerminalTileLayout.cascade(count: 30, over: base)
        let step = pile[1].x - pile[0].x
        XCTAssertLessThan(step, TerminalTileLayout.cascadeStep)
        XCTAssertGreaterThanOrEqual(step, 8, "every title bar still has to be grabbable")
        XCTAssertGreaterThan(pile.last!.w, base.w / 2)
        XCTAssertLessThanOrEqual(pile.last!.x2, base.x2)
    }

    // MARK: - The window being typed in

    func testTheFrontWindowIsKeptOutOfTheQuadrantThePileLandsOn() {
        // Front-most window sitting in the bottom-right corner — ⌘⌃C with the
        // mouse down there — plus enough windows to make a pile.
        let windows = [win(1900, 1100), win(100, 100), win(1900, 100), win(100, 1100), win(1900, 1100)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertNotEqual(out[0], quads[3], "the new terminal must not end up under the cascade")
        XCTAssertEqual(out[4].x2, quads[3].x2, "the extra still piles onto the bottom-right")
    }

    func testWithoutAPileTheFrontWindowMayKeepTheBottomRightQuadrant() {
        let windows = [win(1900, 1100), win(100, 100)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(out[0], quads[3])
    }

    // MARK: - Screens that are not at the origin

    func testQuadrantsFollowASecondaryDisplaysOffset() {
        let second = Rect(x: -1440, y: -900, w: 1440, h: 900)
        let out = TerminalTileLayout.frames(windows: [win(-1400, -880)], display: second)
        XCTAssertEqual(out[0], TerminalTileLayout.quadrants(of: second)[0])
        XCTAssertEqual(out[0].x, -1440 + TerminalTileLayout.margin)
    }
}

import XCTest
@testable import VictorAddons

/// Where ⌘⌃A puts each Terminal window — quadrants for four, a fan over the
/// bottom-right one for everything after that — and, just as much, what it does
/// *not* do: move a window that is already in place.
final class TerminalTileLayoutTests: XCTestCase {

    private typealias Rect = TerminalTileLayout.Rect

    /// A 2000×1200 display at the origin: quadrants are ~1000×600 each.
    private let display = Rect(x: 0, y: 0, w: 2000, h: 1200)
    private var quads: [Rect] { TerminalTileLayout.quadrants(of: display) }

    private func win(_ x: Int, _ y: Int) -> Rect { Rect(x: x, y: y, w: 300, h: 200) }

    // MARK: - Up to four

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

    // MARK: - Slot order = raise order

    /// `TerminalTiler` raises windows in this order and the last one raised ends on
    /// top, so the order of this array *is* the stacking, top-left first and the
    /// deepest fan slot last.
    func testSlotsComeInRaiseOrderQuadrantsThenTheFanGettingDeeper() {
        let slots = TerminalTileLayout.targets(count: 7, display: display)
        XCTAssertEqual(Array(slots.prefix(4)), quads)
        let fan = Array(slots.dropFirst(4))
        XCTAssertEqual(fan.count, 3)
        for (a, b) in zip(fan, fan.dropFirst()) {
            XCTAssertEqual(b.x - a.x, TerminalTileLayout.cascadeStep)
            XCTAssertEqual(b.y - a.y, TerminalTileLayout.cascadeStep)
            XCTAssertEqual(a.w, b.w, "the fan is one size, so it reads as a stack")
            XCTAssertEqual(a.h, b.h)
        }
    }

    func testFourWindowsOrFewerGetNoFan() {
        XCTAssertEqual(TerminalTileLayout.targets(count: 4, display: display), quads)
        XCTAssertEqual(TerminalTileLayout.targets(count: 1, display: display), quads)
    }

    // MARK: - The fan

    func testTheFanClearsTheTileItLiesOnAndStaysInsideTheQuadrant() {
        let base = quads[3]
        let fan = TerminalTileLayout.cascade(count: 4, over: base)
        // One step clear of the corner, so the tile underneath keeps its title bar.
        XCTAssertEqual(fan.first!.x, base.x + TerminalTileLayout.cascadeStep)
        XCTAssertEqual(fan.first!.y, base.y + TerminalTileLayout.cascadeStep)
        // Flush with the far corner: nothing spills onto the other three tiles.
        XCTAssertEqual(fan.last!.x2, base.x2)
        XCTAssertEqual(fan.last!.y2, base.y2)
        for f in fan {
            XCTAssertGreaterThan(f.x, base.x)
            XCTAssertGreaterThan(f.y, base.y)
            XCTAssertLessThanOrEqual(f.x2, base.x2)
            XCTAssertLessThanOrEqual(f.y2, base.y2)
        }
    }

    func testAManyDeepFanTightensItsStepInsteadOfShrinkingAway() {
        let base = quads[3]
        let fan = TerminalTileLayout.cascade(count: 30, over: base)
        let step = fan[1].x - fan[0].x
        XCTAssertLessThan(step, TerminalTileLayout.cascadeStep)
        XCTAssertGreaterThanOrEqual(step, 8, "every title bar still has to be grabbable")
        XCTAssertGreaterThan(fan.last!.w, base.w / 2)
        XCTAssertLessThanOrEqual(fan.last!.x2, base.x2)
    }

    func testTheFifthWindowLandsOnTheFanAndTheOtherFourKeepTheirQuadrants() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800), win(1500, 800), win(1500, 800)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(Array(out.prefix(3)), [quads[0], quads[1], quads[2]])
        XCTAssertEqual(Set([out[3], out[4]]).count, 2, "two windows, two different slots")
        XCTAssertTrue([out[3], out[4]].contains(quads[3]))
    }

    // MARK: - Re-tiling must not shuffle

    /// The bug that made ⌘⌃A a game of musical chairs: slots used to go to the
    /// four *front-most* windows, and raising the fan made the fan front-most, so
    /// every press swapped the fan with the tiles.
    func testTilingAnAlreadyTiledScreenChangesNothing() {
        let windows = (0..<7).map { _ in win(50, 50) }
        let once = TerminalTileLayout.frames(windows: windows, display: display)
        let twice = TerminalTileLayout.frames(windows: once, display: display)
        XCTAssertEqual(twice, once)
        let thrice = TerminalTileLayout.frames(windows: twice, display: display)
        XCTAssertEqual(thrice, once)
    }

    /// Same layout, windows handed over in a different z-order: the result must not
    /// move a single window, because position is the only thing that decides.
    func testTheOrderWindowsComeInDoesNotMoveThem() {
        let windows = (0..<7).map { _ in win(50, 50) }
        let laidOut = TerminalTileLayout.frames(windows: windows, display: display)
        let shuffled = Array(laidOut.reversed())
        let out = TerminalTileLayout.frames(windows: shuffled, display: display)
        XCTAssertEqual(out, shuffled)
    }

    func testADraggedWindowGoesBackToTheSlotItLeftAndTakesNoOneElsesplace() {
        var laidOut = TerminalTileLayout.frames(windows: (0..<6).map { _ in win(50, 50) },
                                                display: display)
        let strayed = Rect(x: laidOut[4].x + 90, y: laidOut[4].y + 40, w: 400, h: 300)
        let wanted = laidOut[4]
        laidOut[4] = strayed
        let out = TerminalTileLayout.frames(windows: laidOut, display: display)
        XCTAssertEqual(out[4], wanted)
        for i in [0, 1, 2, 3, 5] { XCTAssertEqual(out[i], laidOut[i]) }
    }

    func testEveryWindowGetsItsOwnSlot() {
        let windows = (0..<9).map { i in win(i * 40, i * 30) }
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(out.count, 9)
        XCTAssertEqual(Set(out.map { "\($0)" }).count, 9)
    }

    // MARK: - Screens that are not at the origin

    func testQuadrantsFollowASecondaryDisplaysOffset() {
        let second = Rect(x: -1440, y: -900, w: 1440, h: 900)
        let out = TerminalTileLayout.frames(windows: [win(-1400, -880)], display: second)
        XCTAssertEqual(out[0], TerminalTileLayout.quadrants(of: second)[0])
        XCTAssertEqual(out[0].x, -1440 + TerminalTileLayout.margin)
    }
}

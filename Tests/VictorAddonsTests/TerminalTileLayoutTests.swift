import XCTest
@testable import VictorAddons

/// Where ⌘⌃A puts each Terminal window — quadrants for four, and from the fifth on
/// a Windows-style cascade *inside* one quadrant (bottom-right first, then
/// bottom-left, top-right, top-left), each window pinned to the quadrant's
/// bottom-right corner so the pile can never spill out of its quarter — and, just
/// as much, what it does *not* do: move a window that is already in place.
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

    // MARK: - Slot order

    /// The array is the display read quadrant by quadrant, each pile deepest window
    /// first. `TerminalTiler` raises windows in this order, which is what leaves
    /// every title bar in a pile showing.
    func testSlotsComeInQuadrantOrderEachQuadrantPiledDeepestFirst() {
        let slots = TerminalTileLayout.targets(count: 6, display: display)
        XCTAssertEqual(slots.count, 6)
        XCTAssertEqual(TerminalTileLayout.capacities(count: 6, display: display), [1, 1, 1, 3])
        XCTAssertEqual(Array(slots.prefix(3)), [quads[0], quads[1], quads[2]])
        XCTAssertEqual(Array(slots[3...5]), TerminalTileLayout.cascade(count: 3, in: quads[3]))
        XCTAssertEqual(slots[3], quads[3], "the deepest window of a pile is the whole quadrant")
    }

    func testFourWindowsOrFewerGetPlainQuadrants() {
        XCTAssertEqual(TerminalTileLayout.targets(count: 4, display: display), quads)
        XCTAssertEqual(TerminalTileLayout.targets(count: 1, display: display), quads)
    }

    // MARK: - Filling order

    /// A quadrant is filled to its depth before the next one is touched: the
    /// bottom-right takes the fifth window *and every window after it* until it is
    /// full, and only then does the bottom-left start piling.
    func testAQuadrantFillsToItsDepthBeforeTheNextOneIsTouched() {
        XCTAssertEqual(TerminalTileLayout.depth(in: quads[3]), 7,
                       "seven windows to a pile, and a ~998×598 quadrant has room for them")
        XCTAssertEqual(TerminalTileLayout.depth(in: Rect(x: 0, y: 0, w: 300, h: 200)), 4,
                       "a small screen runs out of room before it runs out of pile")
        XCTAssertEqual(TerminalTileLayout.capacities(count: 5, display: display), [1, 1, 1, 2])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 6, display: display), [1, 1, 1, 3])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 10, display: display), [1, 1, 1, 7])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 11, display: display), [1, 1, 2, 7])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 14, display: display), [1, 1, 5, 7])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 28, display: display), [7, 7, 7, 7])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 29, display: display), [7, 7, 7, 8],
                       "past four full piles the extras go round again and the steps tighten")
    }

    func testNoQuadrantEverHoldsMoreThanSevenUntilEveryQuadrantIsFull() {
        for n in 1...28 {
            let caps = TerminalTileLayout.capacities(count: n, display: display)
            XCTAssertLessThanOrEqual(caps.max()!, TerminalTileLayout.maxDepth, "\(n) windows: \(caps)")
        }
    }

    func testEveryWindowIsAccountedForByTheCapacities() {
        for n in 1...40 {
            let caps = TerminalTileLayout.capacities(count: n, display: display)
            XCTAssertEqual(caps.reduce(0, +), max(4, n))
        }
    }

    // MARK: - The cascade itself

    func testThePileIsPinnedToTheQuadrantsBottomRightCorner() {
        let quad = quads[3]
        for k in 1...7 {
            let pile = TerminalTileLayout.cascade(count: k, in: quad)
            XCTAssertEqual(pile.count, k)
            XCTAssertEqual(pile.first!, quad, "the deepest window is the whole quadrant")
            for r in pile {
                XCTAssertEqual(r.x2, quad.x2, "\(k): the right edge is nailed to the quadrant's")
                XCTAssertEqual(r.y2, quad.y2, "\(k): so is the bottom edge")
                XCTAssertTrue(r.x >= quad.x && r.y >= quad.y, "\(k): the pile stays in its quarter")
            }
        }
    }

    /// A step exposes a whole title bar of the window behind, and a narrow column
    /// of its left edge — enough to read which session it is and to see the Claude
    /// bubble spinning in it.
    func testEachStepExposesATitleBarAndAColumnOfTheLeftEdge() {
        let pile = TerminalTileLayout.cascade(count: 4, in: quads[3])
        for (a, b) in zip(pile, pile.dropFirst()) {
            XCTAssertEqual(b.y - a.y, TerminalTileLayout.titleStep)
            XCTAssertEqual(b.x - a.x, TerminalTileLayout.sideStep)
        }
    }

    /// The floor that defines "full": however many windows a quadrant ends up
    /// holding, the smallest of them still has half the quadrant's width and half
    /// its height — a quarter of its area.
    func testNoWindowEverShrinksBelowAQuarterOfItsQuadrant() {
        for k in 1...40 {
            for r in TerminalTileLayout.cascade(count: k, in: quads[3]) {
                XCTAssertGreaterThanOrEqual(r.w * 2, quads[3].w, "\(k) windows: \(r) is too narrow")
                XCTAssertGreaterThanOrEqual(r.h * 2, quads[3].h, "\(k) windows: \(r) is too short")
            }
        }
    }

    /// Two windows of a pile are never the same frame — one of them would be
    /// invisible behind the other, and the assignment could not tell them apart.
    func testEverySlotOnTheDisplayIsADistinctFrame() {
        for n in 1...32 {
            let slots = TerminalTileLayout.targets(count: n, display: display)
            XCTAssertEqual(Set(slots).count, slots.count, "\(n) windows: two slots coincide")
        }
    }

    func testNoPileEverLeavesItsOwnQuadrant() {
        for n in 1...32 {
            let slots = TerminalTileLayout.targets(count: n, display: display)
            for s in slots {
                let home = quads.first { $0.x <= s.x && $0.y <= s.y && s.x2 <= $0.x2 && s.y2 <= $0.y2 }
                XCTAssertNotNil(home, "\(n) windows: \(s) is in no quadrant")
            }
        }
    }

    func testTheFifthWindowCascadesOnTheBottomRightQuadrantAndTheOthersKeepTheirs() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800), win(1500, 800), win(1600, 1100)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(Array(out.prefix(3)), [quads[0], quads[1], quads[2]])
        XCTAssertEqual(Set([out[3], out[4]]), Set(TerminalTileLayout.cascade(count: 2, in: quads[3])))
    }

    // MARK: - Re-tiling must not shuffle

    /// The bug that made ⌘⌃A a game of musical chairs: slots used to go to the
    /// four *front-most* windows, and raising the pile made the pile front-most, so
    /// every press swapped the pile with the tiles.
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
        let strayed = Rect(x: laidOut[4].x + 20, y: laidOut[4].y + 10,
                           w: laidOut[4].w, h: laidOut[4].h)
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
        XCTAssertEqual(Set(out).count, 9)
    }

    // MARK: - Screens that are not at the origin

    func testQuadrantsFollowASecondaryDisplaysOffset() {
        let second = Rect(x: -1440, y: -900, w: 1440, h: 900)
        let out = TerminalTileLayout.frames(windows: [win(-1400, -880)], display: second)
        XCTAssertEqual(out[0], TerminalTileLayout.quadrants(of: second)[0])
        XCTAssertEqual(out[0].x, -1440 + TerminalTileLayout.margin)
    }
}

import XCTest
@testable import VictorAddons

/// Where ⌘⌃A puts each Terminal window — quadrants for four, and from the fifth
/// on a quadrant split into rows (bottom-right first, then bottom-left, top-right,
/// top-left) so that nothing is ever piled on anything — and, just as much, what
/// it does *not* do: move a window that is already in place.
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

    /// The array is the display read top to bottom: the four quadrants in order,
    /// each already sliced into the rows it has to hold. `TerminalTiler` raises
    /// windows in this order, and it is also the order that makes the layout
    /// readable as a list.
    func testSlotsComeInQuadrantOrderEachQuadrantSlicedIntoItsRows() {
        let slots = TerminalTileLayout.targets(count: 7, display: display)
        XCTAssertEqual(slots.count, 7)
        // 7 = one each, then the extras to bottom-right, bottom-left, top-right.
        XCTAssertEqual(TerminalTileLayout.capacities(count: 7), [1, 2, 2, 2])
        XCTAssertEqual(slots[0], quads[0])
        XCTAssertEqual(Array(slots[1...2]), TerminalTileLayout.rows(count: 2, in: quads[1]))
        XCTAssertEqual(Array(slots[3...4]), TerminalTileLayout.rows(count: 2, in: quads[2]))
        XCTAssertEqual(Array(slots[5...6]), TerminalTileLayout.rows(count: 2, in: quads[3]))
    }

    func testFourWindowsOrFewerGetPlainQuadrants() {
        XCTAssertEqual(TerminalTileLayout.targets(count: 4, display: display), quads)
        XCTAssertEqual(TerminalTileLayout.targets(count: 1, display: display), quads)
    }

    // MARK: - Filling order

    /// Bottom-right takes the fifth window, bottom-left the sixth, top-right the
    /// seventh, top-left the eighth — then round again.
    func testExtrasGoBottomRightThenBottomLeftThenTopRightThenTopLeft() {
        XCTAssertEqual(TerminalTileLayout.capacities(count: 5), [1, 1, 1, 2])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 6), [1, 1, 2, 2])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 7), [1, 2, 2, 2])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 8), [2, 2, 2, 2])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 9), [2, 2, 2, 3])
        XCTAssertEqual(TerminalTileLayout.capacities(count: 13), [3, 3, 3, 4])
    }

    func testEveryWindowIsAccountedForByTheCapacities() {
        for n in 1...20 {
            let caps = TerminalTileLayout.capacities(count: n)
            XCTAssertEqual(caps.reduce(0, +), max(4, n))
        }
    }

    // MARK: - Splitting a quadrant

    func testRowsFillTheQuadrantExactlyAndNeverOverlap() {
        for k in 1...5 {
            let rows = TerminalTileLayout.rows(count: k, in: quads[3])
            XCTAssertEqual(rows.count, k)
            XCTAssertEqual(rows.first!.y, quads[3].y)
            XCTAssertEqual(rows.last!.y2, quads[3].y2)
            for r in rows {
                XCTAssertEqual(r.x, quads[3].x, "a row keeps the full width — the title is what we are protecting")
                XCTAssertEqual(r.w, quads[3].w)
            }
            for (a, b) in zip(rows, rows.dropFirst()) {
                XCTAssertEqual(a.y2, b.y, "rows abut: no overlap, no seam")
            }
        }
    }

    /// The whole point of the change: no window is ever laid on top of another.
    func testNoTwoSlotsEverOverlap() {
        for n in 1...16 {
            let slots = TerminalTileLayout.targets(count: n, display: display)
            for (i, a) in slots.enumerated() {
                for b in slots[(i + 1)...] {
                    let overlaps = a.x < b.x2 && b.x < a.x2 && a.y < b.y2 && b.y < a.y2
                    XCTAssertFalse(overlaps, "\(n) windows: \(a) overlaps \(b)")
                }
            }
        }
    }

    func testTheFifthWindowHalvesTheBottomRightQuadrantAndTheOthersKeepTheirs() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800), win(1500, 800), win(1600, 1100)]
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        XCTAssertEqual(Array(out.prefix(3)), [quads[0], quads[1], quads[2]])
        XCTAssertEqual(Set([out[3], out[4]]), Set(TerminalTileLayout.rows(count: 2, in: quads[3])))
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

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

    /// Which quadrant a frame sits in — the part of the layout that geometry, and
    /// only geometry, decides.
    private func home(_ r: Rect) -> Int? {
        quads.firstIndex { $0.x <= r.x && $0.y <= r.y && r.x2 <= $0.x2 && r.y2 <= $0.y2 }
    }

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

    // MARK: - The focused window

    /// Only the front-most slot of a quadrant has nothing stacked on it, and with a
    /// pile on the screen the quadrants still holding one window are the biggest of
    /// those — so those are where the keyboard may go.
    func testTheBestSlotsAreTheUnobstructedWholeQuadrants() {
        XCTAssertEqual(TerminalTileLayout.topSlots(count: 6, display: display), [0, 1, 2])
        XCTAssertEqual(TerminalTileLayout.topSlots(count: 4, display: display), [0, 1, 2, 3],
                       "four equal quadrants, nothing stacked: every one of them is the best")
    }

    /// The window being typed in comes out of the pile and onto a whole quadrant —
    /// the largest surface with nothing lying on top of it — and, among the equally
    /// good ones, the nearest, so it travels no further than it has to.
    func testTheFocusedWindowGetsAWholeQuadrantInsteadOfASlotInThePile() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800)]
            + (0..<3).map { win(1500 + $0 * 40, 800 + $0 * 40) }
        let out = TerminalTileLayout.frames(windows: windows, display: display, focused: 5)
        XCTAssertEqual(out[5], quads[1], "the whole quadrant nearest the pile it came out of")
        XCTAssertEqual(Set(out).count, windows.count, "and nobody is left sharing a slot")
        XCTAssertFalse(out.dropLast().contains(quads[1]), "nor sitting where it used to be")
    }

    /// Whichever window has the keyboard, it lands on a quadrant no other window is
    /// stacked on — never on a slot in a cascade.
    func testNoFocusedWindowEverEndsUpInsideAPile() {
        let windows = (0..<9).map { win(100 + $0 * 30, 100 + $0 * 30) }
        for focused in windows.indices {
            let out = TerminalTileLayout.frames(windows: windows, display: display, focused: focused)
            XCTAssertTrue(quads.contains(out[focused]),
                          "window \(focused) landed on \(out[focused]), not a whole quadrant")
        }
    }

    /// When every candidate is the same size — four windows, four quadrants — the
    /// nearest one is the one the focused window already sits in, so pinning it
    /// moves nothing and ⌘⌃A twice is still a no-op.
    func testPinningTheFocusedWindowMovesNothingWhenEveryQuadrantIsEqual() {
        let windows = [win(1500, 800), win(100, 100), win(1500, 100), win(100, 800)]
        let plain = TerminalTileLayout.frames(windows: windows, display: display)
        for focused in windows.indices {
            XCTAssertEqual(TerminalTileLayout.frames(windows: windows, display: display,
                                                     focused: focused), plain)
        }
    }

    /// Pressing ⌘⌃A again with the same window focused finds it already on its
    /// slot and leaves the whole screen alone.
    func testRetilingWithTheSameWindowFocusedChangesNothing() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800)]
            + (0..<4).map { win(1500 + $0 * 40, 800 + $0 * 40) }
        let once = TerminalTileLayout.frames(windows: windows, display: display, focused: 6)
        XCTAssertEqual(TerminalTileLayout.frames(windows: once, display: display, focused: 6), once)
    }

    // MARK: - The sessions that are running

    /// The quadrants nobody is stacked on — which is `topSlots` minus the front
    /// slots of the piles, because those are only unobstructed for whoever is
    /// front-most in z, and the tile is not allowed to decide that.
    func testTheWholeQuadrantsAreTheOnesNothingIsStackedOn() {
        XCTAssertEqual(TerminalTileLayout.wholeQuadrantSlots(count: 6, display: display), [0, 1, 2])
        XCTAssertEqual(TerminalTileLayout.wholeQuadrantSlots(count: 4, display: display), [0, 1, 2, 3])
        XCTAssertEqual(TerminalTileLayout.wholeQuadrantSlots(count: 11, display: display), [0, 1],
                       "the bottom-left has started piling, so it is no longer one of them")
        XCTAssertEqual(TerminalTileLayout.wholeQuadrantSlots(count: 28, display: display), [],
                       "every quadrant piled: the preference has nothing left to give")
    }

    /// The terminals with a session running in them come out of the pile and onto
    /// the free quadrants; the bare shells take their place in the cascade.
    func testTheClaudeSessionsTakeTheFreeQuadrantsAndTheShellsGoIntoThePile() {
        let shells = [win(100, 100), win(1500, 100), win(100, 800)]
        let sessions = (0..<3).map { win(1500 + $0 * 40, 800 + $0 * 40) }
        let out = TerminalTileLayout.frames(windows: shells + sessions, display: display,
                                            claude: [3, 4, 5])
        for i in 3...5 {
            XCTAssertTrue(quads.contains(out[i]), "session \(i) landed on \(out[i]), not a quadrant")
        }
        let pile = Set(TerminalTileLayout.cascade(count: 3, in: quads[3]))
        XCTAssertEqual(Set(out.prefix(3)), pile, "the three shells are the pile now")
        XCTAssertEqual(Set(out).count, 6)
    }

    /// …and pressing ⌘⌃A again with the same sessions running finds every one of
    /// them where it left it. Cost-0 pairs are taken first in the preference round
    /// too, which is what keeps this from being a merry-go-round.
    func testRetilingWithTheSameSessionsRunningChangesNothing() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800)]
            + (0..<3).map { win(1500 + $0 * 40, 800 + $0 * 40) }
        let once = TerminalTileLayout.frames(windows: windows, display: display, claude: [3, 4, 5])
        XCTAssertEqual(TerminalTileLayout.frames(windows: once, display: display, claude: [3, 4, 5]),
                       once)
    }

    /// ⌘` has moved the front window to the back of the stack — the tile must not
    /// answer that by moving the sessions off their quadrants. The shells left in
    /// the pile are re-dealt among themselves, because depth in a pile *is* z-order
    /// and the stacking is the thing that just changed; the sessions are each alone
    /// in a quadrant, so nothing about them depends on it.
    func testACycleThroughTheWindowsDoesNotMoveTheSessions() {
        let windows = [win(100, 100), win(1500, 100), win(100, 800)]
            + (0..<3).map { win(1500 + $0 * 40, 800 + $0 * 40) }
        let laidOut = TerminalTileLayout.frames(windows: windows, display: display, claude: [3, 4, 5])
        let cycled = Array(laidOut.dropFirst()) + [laidOut[0]]
        let out = TerminalTileLayout.frames(windows: cycled, display: display, claude: [2, 3, 4])
        XCTAssertEqual(Array(out[2...4]), Array(cycled[2...4]), "a session changed quadrant")
        XCTAssertEqual(Set(out), Set(laidOut), "and the screen is filled by the same slots")
    }

    /// The keyboard outranks the preference: the focused window is served first,
    /// and a session that is left over is dealt into a pile like any other window.
    func testTheFocusedWindowIsServedBeforeTheSessions() {
        let windows = (0..<9).map { i in win(100 + i * 30, 100 + i * 30) }
        let out = TerminalTileLayout.frames(windows: windows, display: display,
                                            focused: 8, claude: Set(0..<8))
        XCTAssertTrue(quads.contains(out[8]), "the keyboard did not get a whole quadrant")
        XCTAssertEqual(Set(out).count, windows.count)
    }

    /// Every terminal running a session is the ordinary state of this Mac: the
    /// preference has nothing to choose between, so the layout is the one pure
    /// geometry gives.
    func testWhenEveryTerminalRunsASessionTheLayoutIsUnchanged() {
        let windows = TerminalTileLayout.frames(windows: (0..<6).map { _ in win(50, 50) },
                                                display: display)
        XCTAssertEqual(TerminalTileLayout.frames(windows: windows, display: display,
                                                 claude: Set(windows.indices)),
                       TerminalTileLayout.frames(windows: windows, display: display))
    }

    /// Nothing is promised past the free quadrants: with eleven windows only two
    /// quadrants are still whole, so nine of the eleven sessions are piled — but
    /// the two that fit are sessions, not shells.
    func testTheSessionsTakeTheFreeQuadrantsEvenWhenMostOfThemCannotFit() {
        let shells = (0..<2).map { win(100 + $0 * 20, 100 + $0 * 20) }
        let sessions = (0..<9).map { win(1500 + $0 * 20, 800 + $0 * 20) }
        let out = TerminalTileLayout.frames(windows: shells + sessions, display: display,
                                            claude: Set(2..<11))
        let whole = TerminalTileLayout.wholeQuadrantSlots(count: 11, display: display)
            .map { TerminalTileLayout.targets(count: 11, display: display)[$0] }
        XCTAssertEqual(whole.count, 2)
        for w in whole {
            let owner = out.firstIndex(of: w)
            XCTAssertNotNil(owner)
            XCTAssertGreaterThanOrEqual(owner!, 2, "a bare shell took a free quadrant")
        }
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

    /// Same layout, windows handed over in a different order: nobody changes
    /// *quadrant*, because position is the only thing that decides which quarter of
    /// the screen a window belongs to.
    func testTheOrderWindowsComeInNeverMovesThemToAnotherQuadrant() {
        let windows = (0..<7).map { _ in win(50, 50) }
        let laidOut = TerminalTileLayout.frames(windows: windows, display: display)
        let shuffled = Array(laidOut.reversed())
        let out = TerminalTileLayout.frames(windows: shuffled, display: display)
        XCTAssertEqual(out.map(home), shuffled.map(home))
    }

    /// …but inside the pile the order *is* what decides, because a cascade's depth
    /// and the windows' z-order are the same thing, and ⌘` walks that z-order. The
    /// deepest slot — the whole quadrant — goes to the window that is already
    /// back-most, so `TerminalTiler` can leave the stacking alone and ⌘⇧` still
    /// lands in the terminal it landed in before the tile.
    func testThePileIsDealtByTheOrderTheWindowsCameIn() {
        let windows = (0..<7).map { _ in win(50, 50) }   // front-to-back, all in one place
        let out = TerminalTileLayout.frames(windows: windows, display: display)
        let pile = TerminalTileLayout.cascade(count: 4, in: quads[3])
        XCTAssertEqual(Array(out.suffix(4)), Array(pile.reversed()),
                       "the back-most window is the whole quadrant, the front-most the smallest")
    }

    /// The one window that keeps the slot geometry gave it is the one holding the
    /// keyboard: the pin puts it on an unobstructed slot and the rest of its pile is
    /// dealt around it.
    func testDealingThePileLeavesTheFocusedWindowOnItsPinnedSlot() {
        let windows = (0..<9).map { i in win(100 + i * 30, 100 + i * 30) }
        for focused in windows.indices {
            let out = TerminalTileLayout.frames(windows: windows, display: display, focused: focused)
            XCTAssertTrue(quads.contains(out[focused]), "window \(focused) landed in a pile")
            XCTAssertEqual(Set(out).count, windows.count, "window \(focused): a slot is shared")
        }
    }

    /// Re-tiling after ⌘` has raised a buried window is still a no-op *as a set of
    /// frames*: the pile is re-dealt to the new stacking, so the same slots are
    /// filled by the same windows in a different order — nothing is lost and no two
    /// windows share a frame.
    func testReDealingAfterACycleKeepsTheSameSetOfSlots() {
        let windows = (0..<7).map { _ in win(50, 50) }
        let laidOut = TerminalTileLayout.frames(windows: windows, display: display)
        // ⌘`: the front window goes to the back.
        let cycled = Array(laidOut.dropFirst()) + [laidOut[0]]
        let out = TerminalTileLayout.frames(windows: cycled, display: display)
        XCTAssertEqual(Set(out), Set(laidOut))
        XCTAssertEqual(out.map(home), cycled.map(home), "and nobody left their quadrant")
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

import XCTest
@testable import VictorAddons

final class ShareZoomPolicyTests: XCTestCase {

    private let screen = CGSize(width: 1728, height: 1117)

    // MARK: - The dial

    /// Positive (after `ScrollReversal`) = closer, for a notched wheel.
    func testPositiveWheelDeltaZoomsIn() {
        XCTAssertGreaterThan(ShareZoomPolicy.step(1, delta: 1, source: .wheel), 1)
        XCTAssertLessThan(ShareZoomPolicy.step(2, delta: -1, source: .wheel), 2)
    }

    /// Victor's Logi M650 under Options+: continuous, no phase, wheel-up positive
    /// (measured 2026-10-15). Closer, by its delta, as the macOS magnifier zooms:
    /// one 12 px detent is ×1.01, a fast 1131 px event ×2.55 (2026-10-30).
    func testSmoothWheelZoomsByItsDeltaLikeTheMagnifier() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: 12, source: .smoothWheel), 1.01, accuracy: 0.0001)
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: 1131, source: .smoothWheel),
                       pow(1.01, 1131.0 / 12), accuracy: 0.001)
        XCTAssertLessThan(ShareZoomPolicy.step(2, delta: -13, source: .smoothWheel), 2)
    }

    func testAPhaselessContinuousScrollIsASmoothWheel() {
        XCTAssertEqual(ShareZoomPolicy.Source.of(continuous: true, phase: 0, momentumPhase: 0), .smoothWheel)
        XCTAssertEqual(ShareZoomPolicy.Source.of(continuous: true, phase: 2, momentumPhase: 0), .trackpad)
        XCTAssertEqual(ShareZoomPolicy.Source.of(continuous: true, phase: 0, momentumPhase: 3), .trackpad)
        XCTAssertEqual(ShareZoomPolicy.Source.of(continuous: false, phase: 0, momentumPhase: 0), .wheel)
    }

    /// Halved twice, then 20 % bigger three times (all in the log domain): one notch
    /// is 1.15^0.432, so ten notches make 4.32 of the first build's.
    func testTenNotchesMakeOverFourOfTheFirstBuildsSteps() {
        var f: CGFloat = 1
        for _ in 0..<10 { f = ShareZoomPolicy.step(f, delta: 1, source: .wheel) }
        XCTAssertEqual(f, pow(1.15, 4.32), accuracy: 0.0001)
    }

    /// Sensitivity proportional to the zoom: from 2× up, the drawn cursor crosses the
    /// glass at the same speed whatever the factor (2026-10-29, ^1.5 was 0.71 at 2× and
    /// 0.35 at 8×).
    func testTheGlassSpeedIsTheSameAtEveryFactorFromTwoUp() {
        for f: CGFloat in [2, 3, 4, 6, 8] {
            XCTAssertEqual(f / ShareZoomPolicy.pointerSlowdown(f), ShareZoomPolicy.defaultGlassSpeed, accuracy: 0.0001)
        }
    }

    /// Below 2× it eases in from the unzoomed speed instead of halving at the first notch.
    func testTheSlowdownStartsFromOneAtOneAndNeverJumps() {
        XCTAssertEqual(ShareZoomPolicy.pointerSlowdown(1), 1)
        XCTAssertEqual(ShareZoomPolicy.pointerSlowdown(1.036), 1.036 * 1.036, accuracy: 0.0001)
        var last: CGFloat = 1
        for i in 1...700 {
            let s = ShareZoomPolicy.pointerSlowdown(1 + CGFloat(i) / 100)
            XCTAssertGreaterThan(s, last)
            XCTAssertLessThan(s - last, 0.05)
            last = s
        }
    }

    /// A hard throw to the other monitor is still the hand: slowed, however big.
    func testABigMoveTheDeltaExplainsIsScaled() {
        let last = CGPoint(x: 500, y: 700)
        XCTAssertFalse(ShareZoomPolicy.followsUnscaled(
            now: CGPoint(x: 1400, y: 700), last: last, delta: CGVector(dx: 900, dy: 0)))
        // Placed before our last warp landed: off by that warp's step, still the hand.
        XCTAssertFalse(ShareZoomPolicy.followsUnscaled(
            now: CGPoint(x: 1400 + 337, y: 700), last: last, delta: CGVector(dx: 450 + 450, dy: 0)))
    }

    /// A warp by someone else or a display change: the delta says a few points, the
    /// cursor is somewhere else entirely.
    func testAJumpTheDeltaDoesNotExplainIsFollowed() {
        XCTAssertTrue(ShareZoomPolicy.followsUnscaled(
            now: CGPoint(x: -1500, y: 300), last: CGPoint(x: 500, y: 700), delta: CGVector(dx: 3, dy: 0)))
        XCTAssertFalse(ShareZoomPolicy.followsUnscaled(
            now: CGPoint(x: 503, y: 701), last: CGPoint(x: 500, y: 700), delta: CGVector(dx: 3, dy: 0)))
    }

    func testTheGlassSpeedIsTunable() {
        XCTAssertEqual(4 / ShareZoomPolicy.pointerSlowdown(4, glassSpeed: 0.7), 0.7, accuracy: 0.0001)
    }

    func testTheCeilingIsEightyPercentOfTheOldTen() {
        XCTAssertEqual(ShareZoomPolicy.maxFactor, 8)
    }

    func testOneFastSpinCountsForAtMostThreeNotches() {
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: 10, source: .wheel),
                       pow(ShareZoomPolicy.notchFactor, 3), accuracy: 0.0001)
    }

    func testTrackpadPixelsAccumulateIntoNotches() {
        // Fingers up = negative (natural scrolling) = closer, like ⌥+scroll.
        XCTAssertEqual(ShareZoomPolicy.step(1, delta: -12, source: .trackpad), ShareZoomPolicy.notchFactor, accuracy: 0.0001)
        XCTAssertLessThan(ShareZoomPolicy.step(2, delta: 12, source: .trackpad), 2)
    }

    func testTheDialStopsAtOneAndAtTheCeiling() {
        XCTAssertEqual(ShareZoomPolicy.step(1.05, delta: -3, source: .wheel), 1)
        XCTAssertEqual(ShareZoomPolicy.step(7.9, delta: 3, source: .wheel), ShareZoomPolicy.maxFactor)
    }

    func testScrollingBackAsFarAsInLandsOnExactlyOne() {
        var f: CGFloat = 1
        for _ in 0..<20 { f = ShareZoomPolicy.step(f, delta: 1, source: .wheel) }
        for _ in 0..<20 { f = ShareZoomPolicy.step(f, delta: -1, source: .wheel) }
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

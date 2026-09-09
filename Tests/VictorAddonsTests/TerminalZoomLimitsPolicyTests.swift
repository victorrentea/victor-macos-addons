import CoreGraphics
import XCTest

@testable import VictorAddons

/// The two bounds of the Cmd+scroll font zoom, expressed the only way they can be
/// measured: the height of one character cell.
final class TerminalZoomLimitsPolicyTests: XCTestCase {

    /// Cell heights measured on Victor's profile through `TerminalFontSize.cell`,
    /// so the numbers in the tests are the ones the AX call really returns.
    private let atFloor: CGFloat = 14      // 11 pt
    private let oneAboveFloor: CGFloat = 15  // 12 pt
    private let atCeiling: CGFloat = 28    // 23 pt
    private let oneBelowCeiling: CGFloat = 27  // 22 pt
    private let profileDefault: CGFloat = 23   // 18 pt, where every window sits

    func testMidRangeAllowsBothDirections() {
        let allowed = TerminalZoomLimitsPolicy.allowed(cellHeight: profileDefault)
        XCTAssertTrue(allowed.smaller)
        XCTAssertTrue(allowed.bigger)
    }

    func testAtTheFloorItWillNotShrinkFurther() {
        let allowed = TerminalZoomLimitsPolicy.allowed(cellHeight: atFloor)
        XCTAssertFalse(allowed.smaller)
        // Getting back out of the floor must always work, or a mis-set bound
        // would strand the window there.
        XCTAssertTrue(allowed.bigger)
    }

    func testAtTheCeilingItWillNotGrowFurther() {
        let allowed = TerminalZoomLimitsPolicy.allowed(cellHeight: atCeiling)
        XCTAssertFalse(allowed.bigger)
        XCTAssertTrue(allowed.smaller)
    }

    /// Both bounds are *reachable*: the last step onto them is allowed, and only
    /// the one that would pass them is refused.
    func testTheStepOntoEachBoundIsAllowed() {
        XCTAssertTrue(TerminalZoomLimitsPolicy.allowed(cellHeight: oneAboveFloor).smaller)
        XCTAssertTrue(TerminalZoomLimitsPolicy.allowed(cellHeight: oneBelowCeiling).bigger)
    }

    /// A window already past a bound — zoomed there before this app started, or
    /// with the plain Cmd+= this gesture does not manage — is not stuck: it can
    /// still be brought back towards the range, just not taken further out.
    func testAWindowAlreadyOutsideTheRangeCanComeBack() {
        let tiny = TerminalZoomLimitsPolicy.allowed(cellHeight: 9)
        XCTAssertFalse(tiny.smaller)
        XCTAssertTrue(tiny.bigger)

        let huge = TerminalZoomLimitsPolicy.allowed(cellHeight: 60)
        XCTAssertTrue(huge.smaller)
        XCTAssertFalse(huge.bigger)
    }

    /// A limit that fires because the measurement failed would be worse than no
    /// limit — an unreadable terminal keeps the pre-2026-09-09 behaviour.
    func testAnUnmeasurableWindowIsNotRestricted() {
        XCTAssertEqual(TerminalZoomLimitsPolicy.allowed(cellHeight: nil),
                       TerminalZoomLimitsPolicy.Allowed.unrestricted)
    }
}

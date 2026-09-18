import AppKit
import XCTest
@testable import VictorAddons

/// Hermetic tests for `BottomTabBanner`'s pure geometry and motion rules — the
/// decisions that place the tab and time its slide. Rendering itself (panels,
/// glass, rounded top corners) needs a window server and is covered by the
/// manual `/test/bell` check.
final class BottomTabBannerTests: XCTestCase {

    private typealias Style = BottomTabBanner.Style

    // MARK: - Width

    func testWidthHugsTheTextWithPaddingOnBothSides() {
        XCTAssertEqual(BottomTabBanner.tabWidth(textWidth: 300, screenWidth: 2000),
                       300 + 2 * Style.horizontalPadding)
    }

    func testShortTextStillGetsTheMinimumWidth() {
        // A one-word tab ("🔔 Ana") must not shrink to a stub.
        XCTAssertEqual(BottomTabBanner.tabWidth(textWidth: 10, screenWidth: 2000), Style.minWidth)
    }

    func testRunawayTextIsCappedToAFractionOfTheScreen() {
        // Three coalesced long names must not span the whole projector.
        XCTAssertEqual(BottomTabBanner.tabWidth(textWidth: 5000, screenWidth: 1000),
                       1000 * Style.maxWidthFraction)
    }

    func testMinimumWinsOverTheCapOnAVeryNarrowScreen() {
        // The cap must never produce a tab narrower than the floor.
        XCTAssertEqual(BottomTabBanner.tabWidth(textWidth: 5000, screenWidth: 100), Style.minWidth)
    }

    // MARK: - Horizontal placement

    func testTabIsCentredOnItsScreen() {
        XCTAssertEqual(BottomTabBanner.originX(tabWidth: 400, screenMinX: 0, screenWidth: 1000), 300)
    }

    func testCentringRespectsTheScreensGlobalOrigin() {
        // A second display to the right of the built-in one: the tab centres on
        // THAT screen, not on the global origin.
        XCTAssertEqual(BottomTabBanner.originX(tabWidth: 400, screenMinX: 1920, screenWidth: 1000),
                       1920 + 300)
    }

    func testOriginIsWholePixels() {
        // Odd leftover → still an integer, so the glass never lands on a half
        // pixel and blurs the text.
        let x = BottomTabBanner.originX(tabWidth: 401, screenMinX: 0, screenWidth: 1000)
        XCTAssertEqual(x, x.rounded())
    }

    // MARK: - Slide

    func testRiseStartsFullyBelowTheEdgeAndEndsFlush() {
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 0, rising: true), -Style.tabHeight)
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 1, rising: true), 0)
    }

    func testFallStartsFlushAndEndsFullyBelowTheEdge() {
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 0, rising: false), 0)
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 1, rising: false), -Style.tabHeight)
    }

    func testRiseDeceleratesAndFallAccelerates() {
        // At the halfway point in time the rising tab is already three quarters
        // of the way up (easeOut: it arrives, it does not slam), while the
        // falling tab has only dropped a quarter (easeIn: it lets go slowly).
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 0.5, rising: true),
                       -Style.tabHeight * 0.25, accuracy: 0.001)
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 0.5, rising: false),
                       -Style.tabHeight * 0.25, accuracy: 0.001)
    }

    func testSlideNeverLeavesItsTrackWhenProgressOvershoots() {
        // A timer frame can land past the end; the offset must clamp, never
        // push the tab above the edge or below the panel.
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 1.4, rising: true), 0)
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: -0.3, rising: true), -Style.tabHeight)
        XCTAssertEqual(BottomTabBanner.slideOffset(progress: 1.4, rising: false), -Style.tabHeight)
    }

    // MARK: - Timing

    func testTabHoldsForThreeSeconds() {
        // The spec'd dwell: sneak in, wait about three seconds, fall away.
        XCTAssertEqual(Style.holdDuration, 3.0)
    }

    // MARK: - Label

    func testLabelIsInsetByThePaddingOnBothSides() {
        let frame = BottomTabBanner.labelFrame(tabWidth: 500, font: Style.defaultFont())
        XCTAssertEqual(frame.minX, Style.horizontalPadding)
        XCTAssertEqual(frame.width, 500 - 2 * Style.horizontalPadding)
    }

    func testLabelIsVerticallyCentredInTheTab() {
        let frame = BottomTabBanner.labelFrame(tabWidth: 500, font: Style.defaultFont())
        XCTAssertEqual(frame.midY, Style.tabHeight / 2, accuracy: 0.51)
    }
}

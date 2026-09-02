import XCTest
@testable import VictorAddons

/// The entrance wipe is specified as a constant SPEED, not a constant duration:
/// the pill's right edge leaves the screen's left edge at the same rate whatever
/// the pill says, so a two-word flash snaps in and a long prompt takes visibly
/// longer. These pin that, plus the ceiling that sets the rate.
final class BottomLeftBannerWipeTests: XCTestCase {
    private typealias Style = BottomLeftBanner.Style

    private func duration(pillWidth: CGFloat, screenWidth: CGFloat) -> TimeInterval {
        TimeInterval(pillWidth / Style.wipeSpeed(screenWidth: screenWidth))
    }

    func testWidestAllowedPillTakesExactlyTheFullWidthDuration() {
        let screenWidth: CGFloat = 3456
        let widest = screenWidth * Style.maxWidthFraction   // the layout's hard cap
        XCTAssertEqual(duration(pillWidth: widest, screenWidth: screenWidth),
                       Style.wipeFullWidthDuration, accuracy: 0.0001)
    }

    func testNoPillCanExceedHalfASecond() {
        XCTAssertLessThanOrEqual(Style.wipeFullWidthDuration, 0.5)
    }

    func testHalfAsWideTakesHalfAsLong() {
        let screenWidth: CGFloat = 1920
        let wide = duration(pillWidth: 600, screenWidth: screenWidth)
        let narrow = duration(pillWidth: 300, screenWidth: screenWidth)
        XCTAssertEqual(narrow, wide / 2, accuracy: 0.0001)
    }

    func testSpeedIsIndependentOfWhatThePillSays() {
        // Same screen ⇒ same points-per-second, whatever width the text produced.
        let screenWidth: CGFloat = 1920
        let speedA = 200 / duration(pillWidth: 200, screenWidth: screenWidth)
        let speedB = 900 / duration(pillWidth: 900, screenWidth: screenWidth)
        XCTAssertEqual(speedA, speedB, accuracy: 0.0001)
        XCTAssertEqual(CGFloat(speedA), Style.wipeSpeed(screenWidth: screenWidth), accuracy: 0.0001)
    }

    func testAWiderScreenWipesProportionallyFaster() {
        XCTAssertEqual(Style.wipeSpeed(screenWidth: 3840),
                       Style.wipeSpeed(screenWidth: 1920) * 2, accuracy: 0.0001)
    }
}

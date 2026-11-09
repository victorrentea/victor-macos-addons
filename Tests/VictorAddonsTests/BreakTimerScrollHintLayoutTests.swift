import XCTest
@testable import VictorAddons

final class BreakTimerScrollHintLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testSitsRightOfTheWatchCentredOnItsHeight() {
        let watch = CGRect(x: 20, y: 800, width: 360, height: 220)
        let f = BreakTimerScrollHintLayout.frame(watch: watch, visible: screen)
        XCTAssertEqual(f.minX, watch.maxX + BreakTimerScrollHintLayout.gap)
        XCTAssertEqual(f.midY, watch.midY, accuracy: 1)
        XCTAssertLessThan(f.width, f.height)
    }

    func testFlipsLeftWhenTheRightWouldLeaveTheScreen() {
        let watch = CGRect(x: 1728 - 364, y: 800, width: 360, height: 220)
        let f = BreakTimerScrollHintLayout.frame(watch: watch, visible: screen)
        XCTAssertEqual(f.maxX, watch.minX - BreakTimerScrollHintLayout.gap)
    }

    func testStaysOnScreenVertically() {
        let watch = CGRect(x: 20, y: 1117 - 60, width: 160, height: 100)
        let f = BreakTimerScrollHintLayout.frame(watch: watch, visible: screen)
        XCTAssertLessThanOrEqual(f.maxY, screen.maxY)
    }

    func testSizeIsBoundedForTinyAndHugeWatches() {
        XCTAssertEqual(BreakTimerScrollHintLayout.size(forWatchHeight: 40).height, 84)
        XCTAssertEqual(BreakTimerScrollHintLayout.size(forWatchHeight: 2000).height, 150)
    }
}

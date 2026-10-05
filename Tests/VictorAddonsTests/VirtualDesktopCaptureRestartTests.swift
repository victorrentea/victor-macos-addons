import XCTest
@testable import VictorAddons

final class VirtualDesktopCaptureRestartTests: XCTestCase {

    func testADeadStreamComesBackWithinASecondThenBacksOffToHalfAMinute() {
        let delays = (1...7).map { VirtualDesktop.captureRestartDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30])
    }
}

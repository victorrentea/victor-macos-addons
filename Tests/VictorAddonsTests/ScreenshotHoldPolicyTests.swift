import XCTest
@testable import VictorAddons

final class ScreenshotHoldPolicyTests: XCTestCase {

    /// A normal keypress is 80–150 ms. None of that may be read as a hold —
    /// a tap must stay the full-screen shot, every time.
    func testOrdinaryTapIsNotAHold() {
        XCTAssertFalse(ScreenshotHoldPolicy.isHold(pressDuration: 0.05))
        XCTAssertFalse(ScreenshotHoldPolicy.isHold(pressDuration: 0.15))
        XCTAssertFalse(ScreenshotHoldPolicy.isHold(pressDuration: 0.44))
    }

    func testKeepingItDownIsAHold() {
        XCTAssertTrue(ScreenshotHoldPolicy.isHold(pressDuration: ScreenshotHoldPolicy.holdSeconds))
        XCTAssertTrue(ScreenshotHoldPolicy.isHold(pressDuration: 0.8))
        XCTAssertTrue(ScreenshotHoldPolicy.isHold(pressDuration: 3.0))
    }

    /// The threshold has to sit above a fast typist's press and below the wait
    /// that would make "hold it" feel like a hang.
    func testThresholdStaysInTheUsableBand() {
        XCTAssertGreaterThan(ScreenshotHoldPolicy.holdSeconds, 0.25)
        XCTAssertLessThan(ScreenshotHoldPolicy.holdSeconds, 0.7)
    }
}

import XCTest
@testable import VictorAddons

final class WheelCropPolicyTests: XCTestCase {

    /// A middle click that wobbles a few points is still a click — it closes
    /// the Chrome tab, it does not dim the screen.
    func testTremorIsNotADrag() {
        XCTAssertFalse(WheelCropPolicy.isDrag(from: .zero, to: CGPoint(x: 5, y: 5)))
        XCTAssertFalse(WheelCropPolicy.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 111, y: 100)))
    }

    func testMovingPastTheThresholdIsADrag() {
        XCTAssertTrue(WheelCropPolicy.isDrag(from: .zero, to: CGPoint(x: 12, y: 0)))
        XCTAssertTrue(WheelCropPolicy.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 90, y: 90)))
    }

    /// The wheel hold and the ⌃P hold are one length of time.
    func testHoldMatchesTheKeyboardHold() {
        XCTAssertEqual(WheelCropPolicy.holdSeconds, ScreenshotHoldPolicy.holdSeconds)
    }
}

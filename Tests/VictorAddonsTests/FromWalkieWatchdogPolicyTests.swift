import XCTest
@testable import VictorAddons

/// 🎚️ The From Walkie watchdog — the 5 s decision, without CoreAudio or a running relay.
final class FromWalkieWatchdogPolicyTests: XCTestCase {

    /// Walkie crashed or was `kill -9`ed: its quit never ran, so the device is still on.
    func testWalkieGoneAndDeviceOnTurnsItOff() {
        XCTAssertTrue(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: false, deviceOn: true))
    }

    func testWalkieRunningLeavesItAlone() {
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: true, deviceOn: true))
    }

    /// One-way: the watchdog never turns the device on, even with Walkie up.
    func testDeviceOffIsNeverTouched() {
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: true, deviceOn: false))
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: false, deviceOn: false))
    }
}

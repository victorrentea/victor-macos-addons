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

    /// A restart's ~1 s gap is one miss: the newcomer must find the device still on.
    func testOneMissIsARestartNotACrash() {
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: false, deviceOn: true, missesInARow: 1))
        XCTAssertTrue(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: false, deviceOn: true, missesInARow: 2))
    }

    /// The kernel's process table, read the way the tick reads it: this test runner is there,
    /// a name nothing runs under is not.
    func testTheProcessTableFindsARunningExecutable() {
        let me = "/" + URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        XCTAssertTrue(FromWalkieWatchdog.processRunning(executableSuffix: me))
        XCTAssertFalse(FromWalkieWatchdog.processRunning(executableSuffix: "/no-such-executable-\(UUID().uuidString)"))
    }

    /// One-way: the watchdog never turns the device on, even with Walkie up.
    func testDeviceOffIsNeverTouched() {
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: true, deviceOn: false))
        XCTAssertFalse(FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: false, deviceOn: false))
    }
}

import XCTest
@testable import VictorAddons

final class LidAwakePolicyTests: XCTestCase {

    // MARK: - The beep is narrow on purpose

    func testBeepsOnlyWithTheLidShutOnBattery() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: 80),
            .beep)
    }

    func testOpenLidIsSilent() {
        // Awake anyway — the flag is set — but a beep every five seconds at the
        // desk would make the feature unusable.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: false, onAC: false, battery: 80),
            .quiet)
    }

    func testOnACIsSilentEvenWithTheLidShut() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: true, battery: 80),
            .quiet)
    }

    func testDisabledDoesNothing() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: false, lidClosed: true, onAC: false, battery: 5),
            .quiet)
    }

    // MARK: - The floor

    func testStandsDownBelowTheFloor() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: 19),
            .standDown)
    }

    func testExactlyAtTheFloorStillRuns() {
        // "sub 20%" — 20 is not below 20.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: 20),
            .beep)
    }

    func testFloorIsCheckedBeforeTheBeep() {
        // The tick that stands down must not also sound like a healthy tick.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: 3),
            .standDown)
    }

    func testFloorDoesNotApplyOnAC() {
        // Plugged in at 4%: the number is going up, and cutting the flag here
        // would sleep the Mac for no reason.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: true, battery: 4),
            .quiet)
    }

    func testUnreadableBatteryDoesNotStandDown() {
        // A failed read is not evidence of a low charge; taking the machine
        // down mid-flight on a missing number is the worse mistake.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: nil),
            .beep)
    }
}

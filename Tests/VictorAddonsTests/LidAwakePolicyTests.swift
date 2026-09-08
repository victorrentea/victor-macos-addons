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

    // MARK: - Reading the flag back out of `pmset -g`

    /// Verbatim from `pmset -g` on this Mac. The columns are **tab**-separated,
    /// which is the whole point of this test: the first version split on `" "`
    /// alone, so the read-back never saw the `1`, the toggle reported failure,
    /// and the row sat unticked over a live SleepDisabled flag.
    private let pmsetOutput = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     hibernatemode        3
     displaysleep         15
    """

    func testFlagIsReadThroughTabColumns() {
        XCTAssertTrue(LidAwake.parseSleepDisabled(fromPmsetOutput: pmsetOutput))
    }

    func testClearedFlagReadsFalse() {
        // Once set, the line stays in the output and reads 0 — a missing line
        // is not the only way to be off.
        XCTAssertFalse(LidAwake.parseSleepDisabled(
            fromPmsetOutput: pmsetOutput.replacingOccurrences(of: "SleepDisabled\t\t1",
                                                              with: "SleepDisabled\t\t0")))
    }

    func testAbsentLineIsOff() {
        // Never set since boot: pmset does not print the line at all.
        XCTAssertFalse(LidAwake.parseSleepDisabled(fromPmsetOutput: """
        System-wide power settings:
        Currently in use:
         standby              1
        """))
    }

    func testSpaceSeparatedColumnsAlsoParse() {
        // Not what this Mac emits today, but the neighbouring rows in the very
        // same output are space-padded — the parser must not care which it got.
        XCTAssertTrue(LidAwake.parseSleepDisabled(fromPmsetOutput: " SleepDisabled        1"))
    }

    func testUnreadableBatteryDoesNotStandDown() {
        // A failed read is not evidence of a low charge; taking the machine
        // down mid-flight on a missing number is the worse mistake.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, lidClosed: true, onAC: false, battery: nil),
            .beep)
    }
}

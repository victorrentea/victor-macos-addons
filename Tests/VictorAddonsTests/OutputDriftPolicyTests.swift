import XCTest
@testable import VictorAddons

/// The latch policy behind the "Wispr started but output ≠ 🔊OS Output" alert.
/// Pure decision: given the current default-output name and whether we've
/// already warned, return whether to alert now and the next latch state.
final class OutputDriftPolicyTests: XCTestCase {

    private let monitored = OutputDriftPolicy.monitored

    func testCorrectOutputDoesNotAlertAndRearms() {
        // Output is the monitored loopback → mute path is wired → stay quiet,
        // and clear the latch so a later drift can alert again.
        let r = OutputDriftPolicy.evaluate(output: monitored, alerted: true)
        XCTAssertFalse(r.alert)
        XCTAssertFalse(r.alerted)
    }

    func testWrongOutputFirstTimeAlertsAndLatches() {
        let r = OutputDriftPolicy.evaluate(output: "MacBook Pro Speakers", alerted: false)
        XCTAssertTrue(r.alert)
        XCTAssertTrue(r.alerted)
    }

    func testWrongOutputAlreadyAlertedStaysQuiet() {
        let r = OutputDriftPolicy.evaluate(output: "MacBook Pro Speakers", alerted: true)
        XCTAssertFalse(r.alert)
        XCTAssertTrue(r.alerted)
    }

    func testUnknownOutputNeverAlertsAndLeavesLatchUntouched() {
        let armed = OutputDriftPolicy.evaluate(output: nil, alerted: false)
        XCTAssertFalse(armed.alert)
        XCTAssertFalse(armed.alerted)
        let latched = OutputDriftPolicy.evaluate(output: nil, alerted: true)
        XCTAssertFalse(latched.alert)
        XCTAssertTrue(latched.alerted)
    }

    /// Drift → alert once → silent → correct re-arms → drift alerts again.
    func testRearmSequence() {
        var alerted = false

        var r = OutputDriftPolicy.evaluate(output: "MacBook Pro Speakers", alerted: alerted)
        XCTAssertTrue(r.alert, "first drift should alert")
        alerted = r.alerted

        r = OutputDriftPolicy.evaluate(output: "MacBook Pro Speakers", alerted: alerted)
        XCTAssertFalse(r.alert, "still wrong → no repeat")
        alerted = r.alerted

        r = OutputDriftPolicy.evaluate(output: monitored, alerted: alerted)
        XCTAssertFalse(r.alert, "corrected → quiet")
        alerted = r.alerted

        r = OutputDriftPolicy.evaluate(output: "MacBook Pro Speakers", alerted: alerted)
        XCTAssertTrue(r.alert, "drift after correction should alert again")
    }
}

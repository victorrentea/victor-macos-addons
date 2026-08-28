import XCTest
@testable import VictorAddons

final class BluetoothAutoOutputPolicyTests: XCTestCase {

    func testConnectingTheSpeakersTakesTheOutput() {
        let target = BluetoothAutoOutputPolicy.evaluate(
            previous: [], current: ["JBL Charge 5"], defaultOutput: "MacBook Pro Speakers")
        XCTAssertEqual(target, "JBL Charge 5")
    }

    func testNothingHappensWithoutAnEdge() {
        // Some other device appeared/vanished; the speakers were already there.
        XCTAssertNil(BluetoothAutoOutputPolicy.evaluate(
            previous: ["JBL Charge 5"], current: ["JBL Charge 5"], defaultOutput: "Vic Bose"))
    }

    func testAManualSwitchAwayIsNotUndone() {
        // Victor moves the output to the headphones while the JBL stays
        // connected: no device-list change, so no edge, so no takeover.
        XCTAssertNil(BluetoothAutoOutputPolicy.evaluate(
            previous: ["JBL Charge 5"], current: ["JBL Charge 5"], defaultOutput: "🔊OS Output"))
    }

    func testAReconnectCountsAsAFreshConnect() {
        XCTAssertEqual(
            BluetoothAutoOutputPolicy.evaluate(
                previous: [], current: ["JBL Charge 5"], defaultOutput: "🔊OS Output"),
            "JBL Charge 5")
    }

    func testAlreadyTheDefaultOutputIsANoOp() {
        XCTAssertNil(BluetoothAutoOutputPolicy.evaluate(
            previous: [], current: ["JBL Charge 5"], defaultOutput: "JBL Charge 5"))
    }

    func testDisconnectDoesNothing() {
        XCTAssertNil(BluetoothAutoOutputPolicy.evaluate(
            previous: ["JBL Charge 5"], current: [], defaultOutput: "MacBook Pro Speakers"))
    }

    func testTwoSpeakersAppearingAtOnceResolveDeterministically() {
        XCTAssertEqual(
            BluetoothAutoOutputPolicy.evaluate(
                previous: [], current: ["JBL Go 4", "JBL Charge 5"], defaultOutput: "MacBook Pro Speakers"),
            "JBL Charge 5")
    }

    func testUnreadableDefaultOutputStillSwitches() {
        XCTAssertEqual(
            BluetoothAutoOutputPolicy.evaluate(previous: [], current: ["JBL Charge 5"], defaultOutput: nil),
            "JBL Charge 5")
    }

    func testNameMatchIsCaseInsensitiveAndSubstring() {
        XCTAssertTrue(BluetoothAutoOutputPolicy.matches("jbl charge 5"))
        XCTAssertTrue(BluetoothAutoOutputPolicy.matches("JBL Go 4"))
        XCTAssertFalse(BluetoothAutoOutputPolicy.matches("Vic Bose"))
        XCTAssertFalse(BluetoothAutoOutputPolicy.matches("MacBook Pro Speakers"))
    }
}

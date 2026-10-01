import XCTest
@testable import VictorAddons

/// Class-of-device values are the ones IOBluetooth reports for this Mac's
/// paired devices: both JBL boxes are major 4 / minor 5, the JBL TUNE500BT
/// headphones and the Bose are major 4 / minor 1.
final class SpeakerReconnectPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testBothJBLBoxesAreSpeakers() {
        XCTAssertTrue(SpeakerReconnectPolicy.isSpeaker(name: "Victor's JBL Go 4", major: 4, minor: 5))
        XCTAssertTrue(SpeakerReconnectPolicy.isSpeaker(name: "JBL", major: 4, minor: 5))
    }

    func testJBLHeadphonesAreNot() {
        XCTAssertFalse(SpeakerReconnectPolicy.isSpeaker(name: "JBL TUNE500BT", major: 4, minor: 1))
    }

    func testAnotherBrandOfSpeakerIsNot() {
        XCTAssertFalse(SpeakerReconnectPolicy.isSpeaker(name: "Sony SRS", major: 4, minor: 5))
    }

    func testNeverHuntsForSpeakersNotUsedSinceLaunch() {
        XCTAssertFalse(SpeakerReconnectPolicy.shouldPage(
            anyConnected: false, lastSeenConnected: nil, lastAttempt: nil, now: t0))
    }

    func testPagesTheSpareRightAwayWhileOneBoxPlays() {
        XCTAssertTrue(SpeakerReconnectPolicy.shouldPage(
            anyConnected: true, lastSeenConnected: t0, lastAttempt: nil, now: t0))
    }

    func testPagesTheSpareOnlyEveryThreeMinutesWhileOneBoxPlays() {
        XCTAssertFalse(SpeakerReconnectPolicy.shouldPage(
            anyConnected: true, lastSeenConnected: t0, lastAttempt: t0, now: t0 + 60))
        XCTAssertTrue(SpeakerReconnectPolicy.shouldPage(
            anyConnected: true, lastSeenConnected: t0, lastAttempt: t0, now: t0 + 180))
    }

    func testLooksHardRightAfterTheLastBoxDied() {
        XCTAssertTrue(SpeakerReconnectPolicy.shouldPage(
            anyConnected: false, lastSeenConnected: t0, lastAttempt: t0, now: t0 + 30))
    }

    func testGivesUpFifteenMinutesAfterTheLastBoxDied() {
        XCTAssertTrue(SpeakerReconnectPolicy.shouldPage(
            anyConnected: false, lastSeenConnected: t0, lastAttempt: nil, now: t0 + 15 * 60))
        XCTAssertFalse(SpeakerReconnectPolicy.shouldPage(
            anyConnected: false, lastSeenConnected: t0, lastAttempt: nil, now: t0 + 15 * 60 + 1))
    }
}

import XCTest
@testable import VictorAddons

final class PhoneBatteryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func reading(_ pct: Int, charging: Bool = false, ageS: Int = 0, fetchedAgo: TimeInterval = 0) -> PhoneCharge.Reading {
        PhoneCharge.Reading(pct: pct, charging: charging, ageS: ageS, fetchedAt: now.addingTimeInterval(-fetchedAgo))
    }

    func testWarnsAtThirtyOrLess() {
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(reading(30), now: now))
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(reading(31), now: now))
    }

    func testAChargingPhoneIsFine() {
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(reading(12, charging: true), now: now))
    }

    func testNoReadingIsNoWarning() {
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(nil, now: now))
    }

    func testAgeCountsBothVictorNetsAndOurOwn() {
        let limit = Int(PhoneBatteryPolicy.staleAfter)
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(reading(12, ageS: limit), now: now))
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(reading(12, ageS: limit, fetchedAgo: 1), now: now))
    }

    func testPingFields() {
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: reading(12), now: now), ",\"phoneBatteryLow\":true,\"phoneBatteryPct\":12")
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: reading(80), now: now), ",\"phoneBatteryLow\":false,\"phoneBatteryPct\":-1")
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: nil, now: now), ",\"phoneBatteryLow\":false,\"phoneBatteryPct\":-1")
    }
}

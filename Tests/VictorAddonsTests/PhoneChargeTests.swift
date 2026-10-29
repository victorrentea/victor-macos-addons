import XCTest
@testable import VictorAddons

/// 🔋 The phone's charge, from Victor Net to the tablet's `/ping`.
final class PhoneChargeTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testParsesVictorNetAnswer() {
        let r = PhoneCharge.parse(Data(#"{"pct":63,"charging":true,"age_s":120}"#.utf8), now: now)
        XCTAssertEqual(r, PhoneCharge.Reading(pct: 63, charging: true, ageS: 120, fetchedAt: now))
    }

    /// Victor Net has not heard from the phone yet: nothing, not 0%.
    func testUnknownPhoneIsNil() {
        XCTAssertNil(PhoneCharge.parse(Data(#"{"pct":-1}"#.utf8), now: now))
    }

    /// Victor Net down (or never heard from the phone) → the tablet shows no number.
    func testNoReadingTellsTabletToShowNothing() {
        XCTAssertEqual(PhoneCharge.pingFields(nil, now: now), ",\"phoneChargePct\":-1")
    }

    /// The age keeps growing between two polls of Victor Net.
    func testAgeIncludesTimeSinceFetch() {
        let r = PhoneCharge.Reading(pct: 40, charging: false, ageS: 100, fetchedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(PhoneCharge.pingFields(r, now: now),
                       ",\"phoneChargePct\":40,\"phoneCharging\":false,\"phoneChargeAgeS\":110")
    }
}

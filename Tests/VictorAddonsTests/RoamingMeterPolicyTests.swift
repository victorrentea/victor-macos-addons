import XCTest
@testable import VictorAddons

final class RoamingMeterPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let limit: Int64 = 13_703_000_000

    private func reading(left: Int64, roamingNow: Bool = true, readAgo: TimeInterval = 60,
                         blocked: Bool = false) -> RoamingWarningPolicy.Reading {
        RoamingWarningPolicy.Reading(
            cycleTotal: limit - left, cycleHotspot: 0, today: 1, roamingNow: roamingNow,
            limit: limit, lowFraction: 0.10, nextReset: now.addingTimeInterval(86_400),
            readAt: now.addingTimeInterval(-readAgo), hotspotBlocked: blocked)
    }

    func testMacBytesSinceTheReadingComeOffThePhonesNumber() {
        let r = reading(left: 3_200_000_000)
        XCTAssertEqual(RoamingMeterPolicy.estimate(r, macBytesSince: 700_000_000), 2_500_000_000)
        XCTAssertEqual(RoamingMeterPolicy.display(r, macBytesSince: 700_000_000, now: now),
                       .init(title: "📶 2.5 GB", tint: .orange))
    }

    func testRedUnderOneAndAHalfAndBlockedUnderTheReserve() {
        XCTAssertEqual(RoamingMeterPolicy.display(reading(left: 1_400_000_000), macBytesSince: 0, now: now),
                       .init(title: "📶 1.4 GB", tint: .red))
        XCTAssertEqual(RoamingMeterPolicy.display(reading(left: 900_000_000), macBytesSince: 0, now: now).title,
                       "📵 0.9 GB")
    }

    func testNeverBelowZero() {
        XCTAssertEqual(RoamingMeterPolicy.estimate(reading(left: 100), macBytesSince: 5_000), 0)
    }

    func testAStaleReadingIsShownAsAnEstimate() {
        XCTAssertEqual(RoamingMeterPolicy.display(reading(left: 5_000_000_000, readAgo: 3600),
                                                  macBytesSince: 0, now: now).title, "📶 ~5.0 GB")
    }

    func testNoReadingIsAQuestionMark() {
        XCTAssertEqual(RoamingMeterPolicy.display(nil, macBytesSince: 0, now: now).title, "📶 ?")
    }

    func testOnlyOnTheHotspotAndNotWhenTheFreshReadingSaysHome() {
        XCTAssertFalse(RoamingMeterPolicy.visible(onHotspot: false, reading: reading(left: 1), now: now))
        XCTAssertTrue(RoamingMeterPolicy.visible(onHotspot: true, reading: nil, now: now))
        XCTAssertTrue(RoamingMeterPolicy.visible(onHotspot: true, reading: reading(left: 1), now: now))
        XCTAssertFalse(RoamingMeterPolicy.visible(onHotspot: true, reading: reading(left: 1, roamingNow: false), now: now))
        // An old "home" reading proves nothing about now.
        XCTAssertTrue(RoamingMeterPolicy.visible(onHotspot: true, reading: reading(left: 1, roamingNow: false, readAgo: 3600), now: now))
    }

    func testTheCounterSurvivesThe32BitWrapAndOnlyCountsOnTheHotspot() {
        var c = InterfaceByteCounter()
        c.add(sample: UInt32.max - 100, at: now, counting: true)
        c.add(sample: 400, at: now.addingTimeInterval(5), counting: true)       // wrapped: +501
        c.add(sample: 1_400, at: now.addingTimeInterval(10), counting: false)   // other Wi-Fi
        c.add(sample: 1_500, at: now.addingTimeInterval(15), counting: true)
        XCTAssertEqual(c.total, 601)
        XCTAssertEqual(c.since(now.addingTimeInterval(7)), 100)
    }

    func testTheBlockedFieldIsReadFromThePhone() {
        let line = #"{"v":1,"cycleTotal":13000000000,"today":5,"limit":13703000000,"readAt":1791000000000,"roamingNow":true,"hotspotBlocked":true,"reserve":1000000000}"#
        let r = RoamingWarningPolicy.parse(line)
        XCTAssertEqual(r?.hotspotBlocked, true)
        XCTAssertEqual(r?.reserve, 1_000_000_000)
    }
}

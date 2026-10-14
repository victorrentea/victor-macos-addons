import XCTest
@testable import VictorAddons

final class RoamingDataPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func decide(onHotspot: Bool = true, phone: Bool? = nil, phoneAgo: TimeInterval = 60,
                        country: String? = nil, countryAgo: TimeInterval = 60,
                        tz: String = "Europe/Bucharest") -> RoamingDataPolicy.Verdict {
        RoamingDataPolicy.decide(onHotspot: onHotspot,
                                 phoneRoamingNow: phone, phoneReadAt: phone == nil ? nil : now.addingTimeInterval(-phoneAgo),
                                 country: country, countryAt: country == nil ? nil : now.addingTimeInterval(-countryAgo),
                                 timeZone: tz, now: now)
    }

    func testOffTheHotspotIsNeverRoamingData() {
        XCTAssertEqual(decide(onHotspot: false, phone: true, tz: "Europe/Amsterdam"),
                       .init(roamingData: false, source: .notOnHotspot))
    }

    func testAFreshPhoneReadingWinsOverEverything() {
        XCTAssertEqual(decide(phone: false, country: "NL", tz: "Europe/Amsterdam"), .init(roamingData: false, source: .phone))
        XCTAssertEqual(decide(phone: true, country: "RO"), .init(roamingData: true, source: .phone))
    }

    func testAStalePhoneReadingFallsBackToTheCountry() {
        XCTAssertEqual(decide(phone: false, phoneAgo: 3600, country: "BG"), .init(roamingData: true, source: .location))
        XCTAssertEqual(decide(country: "ro"), .init(roamingData: false, source: .location))
    }

    func testTheTimezoneIsTheLastResort() {
        XCTAssertEqual(decide(tz: "Europe/Amsterdam"), .init(roamingData: true, source: .timezone))
        XCTAssertEqual(decide(country: "NL", countryAgo: 7 * 3600), .init(roamingData: false, source: .timezone))
    }

    func testTheHooksLine() {
        let line = RoamingDataPolicy.json(.init(roamingData: true, source: .phone), onHotspot: true,
                                          suspendClaude: true, country: "NL", now: now)
        XCTAssertEqual(line, #"{"country":"NL","onHotspot":true,"roamingData":true,"source":"phone","suspendClaude":true,"updatedAt":1791000000}"#)
    }
}

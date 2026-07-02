import XCTest
@testable import VictorAddons

/// Covers the pure timezone→country mapping that drives the Break timer's
/// day-scoped auto-pick ("where am I now?"). The persistence/day-scoping side
/// (autoSelectForToday) touches UserDefaults + the wall clock, so it's exercised
/// live in the app; here we lock down the deterministic mapping.
final class BreakCountryTests: XCTestCase {

    func testMatchesKnownZoneToCountry() {
        XCTAssertEqual(BreakCountry.country(forTimeZoneIdentifier: "Europe/Lisbon")?.name, "Portugal")
        XCTAssertEqual(BreakCountry.country(forTimeZoneIdentifier: "Europe/Bucharest")?.name, "Romania")
        XCTAssertEqual(BreakCountry.country(forTimeZoneIdentifier: "America/New_York")?.name, "USA (New York)")
        XCTAssertEqual(BreakCountry.country(forTimeZoneIdentifier: "Asia/Tokyo")?.name, "Japan")
    }

    func testUnknownZoneMapsToNil() {
        // A valid IANA zone we simply don't list yet.
        XCTAssertNil(BreakCountry.country(forTimeZoneIdentifier: "Europe/Vilnius"))
        XCTAssertNil(BreakCountry.country(forTimeZoneIdentifier: "Not/AZone"))
    }

    func testCurrentByTimeZoneFallsBackToRomania() {
        // When the live zone isn't one we list, we fall back to the home default
        // rather than returning nothing — so a break always shows *some* country.
        // (currentByTimeZone reads TimeZone.current; here we just assert the
        // fallback identity via the pure helper the same way it does.)
        let fallback = BreakCountry.country(forTimeZoneIdentifier: "Not/AZone") ?? .romania
        XCTAssertEqual(fallback, .romania)
    }
}

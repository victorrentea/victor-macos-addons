import XCTest
@testable import VictorAddons

final class CountrySearchTests: XCTestCase {

    private func names(_ q: String) -> [String] { CountrySearch.search(q).map(\.name) }

    func testAbbreviationFindsTheCountry() {
        XCTAssertEqual(names("UK").first, "United Kingdom")
        XCTAssertEqual(names("u.k.").first, "United Kingdom")
        XCTAssertEqual(names("uae"), ["United Arab Emirates"])
    }

    func testUsPutsTheUsaRowsBeforeContainsMatches() {
        let r = names("us")
        XCTAssertEqual(Array(r.prefix(4)), ["USA (Chicago)", "USA (Denver)", "USA (Los Angeles)", "USA (New York)"])
        XCTAssertTrue(r.contains("Australia (Perth)"), "contains-matches still listed, just later")
    }

    func testRomanianAndNativeNames() {
        XCTAssertEqual(names("Anglia"), ["United Kingdom"])
        XCTAssertEqual(names("olanda"), ["Netherlands"])
        XCTAssertEqual(names("Elvetia"), ["Switzerland"])
        XCTAssertEqual(names("Deutschland"), ["Germany"])
        XCTAssertEqual(names("SUA").count, 4)
    }

    func testTimezoneCityMatches() {
        XCTAssertEqual(names("London"), ["United Kingdom"])
        XCTAssertEqual(names("zurich"), ["Switzerland"])
    }

    func testTyposStillLand() {
        XCTAssertEqual(names("Germnay").first, "Germany")
        XCTAssertEqual(names("Swizerland").first, "Switzerland")
        XCTAssertEqual(names("Romaina").first, "Romania")
        XCTAssertEqual(names("Untied Kingdom").first, "United Kingdom")
        XCTAssertEqual(names("netherland").first, "Netherlands")
    }

    func testShortQueriesStayLiteral() {
        XCTAssertEqual(names("arg"), ["Argentina"])
        XCTAssertTrue(names("xq").isEmpty)
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(CountrySearch.search("  ").count, BreakCountry.all.count)
    }

    func testPrefixDistance() {
        XCTAssertEqual(CountrySearch.prefixDistance("germnay", "germany"), 1)
        XCTAssertEqual(CountrySearch.prefixDistance("swiz", "switzerland"), 1)
        XCTAssertEqual(CountrySearch.prefixDistance("fra", "france"), 0)
    }
}

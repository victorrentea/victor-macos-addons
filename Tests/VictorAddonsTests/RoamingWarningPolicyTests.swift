import XCTest
@testable import VictorAddons

final class RoamingWarningPolicyTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()
    /// 25 Sep 2026, 14:00 in Bucharest.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 14))! }
    private let limit: Int64 = 13_703_000_000

    private func reading(leftPct: Int64, today: Int64 = 5_000_000, roamingNow: Bool = true,
                         readAgo: TimeInterval = 60) -> RoamingWarningPolicy.Reading {
        RoamingWarningPolicy.Reading(
            cycleTotal: limit - limit * leftPct / 100, cycleHotspot: 0, today: today,
            roamingNow: roamingNow, limit: limit, lowFraction: 0.15,
            nextReset: now.addingTimeInterval(86_400 * 7), readAt: now.addingTimeInterval(-readAgo))
    }

    func testWarnsUnder15PercentOnARoamingDay() {
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(reading(leftPct: 12), now: now, dismissedDay: nil, calendar: cal))
    }

    func testSilentAtOrAbove15Percent() {
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(reading(leftPct: 15), now: now, dismissedDay: nil, calendar: cal))
    }

    func testSilentOnADayWithoutRoaming() {
        let home = reading(leftPct: 5, today: 0, roamingNow: false)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(home, now: now, dismissedDay: nil, calendar: cal))
    }

    func testRoamingNowCountsBeforeAnyTrafficToday() {
        let morning = reading(leftPct: 5, today: 0, roamingNow: true)
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(morning, now: now, dismissedDay: nil, calendar: cal))
    }

    func testOverTheCeilingIsZeroLeftAndWarns() {
        let over = RoamingWarningPolicy.Reading(
            cycleTotal: limit + 2_000_000_000, cycleHotspot: 0, today: 1, roamingNow: true, limit: limit,
            lowFraction: 0.15, nextReset: now, readAt: now)
        XCTAssertEqual(over.remaining, 0)
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(over, now: now, dismissedDay: nil, calendar: cal))
    }

    func testDismissalLastsForTheDayOnly() {
        let r = reading(leftPct: 10)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(r, now: now, dismissedDay: "2026-09-25", calendar: cal))
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(r, now: now, dismissedDay: "2026-09-24", calendar: cal))
    }

    func testStaleOrYesterdaysReadingDoesNotWarn() {
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(reading(leftPct: 5, readAgo: 2 * 3600), now: now,
                                                       dismissedDay: nil, calendar: cal))
        let justAfterMidnight = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 0, minute: 10))!
        let lateYesterday = reading(leftPct: 5, readAgo: 0)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(
            RoamingWarningPolicy.Reading(cycleTotal: lateYesterday.cycleTotal, cycleHotspot: 0, today: 1,
                                         roamingNow: true, limit: limit, lowFraction: 0.15, nextReset: now,
                                         readAt: justAfterMidnight.addingTimeInterval(-20 * 60)),
            now: justAfterMidnight, dismissedDay: nil, calendar: cal))
    }

    func testParsesThePhonesLine() throws {
        let line = #"{"v":1,"cycleTotal":12000000000,"cycleHotspot":9000000000,"today":300000000,"roamingNow":true,"cycleStart":1788300000000,"nextReset":1790892000000,"limit":13703000000,"lowFraction":0.15,"readAt":1790330000000}"#
        let r = try XCTUnwrap(RoamingWarningPolicy.parse(line))
        XCTAssertEqual(r.cycleTotal, 12_000_000_000)
        XCTAssertEqual(r.limit, 13_703_000_000)
        XCTAssertTrue(r.roamingNow)
        XCTAssertEqual(r.readAt.timeIntervalSince1970, 1_790_330_000, accuracy: 0.001)
        XCTAssertEqual(RoamingWarningPolicy.text(r), "📶 Roaming: 1.7 GB left (12%)")
    }

    func testPhoneErrorIsNotAReading() {
        XCTAssertNil(RoamingWarningPolicy.parse(#"{"v":1,"error":"no Usage access"}"#))
        XCTAssertNil(RoamingWarningPolicy.parse("garbage"))
    }
}

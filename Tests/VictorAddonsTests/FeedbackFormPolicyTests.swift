import XCTest
@testable import VictorAddons

final class FeedbackFormPolicyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()

    private func evening(_ month: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 16, minute: 50))!
    }

    /// A three-day set: the survey belongs at the end of it, not at the end of
    /// each day.
    func testSilentOnEveryDayButTheLast() {
        XCTAssertFalse(FeedbackFormPolicy.mayOffer(lastDay: "2026-09-16", now: evening(9, 14), calendar: cal))
        XCTAssertFalse(FeedbackFormPolicy.mayOffer(lastDay: "2026-09-16", now: evening(9, 15), calendar: cal))
        XCTAssertTrue(FeedbackFormPolicy.mayOffer(lastDay: "2026-09-16", now: evening(9, 16), calendar: cal))
    }

    /// A one-day workshop is its own last day — the common case must not regress.
    func testSingleDaySetStillAsks() {
        XCTAssertTrue(FeedbackFormPolicy.mayOffer(lastDay: "2026-09-22", now: evening(9, 22), calendar: cal))
    }

    /// The daemon could not name a last day (folder without a date prefix):
    /// asking every evening is the lesser evil against never asking.
    func testUnknownLastDayFallsBackToAsking() {
        XCTAssertTrue(FeedbackFormPolicy.mayOffer(lastDay: nil, now: evening(9, 14), calendar: cal))
    }

    /// The Mac keeps the date it was told and compares it to *today*, so a
    /// daemon that announced the session days ago cannot make it fire late.
    func testAStaleLastDayInThePastNeverFires() {
        XCTAssertFalse(FeedbackFormPolicy.mayOffer(lastDay: "2026-09-16", now: evening(9, 17), calendar: cal))
    }

    func testIsoDayZeroPadsToMatchTheDaemonsFormat() {
        XCTAssertEqual(FeedbackFormPolicy.isoDay(evening(9, 4), calendar: cal), "2026-09-04")
    }
}

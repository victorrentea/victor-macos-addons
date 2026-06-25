import XCTest
@testable import VictorAddons

final class GroupPhotoSchedulerTests: XCTestCase {

    /// Build a local-time `Date` for the given wall clock on an arbitrary day.
    private func localDate(hour: Int, minute: Int, second: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 25
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    func testFiresAtExactlyThirteenHundred() {
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 13, minute: 0)))
    }

    func testFiresAnySecondWithinTheTriggerMinute() {
        // Whichever second a tick lands on inside 13:00, it must still match.
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 13, minute: 0, second: 1)))
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 13, minute: 0, second: 59)))
    }

    func testDoesNotFireOneMinuteBefore() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 12, minute: 59)))
    }

    func testDoesNotFireOneMinuteAfter() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 13, minute: 1)))
    }

    func testDoesNotFireOtherHourSameMinute() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 14, minute: 0)))
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 1, minute: 0)))
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 0, minute: 0)))
    }
}

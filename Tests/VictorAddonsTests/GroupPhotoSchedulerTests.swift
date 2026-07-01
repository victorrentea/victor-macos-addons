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

    func testFiresAtExactlyElevenFifteen() {
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 11, minute: 15)))
    }

    func testFiresAnySecondWithinTheTriggerMinute() {
        // Whichever second a tick lands on inside 11:15, it must still match.
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 11, minute: 15, second: 1)))
        XCTAssertTrue(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 11, minute: 15, second: 59)))
    }

    func testDoesNotFireOneMinuteBefore() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 11, minute: 14)))
    }

    func testDoesNotFireOneMinuteAfter() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 11, minute: 16)))
    }

    func testDoesNotFireOtherHourSameMinute() {
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 12, minute: 15)))
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 10, minute: 15)))
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 13, minute: 0)))
        XCTAssertFalse(GroupPhotoScheduler.isTriggerMinute(at: localDate(hour: 0, minute: 0)))
    }
}

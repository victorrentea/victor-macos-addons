import XCTest
@testable import VictorAddons

final class SummaryReminderPolicyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()

    /// 2026-08-06 is a Thursday — a working day, so the base case fires.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: hour, minute: minute))!
    }

    private func onDay(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    func testFiresExactlyOnTheFirstSlot() {
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: at(16, 45), calendar: cal, alreadyFired: []),
                       "2026-08-06 16:45")
    }

    func testFiresExactlyOnTheSecondSlot() {
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: at(17, 15), calendar: cal, alreadyFired: []),
                       "2026-08-06 17:15")
    }

    func testSilentBeforeTheFirstSlot() {
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(16, 44), calendar: cal, alreadyFired: []))
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(9, 0), calendar: cal, alreadyFired: []))
    }

    /// The app restarts several times a day; a slot that came due while it was
    /// down still fires, a few minutes late.
    func testFiresLateWithinTheGraceWindow() {
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: at(16, 55), calendar: cal, alreadyFired: []),
                       "2026-08-06 16:45")
    }

    func testStopsAskingOnceTheGraceWindowClosed() {
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(16, 56), calendar: cal, alreadyFired: []))
        // …and the gap between the two slots is silent again.
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(17, 5), calendar: cal, alreadyFired: []))
    }

    func testNeverAsksTwiceForTheSameSlot() {
        let fired: Set<String> = ["2026-08-06 16:45"]
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(16, 45), calendar: cal, alreadyFired: fired))
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: at(16, 50), calendar: cal, alreadyFired: fired))
    }

    /// Having answered the 16:45 offer must not swallow the 17:15 one — that
    /// second ask is the point of having two.
    func testTheSecondSlotStillFiresAfterTheFirstWasAnswered() {
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: at(17, 15),
                                                     calendar: cal,
                                                     alreadyFired: ["2026-08-06 16:45"]),
                       "2026-08-06 17:15")
    }

    /// Yesterday's keys must not suppress today's offer.
    func testAPreviousDaysFiringDoesNotCarryOver() {
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: at(16, 45),
                                                     calendar: cal,
                                                     alreadyFired: ["2026-08-05 16:45"]),
                       "2026-08-06 16:45")
    }

    // 2026-08-08 is a Saturday, 2026-08-09 a Sunday, 2026-08-10 a Monday.
    func testSilentOnSaturday() {
        XCTAssertFalse(SummaryReminderPolicy.isWorkday(onDay(8, 16, 45), calendar: cal))
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: onDay(8, 16, 45), calendar: cal, alreadyFired: []))
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: onDay(8, 17, 15), calendar: cal, alreadyFired: []))
    }

    func testSilentOnSunday() {
        XCTAssertFalse(SummaryReminderPolicy.isWorkday(onDay(9, 16, 45), calendar: cal))
        XCTAssertNil(SummaryReminderPolicy.dueSlot(now: onDay(9, 16, 45), calendar: cal, alreadyFired: []))
    }

    func testFiresAgainOnMonday() {
        XCTAssertTrue(SummaryReminderPolicy.isWorkday(onDay(10, 16, 45), calendar: cal))
        XCTAssertEqual(SummaryReminderPolicy.dueSlot(now: onDay(10, 16, 45), calendar: cal, alreadyFired: []),
                       "2026-08-10 16:45")
    }

    func testEveryWeekdayIsAWorkday() {
        // Mon 10th … Fri 14th August 2026.
        for day in 10...14 {
            XCTAssertTrue(SummaryReminderPolicy.isWorkday(onDay(day, 16, 45), calendar: cal),
                          "day \(day) should be a workday")
        }
    }

    func testSlotsAreTheAdvertisedTimes() {
        XCTAssertEqual(SummaryReminderPolicy.slots.map { "\($0.hour):\($0.minute)" },
                       ["16:45", "17:15"])
    }
}

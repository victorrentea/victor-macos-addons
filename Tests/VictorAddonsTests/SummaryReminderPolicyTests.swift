import XCTest
@testable import VictorAddons

final class SummaryReminderPolicyTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: hour, minute: minute))!
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

    func testSlotsAreTheAdvertisedTimes() {
        XCTAssertEqual(SummaryReminderPolicy.slots.map { "\($0.hour):\($0.minute)" },
                       ["16:45", "17:15"])
    }
}

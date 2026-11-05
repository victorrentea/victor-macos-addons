import XCTest
@testable import VictorAddons

final class PowerPointSavedBadgeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day,
                                           hour: hour, minute: minute, second: second))!
    }

    private func text(_ saved: Date, unsaved: Bool = false, now: Date) -> String {
        PowerPointSavedBadgePolicy.text(savedAt: saved, unsaved: unsaved, now: now, calendar: calendar)
    }

    func testSavedDeckSaysSoAndShowsNoAge() {
        XCTAssertEqual(text(date(5, 19, 21), now: date(5, 19, 56)), "✓ Saved · 19:21")
    }

    func testUnsavedDeckSaysSoAndWhenItLastReachedTheDisk() {
        XCTAssertEqual(text(date(5, 19, 21), unsaved: true, now: date(5, 19, 56)),
                       "● Unsaved · last save 19:21")
    }

    func testSavedOnAnotherDayShowsTheDate() {
        XCTAssertEqual(text(date(3, 22, 43), now: date(5, 10, 0)), "✓ Saved · 3 Nov 22:43")
    }

    func testUnsavedOnAnotherDayShowsTheDate() {
        XCTAssertEqual(text(date(3, 22, 43), unsaved: true, now: date(5, 10, 0)),
                       "● Unsaved · last save 3 Nov 22:43")
    }

    func testCenteredOnTheStatusBarOfTheWindow() {
        // AX: window 1000 wide at x=100, bottom edge at y=900 on a 1117 pt tall primary screen.
        let origin = PowerPointSavedBadgePolicy.origin(
            window: CGRect(x: 100, y: 100, width: 1000, height: 800),
            badge: CGSize(width: 120, height: 18), primaryScreenHeight: 1117)
        XCTAssertEqual(origin, CGPoint(x: 540, y: 221))
    }
}

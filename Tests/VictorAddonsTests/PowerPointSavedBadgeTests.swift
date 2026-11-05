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

    private func text(_ saved: Date, now: Date) -> String {
        PowerPointSavedBadgePolicy.text(savedAt: saved, now: now, calendar: calendar)
    }

    func testSavedThisMinute() {
        XCTAssertEqual(text(date(5, 19, 21, 26), now: date(5, 19, 22, 25)), "💾 19:21 · just now")
    }

    func testSavedMinutesAgo() {
        XCTAssertEqual(text(date(5, 19, 21), now: date(5, 19, 33)), "💾 19:21 · 12 min ago")
    }

    func testSavedHoursAgo() {
        XCTAssertEqual(text(date(5, 9, 5), now: date(5, 12, 4)), "💾 09:05 · 2 h ago")
    }

    func testAnotherDayShowsTheDateAndNoAge() {
        XCTAssertEqual(text(date(3, 22, 43), now: date(5, 10, 0)), "💾 3 Nov 22:43")
    }

    func testAFileStampedInTheFutureIsJustNow() {
        XCTAssertEqual(text(date(5, 19, 22), now: date(5, 19, 21)), "💾 19:22 · just now")
    }

    func testCenteredOnTheStatusBarOfTheWindow() {
        // AX: window 1000 wide at x=100, bottom edge at y=900 on a 1117 pt tall primary screen.
        let origin = PowerPointSavedBadgePolicy.origin(
            window: CGRect(x: 100, y: 100, width: 1000, height: 800),
            badge: CGSize(width: 120, height: 18), primaryScreenHeight: 1117)
        XCTAssertEqual(origin, CGPoint(x: 540, y: 221))
    }
}

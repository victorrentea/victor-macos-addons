import XCTest
@testable import VictorAddons

final class GroupPhotoBreakPolicyTests: XCTestCase {

    /// Build a local-time `Date` for the given wall clock on an arbitrary day.
    private func localDate(hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 25
        comps.hour = hour
        comps.minute = minute
        comps.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private func shouldPrompt(_ minutes: Int, atHour hour: Int) -> Bool {
        GroupPhotoBreakPolicy.shouldPrompt(breakMinutes: minutes, at: localDate(hour: hour))
    }

    // MARK: Lunch (≥ 60 min) fires at any time of day

    func testLunchFiresInTheMorning() {
        XCTAssertTrue(shouldPrompt(60, atHour: 11))
    }

    func testLunchFiresInTheAfternoon() {
        XCTAssertTrue(shouldPrompt(60, atHour: 14))
    }

    func testLongerThanLunchAlsoFires() {
        XCTAssertTrue(shouldPrompt(90, atHour: 9))
    }

    // MARK: Afternoon (≥ 13:00) breaks fire only when ≥ 10 min

    func testAfternoonTenMinuteBreakFires() {
        XCTAssertTrue(shouldPrompt(10, atHour: 13))
    }

    func testAfternoonFifteenMinuteBreakFires() {
        XCTAssertTrue(shouldPrompt(15, atHour: 15))
    }

    func testAfternoonShortBreakDoesNotFire() {
        XCTAssertFalse(shouldPrompt(7, atHour: 15))
    }

    func testBreakStartingExactlyAtOnePMCountsAsAfternoon() {
        XCTAssertTrue(shouldPrompt(10, atHour: 13))
    }

    // MARK: Morning short/medium breaks are ignored

    func testMorningTenMinuteBreakDoesNotFire() {
        XCTAssertFalse(shouldPrompt(10, atHour: 10))
    }

    func testLateMorningFifteenMinuteBreakDoesNotFire() {
        // 12:xx is still before the 13:00 afternoon cutoff.
        XCTAssertFalse(shouldPrompt(15, atHour: 12))
    }

    // MARK: - The second prompt, when the break ends

    func testEndPromptOnlyWhenTheStartPromptArmedIt() {
        // No latch = this break never asked for a photo (too short, or nobody
        // connected to gather) — its end must stay quiet.
        XCTAssertFalse(GroupPhotoBreakPolicy.shouldPromptAtEnd(breakStartedAt: nil, now: Date()))
    }

    func testLunchBreakPromptsAgainWhenItEnds() {
        let now = Date()
        let startedAnHourAgo = now.addingTimeInterval(-60 * 60)
        XCTAssertTrue(GroupPhotoBreakPolicy.shouldPromptAtEnd(breakStartedAt: startedAnHourAgo, now: now))
    }

    func testABreakClosedSecondsAfterItStartedDoesNotPromptTwice() {
        let now = Date()
        let justStarted = now.addingTimeInterval(-30)
        XCTAssertFalse(GroupPhotoBreakPolicy.shouldPromptAtEnd(breakStartedAt: justStarted, now: now))
    }

    func testAStaleLatchIsNotCashedInByALaterBreak() {
        // The latch is persisted, so it can outlive the break that set it (app
        // quit, machine slept). Yesterday's lunch must not fire during today.
        let now = Date()
        let yesterday = now.addingTimeInterval(-20 * 60 * 60)
        XCTAssertFalse(GroupPhotoBreakPolicy.shouldPromptAtEnd(breakStartedAt: yesterday, now: now))
    }
}

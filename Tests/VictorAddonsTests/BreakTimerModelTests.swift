import XCTest
@testable import VictorAddons

final class BreakTimerModelTests: XCTestCase {

    // MARK: - format(remaining:)

    func testFormatZero() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 0), "00:00")
    }

    func testFormatSecondsOnly() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 9), "00:09")
    }

    func testFormatMinutesAndSeconds() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 65), "01:05")
    }

    func testFormatSevenMinutes() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 7 * 60), "07:00")
    }

    func testFormatFortyFiveMinutes() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 45 * 60), "45:00")
    }

    func testFormatOneHourKeepsTwoGroups() {
        // One hour keeps the MM:SS two-group look (minutes exceed 59).
        XCTAssertEqual(BreakTimerModel.format(remaining: 3600), "60:00")
    }

    func testFormatBeyondOneHour() {
        XCTAssertEqual(BreakTimerModel.format(remaining: 61 * 60 + 1), "61:01")
    }

    func testFormatNegativeClampsToZero() {
        XCTAssertEqual(BreakTimerModel.format(remaining: -5), "00:00")
    }

    // MARK: - finishDate(now:remaining:)

    func testFinishDateAddsRemaining() {
        let now = Date(timeIntervalSince1970: 0)
        let finish = BreakTimerModel.finishDate(now: now, remaining: 600)
        XCTAssertEqual(finish.timeIntervalSince1970, 600, accuracy: 0.001)
    }

    // MARK: - finishLabel(now:remaining:timeZone:)

    func testFinishLabelCET() {
        // Epoch 0 = 1970-01-01 00:00 UTC = 01:00 CET (winter, no DST) in Paris.
        let now = Date(timeIntervalSince1970: 0)
        let tz = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(BreakTimerModel.finishLabel(now: now, remaining: 600, timeZone: tz),
                       "01:10 CET")
    }

    func testFinishLabelLocalBucharest() {
        // Epoch 0 in Europe/Bucharest = 1970-01-01 02:00 EET (UTC+2 winter).
        let now = Date(timeIntervalSince1970: 0)
        let tz = TimeZone(identifier: "Europe/Bucharest")!
        XCTAssertEqual(BreakTimerModel.finishLabel(now: now, remaining: 0, timeZone: tz),
                       "02:00 EET")
    }

    func testFinishLabelAfternoonUses24Hour() {
        // 15:00 must render as "15:00 …", not "03:00 …" (would be 12-hour format).
        let now = Date(timeIntervalSince1970: 15 * 3600)
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BreakTimerModel.finishLabel(now: now, remaining: 0, timeZone: tz),
                       "15:00 GMT")
    }
}

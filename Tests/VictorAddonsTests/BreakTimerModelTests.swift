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

    // MARK: - enlargedFrame(in:aspect:fraction:)

    func testEnlargedFrameWideScreenFitsByHeight() {
        // Wide screen: 85% width (1700) would make the aspect-1.85 rect 919 tall,
        // which exceeds 85% height (850) → must fit by height instead.
        let f = BreakTimerModel.enlargedFrame(in: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                              aspect: 1.85, fraction: 0.85)
        XCTAssertEqual(f.height, 850, accuracy: 0.001)            // height-constrained
        XCTAssertEqual(f.width, 850 * 1.85, accuracy: 0.001)
        XCTAssertEqual(f.width / f.height, 1.85, accuracy: 0.0001) // aspect preserved
        XCTAssertEqual(f.midX, 1000, accuracy: 0.001)             // centered
        XCTAssertEqual(f.midY, 500, accuracy: 0.001)
    }

    func testEnlargedFrameTallScreenFitsByWidth() {
        // Tall screen: 85% width (850) gives a rect only 459 tall, well within the
        // 85% height (1700) → fits by width.
        let f = BreakTimerModel.enlargedFrame(in: CGRect(x: 0, y: 0, width: 1000, height: 2000),
                                              aspect: 1.85, fraction: 0.85)
        XCTAssertEqual(f.width, 850, accuracy: 0.001)             // width-constrained
        XCTAssertEqual(f.height, 850 / 1.85, accuracy: 0.001)
        XCTAssertEqual(f.midX, 500, accuracy: 0.001)
        XCTAssertEqual(f.midY, 1000, accuracy: 0.001)
    }

    func testEnlargedFrameClampsWithinFractionOnBothAxes() {
        // For any screen/aspect the result must never exceed `fraction` of either
        // dimension (so it stays "big but not the whole desktop").
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let f = BreakTimerModel.enlargedFrame(in: screen, aspect: 1.63, fraction: 0.85)
        XCTAssertLessThanOrEqual(f.width, screen.width * 0.85 + 0.001)
        XCTAssertLessThanOrEqual(f.height, screen.height * 0.85 + 0.001)
    }

    func testEnlargedFrameRespectsScreenOrigin() {
        // A non-zero screen origin (a secondary display) must be honored in the
        // centering math, not assumed to start at (0,0).
        let screen = CGRect(x: 100, y: 200, width: 1600, height: 1000)
        let f = BreakTimerModel.enlargedFrame(in: screen, aspect: 1.63, fraction: 0.85)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(f.midY, screen.midY, accuracy: 0.001)
    }
}

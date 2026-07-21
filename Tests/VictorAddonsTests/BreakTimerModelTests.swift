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

    // MARK: - fullscreenFrame(in:fraction:)

    func testFullscreenFrameFillsWholeScreenAtFraction1() {
        // fraction 1.0 → the panel covers the entire screen (desktop-like), aspect
        // is NOT preserved — width and height both equal the screen's.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let f = BreakTimerModel.fullscreenFrame(in: screen, fraction: 1.0)
        XCTAssertEqual(f, screen)
    }

    func testFullscreenFrameDefaultsToFullCoverage() {
        // The default fraction is 1.0 (full retina fill).
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(BreakTimerModel.fullscreenFrame(in: screen), screen)
    }

    func testFullscreenFrameCentersAtFractionBelow1() {
        // A sub-1 fraction shrinks both axes and stays centered (still not aspect-
        // locked — it's a plain centered rect of `fraction` × screen).
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let f = BreakTimerModel.fullscreenFrame(in: screen, fraction: 0.5)
        XCTAssertEqual(f.width, 1000, accuracy: 0.001)
        XCTAssertEqual(f.height, 500, accuracy: 0.001)
        XCTAssertEqual(f.midX, 1000, accuracy: 0.001)            // centered
        XCTAssertEqual(f.midY, 500, accuracy: 0.001)
    }

    func testFullscreenFrameRespectsScreenOrigin() {
        // A non-zero screen origin (a secondary display) must be honored in the
        // centering math, not assumed to start at (0,0).
        let screen = CGRect(x: 100, y: 200, width: 1600, height: 1000)
        let f = BreakTimerModel.fullscreenFrame(in: screen, fraction: 0.8)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(f.midY, screen.midY, accuracy: 0.001)
    }

    func testFullscreenFrameClampsFractionAboveOne() {
        // Fractions above 1 clamp to full-screen (never larger than the screen).
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let f = BreakTimerModel.fullscreenFrame(in: screen, fraction: 1.5)
        XCTAssertEqual(f, screen)
    }
}

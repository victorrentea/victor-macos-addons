import XCTest
@testable import VictorAddons

final class VideoGainTests: XCTestCase {
    func testCurveMatchesTheTilesAndStopsAtOne() {
        XCTAssertEqual(VideoGain.volume(position: nil), 1)
        XCTAssertEqual(VideoGain.volume(position: 80), 1, accuracy: 0.0001)
        XCTAssertEqual(VideoGain.volume(position: 40), 0.25, accuracy: 0.0001)
        XCTAssertEqual(VideoGain.volume(position: 0), 0)
        XCTAssertEqual(VideoGain.volume(position: 100), 1)
    }

    func testOnlyAVideoGainPathIsRecognised() {
        XCTAssertEqual(VideoGain.parseGainPath("/sound/gain/video:dQw4w9WgXcQ/55")?.id, "dQw4w9WgXcQ")
        XCTAssertEqual(VideoGain.parseGainPath("/sound/gain/video%3Aabc/55")?.pct, 55)
        XCTAssertNil(VideoGain.parseGainPath("/sound/gain/03_explosion.mp3/55"))
        XCTAssertNil(VideoGain.parseGainPath("/sound/gain/video:/55"))
        XCTAssertNil(VideoGain.parseGainPath("/sound/gains"))
    }
}

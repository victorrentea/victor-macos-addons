import XCTest
@testable import VictorAddons

/// The seek bar's two pieces of arithmetic: where a click lands in the clip,
/// and the clock it prints.
final class SeekBarTests: XCTestCase {
    private let track = NSRect(x: 20, y: 0, width: 200, height: 8)

    func testClickMapsAlongTheTrack() {
        XCTAssertEqual(SeekBar.seconds(atX: 20, track: track, duration: 58), 0)
        XCTAssertEqual(SeekBar.seconds(atX: 120, track: track, duration: 58), 29, accuracy: 0.001)
        XCTAssertEqual(SeekBar.seconds(atX: 220, track: track, duration: 58), 58, accuracy: 0.001)
    }

    func testClickOutsideTheTrackIsClamped() {
        XCTAssertEqual(SeekBar.seconds(atX: -50, track: track, duration: 58), 0)
        XCTAssertEqual(SeekBar.seconds(atX: 900, track: track, duration: 58), 58, accuracy: 0.001)
    }

    func testUnknownDurationSeeksNowhere() {
        XCTAssertEqual(SeekBar.seconds(atX: 120, track: track, duration: 0), 0)
    }

    func testClock() {
        XCTAssertEqual(SeekBar.clock(0), "0:00")
        XCTAssertEqual(SeekBar.clock(58.44), "0:58")
        XCTAssertEqual(SeekBar.clock(125), "2:05")
        XCTAssertEqual(SeekBar.clock(.nan), "0:00")
    }
}

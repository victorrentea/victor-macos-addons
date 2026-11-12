import XCTest
@testable import VictorAddons

final class VoiceRecorderTests: XCTestCase {
    // What this Mac showed on 2026-11-12: default input = the MacBook's own mic,
    // DJI receiver plugged in. The DJI must win.
    let desk = ["MacBook Pro Microphone", "Wireless Mic Rx", "krisp microphone",
                "ZoomAudioDevice", "From Walkie"]

    func testLadderPicksTheDjiOverTheLaptopMic() {
        XCTAssertEqual(VoiceRecorder.pick(names: desk, preferredPattern: nil), 1)
    }

    func testTheMicTranscriptionHearsWins() {
        XCTAssertEqual(VoiceRecorder.pick(names: desk, preferredPattern: "MacBook"), 0)
    }

    func testAnUnpluggedPreferenceFallsBackToTheLadder() {
        XCTAssertEqual(VoiceRecorder.pick(names: desk, preferredPattern: "XLR"), 1)
    }

    func testNeverRecordHeadsetIsSkipped() {
        XCTAssertNil(VoiceRecorder.pick(names: ["WH-1000XM5 Bose"], preferredPattern: nil))
    }

    func testNothingKnownMeansSystemDefault() {
        XCTAssertNil(VoiceRecorder.pick(names: ["ZoomAudioDevice"], preferredPattern: nil))
    }

    func testClock() {
        XCTAssertEqual(VoiceRecorder.clock(65.9), "1:05")
        XCTAssertEqual(VoiceRecorder.clock(3725), "1:02:05")
    }
}

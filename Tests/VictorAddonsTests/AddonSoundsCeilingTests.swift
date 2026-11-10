import XCTest
@testable import VictorAddons

/// 🎚️ The break gong asks the effects app for the same voice cap the soundboard gets.
final class AddonSoundsCeilingTests: XCTestCase {
    func testAsksTheCeilingForTheGongByFileName() {
        XCTAssertEqual(AddonSounds.ceilingPath(file: "50_gong.mp3", asked: 1),
                       "/voice/ceiling?file=50_gong.mp3&volume=1.0")
    }

    func testTheEffectsAnswerIsReadLikeAVideos() {
        let json = #"{"volume":0.251,"maxVolume":0.251,"takenDb":12.0}"#.data(using: .utf8)!
        let r = VideoCeiling.parse(json)
        XCTAssertEqual(r?.volume ?? 0, 0.251, accuracy: 0.001)
        XCTAssertEqual(r?.takenDb ?? 0, 12.0, accuracy: 0.01)
    }
}

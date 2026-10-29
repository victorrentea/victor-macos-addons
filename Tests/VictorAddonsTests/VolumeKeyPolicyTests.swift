import XCTest
@testable import VictorAddons

/// 🔊 The volume keys as the HID tap sees them, and the steps they take.
final class VolumeKeyPolicyTests: XCTestCase {

    private func data1(key: Int, state: Int) -> Int { (key << 16) | (state << 8) }

    func testVolumeUpKeyDownIsRecognised() {
        let k = VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 0, state: 0x0A))
        XCTAssertEqual(k?.kind, .up)
        XCTAssertEqual(k?.isDown, true)
    }

    func testMuteKeyUpIsRecognisedAsUp() {
        let k = VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 7, state: 0x0B))
        XCTAssertEqual(k?.kind, .mute)
        XCTAssertEqual(k?.isDown, false)
    }

    /// Brightness (2/3) and play/pause (16) must reach macOS untouched.
    func testOtherMediaKeysAreLeftAlone() {
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 2, state: 0x0A)))
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 8, data1: data1(key: 16, state: 0x0A)))
    }

    func testOtherSubtypesAreLeftAlone() {
        XCTAssertNil(VolumeKeyPolicy.key(subtype: 7, data1: data1(key: 0, state: 0x0A)))
    }

    func testOneStepIsASixteenth() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: true, fine: false), 9 / 16)
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: false, fine: false), 7 / 16)
    }

    func testOptionShiftStepIsASixtyFourth() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.5, up: true, fine: true), 33 / 64)
    }

    /// A level set elsewhere snaps onto the grid instead of drifting off it.
    func testOffGridLevelSnapsToTheGrid() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0.53, up: true, fine: false), 9 / 16)
    }

    func testStaysWithinZeroAndOne() {
        XCTAssertEqual(VolumeKeyPolicy.next(from: 1, up: true, fine: false), 1)
        XCTAssertEqual(VolumeKeyPolicy.next(from: 0, up: false, fine: false), 0)
    }

    func testMutedShowsTheSlashedSpeaker() {
        XCTAssertEqual(VolumeKeyPolicy.symbol(level: 0.8, muted: true), "speaker.slash.fill")
        XCTAssertEqual(VolumeKeyPolicy.symbol(level: 0.8, muted: false), "speaker.wave.3.fill")
    }
}

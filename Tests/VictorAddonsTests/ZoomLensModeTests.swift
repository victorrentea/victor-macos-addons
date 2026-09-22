import XCTest
@testable import VictorAddons

/// The rule that decides when ⌥⌘F says something. The silences are the interesting
/// part: a pill that fires at launch, or once a second forever, is worse than none.
final class ZoomLensModeTests: XCTestCase {

    func testFirstReadingIsNeverAnnounced() {
        XCTAssertNil(ZoomLensModePolicy.announcement(previous: nil, current: .pictureInPicture))
        XCTAssertNil(ZoomLensModePolicy.announcement(previous: nil, current: .fullScreen))
    }

    func testUnchangedModeSaysNothing() {
        XCTAssertNil(ZoomLensModePolicy.announcement(previous: .fullScreen, current: .fullScreen))
        XCTAssertNil(ZoomLensModePolicy.announcement(previous: .pictureInPicture,
                                                     current: .pictureInPicture))
    }

    /// The ⌥⌘F toggle, both ways — the only transition that happens in practice.
    func testToggleIsAnnouncedBothWays() {
        XCTAssertEqual(ZoomLensModePolicy.announcement(previous: .fullScreen,
                                                       current: .pictureInPicture), "🔍 PiP")
        XCTAssertEqual(ZoomLensModePolicy.announcement(previous: .pictureInPicture,
                                                       current: .fullScreen), "🔍 Full screen")
    }

    func testSplitScreenHasItsOwnPill() {
        XCTAssertEqual(ZoomLensModePolicy.announcement(previous: .fullScreen,
                                                       current: .splitScreen), "🔍 Split")
    }

    /// The raw values are macOS's, not ours — `closeViewZoomMode` is read straight from
    /// `com.apple.universalaccess`, so renumbering them would silently mislabel the pill.
    func testRawValuesMatchTheSystemPreference() {
        XCTAssertEqual(ZoomLensMode.fullScreen.rawValue, 0)
        XCTAssertEqual(ZoomLensMode.pictureInPicture.rawValue, 1)
        XCTAssertEqual(ZoomLensMode.splitScreen.rawValue, 2)
        XCTAssertNil(ZoomLensMode(rawValue: 3))
    }

    /// ⌘⌃U is a two-position switch over a three-value setting, so the third value
    /// has to have a defined exit — and it must be the style a share carries, not
    /// the one it drops.
    func testToggleIsATwoPositionSwitch() {
        XCTAssertEqual(ZoomLensModePolicy.toggled(from: .fullScreen), .pictureInPicture)
        XCTAssertEqual(ZoomLensModePolicy.toggled(from: .pictureInPicture), .fullScreen)
        XCTAssertEqual(ZoomLensModePolicy.toggled(from: .splitScreen), .pictureInPicture)
    }

    /// Pressing the key twice must land back where it started, from either end —
    /// otherwise the shortcut drifts and Victor has to look at the pill to know
    /// which way it went.
    func testTogglingTwiceIsIdentityFromEitherEnd() {
        for start in [ZoomLensMode.fullScreen, .pictureInPicture] {
            let there = ZoomLensModePolicy.toggled(from: start)
            XCTAssertEqual(ZoomLensModePolicy.toggled(from: there), start)
        }
    }
}

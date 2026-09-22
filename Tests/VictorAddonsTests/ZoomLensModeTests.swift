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
}

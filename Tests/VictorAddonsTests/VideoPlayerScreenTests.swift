import XCTest
@testable import VictorAddons

/// The Retina must get the clip whatever macOS calls the main display, and the
/// only tricky part of that is the coordinate flip: AppKit measures y **up** from
/// the bottom of the primary screen, Accessibility measures it **down** from the
/// top. They agree only for the primary screen — i.e. everywhere except the
/// venue layout this feature exists for.
final class VideoPlayerScreenTests: XCTestCase {

    func testPrimaryScreenIsUnchanged() {
        // At the desk: the Retina is primary, so AX and AppKit agree.
        let retina = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(
            VideoPlayer.axFrame(screenFrame: retina, primaryTopY: 1117),
            retina
        )
    }

    func testRetinaLeftOfAnAsusPrimaryAtAVenue() {
        // The venue scene DisplayArrangementManager builds: the ASUS is primary
        // at (0,0,1920,1080), the Retina extended to its left at x=-1920. Both
        // sit on the same bottom edge, and the taller Retina therefore rises 37pt
        // above the primary's top — which in AX coordinates is a NEGATIVE y.
        let retina = CGRect(x: -1920, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(
            VideoPlayer.axFrame(screenFrame: retina, primaryTopY: 1080),
            CGRect(x: -1920, y: -37, width: 1728, height: 1117)
        )
    }

    func testScreenBelowThePrimaryTopGetsAPositiveOffset() {
        // A display sitting lower than the primary (Cocoa y negative) is further
        // DOWN in AX terms, not up — the sign really does invert.
        let below = CGRect(x: 1728, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(
            VideoPlayer.axFrame(screenFrame: below, primaryTopY: 1117),
            CGRect(x: 1728, y: 1117, width: 1920, height: 1080)
        )
    }

    func testSizeIsCarriedThroughUntouched() {
        let f = CGRect(x: 3648, y: 37, width: 1920, height: 1080)
        let ax = VideoPlayer.axFrame(screenFrame: f, primaryTopY: 1117)
        XCTAssertEqual(ax.size, f.size)
        XCTAssertEqual(ax.origin.x, f.origin.x)
    }
}

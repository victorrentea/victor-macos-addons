import XCTest
@testable import VictorAddons

final class ZoomShareWindowsTests: XCTestCase {
    func testAnnotationWindowMeansSharing() {
        XCTAssertTrue(ZoomShareWindows.isSharing(windowNames: ["Zoom Meeting", "Annotation - Zoom"]))
    }

    func testShareToolbarMeansSharing() {
        XCTAssertTrue(ZoomShareWindows.isSharing(windowNames: ["zoom share toolbar window"]))
    }

    func testMeetingWithoutShareIsNotSharing() {
        XCTAssertFalse(ZoomShareWindows.isSharing(windowNames: ["Zoom Meeting", "Zoom Workplace", ""]))
    }
}

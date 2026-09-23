import XCTest
@testable import VictorAddons

/// When the cursor is kept on the magnified screen, and where it is put back.
final class ZoomLensCursorFenceTests: XCTestCase {

    func testFencedOnlyWhilePiPIsMagnifying() {
        XCTAssertTrue(ZoomLensCursorFencePolicy.shouldFence(mode: .pictureInPicture, zoomedIn: true, factor: 2))
    }
    func testZoomingBackTo1xIsTheWayOut() {
        XCTAssertFalse(ZoomLensCursorFencePolicy.shouldFence(mode: .pictureInPicture, zoomedIn: true, factor: 1))
    }
    func testNotZoomedInIsNotFenced() {
        XCTAssertFalse(ZoomLensCursorFencePolicy.shouldFence(mode: .pictureInPicture, zoomedIn: false, factor: 2))
    }
    func testOtherStylesAreNeverFenced() {
        XCTAssertFalse(ZoomLensCursorFencePolicy.shouldFence(mode: .fullScreen, zoomedIn: true, factor: 2))
        XCTAssertFalse(ZoomLensCursorFencePolicy.shouldFence(mode: .splitScreen, zoomedIn: true, factor: 2))
        XCTAssertFalse(ZoomLensCursorFencePolicy.shouldFence(mode: nil, zoomedIn: true, factor: 2))
    }

    /// The rig on 2026-09-23: retina at -1920,0 mirrored to the projector, ASUS to its right at 0,0.
    private let retina = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    func testCrossingTowardsTheASUSStopsOnTheRetinaEdge() {
        XCTAssertEqual(ZoomLensCursorFencePolicy.clamp(CGPoint(x: 12, y: 500), to: retina), CGPoint(x: -1, y: 500))
    }
    func testInsidePointIsUntouched() {
        XCTAssertEqual(ZoomLensCursorFencePolicy.clamp(CGPoint(x: -960, y: 540), to: retina), CGPoint(x: -960, y: 540))
    }
    func testCornerIsClampedOnBothAxes() {
        XCTAssertEqual(ZoomLensCursorFencePolicy.clamp(CGPoint(x: 300, y: 2000), to: retina), CGPoint(x: -1, y: 1079))
    }
}

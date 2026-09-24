import XCTest
@testable import VictorAddons

/// When the cursor is kept on the magnified screen, where the decoupled band is, and
/// how a raw step is turned into points.
final class ZoomLensCursorFenceTests: XCTestCase {
    typealias P = ZoomLensCursorFencePolicy

    func testFencedOnlyWhilePiPIsMagnifying() {
        XCTAssertTrue(P.shouldFence(mode: .pictureInPicture, zoomedIn: true, factor: 2))
    }
    func testZoomingBackTo1xIsTheWayOut() {
        XCTAssertFalse(P.shouldFence(mode: .pictureInPicture, zoomedIn: true, factor: 1))
    }
    func testNotZoomedInIsNotFenced() {
        XCTAssertFalse(P.shouldFence(mode: .pictureInPicture, zoomedIn: false, factor: 2))
    }
    func testOtherStylesAreNeverFenced() {
        XCTAssertFalse(P.shouldFence(mode: .fullScreen, zoomedIn: true, factor: 2))
        XCTAssertFalse(P.shouldFence(mode: .splitScreen, zoomedIn: true, factor: 2))
        XCTAssertFalse(P.shouldFence(mode: nil, zoomedIn: true, factor: 2))
    }

    /// The home rig on 2026-09-23: retina main at 0,0, ASUS to its right.
    private let retina = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let asus = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

    func testASUSOnTheRightIsTheOnlyExit() {
        XCTAssertEqual(P.exitEdges(of: retina, others: [retina, asus]), [.right])
    }
    func testAloneThereIsNoExit() {
        XCTAssertEqual(P.exitEdges(of: retina, others: [retina]), [])
    }
    func testProjectorRigExitsLeftOfTheASUS() {
        let mirrored = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let asusMain = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(P.exitEdges(of: mirrored, others: [mirrored, asusMain]), [.right])
    }
    func testBandIsOnlyAlongTheExitEdge() {
        XCTAssertTrue(P.inBand(CGPoint(x: 1700, y: 500), rect: retina, edges: [.right]))
        XCTAssertFalse(P.inBand(CGPoint(x: 1600, y: 500), rect: retina, edges: [.right]))
        XCTAssertFalse(P.inBand(CGPoint(x: 10, y: 500), rect: retina, edges: [.right]))
        XCTAssertFalse(P.inBand(CGPoint(x: 900, y: 5), rect: retina, edges: [.right]))
    }
    func testStepIsScaledAndStopsOnTheEdge() {
        let p = P.step(from: CGPoint(x: 1700, y: 500), rawDX: 33, rawDY: 0, in: retina)
        XCTAssertEqual(p.x, 1710, accuracy: 0.001)
        XCTAssertEqual(P.step(from: CGPoint(x: 1720, y: 500), rawDX: 330, rawDY: 0, in: retina).x, 1727)
    }
    func testCornerIsClampedOnBothAxes() {
        XCTAssertEqual(P.clamp(CGPoint(x: 3000, y: 2000), to: retina), CGPoint(x: 1727, y: 1116))
    }
}

/// A fence measured on one display layout must not survive the next one: a
/// mouse decoupled inside a rect that no display draws any more is a mouse that
/// looks frozen (the suspicion of 2026-09-24).
final class ZoomLensCursorFenceLayoutTests: XCTestCase {
    typealias P = ZoomLensCursorFencePolicy
    private let mirrored = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let asusMain = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let retinaMain = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let asusRight = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

    func testFenceHoldsWhileItsDisplayIsStillThere() {
        XCTAssertTrue(P.fenceStillValid(rect: mirrored, masters: [asusMain, mirrored]))
    }
    func testFenceDropsWhenTheLayoutMoves() {
        // "mirror + ASUS primary" → "Retina main + ASUS right": the old rect is gone.
        XCTAssertFalse(P.fenceStillValid(rect: mirrored, masters: [retinaMain, asusRight]))
    }
    func testFenceDropsWhenTheOtherDisplayUnplugs() {
        XCTAssertFalse(P.fenceStillValid(rect: mirrored, masters: [retinaMain]))
    }
}

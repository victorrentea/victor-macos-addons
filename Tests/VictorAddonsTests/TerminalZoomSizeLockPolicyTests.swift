import XCTest
@testable import VictorAddons

/// Which frame a Cmd+scroll zoom gesture pins the terminal window at.
final class TerminalZoomSizeLockPolicyTests: XCTestCase {

    private let window = CGRect(x: 100, y: 60, width: 1200, height: 800)

    func testFirstGesturePinsWhatItSees() {
        let pinned = TerminalZoomSizeLockPolicy.frameToPin(
            observed: window, pinned: nil, settled: nil)
        XCTAssertEqual(pinned, window)
    }

    /// The terminal snaps our write-back down to whole character cells, so it
    /// settles a few points short of the frame we asked for. Recognising that
    /// settled frame means the next gesture aims at the ORIGINAL size again,
    /// instead of shrinking the window by a cell every time.
    func testUntouchedWindowKeepsTheOriginalFrameDespiteCellSnapping() {
        let settled = CGRect(x: 100, y: 60, width: 1188, height: 782)
        let pinned = TerminalZoomSizeLockPolicy.frameToPin(
            observed: settled, pinned: window, settled: settled)
        XCTAssertEqual(pinned, window)
    }

    func testManualResizeBetweenGesturesBecomesTheNewTruth() {
        let settled = CGRect(x: 100, y: 60, width: 1188, height: 782)
        let resizedByHand = CGRect(x: 100, y: 60, width: 700, height: 500)
        let pinned = TerminalZoomSizeLockPolicy.frameToPin(
            observed: resizedByHand, pinned: window, settled: settled)
        XCTAssertEqual(pinned, resizedByHand)
    }

    func testWindowDraggedElsewhereBecomesTheNewTruth() {
        let settled = CGRect(x: 100, y: 60, width: 1188, height: 782)
        let moved = settled.offsetBy(dx: 640, dy: 0)
        let pinned = TerminalZoomSizeLockPolicy.frameToPin(
            observed: moved, pinned: window, settled: settled)
        XCTAssertEqual(pinned, moved)
    }

    /// No record of where we left the window (a different window got focus, or the
    /// app restarted) → trust the eyes, not the memory.
    func testNoSettledFrameFallsBackToObserved() {
        let observed = CGRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(
            TerminalZoomSizeLockPolicy.frameToPin(observed: observed, pinned: window, settled: nil),
            observed)
        XCTAssertEqual(
            TerminalZoomSizeLockPolicy.frameToPin(observed: observed, pinned: nil, settled: observed),
            observed)
    }

    func testSubPointNoiseStillCountsAsUntouched() {
        let settled = CGRect(x: 100, y: 60, width: 1188, height: 782)
        let noisy = CGRect(x: 100.2, y: 59.9, width: 1188.1, height: 781.8)
        XCTAssertEqual(
            TerminalZoomSizeLockPolicy.frameToPin(observed: noisy, pinned: window, settled: settled),
            window)
    }
}

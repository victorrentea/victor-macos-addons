import CoreGraphics
import XCTest

@testable import VictorAddons

/// Which terminal window a Cmd+scroll zoom aims at: the one under the pointer,
/// falling back to the one holding the keyboard.
final class TerminalZoomTargetPolicyTests: XCTestCase {

    private let terminal: pid_t = 501
    private let otherApp: pid_t = 777

    private func win(_ pid: pid_t, _ rect: CGRect, layer: Int = 0) -> ZoomWindowInfo {
        ZoomWindowInfo(pid: pid, layer: layer, bounds: rect)
    }

    // Two tiled quarters of a screen, side by side and not overlapping.
    private var left: CGRect { CGRect(x: 0, y: 0, width: 960, height: 540) }
    private var right: CGRect { CGRect(x: 960, y: 0, width: 960, height: 540) }

    func testPointerOverATerminalWindowPicksThatWindow() {
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 1200, y: 300),
            windows: [win(terminal, left), win(terminal, right)],
            frontmostTerminalPid: terminal)
        XCTAssertEqual(choice, .windowUnderMouse(pid: terminal, bounds: right))
    }

    func testFrontToBackOrderDecidesOverlappingWindows() {
        // The window server lists front first; the pointer is over both.
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 100, y: 100),
            windows: [win(terminal, CGRect(x: 50, y: 50, width: 400, height: 400)),
                      win(terminal, left)],
            frontmostTerminalPid: terminal)
        XCTAssertEqual(choice,
                       .windowUnderMouse(pid: terminal,
                                         bounds: CGRect(x: 50, y: 50, width: 400, height: 400)))
    }

    func testPointerOverNothingFallsBackToTheKeyboard() {
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 3000, y: 3000),
            windows: [win(terminal, left)],
            frontmostTerminalPid: terminal)
        XCTAssertEqual(choice, .focusedWindow(pid: terminal))
    }

    func testPointerOverAnotherAppFallsBackToTheKeyboard() {
        // Chrome laid over the terminal: zooming it would mean activating it.
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 100, y: 100),
            windows: [win(otherApp, left), win(terminal, left)],
            frontmostTerminalPid: terminal)
        XCTAssertEqual(choice, .focusedWindow(pid: terminal))
    }

    func testOverlayLayersAreNeitherTargetsNorBlockers() {
        // One of this app's click-through overlays covering the whole screen must
        // not shadow the terminal under it.
        let overlay = win(otherApp, CGRect(x: 0, y: 0, width: 3000, height: 2000), layer: 25)
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 100, y: 100),
            windows: [overlay, win(terminal, left)],
            frontmostTerminalPid: terminal)
        XCTAssertEqual(choice, .windowUnderMouse(pid: terminal, bounds: left))
    }

    func testNoTerminalInFrontMeansNoZoom() {
        let choice = TerminalZoomTargetPolicy.choose(
            point: CGPoint(x: 100, y: 100),
            windows: [win(terminal, left)],
            frontmostTerminalPid: nil)
        XCTAssertEqual(choice, .none)
    }

    // MARK: - Matching a window-server frame to an Accessibility one

    func testRoundingBetweenTheTwoAPIsStillMatches() {
        XCTAssertTrue(TerminalZoomTargetPolicy.sameWindow(
            CGRect(x: 960, y: 25, width: 960, height: 539),
            CGRect(x: 961, y: 25, width: 959, height: 540)))
    }

    func testTwoDifferentWindowsDoNotMatch() {
        XCTAssertFalse(TerminalZoomTargetPolicy.sameWindow(left, right))
    }
}

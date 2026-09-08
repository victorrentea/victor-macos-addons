import XCTest
@testable import VictorAddons

/// The bottom-left pill may not paint on a screen that isn't its own.
///
/// The bug these pin: a monitor arranged directly ABOVE the built-in retina
/// shares its bottom edge with the retina's top edge, so the pill "sliding off
/// the bottom" of that monitor was drawn across the TOP of the retina — the one
/// screen that gets projected to the room — for the last ~80 ms of every
/// un-hovered prompt offer. Downward motion must therefore stay inside the
/// window, which stays inside its screen.
final class PillPlacementTests: XCTestCase {
    private let boxHeight: CGFloat = 90          // BottomLeftBanner.Style.boxHeight
    private let sink: CGFloat = 150              // boxHeight + 60, the sinking exit
    private let rise: CGFloat = 140              // the rising exit

    /// Victor's arrangement on 2026-09-08: the retina is the main screen and one
    /// of the DELLs sits directly above it, x-overlapping it almost completely.
    private let retina = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let dellAbove = CGRect(x: -89, y: 1117, width: 1920, height: 1080)

    /// The window rect the banner ends up with for a pill placed `offset` from
    /// rest on `screen` — the geometry `BottomLeftBanner.place` applies.
    private func windowRect(on screen: CGRect, offset: CGFloat, width: CGFloat = 960) -> CGRect {
        CGRect(x: screen.minX,
               y: screen.minY + PillPlacement.windowRise(offset: offset),
               width: width, height: boxHeight)
    }

    func testDownwardMotionNeverMovesTheWindow() {
        XCTAssertEqual(PillPlacement.windowRise(offset: -sink), 0)
        XCTAssertEqual(PillPlacement.pillDrop(offset: -sink), -sink)
    }

    func testUpwardMotionMovesOnlyTheWindow() {
        XCTAssertEqual(PillPlacement.windowRise(offset: rise), rise)
        XCTAssertEqual(PillPlacement.pillDrop(offset: rise), 0)
    }

    func testRestIsNeither() {
        XCTAssertEqual(PillPlacement.windowRise(offset: 0), 0)
        XCTAssertEqual(PillPlacement.pillDrop(offset: 0), 0)
    }

    func testTheSplitAlwaysAddsBackUpToTheRequestedOffset() {
        for offset in stride(from: -sink, through: rise, by: 0.5) {
            XCTAssertTrue(PillPlacement.resolves(offset: CGFloat(offset)), "offset \(offset)")
        }
    }

    /// The regression itself, frame by frame: sinking the pill of the monitor
    /// above must never put a window pixel inside the retina.
    func testSinkingFromTheScreenAboveStaysOffTheRetina() {
        for step in 0...60 {
            let eased = pow(CGFloat(step) / 60, 2)          // the exit's easeIn
            let rect = windowRect(on: dellAbove, offset: -sink * eased)
            XCTAssertFalse(rect.intersects(retina),
                           "sink step \(step) leaked onto the retina: \(rect)")
            XCTAssertGreaterThanOrEqual(rect.minY, dellAbove.minY, "left its own screen")
        }
    }

    /// The hover nudge is the same motion 15× smaller — and used to leak the same way.
    func testDownwardNudgeFromTheScreenAboveStaysOffTheRetina() {
        let rect = windowRect(on: dellAbove, offset: -10)    // Style.hoverNudgeDistance
        XCTAssertFalse(rect.intersects(retina))
    }

    /// The rise still moves the window — and is small enough to stay on any real screen.
    func testRisingStaysWithinItsOwnScreen() {
        for screen in [retina, dellAbove] {
            let rect = windowRect(on: screen, offset: rise)
            XCTAssertTrue(screen.contains(CGRect(x: rect.minX, y: rect.minY,
                                                 width: min(rect.width, screen.width),
                                                 height: rect.height)),
                          "rise left \(screen)")
        }
    }
}
